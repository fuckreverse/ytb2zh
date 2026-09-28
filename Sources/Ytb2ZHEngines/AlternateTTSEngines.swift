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

// MARK: - Edge TTS 引擎（纯 Swift 直连微软端点，免费神经语音，零外部依赖）

public struct EdgeTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "edge-tts", "Edge TTS（免费·内置）", "纯 Swift 直连微软端点，无需安装任何依赖")
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

        // 微软端点时好时坏：5 次重试 + 递增退避；每次重试重新生成 Sec-MS-GEC 令牌
        var lastError = "unknown"
        for attempt in 0..<5 {
            do {
                let data = try await EdgeTTSClient(proxy: options.edgeProxy)
                    .synthesize(text: text, voice: options.edgeVoice)
                try data.write(to: mp3)
                let dur = probeDuration(mp3) ?? 0
                try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
                if dur >= 0.35 { return (mp3, dur) }
                lastError = "合成时长异常 \(dur)s"
            } catch {
                lastError = error.localizedDescription
                if lastError.contains("未安装") { throw error }  // 保留语义兼容，纯 Swift 实现下不应出现
            }
            try await Task.sleep(for: .seconds(3 * (attempt + 1)))
        }
        throw EngineError.engineFailure("Edge TTS 失败：\(lastError)")
    }
}
