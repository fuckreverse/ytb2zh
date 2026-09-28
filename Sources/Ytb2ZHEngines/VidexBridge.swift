import Foundation
import Ytb2ZHCore
import Videx

// MARK: - Videx 桥接：原生 Swift 提取库接入下载/元数据/原声播放

/// Videx 支持的站点判定与提取（YouTube / Bilibili / 抖音 / TikTok）。
public enum VidexBridge {

    /// Videx 能否处理该 URL（不发网络请求）。
    public static func canHandle(_ url: String) -> Bool {
        guard let u = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return false }
        return ExtractorRegistry.standard.extractor(for: u) != nil
    }

    /// 提取 MediaInfo（原生 async）。
    public static func extract(_ url: String, proxy: String) async throws -> MediaInfo {
        let u = try Self.validatedURL(url)
        var options = ExtractionOptions(proxy: proxy.isEmpty ? nil : proxy)
        options.log = StderrLogSink(minLevel: .warn)
        return try await ExtractorRegistry.standard.extract(url: u, options: options)
    }

    /// 同步桥：供旧的同步 API（VideoInfoService / OrigStreamService）调用。
    /// 调用方应处于后台线程。
    public static func extractSync(_ url: String, proxy: String) throws -> MediaInfo {
        var result: Result<MediaInfo, Error>?
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do { result = .success(try await extract(url, proxy: proxy)) }
            catch { result = .failure(error) }
            semaphore.signal()
        }
        semaphore.wait()
        return try result!.get()
    }

    static func validatedURL(_ url: String) throws -> URL {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let u = URL(string: trimmed), u.host != nil else {
            throw EngineError.engineFailure("非法链接：\(url.prefix(80))")
        }
        return u
    }

    // MARK: - MediaInfo → VideoDetails（媒体库详情）

    public static func toDetails(_ info: MediaInfo, url: String) -> VideoDetails {
        VideoDetails(
            url: url,
            title: info.title,
            videoDescription: info.videoDescription,
            channel: info.uploader,
            channelURL: info.channelID.flatMap { id in
                switch info.extractorID {
                case "youtube": "https://www.youtube.com/@\(id)"
                case "bilibili": "https://space.bilibili.com/\(id)"
                default: nil
                }
            },
            uploadDate: info.uploadDate,
            duration: info.duration ?? 0,
            viewCount: info.viewCount.map(Int.init),
            likeCount: info.extras["likeCount"].flatMap(Int.init),
            tags: [],
            thumbnail: info.thumbnailURL?.absoluteString
        )
    }

    // MARK: - MediaInfo → OrigStreamInfo（原声播放）

    /// 挑选可播流：优先 muxed ≤720p（avc1/AAC 偏好）。拿不到 muxed 返回 nil，
    /// 由调用方回退 yt-dlp 的 HLS 路线。
    public static func playableStream(_ info: MediaInfo) -> OrigStreamInfo? {
        let muxed = info.formats.filter { $0.kind == .muxed && $0.height.map { $0 <= 720 } ?? true }
        let best = muxed.max { a, b in
            let avcA = a.videoCodec?.contains("avc1") == true || a.videoCodec?.contains("h264") == true
            let avcB = b.videoCodec?.contains("avc1") == true || b.videoCodec?.contains("h264") == true
            if avcA != avcB { return !avcA }
            return (a.height ?? 0, a.averageBitrate ?? 0) < (b.height ?? 0, b.averageBitrate ?? 0)
        }
        guard let best else { return nil }
        return OrigStreamInfo(
            kind: .progressive(url: best.url.absoluteString),
            title: info.title,
            duration: info.duration ?? 0
        )
    }
}

// MARK: - 下载引擎

