import Foundation
import Ytb2ZHCore

// MARK: - yt-dlp 下载引擎（备用：按需下载的官方独立二进制，默认不随 App 分发）

public final class YtDlpDownloadEngine: DownloadEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "yt-dlp", "yt-dlp（备用）", "内置提取失败时按需下载的官方二进制；也可在引擎列表显式选用")

    private let runner = ProcessRunner()

    public init() {}

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 断点续跑：目标已是完整文件则跳过（缓存命中时无需准备二进制）
        if let size = fileSize(dest.path), size > 1_000_000 { return dest }
        // yt-dlp 可能落到其它扩展名（source.webm/mkv…）：dest 缺失但同前缀完整产物已存在也直接复用，
        // 避免管线二次调用时对同一视频完整重下（排除 .part / .ytdl 等未完成续传文件）
        let ignoredExts: Set<String> = ["json", "part", "ytdl", "temp"]
        if !ignoredExts.contains(dest.pathExtension.lowercased()) {
            let base = dest.deletingPathExtension().lastPathComponent
            let siblings = ((try? fm.contentsOfDirectory(at: dest.deletingLastPathComponent(),
                                                        includingPropertiesForKeys: nil)) ?? [])
                .filter {
                    $0.lastPathComponent.hasPrefix("\(base).")
                        && !ignoredExts.contains($0.pathExtension.lowercased())
                }
            if let any = siblings.first(where: { (fileSize($0.path) ?? 0) > 1_000_000 }) { return any }
        }
        // 真正需要下载时才确保二进制就绪（未安装则按需下载）
        _ = try await YtDlpInstaller.ensureInstalled(proxy: options.proxy)

        let outTpl = dest.deletingLastPathComponent()
            .appendingPathComponent("source.%(ext)s").path
        var args: [String] = []
        if !options.proxy.isEmpty { args += ["--proxy", options.proxy] }
        args += ["--no-playlist", "--continue", "--concurrent-fragments", "4",
                 "-f", options.format, "-o", outTpl, "--newline", url]
        // 备用二进制使用独立的 PO Token / JS 求解器配置；
        // 此路径不会自动复用应用内 WKWebView 的会话，受限格式的可用性由其配置决定。
        // 试转模式：只下载前 N 秒（download-sections 需 ffmpeg 切段合并，管线本就依赖 ffmpeg；
        // 关键帧处切段即可，时长略超无妨——Pipeline 会再统一精确截取）
        if let secs = options.partialSeconds, secs > 0 {
            args += ["--download-sections", String(format: "*0-%d", secs)]
        }

        let ytdlp = SidecarPaths.ytDlp
        let stderrTail = Mutex([String]())
        let result = try runner.run(ytdlp, args, onStdout: { chunk in
            for line in chunk.split(separator: "\n") where line.contains("[download]") {
                if let pct = Self.parseProgress(String(line)) {
                    progress(pct, line.trimmingCharacters(in: .whitespaces))
                }
            }
        }, onStderr: { s in
            stderrTail.with {
                $0.append(s)
                if $0.count > 40 { $0.removeFirst() }
            }
        })

        guard result.code == 0 else {
            let err = stderrTail.wrapped.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            throw EngineError.engineFailure("yt-dlp 下载失败：\(err.isEmpty ? "exit \(result.code)" : String(err.suffix(800)))")
        }

        // yt-dlp 可能落到 source.mp4 / source.webm / source.mkv 等
        let dir = dest.deletingLastPathComponent()
        let candidates = ((try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("source.") && !ignoredExts.contains($0.pathExtension.lowercased()) }
        if let mp4 = candidates.first(where: { $0.pathExtension == "mp4" }) { return mp4 }
        if let any = candidates.first { return any }
        throw EngineError.engineFailure("yt-dlp 未产出媒体文件")
    }

    private static func parseProgress(_ line: String) -> Double? {
        guard let range = line.range(of: #"\d+(?:\.\d+)?%"#, options: .regularExpression) else { return nil }
        return Double(line[range].dropLast())
    }
}

