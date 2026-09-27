import Foundation
import Ytb2ZHCore

// MARK: - OpenAI 兼容 TTS 引擎（POST /v1/audio/speech，任意兼容端点）

public struct OpenAITTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "openai-tts", "OpenAI 兼容 TTS", "/v1/audio/speech 接口，配合 synth.compat* 参数")
    public var supportsRateControl: Bool { false }

    public init() {}

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = probeDuration(mp3), cached >= 0.35 {
            return (mp3, cached)
        }
        guard !options.compatAPIKey.isEmpty else {
            throw EngineError.engineFailure("synth.compatAPIKey 未配置")
        }

        struct Body: Encodable {
            let model: String
            var voice: String
            let input: String
            let response_format: String
            var speed: Double?
        }
        let url = options.compatBaseURL.hasSuffix("/")
            ? options.compatBaseURL + "audio/speech" : options.compatBaseURL + "/audio/speech"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(options.compatAPIKey)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 120
        req.httpBody = try JSONEncoder().encode(Body(
            model: options.compatTTSModel, voice: options.voice,
            input: text, response_format: "mp3", speed: 1.0))

        var lastError = "unknown"
        for attempt in 0..<3 {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw EngineError.engineFailure("TTS 响应异常")
                }
                guard http.statusCode == 200 else {
                    lastError = "HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                guard data.count > 1000 else {
                    throw EngineError.engineFailure("音频过短 (\(data.count)B)")
                }
                try data.write(to: mp3)
                let dur = probeDuration(mp3) ?? 0
                try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
                if dur >= 0.35 { return (mp3, dur) }
                throw EngineError.engineFailure("合成时长异常 \(dur)s")
            } catch {
                lastError = error.localizedDescription
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw EngineError.engineFailure("OpenAI 兼容 TTS 失败：\(lastError)")
    }
}

// MARK: - Edge TTS 引擎（python -m edge_tts sidecar，免费微软神经语音）

public struct EdgeTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "edge-tts", "Edge TTS（免费）", "python -m edge_tts，需 pip install edge-tts")
    public var supportsRateControl: Bool { false }

    public init() {}

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = probeDuration(mp3), cached >= 0.35 {
            return (mp3, cached)
        }

        guard let python = SidecarPaths.which("python3") else {
            throw EngineError.engineFailure("未找到 python3")
        }
        try? fm.removeItem(at: mp3)
        let runner = ProcessRunner()
        // edge-tts 对微软端点时好时坏：5 次重试 + 递增退避
        var lastError = "unknown"
        for attempt in 0..<5 {
            // edge-tts 原生支持 --proxy（比环境变量透传可靠）
            var argv = ["-m", "edge_tts", "--voice", options.edgeVoice,
                        "--text", text, "--write-media", mp3.path]
            if !options.edgeProxy.isEmpty { argv += ["--proxy", options.edgeProxy] }
            let r = try runner.run(python, argv)
            if r.code == 0, fm.fileExists(atPath: mp3.path) {
                let dur = probeDuration(mp3) ?? 0
                try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
                if dur >= 0.35 { return (mp3, dur) }
                lastError = "合成时长异常 \(dur)s"
            } else {
                lastError = r.stderr.suffix(300).description
                if lastError.contains("No module named") {
                    throw EngineError.engineFailure("edge-tts 未安装：pip3 install edge-tts")
                }
            }
            try await Task.sleep(for: .seconds(3 * (attempt + 1)))
        }
        throw EngineError.engineFailure("Edge TTS 失败：\(lastError)")
    }
}
