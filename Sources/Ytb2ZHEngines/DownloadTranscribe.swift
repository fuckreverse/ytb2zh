import Foundation
import Ytb2ZHCore

// MARK: - yt-dlp 下载引擎（sidecar：捆绑的 yt-dlp_macos 二进制）

public final class YtDlpDownloadEngine: DownloadEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "yt-dlp", "yt-dlp（捆绑）", "官方 sidecar 二进制，带自动定位与代理解析")

    private let runner = ProcessRunner()

    public init() {}

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        // 断点续跑：目标已是完整文件则跳过
        if let size = fileSize(dest.path), size > 1_000_000 { return dest }

        let outTpl = dest.deletingLastPathComponent()
            .appendingPathComponent("source.%(ext)s").path
        var args: [String] = []
        if !options.proxy.isEmpty { args += ["--proxy", options.proxy] }
        args += ["--no-playlist", "--no-part", "-f", options.format,
                 "-o", outTpl, "--newline", url]

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
            .filter { $0.lastPathComponent.hasPrefix("source.") && $0.pathExtension != "json" }
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

        // 2) whisper-cli，-ojf 输出全量 token 时间戳（stderr 打进度，无真实百分比）
        progress(0.08, "开始转录（40 分钟视频约 4 分钟）")
        let model = (options.modelPath as NSString).expandingTildeInPath
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

        // 3) 解析 token 流
        guard let data = try? Data(contentsOf: jsonPath),
              let decoded = try? JSONDecoder().decode(WhisperJSON.self, from: data) else {
            throw EngineError.engineFailure("whisper 输出解析失败：\(jsonPath.path)")
        }
        var words: [TimedWord] = []
        for seg in decoded.transcription {
            for tok in seg.tokens {
                let text = tok.text.trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                words.append(TimedWord(start: Double(tok.offsets.from) / 100.0,
                                       end: Double(tok.offsets.to) / 100.0, text: text))
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