// MARK: - whisper.cpp 转录引擎（sidecar：whisper-cli，输出词级 JSON）

public final class WhisperCliEngine: TranscribeEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "whisper-cpp", "whisper.cpp（本地）", "ggml 模型，词级时间戳，M 系加速")

    private let runner = ProcessRunner()
    private var tickCounter = 0

    public init() {}

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let wav = workDir.appendingPathComponent("audio16k.wav")

        // 1) 抽 16k 单声道 wav
        progress(0.02, "抽取音轨")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000", wav.path])
        guard extract.code == 0 else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        // 2) 模型就绪（与内嵌引擎同一套解析/自动下载逻辑：显式路径直接用，
        //    已知模型名/留空/旧版 vid2zh 路径则下载默认 ggml-base.en）
        progress(0.03, "检查 whisper 模型")
        let model = try await ModelStore.ensureWhisperModel(configured: options.modelPath) { frac, msg in
            progress(0.03 + frac * 0.05, msg)
        }

        // 3) whisper-cli，-ojf 输出全量 token 时间戳（stderr 打进度，无真实百分比）
        progress(0.08, "开始转录（40 分钟视频约 4 分钟）")
        let jsonPath = workDir.appendingPathComponent("audio16k.json")
        tickCounter = 0
        let result = try runner.run(SidecarPaths.whisperCli,
            ["-m", model, "-l", options.language, "-f", wav.path,
             "-ojf", "-of", workDir.appendingPathComponent("audio16k").path],
            onStderr: { [weak self] _ in
                guard let self else { return }
                progress(min(0.9, 0.1 + self.nextTick()), "转录中")
            })
        guard result.code == 0 else {
            throw EngineError.engineFailure("whisper-cli 失败：\(String(result.stderr.suffix(400)))")
        }

        // 4) 解析 token 流
        guard let data = try? Data(contentsOf: jsonPath),
              let decoded = try? JSONDecoder().decode(WhisperJSON.self, from: data) else {
            throw EngineError.engineFailure("whisper 输出解析失败：\(jsonPath.path)")
        }
        var words: [TimedWord] = []
        for seg in decoded.transcription {
            for tok in seg.tokens {
                let text = tok.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // whisper -ojf 的 offsets 单位是毫秒
                words.append(TimedWord(start: Double(tok.offsets.from) / 1000.0,
                                       end: Double(tok.offsets.to) / 1000.0, text: text))
            }
        }
        progress(1.0, "\(words.count) 词")
        return words
    }

    private func nextTick() -> Double {
        tickCounter += 1
        return Double(tickCounter) * 0.002
    }
}

// MARK: - whisper JSON 结构

struct WhisperJSON: Decodable {
    struct Segment: Decodable {
        struct Token: Decodable {
            let text: String
            let offsets: Offsets
        }
        struct Offsets: Decodable {
            let from: Int
            let to: Int
        }
        let tokens: [Token]
    }
    let transcription: [Segment]
}

func fileSize(_ path: String) -> Int64? {
    guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
          let n = attrs[.size] as? NSNumber else { return nil }
    return n.int64Value
}

// MARK: - OpenAI 兼容语音识别引擎（POST /v1/audio/transcriptions，适配 OpenAI / Groq / 硅基流动 SenseVoice 等）