/// Videx 原生下载引擎：提取 → URLSession 直下（muxed）或 ffmpeg 合流（DASH）。
/// 支持代理、断点续跑判定、试转截段；不依赖 yt-dlp 二进制。
public final class VidexDownloadEngine: DownloadEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "videx", "Videx（原生提取）", "纯 Swift 提取 YouTube/B站/抖音/TikTok，无外部二进制依赖")

    public init() {}

    // MARK: DownloadEngine

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)

        // 断点续跑：目标已是完整文件则跳过（与 yt-dlp 引擎约定一致）
        if let size = fileSize(dest.path), size > 1_000_000 { return dest }

        // 1. 提取
        progress(0.02, "Videx 解析视频信息")
        let info = try await VidexBridge.extract(url, proxy: options.proxy)
        progress(0.08, "已解析：\(info.title)")
        guard !info.formats.isEmpty else {
            throw EngineError.engineFailure("Videx：未解析到可用流")
        }

        // 2. 选流（按 yt-dlp -f 表达式的意图：height<=N 限制 + avc1 偏好）
        let (maxHeight, preferAVC) = Self.parseFormatIntent(options.format)
        let selection = Self.select(info, maxHeight: maxHeight, preferAVC: preferAVC)

        // 3. 下载（muxed 直下 / DASH 合流）
        let referer = ["tiktok", "douyin"].contains(info.extractorID) ? info.webpageURL : nil
        switch selection {
        case .single(let format):
            let target = Self.destURL(for: format, base: dest)
            try await Self.fetch(format.url, to: target, proxy: options.proxy,
                                 referer: referer?.absoluteString,
                                 range: 0.1...0.95, progress: progress)
            progress(0.97, "下载完成")
            try await Self.cutIfPartial(target, seconds: options.partialSeconds)
            return target

        case .merge(let video, let audio):
            let videoFile = fm.temporaryDirectory
                .appendingPathComponent("videx-video-\(UUID().uuidString).\(video.container ?? "mp4")")
            let audioFile = fm.temporaryDirectory
                .appendingPathComponent("videx-audio-\(UUID().uuidString).\(audio.container ?? "m4a")")
            defer { try? fm.removeItem(at: videoFile); try? fm.removeItem(at: audioFile) }

            try await Self.fetch(video.url, to: videoFile, proxy: options.proxy,
                                 referer: referer?.absoluteString,
                                 range: 0.1...0.55, progress: progress,
                                 fallbackURLs: video.backupURLs)
            try await Self.fetch(audio.url, to: audioFile, proxy: options.proxy,
                                 referer: referer?.absoluteString,
                                 range: 0.55...0.85, progress: progress,
                                 fallbackURLs: audio.backupURLs)

            progress(0.87, "ffmpeg 合流")
            let target = Self.destURL(for: video, base: dest)
            try Self.merge(video: videoFile, audio: audioFile, to: target)
            progress(0.97, "合流完成")
            try await Self.cutIfPartial(target, seconds: options.partialSeconds)
            return target
        }
    }

    // MARK: - 选流

    enum Selection {
        /// 单文件（muxed 或纯音频幻灯片）
        case single(MediaFormat)
        /// DASH：视频流 + 音频流，需 ffmpeg 合流
        case merge(video: MediaFormat, audio: MediaFormat)
    }

    /// 解析 yt-dlp -f 表达式的意图：`height<=720` → 高度上限；含 "avc1" → 偏好 H.264。
    static func parseFormatIntent(_ expr: String) -> (maxHeight: Int?, preferAVC: Bool) {
        var maxHeight: Int?
        if let range = expr.range(of: #"height<=(\d+)"#, options: .regularExpression) {
            let digits = expr[range].drop { !$0.isNumber }
            maxHeight = Int(digits)
        }
        return (maxHeight, expr.contains("avc1"))
    }

    /// 选流纯函数（供测试）：muxed 优先，其次 DASH 合流，最后纯音频。
    static func select(_ info: MediaInfo, maxHeight: Int?, preferAVC: Bool) -> Selection {
        func heightOK(_ f: MediaFormat) -> Bool {
            guard let maxHeight else { return true }
            // 高度未知（nil）的流保守保留；已知则按上限过滤
            return f.height.map { $0 <= maxHeight } ?? true
        }
        func isAVC(_ f: MediaFormat) -> Bool {
            f.videoCodec?.contains("avc1") == true || f.videoCodec?.contains("h264") == true
        }
        func rank(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
            if preferAVC {
                let avcA = isAVC(a), avcB = isAVC(b)
                if avcA != avcB { return !avcA }   // avc 优先
            }
            return (a.height ?? 0, a.averageBitrate ?? 0) < (b.height ?? 0, b.averageBitrate ?? 0)
        }

        // 1. muxed（字节系全是 muxed；YouTube 有 itag 18/22）
        if let best = info.formats.filter({ $0.kind == .muxed && heightOK($0) }).max(by: rank) {
            return .single(best)
        }
        // 2. DASH：最佳视频流 + 最佳音频流
        let videos = info.formats.filter { $0.kind == .videoOnly && heightOK($0) }
        let audios = info.formats.filter { $0.kind == .audioOnly }
        if let v = videos.max(by: rank), let a = audios.max(by: rank) {
            return .merge(video: v, audio: a)
        }
        // 3. 只有音频（幻灯片/图集）
        if let a = audios.max(by: rank) { return .single(a) }
        // 兜底：任意一条
        if let any = info.formats.first { return .single(any) }
        return .single(MediaFormat(formatID: "none", kind: .muxed,
                                   url: URL(string: "about:blank")!))
    }

    // MARK: - 文件下载（URLSessionDownloadDelegate，带代理与进度）

    final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Double, String?) -> Void
        let range: ClosedRange<Double>
        let label: String
        let expectedSize: Int64?
        var continuation: CheckedContinuation<URL, Error>?
        /// 目标路径：必须在 didFinishDownloadingTo 回调内完成移动（回调返回后 tmp 会被系统回收）
        let destination: URL

        init(progress: @escaping @Sendable (Double, String?) -> Void,
             range: ClosedRange<Double>, label: String, expectedSize: Int64?,
             destination: URL) {
            self.progress = progress
            self.range = range
            self.label = label
            self.expectedSize = expectedSize
            self.destination = destination
        }

        func run(_ url: URL, proxy: String, referer: String?) async throws -> URL {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 60
            config.timeoutIntervalForResource = 3600
            if !proxy.isEmpty {
                config.connectionProxyDictionary = URLSessionHTTPClient.proxyDictionary(from: proxy)
            }
            let session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            defer { session.finishTasksAndInvalidate() }

            var request = URLRequest(url: url)
            request.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36",
                             forHTTPHeaderField: "User-Agent")
            if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }

            return try await withCheckedThrowingContinuation { cont in
                self.continuation = cont
                session.downloadTask(with: request).resume()
            }
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                        totalBytesExpectedToWrite: Int64) {
            let total = totalBytesExpectedToWrite > 0
                ? totalBytesExpectedToWrite
                : (expectedSize ?? 0)
            let fraction = total > 0 ? Double(totalBytesWritten) / Double(total) : 0
            let pct = range.lowerBound + (range.upperBound - range.lowerBound) * min(1, fraction)
            progress(pct, "\(label) \(Int(fraction * 100))%")
        }

        func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                        didFinishDownloadingTo location: URL) {
            guard let continuation else { return }
            self.continuation = nil
            do {
                let fm = FileManager.default
                try? fm.removeItem(at: destination)
                try fm.moveItem(at: location, to: destination)
                continuation.resume(returning: destination)
            } catch {
                continuation.resume(throwing: error)
            }
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            guard let error, let continuation else { return }
            self.continuation = nil
            continuation.resume(throwing: EngineError.engineFailure(
                "Videx 下载失败：\(error.localizedDescription)"))
        }
    }

    /// 下载（主 URL 失败自动切换备用 CDN），落盘到 target。
    static func fetch(_ url: URL, to target: URL, proxy: String, referer: String?,
                      range: ClosedRange<Double>, progress: @escaping @Sendable (Double, String?) -> Void,
                      fallbackURLs: [URL]? = nil) async throws {
        let candidates = [url] + (fallbackURLs ?? [])
        var lastError: Error = EngineError.engineFailure("无下载地址")
        for candidate in candidates {
            do {
                let downloader = Downloader(progress: progress, range: range, label: "下载",
                                            expectedSize: nil, destination: target)
                _ = try await downloader.run(candidate, proxy: proxy, referer: referer)
                return
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    /// ffmpeg 合流（-c copy 不重编码；mp4 输出需要 +faststart 便于边下边播）。
    static func merge(video: URL, audio: URL, to target: URL) throws {
        let output = target.pathExtension.lowercased() == "webm" ? ["-f", "webm"] : ["-movflags", "+faststart"]
        let result = try ProcessRunner().run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-i", audio.path, "-c", "copy"] + output + [target.path])
        guard result.code == 0, FileManager.default.fileExists(atPath: target.path) else {
            throw EngineError.engineFailure("Videx 合流失败：\(String(result.stderr.suffix(400)))")
        }
    }

    /// 试转模式：截取前 N 秒（-c copy 关键帧切割）。
    static func cutIfPartial(_ file: URL, seconds: Int?) async throws {
        guard let seconds, seconds > 0 else { return }
        let cut = file.deletingLastPathComponent()
            .appendingPathComponent("videx-cut-\(UUID().uuidString).\(file.pathExtension)")
        let result = try ProcessRunner().run(SidecarPaths.ffmpeg,
            ["-y", "-i", file.path, "-t", String(seconds), "-c", "copy", cut.path])
        guard result.code == 0 else {
            try? FileManager.default.removeItem(at: cut)
            return   // 截段失败不致命，保留完整文件
        }
        _ = try? FileManager.default.replaceItemAt(file, withItemAt: cut)
    }

    /// 按容器扩展名决定最终文件名（dest 通常是 source.mp4；webm 场景落 source.webm）。
    static func destURL(for format: MediaFormat, base dest: URL) -> URL {
        let container = (format.container ?? "mp4").lowercased()
        if dest.pathExtension.lowercased() == container { return dest }
        return dest.deletingLastPathComponent()
            .appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent).\(container)")
    }
}
