import Foundation

// MARK: - YouTube 浏览：yt-dlp -J 搜索（关键词 ytsearch / 频道页 / 播放列表 URL）

public struct CatalogVideo: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let title: String
    public let url: String
    public let thumbnail: String?
    public let duration: Double
    public let channel: String?
    public let viewCount: Int?

    public init(id: String, title: String, url: String,
                thumbnail: String? = nil, duration: Double = 0, channel: String? = nil,
                viewCount: Int? = nil) {
        self.id = id; self.title = title; self.url = url
        self.thumbnail = thumbnail; self.duration = duration; self.channel = channel
        self.viewCount = viewCount
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, url, thumbnail, duration, channel, viewCount
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        url = try c.decode(String.self, forKey: .url)
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        duration = try c.decodeIfPresent(Double.self, forKey: .duration) ?? 0
        channel = try c.decodeIfPresent(String.self, forKey: .channel)
        viewCount = try c.decodeIfPresent(Int.self, forKey: .viewCount)
    }

    /// YouTube 视频 id 提取（watch?v= / youtu.be / shorts/ / embed/），无 id 返回 nil
    public static func youTubeID(_ url: String) -> String? {
        let patterns = [
            #"[?&]v=([A-Za-z0-9_-]{11})"#,
            #"youtu\.be/([A-Za-z0-9_-]{11})"#,
            #"youtube\.com/(?:shorts|embed|live)/([A-Za-z0-9_-]{11})"#,
        ]
        for p in patterns {
            guard let r = url.range(of: p, options: .regularExpression) else { continue }
            let m = String(url[r])
            guard m.count >= 11,
                  let id = m.range(of: "[A-Za-z0-9_-]{11}$", options: .regularExpression)
            else { continue }
            return String(m[id])
        }
        return nil
    }

    /// YouTube 缩略图（hqdefault），非 YouTube 返回 nil
    public static func youTubeThumbnail(_ url: String) -> String? {
        guard let id = youTubeID(url) else { return nil }
        return "https://i.ytimg.com/vi/\(id)/hqdefault.jpg"
    }
}

public struct VideoCatalogService: Sendable {
    public init() {}

