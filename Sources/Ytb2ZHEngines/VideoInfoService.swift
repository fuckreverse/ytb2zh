import Foundation

// MARK: - 单视频完整元数据：yt-dlp -J（非 flat，含简介/频道/上传日期/播放量等）

/// 单视频完整元数据（媒体库详情展示用），按 URL 键控持久化
public struct VideoDetails: Codable, Sendable, Hashable {
    public let url: String
    public let title: String
    public let videoDescription: String?
    public let channel: String?
    public let channelURL: String?
    /// yt-dlp uploadDate："yyyyMMdd"
    public let uploadDate: String?
    public let duration: Double
    public let viewCount: Int?
    public let likeCount: Int?
    public let tags: [String]
    public let thumbnail: String?
    public let fetchedAt: Date

    public init(url: String, title: String, videoDescription: String? = nil,
                channel: String? = nil, channelURL: String? = nil, uploadDate: String? = nil,
                duration: Double = 0, viewCount: Int? = nil, likeCount: Int? = nil,
                tags: [String] = [], thumbnail: String? = nil, fetchedAt: Date = Date()) {
        self.url = url; self.title = title; self.videoDescription = videoDescription
        self.channel = channel; self.channelURL = channelURL; self.uploadDate = uploadDate
        self.duration = duration; self.viewCount = viewCount; self.likeCount = likeCount
        self.tags = tags; self.thumbnail = thumbnail; self.fetchedAt = fetchedAt
    }

    /// "yyyyMMdd" → "2026-09-27"
    public var uploadDateText: String? {
        guard let d = uploadDate, d.count == 8, let date = Self.dateFmt.date(from: d) else { return nil }
        return Self.outFmt.string(from: date)
    }

    private static let dateFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyyMMdd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
    private static let outFmt: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.locale = Locale(identifier: "en_US_POSIX")
        return f
    }()
}

public struct VideoInfoService: Sendable {
    public init() {}

    /// 拉取单个视频完整元数据：Videx 原生优先（YouTube/B站/抖音/TikTok），
    /// 内置提取失败时才按需下载 yt-dlp 并回退 -J。
    public func fetch(_ url: String, proxy: String = "") throws -> VideoDetails {
        let u = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard u.hasPrefix("http") else {
            throw EngineError.engineFailure("视频详情：非法链接 \(u.prefix(60))")
        }
        if VidexBridge.canHandle(u) {
            do {
                let info = try VidexBridge.extractSync(u, proxy: proxy)
                return VidexBridge.toDetails(info, url: u)
            } catch {
                // 内置提取失败（风控/私有视频）→ 按需准备 yt-dlp 后回退；
                // 下载失败时抛出安装错误（含 actionable 提示），不掩盖原生失败原因
                _ = try YtDlpInstaller.ensureInstalledSync(proxy: proxy)
            }
        }
        let res = try ProcessRunner().runWithTimeout(60, SidecarPaths.ytDlp, Self.infoArgs(url: u, proxy: proxy))
        guard res.code == 0, !res.stdout.isEmpty else {
            throw EngineError.engineFailure("视频详情拉取失败：\(String(res.stderr.suffix(400)))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any],
              let d = Self.parse(obj, url: u) else {
            throw EngineError.engineFailure("视频详情解析失败")
        }
        return d
    }

    /// yt-dlp 二进制当前是否已就绪（不发网络请求；按需安装见 YtDlpInstaller）。
    static var ytDlpAvailable: Bool {
        YtDlpInstaller.availablePath != nil
    }

    /// yt-dlp 参数构造（纯函数，供测试）
    static func infoArgs(url: String, proxy: String) -> [String] {
        var args = ["-J", "--no-warnings", "--skip-download", "--no-playlist"]
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        args.append(url)
        return args
    }

    /// yt-dlp 单视频 JSON → VideoDetails（字段缺失宽容，只要求有标题）
    static func parse(_ e: [String: Any], url: String) -> VideoDetails? {
        guard let title = e["title"] as? String, !title.isEmpty else { return nil }
        var thumb = e["thumbnail"] as? String
        if thumb == nil, let thumbs = e["thumbnails"] as? [[String: Any]] {
            thumb = (thumbs.last?["url"] as? String)
        }
        if thumb == nil { thumb = CatalogVideo.youTubeThumbnail(url) }
        let duration: Double
        if let d = e["duration"] as? Double { duration = d }
        else if let d = e["duration"] as? Int { duration = Double(d) }
        else if let d = e["duration"] as? String, let num = Double(d) { duration = num }
        else { duration = 0 }
        return VideoDetails(
            url: e["webpage_url"] as? String ?? url,
            title: title,
            videoDescription: e["description"] as? String,
            channel: e["channel"] as? String ?? e["uploader"] as? String,
            channelURL: e["channel_url"] as? String ?? e["uploader_url"] as? String,
            uploadDate: e["upload_date"] as? String,
            duration: duration,
            viewCount: VideoCatalogService.intValue(e["view_count"]),
            likeCount: VideoCatalogService.intValue(e["like_count"]),
            tags: (e["tags"] as? [Any])?.compactMap { $0 as? String } ?? [],
            thumbnail: thumb
        )
    }
}
