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
    ///
    /// Acquire video/session-bound WebPO tokens using the same cookies and proxy as extraction.
    /// Fall back to token-free extraction when the provider is unavailable. Media refresh
    /// explicitly renews rejected tokens and keeps the existing network route.
    public static func extract(_ url: String, proxy: String, refreshPoToken: Bool = false) async throws -> MediaInfo {
        let u = try Self.validatedURL(url)
        let isYouTube = YouTubeExtractor().canHandle(u)
        let cookies = try loadCookies(for: u)
        let videoID = YouTubeURL.videoID(from: u)
        let enabled = isYouTube && WebPotHarvestSetting.enabled
        let scope = WebPoTokenProvider.scope(videoID: videoID, proxy: proxy.isEmpty ? nil : proxy, cookies: cookies)
        if refreshPoToken { WebPoTokenProvider.invalidate(scope: scope) }
        var cached = enabled ? WebPoTokenProvider.cached(scope: scope) : nil
        if enabled && cached == nil {
            do {
                cached = try await WebPoTokenProvider.harvest(videoID: videoID, cookies: cookies,
                    proxy: proxy.isEmpty ? nil : proxy, bypassThrottle: refreshPoToken, log: { Self.stderr($0 + "\n") })
            } catch {
                Self.stderr("Videx: native POT unavailable; continuing token-free extraction: \(error.localizedDescription)\n")
            }
        }

        var lastError: Error
        do {
            return try await extractOnce(u, proxy: proxy, pot: cached)
        } catch {
            lastError = error
        }

        if !refreshPoToken, !proxy.isEmpty, let e = lastError as? ExtractionError, Self.isRiskControlFailure(e) {
            Self.stderr("Videx: 代理出口疑似被风控（\(e.localizedDescription.prefix(120))），直连重试\n")
            do {
                let directScope = WebPoTokenProvider.scope(videoID: videoID, proxy: nil, cookies: cookies)
                return try await extractOnce(u, proxy: "", pot: enabled ? WebPoTokenProvider.cached(scope: directScope) : nil)
            }
            catch { lastError = error }
        }

        // Web PO Token 收割兜底（仅 YouTube，且只在错误属于风控/POT 类时）
        if isYouTube, let e = lastError as? ExtractionError, Self.shouldHarvestPOT(e),
           WebPotHarvestSetting.enabled {
            do {
                Self.stderr("Videx: 尝试用内置 WebView 收割 PO Token（\(e.localizedDescription.prefix(100))）\n")
                let retryProxy = refreshPoToken ? proxy : ""
                let fresh = try await WebPoTokenProvider.harvest(videoID: videoID, cookies: cookies, proxy: retryProxy.isEmpty ? nil : retryProxy, bypassThrottle: true) { line in Self.stderr(line + "\n") }
                return try await extractOnce(u, proxy: retryProxy, pot: fresh)
            } catch {
                // 收割失败（网络/平台限制）不掩盖原始提取错误，只补充诊断
                Self.stderr("Videx: POT 重试未成功（\(error.localizedDescription)），维持原错误\n")
                WebPoTokenProvider.invalidate(scope: scope)
            }
        }
        throw lastError
    }

    /// 单次提取（内部）：日志走 stderr，便于 GUI 外调试。
    /// - Parameter pot: 收割到的 (visitorData, PO Token) 组合；两者必须成对注入。
    private static func extractOnce(_ url: URL, proxy: String, pot: HarvestedPoToken?) async throws -> MediaInfo {
        var cookies = try loadCookies(for: url)
        if let sessionCookies = pot?.cookies { cookies = sessionCookies }
        var options = ExtractionOptions(proxy: proxy.isEmpty ? nil : proxy, cookies: cookies)
        options.log = StderrLogSink(minLevel: .warn)
        if let pot {
            options.youtubeVisitorData = pot.visitorData
            if let videoID = YouTubeURL.videoID(from: url) {
                options.youtubePoTokens = pot.tokens(for: videoID)
            }
        }
        var info: MediaInfo
        if let userAgent = pot?.userAgent, let extractor = ExtractorRegistry.standard.extractor(for: url) {
            let context = ExtractionContext.make(options: options, httpFactory: { options in
                PoTokenSessionHTTPClient(base: URLSessionHTTPClient(proxy: options.proxy, timeout: options.timeout), userAgent: userAgent)
            })
            info = try await extractor.extract(url, context: context)
        } else { info = try await ExtractorRegistry.standard.extract(url: url, options: options) }
        info.extras["videx_proxy"] = proxy
        if let pot {
            var headers: [String: String] = [:]
            if let ua = pot.userAgent { headers["User-Agent"] = ua }
            for index in info.subtitles.indices {
                var requestHeaders = headers
                if let cookie = cookies.header(for: info.subtitles[index].url) { requestHeaders["Cookie"] = cookie }
                info.subtitles[index].requestHeaders = requestHeaders
            }
            for index in info.formats.indices {
                var requestHeaders = info.formats[index].requestHeaders ?? [:]
                requestHeaders.merge(headers) { _, new in new }
                if let cookie = cookies.header(for: info.formats[index].url) { requestHeaders["Cookie"] = cookie }
                info.formats[index].requestHeaders = requestHeaders
                if let ua = pot.userAgent { info.formats[index].sabr?.userAgent = ua }
            }
        }
        return info
    }

    private static func loadCookies(for url: URL) throws -> CookieJar {
        var cookies = CookieJar()
        let cookiePath = UserDefaults.standard.string(forKey: "youtubeCookieFile") ?? ""
        if YouTubeExtractor().canHandle(url), !cookiePath.isEmpty {
            let source = UserDefaults.standard.string(forKey: "youtubeCookieSource") ?? "netscape"
            let file = URL(fileURLWithPath: cookiePath)
            switch source {
            case "firefox": cookies = try BrowserCookies.firefox(database: file)
            case "chrome": cookies = try BrowserCookies.chromium(database: file)
            case "safari": cookies = try BrowserCookies.safari(file: file)
            default: cookies = try CookieJar(netscape: String(contentsOfFile: cookiePath, encoding: .utf8))
            }
        }
        return cookies
    }

    /// WebPO clients supported by the native provider; native Android/iOS attestation is separate.
    static let webFamilyClientKeys = ["web", "web_safari", "web_embedded", "mweb", "tv_samsung", "tv_downgraded", "tv_simply"]

    /// 是否值得「收割新 POT 再试一次」：风控/不可提取类（含缺 POT 导致的空格式）。
    static func shouldHarvestPOT(_ error: ExtractionError) -> Bool {
        switch error {
        case .loginRequired, .notExtractable:
            return true
        case .siteError, .network, .jsFailure, .parse, .unsupportedURL, .malformedURL:
            return false
        }
    }

    private static func stderr(_ message: String) {
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// 是否「风控/登录」类失败（值得直连重试的那种）。
    private static func isRiskControlFailure(_ error: ExtractionError) -> Bool {
        switch error {
        case .loginRequired, .notExtractable, .siteError:
            return true
        case .network, .jsFailure, .parse, .unsupportedURL, .malformedURL:
            return false
        }
    }

    /// 同步桥：供旧的同步 API（VideoInfoService / OrigStreamService）调用。
    /// 调用方应处于后台线程。
    public static func extractSync(_ url: String, proxy: String) throws -> MediaInfo {
        let result = Mutex<Result<MediaInfo, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let info = try await extract(url, proxy: proxy)
                result.with { $0 = .success(info) }
            } catch {
                result.with { $0 = .failure(error) }
            }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.with { try $0!.get() }
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
        let muxed = info.formats.filter { $0.kind == .muxed && $0.protocolType == .https && ($0.height.map { $0 <= 720 } ?? false) }
        let best = muxed.max { a, b in
            let avcA = a.videoCodec?.contains("avc1") == true || a.videoCodec?.contains("h264") == true
            let avcB = b.videoCodec?.contains("avc1") == true || b.videoCodec?.contains("h264") == true
            if avcA != avcB { return !avcA }
            return (a.height ?? 0, a.averageBitrate ?? 0) < (b.height ?? 0, b.averageBitrate ?? 0)
        }
        guard let best else {
            let hls = info.formats.filter { $0.protocolType == .hls }
            if let muxed = hls.filter({ $0.kind == .muxed && ($0.height.map { $0 <= 720 } ?? false) }).max(by: { ($0.height ?? 0) < ($1.height ?? 0) }) {
                return OrigStreamInfo(kind: .hls(video: muxed.url.absoluteString, audio: ""), title: info.title, duration: info.duration ?? 0, proxyOverride: info.extras["videx_proxy"], requestHeaders: muxed.requestHeaders ?? [:])
            }
            let videos = hls.filter { $0.kind == .videoOnly && ($0.height.map { $0 <= 720 } ?? false) }
            let video = videos.max { a, b in
                let avcA = a.videoCodec?.hasPrefix("avc1") == true
                let avcB = b.videoCodec?.hasPrefix("avc1") == true
                if avcA != avcB { return !avcA }
                return (a.height ?? 0) < (b.height ?? 0)
            }
            let audio = hls.filter { $0.kind == .audioOnly }.max { a, b in
                let aacA = a.audioCodec?.hasPrefix("mp4a") == true
                let aacB = b.audioCodec?.hasPrefix("mp4a") == true
                if aacA != aacB { return !aacA }
                return (a.averageBitrate ?? 0) < (b.averageBitrate ?? 0)
            }
            if let video, let audio {
                return OrigStreamInfo(kind: .hls(video: video.url.absoluteString, audio: audio.url.absoluteString), title: info.title, duration: info.duration ?? 0, proxyOverride: info.extras["videx_proxy"], requestHeaders: video.requestHeaders ?? [:])
            }
            return nil
        }
        return OrigStreamInfo(
            kind: .progressive(url: best.url.absoluteString),
            title: info.title,
            duration: info.duration ?? 0, proxyOverride: info.extras["videx_proxy"], requestHeaders: best.requestHeaders ?? [:]
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
        let completionURL = dest.appendingPathExtension("videx-complete.json")
        let identity = [url, options.format, String(options.partialSeconds ?? 0), String(options.startSeconds),
                        String(options.durationSeconds ?? 0), String(options.liveFromStart)].joined(separator: "|")
        if let data = try? Data(contentsOf: completionURL), let completed = try? JSONDecoder().decode(Completion.self, from: data),
           completed.identity == identity, let size = fileSize(completed.output.path), size == completed.bytes, size > 0 {
            return completed.output
        }
        progress(0.02, "Videx 解析视频信息")
        let info = try await VidexBridge.extract(url, proxy: options.proxy)
        let resolvedProxy = info.extras["videx_proxy"] ?? options.proxy
        let selections = try FormatSelector.select(info, expression: options.format)
        let work = dest.deletingLastPathComponent().appendingPathComponent(".videx-download", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var outputs: [URL] = []
        for (selectionIndex, selection) in selections.enumerated() {
            let formatCount = max(1, selection.formats.count)
            let trackFractions = Mutex(Array(repeating: 0.0, count: formatCount))
            let referer = ["tiktok", "douyin"].contains(info.extractorID) ? info.webpageURL.absoluteString : nil
            let partialSeconds = options.partialSeconds
            let startSeconds = options.startSeconds
            let durationSeconds = options.durationSeconds
            let liveFromStart = options.liveFromStart
            let rateLimit = options.rateLimitBytesPerSecond

            let indexedInputs: [(Int, MediaFormat, URL)] = try await withThrowingTaskGroup(of: (Int, MediaFormat, URL).self) { group in
                for (index, format) in selection.formats.enumerated() {
                    let component = format.formatID.replacingOccurrences(of: #"[^A-Za-z0-9._-]"#, with: "_", options: .regularExpression)
                    let local = work.appendingPathComponent("\(selectionIndex)-\(index)-\(component).\(format.container ?? "mp4")")
                    let refresh: @Sendable () async throws -> MediaFormat = {
                        let updated = try await VidexBridge.extract(url, proxy: resolvedProxy, refreshPoToken: true)
                        guard let match = updated.formats.first(where: {
                            $0.formatID == format.formatID && $0.protocolType == format.protocolType
                                && $0.audioTrackID == format.audioTrackID && $0.isDRC == format.isDRC
                        }) else { throw EngineError.engineFailure("媒体地址刷新后原格式不可用") }
                        return match
                    }
                    let trackProgress: @Sendable (Double, String?) -> Void = { frac, msg in
                        let avg = trackFractions.with { arr -> Double in
                            arr[index] = min(1, max(0, frac))
                            return arr.reduce(0, +) / Double(formatCount)
                        }
                        progress(0.08 + (0.85 - 0.08) * avg, msg)
                    }
                    group.addTask {
                        try await Self.fetchFormat(format, to: local, proxy: resolvedProxy, referer: referer,
                            range: 0.0...1.0, progress: trackProgress,
                            partialSeconds: partialSeconds, refresh: refresh,
                            startSeconds: startSeconds, durationSeconds: durationSeconds,
                            liveFromStart: liveFromStart, rateLimit: rateLimit)
                        return (index, format, local)
                    }
                }
                var collected: [(Int, MediaFormat, URL)] = []
                for try await item in group {
                    collected.append(item)
                }
                return collected.sorted { $0.0 < $1.0 }
            }
            let inputs = indexedInputs.map { ($0.1, $0.2) }
            guard let first = inputs.first else { throw EngineError.engineFailure("格式选择为空") }
            let base = selectionIndex == 0 ? dest : dest.deletingLastPathComponent().appendingPathComponent("\(dest.deletingPathExtension().lastPathComponent)-\(selectionIndex).\(dest.pathExtension)")
            let target = Self.destURL(for: first.0, base: base)
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".\(target.lastPathComponent).remux.\(target.pathExtension)")
            var args = ["-y"]
            for (_, input) in inputs { args += ["-i", input.path] }
            for (index, pair) in inputs.enumerated() {
                if pair.0.kind != .audioOnly { args += ["-map", "\(index):v:0?"] }
                if pair.0.kind != .videoOnly { args += ["-map", "\(index):a:0?"] }
            }
            if options.startSeconds > 0 && !selection.formats.contains(where: { $0.protocolType == .sabr }) {
                args += ["-ss", String(options.startSeconds)]
            }
            if let seconds = options.durationSeconds ?? options.partialSeconds.map(Double.init), seconds > 0 { args += ["-t", String(seconds)] }
            args += ["-c", "copy"]
            if target.pathExtension.lowercased() == "mp4" { args += ["-movflags", "+faststart"] }
            args += [temporary.path]
            progress(0.9, "封装媒体文件")
            let result = try ProcessRunner().run(SidecarPaths.ffmpeg, args)
            guard result.code == 0, (fileSize(temporary.path) ?? 0) > 0 else {
                try? fm.removeItem(at: temporary)
                throw EngineError.engineFailure("Videx 封装失败：\(String(result.stderr.suffix(500)))")
            }
            if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
            try fm.moveItem(at: temporary, to: target)
            outputs.append(target)
        }
        guard let output = outputs.first else { throw EngineError.engineFailure("未产生下载文件") }
        try JSONEncoder().encode(Completion(identity: identity, output: output, bytes: fileSize(output.path) ?? 0)).write(to: completionURL, options: .atomic)
        try? fm.removeItem(at: work)
        progress(1, "下载完成")
        return output
    }

    private struct Completion: Codable {
        var identity: String
        var output: URL
        var bytes: Int64
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

    /// 选流纯函数：同编码偏好下保留高清优先；同画质可用合一流，避免额外合流。
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

        let muxed = info.formats.filter { $0.kind == .muxed && heightOK($0) }.max(by: rank)
        let video = info.formats.filter { $0.kind == .videoOnly && heightOK($0) }.max(by: rank)
        let audios = info.formats.filter { $0.kind == .audioOnly }
        let audio = audios.max { a, b in
            let aacA = a.audioCodec?.hasPrefix("mp4a") == true
            let aacB = b.audioCodec?.hasPrefix("mp4a") == true
            if preferAVC && aacA != aacB { return !aacA }
            return (a.averageBitrate ?? 0) < (b.averageBitrate ?? 0)
        }
        if let video, let audio, muxed == nil || rank(muxed!, video) {
            return .merge(video: video, audio: audio)
        }
        if let muxed { return .single(muxed) }
        // 3. 只有音频（幻灯片/图集）
        if let a = audios.max(by: rank) { return .single(a) }
        // 兜底：任意一条
        if let any = info.formats.first { return .single(any) }
        return .single(MediaFormat(formatID: "none", kind: .muxed,
                                   url: URL(string: "about:blank")!))
    }

    // MARK: - 文件下载（统一走 NativeMediaDownloader 多并发 + 断点续传底层）

    /// HLS must be demuxed/remuxed, never saved as a playlist pretending to be MP4.
    static func fetchFormat(_ original: MediaFormat, to target: URL, proxy: String, referer: String?,
                            range: ClosedRange<Double>, progress: @escaping @Sendable (Double, String?) -> Void,
                            partialSeconds: Int? = nil,
                            refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                            startSeconds: Double = 0, durationSeconds: Double? = nil,
                            liveFromStart: Bool = false, rateLimit: Int? = nil) async throws {
        var format = original
        if format.requestHeaders?["User-Agent"] == nil {
            format.requestHeaders = (format.requestHeaders ?? [:]).merging(["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]) { _, new in new }
        }
        if let referer { format.requestHeaders = (format.requestHeaders ?? [:]).merging(["Referer": referer]) { _, new in new } }
        let http: HTTPFetching = RateLimitedHTTPClient(base: URLSessionHTTPClient(proxy: proxy.isEmpty ? nil : proxy), bytesPerSecond: rateLimit)
        let length = durationSeconds ?? partialSeconds.map(Double.init)
        let scaled: @Sendable (Double, String?) -> Void = { fraction, message in
            progress(range.lowerBound + (range.upperBound-range.lowerBound)*fraction, message)
        }
        if format.protocolType == .sabr {
            _ = try await SABRDownloader.download(format: format, to: target, http: http,
                options: SABRDownloadOptions(startSeconds: startSeconds, durationSeconds: length, liveFromStart: liveFromStart),
                refresh: refresh, progress: scaled)
        } else if format.protocolType == .hls {
            let transport = target.appendingPathExtension("transport")
            _ = try await NativeHLSDownloader.download(format: format, to: transport, http: http,
                refresh: refresh, durationSeconds: length.map { $0 + startSeconds }, liveFromStart: liveFromStart, progress: scaled)
            let result = try ProcessRunner().run(SidecarPaths.ffmpeg, ["-y", "-i", transport.path, "-c", "copy", target.path])
            guard result.code == 0 else { throw EngineError.engineFailure("HLS 封装失败：\(String(result.stderr.suffix(400)))") }
            try? FileManager.default.removeItem(at: transport)
        } else {
            _ = try await NativeMediaDownloader.download(format: format, to: target, http: http,
                refresh: refresh, partialSeconds: length.map { $0 + startSeconds }, liveFromStart: liveFromStart, progress: scaled)
        }
    }

    /// 下载（主 URL 失败自动切换备用 CDN），落盘到 target，共享 NativeMediaDownloader 多并发断点续传底层。
    static func fetch(_ url: URL, to target: URL, proxy: String, referer: String?,
                      range: ClosedRange<Double>, progress: @escaping @Sendable (Double, String?) -> Void,
                      fallbackURLs: [URL]? = nil) async throws {
        var headers = ["User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36"]
        if let referer { headers["Referer"] = referer }
        let http = URLSessionHTTPClient(proxy: proxy.isEmpty ? nil : proxy, timeout: 60)
        _ = try await NativeMediaDownloader.downloadFile(
            url: url,
            to: target,
            http: http,
            headers: headers,
            backupURLs: fallbackURLs
        ) { frac, msg in
            progress(range.lowerBound + (range.upperBound - range.lowerBound) * frac, msg)
        }
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