    /// 频道/播放列表标题清理（自动命名用）：去掉 YouTube 页尾部装饰
    public static func cleanListTitle(_ t: String) -> String {
        var clean = t.trimmingCharacters(in: .whitespaces)
        for suffix in [" - Videos", " - Shorts", " - Live", " - Playlists", " - YouTube"]
        where clean.hasSuffix(suffix) {
            clean = String(clean.dropLast(suffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return clean
    }

    /// 录入项是否“播放列表/频道”链接（应展开浏览而不是当做单视频转换）。
    /// watch?v=xx &list=yy 的混合地址视为单视频（下载引擎带 --no-playlist）。
    public static func isLikelyListURL(_ query: String) -> Bool {
        let s = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard s.hasPrefix("http://") || s.hasPrefix("https://") else { return false }
        guard let comps = URLComponents(string: s) else { return false }
        let items = comps.queryItems ?? []
        let hasList = items.contains { $0.name == "list" }
        let hasVideo = items.contains { $0.name == "v" }
        let path = comps.path
        if hasList { return !hasVideo }
        if path.contains("/playlist") { return true }
        if path.hasPrefix("/@") || path.hasPrefix("/channel/") || path.hasPrefix("/c/") { return true }
        return false
    }

    /// 频道/播放列表页拉取结果：容器自身标题（自动命名用）+ 视频列表
    public struct CatalogPage: Sendable {
        public let title: String?
        public let videos: [CatalogVideo]
        public init(title: String?, videos: [CatalogVideo]) {
            self.title = title
            self.videos = videos
        }
    }

    /// 同 search，但额外返回频道/播放列表自身标题（-J 顶层 title）
    public func searchPage(_ query: String, limit: Int = 24, offset: Int = 0,
                           proxy: String = "") throws -> CatalogPage {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return CatalogPage(title: nil, videos: []) }
        let res = try ProcessRunner().run(SidecarPaths.ytDlp,
                                          Self.listArgs(query: q, limit: limit, offset: offset, proxy: proxy))
        guard res.code == 0, !res.stdout.isEmpty else {
            throw EngineError.engineFailure("搜索失败：\(String(res.stderr.suffix(400)))")
        }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(res.stdout.utf8)) as? [String: Any] else {
            throw EngineError.engineFailure("搜索结果解析失败")
        }
        let title = (obj["title"] as? String).map(Self.cleanListTitle)
        // 播放列表/搜索 → entries；单视频 URL → 自身
        if let entries = obj["entries"] as? [[String: Any]] {
            return CatalogPage(title: title, videos: entries.compactMap { Self.parseEntry($0) })
        }
        if let one = Self.parseEntry(obj) {
            // 单视频页：标题用视频自身频道名更合适
            return CatalogPage(title: one.channel ?? title, videos: [one])
        }
        return CatalogPage(title: title, videos: [])
    }

    /// 搜索：query 为关键词（ytsearch）或 http(s) 链接（单视频/频道/播放列表）；
    /// offset 用于播放列表“加载更多”（--playlist-start，仅对 URL 查询生效）。
    public func search(_ query: String, limit: Int = 24, offset: Int = 0, proxy: String = "") throws -> [CatalogVideo] {
        try searchPage(query, limit: limit, offset: offset, proxy: proxy).videos
    }

    /// yt-dlp 参数构造（纯函数，供测试）：URL 走 playlist 窗口；关键词转 ytsearch；
    /// offset>0 时用 --playlist-start 继续取（ytsearch 不支持 offset，只是窗口控制）。
    static func listArgs(query: String, limit: Int, offset: Int, proxy: String) -> [String] {
        let isURL = query.lowercased().hasPrefix("http://") || query.lowercased().hasPrefix("https://")
        var args = ["-J", "--flat-playlist", "--no-warnings",
                    "--playlist-end", String(max(1, limit))]
        if isURL, offset > 0 { args += ["--playlist-start", String(offset + 1)] }
        if !proxy.isEmpty { args += ["--proxy", proxy] }
        args.append(isURL ? query : "ytsearch\(max(1, limit)):\(query)")
        return args
    }

    /// yt-dlp JSON 单条目 → CatalogVideo（flat-playlist 条目只有概要元数据，够浏览用）
    static func parseEntry(_ e: [String: Any]) -> CatalogVideo? {
        let id = e["id"] as? String ?? ""
        var url = e["url"] as? String ?? e["webpage_url"] as? String ?? ""
        if url.isEmpty, !id.isEmpty, id.count == 11 {
            url = "https://www.youtube.com/watch?v=\(id)"
        }
        guard !id.isEmpty, !url.isEmpty else { return nil }

        let viewCount = Self.intValue(e["view_count"])
        let title = e["title"] as? String ?? "（无标题）"
        var thumb = e["thumbnail"] as? String
        if thumb == nil, let thumbs = e["thumbnails"] as? [[String: Any]] {
            thumb = (thumbs.last?["url"] as? String)
        }
        if thumb == nil { thumb = CatalogVideo.youTubeThumbnail(url) }
        let duration: Double
        if let d = e["duration"] as? Double { duration = d }
        else if let d = e["duration"] as? Int { duration = Double(d) }
        else if let d = e["duration"] as? String, let num = Double(d) {
            duration = num   // flat-playlist 可能返回字符串 "972"
        }
        else if let d = e["duration_string"] as? String {
            // "1:23:45" / "12:34"
            let parts = d.split(separator: ":").compactMap { Double($0) }
            duration = parts.reduce(0) { $0 * 60 + $1 }
        } else { duration = 0 }
        let channel = e["channel"] as? String
            ?? e["uploader"] as? String
            ?? e["playlist_channel"] as? String

        return CatalogVideo(id: id, title: title, url: url,
                            thumbnail: thumb, duration: duration, channel: channel,
                            viewCount: viewCount)
    }

    /// yt-dlp 数值字段三态（Int/Double/字符串）→ Int
    static func intValue(_ any: Any?) -> Int? {
        switch any {
        case let i as Int: return i
        case let d as Double: return Int(d)
        case let s as String: return Int(s)
        default: return nil
        }
    }
}
