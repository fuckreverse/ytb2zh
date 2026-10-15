import Foundation
import Ytb2ZHCore

// MARK: - 百炼 qwen-audio TTS 引擎（DashScope WebSocket 协议直连）
// 协议：run-task → task-started → continue-task(文本) → finish-task → 二进制帧收音频 → task-finished
// 幂等缓存：cacheDir/<cacheKey>.mp3 命中且非静音占位则直接返回。

public final class BailianSynthEngine: SpeechSynthesisEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "bailian", "百炼 qwen-audio TTS", "qwen-audio-3.1-tts-flash，WebSocket 流式，RPS=3")
    public var supportsRateControl: Bool { true }

    public init() {}

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = readDuration(mp3, durPath: durPath), cached >= 0.35 {
            return (mp3, cached)
        }

        var lastError: String = "unknown"
        for attempt in 0..<4 {
            do {
                let audio = try await Self.synthesizeWS(text: text, options: options)
                guard audio.count > 1000 else { throw EngineError.engineFailure("音频过短 (\(audio.count)B)") }
                try audio.write(to: mp3)
                let dur = probeDuration(mp3) ?? 0
                try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
                if dur >= 0.35 { return (mp3, dur) }
                throw EngineError.engineFailure("合成时长异常 \(dur)s")
            } catch {
                lastError = error.localizedDescription
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        // 静音占位降级（保持文件存在，调度器按 0.3s 处理）
        _ = try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                           "-i", "anullsrc=r=24000:cl=mono", "-t", "0.3", mp3.path])
        try? String("0.300").write(to: durPath, atomically: true, encoding: .utf8)
        throw EngineError.engineFailure("百炼合成失败（已占位）：\(lastError)")
    }

    // MARK: WebSocket 单次合成

    public static func synthesizeWS(text: String, options: SynthOptions) async throws -> Data {
        guard let url = URL(string: options.wsURL) else {
            throw EngineError.notConfigured("WS 地址无效：\(options.wsURL)")
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(options.apiKey)", forHTTPHeaderField: "Authorization")
        req.setValue("enable", forHTTPHeaderField: "X-DashScope-DataInspection")
        let task = URLSession.shared.webSocketTask(with: req)

        struct TaskHeader: Encodable { let action: String; let task_id: String; let streaming: String }
        struct Payload: Encodable {
            struct Params: Encodable {
                let voice: String
                let format: String
                let sample_rate: Int
                let rate: Double
                let word_timestamp_enabled: Bool
            }
            struct Input: Encodable { var text: String? }
            let task_group: String
            let task: String
            let function: String
            let model: String
            var parameters: Params?
            var input: Input
        }

        let taskID = UUID().uuidString
        func send(_ action: String, payload: Payload) async throws {
            let header = TaskHeader(action: action, task_id: taskID, streaming: "out")
            struct Envelope: Encodable { let header: TaskHeader; let payload: Payload }
            let data = try JSONEncoder().encode(Envelope(header: header, payload: payload))
            try await task.send(.string(String(data: data, encoding: .utf8)!))
        }

        let state = Mutex((audio: Data(), finished: false, failure: Optional<String>.none))

        try await task.resume()

        // run-task（qwen-audio TTS 非流式输入：文本直接随 run-task 下发）
        try await send("run-task", payload: Payload(
            task_group: "audio", task: "tts", function: "SpeechSynthesizer",
            model: options.model,
            parameters: .init(voice: options.voice, format: "mp3", sample_rate: 24000,
                              rate: options.effectiveRate, word_timestamp_enabled: false),
            input: .init(text: text)))

        func receiveLoop() async throws {
            while true {
                if state.wrapped.finished { return }
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    if let obj = try? JSONSerialization.jsonObject(with: Data(s.utf8)) as? [String: Any],
                       let header = obj["header"] as? [String: Any] {
                        let event = header["event"] as? String ?? ""
                        switch event {
                        case "task-started": break
                        case "task-finished":
                            state.with { $0.finished = true }
                        case "task-failed":
                            state.with {
                                $0.failure = (header["error_message"] as? String) ?? "task-failed"
                                $0.finished = true
                            }
                        default: break
                        }
                    }
                case .data(let d):
                    state.with { $0.audio.append(d) }
                @unknown default:
                    break
                }
            }
        }

        do {
            let receiver = Task { try await receiveLoop() }
            try await send("finish-task", payload: Payload(
                task_group: "audio", task: "tts", function: "SpeechSynthesizer",
                model: options.model, parameters: nil, input: .init()))
            try await withTimeout(seconds: 60) { try await receiver.value }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
        task.cancel(with: .goingAway, reason: nil)
        let final = state.wrapped
        if let failure = final.failure { throw EngineError.engineFailure("百炼 task-failed：\(failure)") }
        let audio = final.audio
        guard !audio.isEmpty else { throw EngineError.engineFailure("百炼未返回音频") }
        return audio
    }
}

// MARK: - 工具

public func probeDuration(_ url: URL) -> Double? {
    ffprobeDuration(url)
}

@discardableResult
public func runFFmpeg(_ args: [String]) throws -> (code: Int32, stdout: String, stderr: String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: SidecarPaths.ffmpeg)
    p.arguments = args
    let errPipe = Pipe()
    p.standardOutput = FileHandle.nullDevice
    p.standardError = errPipe
    try p.run()
    p.waitUntilExit()
    let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    guard p.terminationStatus == 0 else {
        throw EngineError.engineFailure("ffmpeg 失败：\(String(err.suffix(400)))")
    }
    return (p.terminationStatus, "", err)
}

/// ffmpeg atempo 单实例有效范围 [0.5, 2.0]；超出（如语速 2.0 × 调度加速 1.3 = 2.6）需链式拆分，
/// 各段乘积为目标倍率。atempo 保持音高，链式段数越多代价略增，正常范围内仍是单段。
public func atempoChain(_ rate: Double) -> String {
    guard rate.isFinite, rate > 0.05 else { return "atempo=1.0000" }
    var r = rate
    var parts: [String] = []
    while r > 2.0 { parts.append("atempo=2.0000"); r /= 2.0 }
    while r < 0.5 { parts.append("atempo=0.5000"); r /= 0.5 }
    parts.append(String(format: "atempo=%.4f", r))
    return parts.joined(separator: ",")
}

func readDuration(_ mp3: URL, durPath: URL) -> Double? {
    if let s = try? String(contentsOf: durPath, encoding: .utf8),
       let d = Double(s.trimmingCharacters(in: .whitespaces)) { return d }
    guard let d = probeDuration(mp3) else { return nil }
    try? String(format: "%.3f", d).write(to: durPath, atomically: true, encoding: .utf8)
    return d
}

func withTimeout(seconds: TimeInterval, _ body: @escaping @Sendable () async throws -> Void) async throws {
    try await withThrowingTaskGroup(of: Void.self) { group in
        group.addTask { try await body() }
        group.addTask {
            try await Task.sleep(for: .seconds(seconds))
            throw EngineError.engineFailure("等待超时 \(seconds)s")
        }
        try await group.next()
        group.cancelAll()
        // 吞掉被取消任务的错误
        _ = try? await group.waitForAll()
    }
}