public final class OpenAITranscribeEngine: TranscribeEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "openai-asr", "OpenAI 兼容语音识别", "/v1/audio/transcriptions 接口（OpenAI Whisper / Groq / SenseVoice 等）")

    private let runner = ProcessRunner()

    public init() {}

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        let key = options.compatAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !OpenAICompatTranslateEngine.isLocalEndpoint(options.compatBaseURL) {
            throw EngineError.engineFailure("语音识别 API Key 未配置")
        }
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let mp3 = workDir.appendingPathComponent("audio16k.mp3")

        progress(0.05, "抽取压缩音轨")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000", "-b:a", "48k", mp3.path])
        guard extract.code == 0, let audioData = try? Data(contentsOf: mp3), !audioData.isEmpty else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        let trimmed = options.compatBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
        let urlString = trimmed.hasSuffix("/audio/transcriptions")
            ? trimmed : "\(trimmed)/audio/transcriptions"
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("语音识别地址无效：\(urlString)")
        }

        progress(0.2, "上传音轨识别中…")
        let boundary = "Boundary-\(UUID().uuidString)"
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 600

        let modelName = options.compatModel.isEmpty ? "whisper-1" : options.compatModel
        var body = Data()
        func appendField(_ name: String, _ value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }
        appendField("model", modelName)
        if !options.language.isEmpty {
            appendField("language", options.language)
        }
        appendField("response_format", "verbose_json")
        appendField("timestamp_granularities[]", "word")
        appendField("timestamp_granularities[]", "segment")
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"audio.mp3\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(audioData)
        body.append("\r\n--\(boundary)--\r\n".data(using: .utf8)!)
        req.httpBody = body

        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let status = (resp as? HTTPURLResponse)?.statusCode ?? -1
            let errText = String(data: data.prefix(400), encoding: .utf8) ?? ""
            throw EngineError.engineFailure("云端语音识别 HTTP \(status)：\(errText)")
        }
        let totalDur = ffprobeDuration(mp3) ?? 60.0
        let words = try Self.parseTranscriptionResponse(data: data, fallbackDuration: totalDur)
        progress(1.0, "\(words.count) 词")
        return words
    }

    static func parseTranscriptionResponse(data: Data, fallbackDuration: Double) throws -> [TimedWord] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.engineFailure("云端语音识别返回非 JSON")
        }
        // 1) 优先词级时间戳 words[]
        if let rawWords = obj["words"] as? [[String: Any]], !rawWords.isEmpty {
            let parsed = rawWords.compactMap { w -> TimedWord? in
                guard let text = (w["word"] as? String ?? w["text"] as? String)?.trimmingCharacters(in: .whitespaces),
                      !text.isEmpty,
                      let start = (w["start"] as? NSNumber)?.doubleValue,
                      let end = (w["end"] as? NSNumber)?.doubleValue else { return nil }
                return TimedWord(start: start, end: max(start + 0.05, end), text: " " + text)
            }
            if !parsed.isEmpty { return parsed }
        }
        // 2) 次选句级时间戳 segments[] → 按词均匀铺时间
        if let segs = obj["segments"] as? [[String: Any]], !segs.isEmpty {
            var words: [TimedWord] = []
            for seg in segs {
                guard let text = (seg["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !text.isEmpty,
                      let start = (seg["start"] as? NSNumber)?.doubleValue,
                      let end = (seg["end"] as? NSNumber)?.doubleValue else { continue }
                let toks = SrtTranscribeEngine.tokenize(text)
                guard !toks.isEmpty else { continue }
                let step = max(0.05, (end - start) / Double(toks.count))
                for (i, t) in toks.enumerated() {
                    let ws = start + Double(i) * step
                    words.append(TimedWord(start: ws, end: min(end, ws + step), text: " " + t.text))
                }
            }
            if !words.isEmpty { return words }
        }
        // 3) 兜底：仅有全文 text（如部分 SenseVoice 端点）
        if let text = (obj["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            let toks = SrtTranscribeEngine.tokenize(text)
            guard !toks.isEmpty else { return [] }
            let step = max(0.05, fallbackDuration / Double(toks.count))
            return toks.enumerated().map { i, t in
                let ws = Double(i) * step
                return TimedWord(start: ws, end: ws + step, text: " " + t.text)
            }
        }
        throw EngineError.engineFailure("云端语音识别结果为空")
    }
}
