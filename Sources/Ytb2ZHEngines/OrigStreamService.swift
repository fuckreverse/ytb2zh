import Foundation

// MARK: - 原版流式播放：yt-dlp 解析直链（不跑翻译管线，配合 App 层本地反代给 AVPlayer 播）
// YouTube 大量视频已无"音视频合一"的 progressive 格式，此时退回 HLS：
// 视频/音频分离的 m3u8 由 App 层合成 master playlist（音频走 rendition 组），AVPlayer 原生混流。

public enum OrigStreamKind: Sendable, Equatable {
    /// 音视频合一直链（支持 Range 拖动）
    case progressive(url: String)
    /// 分离流：视频 m3u8 + 音频 m3u8（App 层合成 master，段落经本地反代转发）
    case hls(video: String, audio: String)
}

public struct OrigStreamInfo: Sendable {
    public let kind: OrigStreamKind
    public let title: String
    public let duration: Double
    public let proxyOverride: String?
    public let requestHeaders: [String: String]

    public init(kind: OrigStreamKind, title: String, duration: Double, proxyOverride: String? = nil, requestHeaders: [String: String] = [:]) {
        self.kind = kind
        self.title = title
        self.duration = duration
        self.proxyOverride = proxyOverride
        self.requestHeaders = requestHeaders
    }
}

public struct OrigStreamService: Sendable {
    public init() {}

    public static func resolveArgs(url: String, proxy: String) -> [String] {
        var args = ["-j", "--no-warnings", "--no-playlist"]
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        args.append(url)
        return args
    }

    /// 格式挑选（纯函数供测试）：优先 progressive（≤720p），无则 HLS 分离流（视频≤720p + 最高码率音频，
    /// 音频优先 mp4a/AAC——AVPlayer 对 webm/opus 兼容差）
    public static func pick(_ formats: [[String: Any]]) -> OrigStreamKind? {
        func str(_ f: [String: Any], _ k: String) -> String { f[k] as? String ?? "" }
        func num(_ f: [String: Any], _ k: String) -> Int { VideoCatalogService.intValue(f[k]) ?? 0 }
        func isHLS(_ f: [String: Any]) -> Bool { str(f, "protocol").contains("m3u8") }
        let usable = formats.filter { str($0, "url").isEmpty == false }

        let progressive = usable.filter {
            str($0, "vcodec") != "none" && str($0, "acodec") != "none"
                && !isHLS($0) && str($0, "protocol") != "mhtml"
                && num($0, "height") > 0 && num($0, "height") <= 720
        }.max { num($0, "height") < num($1, "height") }
        if let p = progressive, let u = p["url"] as? String { return .progressive(url: u) }

        let vHLS = usable.filter {
            str($0, "vcodec") != "none" && str($0, "acodec") == "none" && isHLS($0)
                && num($0, "height") > 0 && num($0, "height") <= 720
        }.max { num($0, "height") < num($1, "height") }
        // 音频：mp4a 优先（AVPlayer 不认 opus/webm），同级取最高 abr
        let aHLS = usable.filter {
            str($0, "acodec") != "none" && str($0, "vcodec") == "none" && isHLS($0)
        }.max { a, b in
            let pa = str(a, "acodec").hasPrefix("mp4a")
            let pb = str(b, "acodec").hasPrefix("mp4a")
            if pa != pb { return !pa }
            return num(a, "abr") < num(b, "abr")
        }
        if let v = vHLS?["url"] as? String, let a = aHLS?["url"] as? String {
            return .hls(video: v, audio: a)
        }
        return nil
    }

    /// 解析单视频可播流：Videx 原生优先（muxed 直链即可播，抖音/TikTok 全 muxed、
    /// YouTube itag 18/22）；拿不到 muxed（如只剩 DASH）时按需准备 yt-dlp 后走 HLS 路线。
    public func resolve(url: String, proxy: String) throws -> OrigStreamInfo {
        if VidexBridge.canHandle(url) {
            if let info = try? VidexBridge.extractSync(url, proxy: proxy),
               let stream = VidexBridge.playableStream(info) {
                return stream
            }
            // 内置无 muxed 才按需下载 yt-dlp（下载失败直接抛安装错误）
            _ = try YtDlpInstaller.ensureInstalledSync(proxy: proxy)
        }
        let res = try ProcessRunner().run(SidecarPaths.ytDlp,
                                          Self.resolveArgs(url: url, proxy: proxy))
        guard res.code == 0, !res.stdout.isEmpty else {
            throw EngineError.engineFailure("原版流解析失败：\(String(res.stderr.suffix(400)))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any],
              let formats = obj["formats"] as? [[String: Any]] else {
            throw EngineError.engineFailure("原版流解析失败：格式列表为空")
        }
        guard let kind = Self.pick(formats) else {
            throw EngineError.engineFailure("原版流解析失败：无可播放的流格式")
        }
        let title = obj["title"] as? String ?? "原版"
        let duration: Double
        if let d = obj["duration"] as? Double { duration = d }
        else { duration = Double(VideoCatalogService.intValue(obj["duration"]) ?? 0) }
        return OrigStreamInfo(kind: kind, title: title, duration: duration)
    }
}
