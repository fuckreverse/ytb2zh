import Foundation

// MARK: - YouTube 搜索/浏览门面（纯 InnerTube，无 yt-dlp 依赖）
//
// 把"关键词或 URL"路由到正确的 InnerTube 端点：
//   关键词                 → search
//   playlist?list=…        → browse(VL+playlistId)
//   channel/UC…            → browse(UC…)
//   @handle / /c/ / /user/ → 频道页解析出 UC ID 后 browse
//   watch?v=…（含 list=）  → 单视频，返回空页由上层直接处理
//
// 分页基于 InnerTube continuation token。为兼容"offset"风格的
// 调用方（UI 的加载更多：offset = 已取条数），内部按
// (query, 已取条数) 缓存 token；缓存未命中时从头顺序补拉兜底。

public final class YouTubeSearchService: @unchecked Sendable {

    public init() {}

    /// 拉取一页结果。offset=0 为首页；offset>0 时优先走 token 缓存，
    /// 未命中则从首页顺序补拉到 offset（正确但代价高，仅兜底）。
    /// videosOnly=true 时只返回视频条目（分页 token 也按过滤后的条数对齐，
    /// 与调用方以"已取视频数"作 offset 的习惯匹配）。
    public func fetchPage(query: String, offset: Int = 0, proxy: String = "",
                          videosOnly: Bool = false) async throws -> InnerTubeSearchResult {
        let client = InnerTubeClient(
            http: URLSessionHTTPClient(proxy: proxy.isEmpty ? nil : proxy),
            cookies: CookieJar())

        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let route = Self.route(trimmed)

        // 首页
        if offset == 0 {
            let result: InnerTubeSearchResult
            switch route {
            case .keyword:
                result = InnerTubeParser.collect(from: try await client.search(query: trimmed))
            case .playlist(let listID):
                result = try await browsePlaylist(listID, client: client)
            case .channelID(let channelID):
                result = InnerTubeParser.collect(
                    from: try await client.browse(browseId: channelID,
                                                  params: InnerTubeBrowseTab.videos.rawValue))
            case .handle(let path):
                let channelID = try await client.resolveChannelID(handlePath: path)
                result = InnerTubeParser.collect(
                    from: try await client.browse(browseId: channelID,
                                                  params: InnerTubeBrowseTab.videos.rawValue))
            case .singleVideo:
                result = InnerTubeSearchResult(items: [], continuation: nil, title: nil)
            }
            let page = Self.finalize(result, videosOnly: videosOnly)
            Self.storeToken(for: trimmed, offset: page.items.count, token: page.continuation)
            return page
        }

        // 翻页：查 token 缓存（UI 以 results.count 作为 offset，天然对齐）
        switch Self.cachedToken(for: trimmed, offset: offset) {
        case .some(.some(let token)):
            guard !token.isEmpty else {
                return InnerTubeSearchResult(items: [], continuation: nil, title: nil) // 已到底
            }
            return try await continuationPage(route: route, query: trimmed, token: token,
                                              client: client, consumedBefore: offset,
                                              videosOnly: videosOnly)
        case .some(.none):
            // 键存在但无 token：防御性空页
            return InnerTubeSearchResult(items: [], continuation: nil, title: nil)
        case .none:
            // 缓存未命中（进程重启/跳页）→ 从头顺序拉到 offset
            var page = try await fetchPage(query: query, offset: 0, proxy: proxy, videosOnly: videosOnly)
            var covered = page.items.count
            while covered < offset, let next = page.continuation {
                page = try await continuationPage(route: route, query: trimmed, token: next,
                                                  client: client, consumedBefore: covered,
                                                  videosOnly: videosOnly)
                covered += page.items.count
            }
            return page
        }
    }

    // MARK: - token 缓存（static 共享，NSLock 保护）

    private static let tokenLock = NSLock()
    private nonisolated(unsafe) static var tokenCache: [String: [Int: String?]] = [:]

    /// String?? 双层可选：nil = 无缓存记录；.some(nil) = 已知无下一页；.some(str) = token
    private static func cachedToken(for query: String, offset: Int) -> String?? {
        tokenLock.withLock { tokenCache[query]?[offset] }
    }

    private static func storeToken(for query: String, offset: Int, token: String?) {
        tokenLock.withLock {
            var perQuery = tokenCache[query] ?? [:]
            perQuery[offset] = token
            tokenCache[query] = perQuery
        }
    }

    /// videosOnly 过滤（保持 continuation/title 透传，分页 token 按过滤后条数对齐）。
    private static func finalize(_ result: InnerTubeSearchResult,
                                 videosOnly: Bool) -> InnerTubeSearchResult {
        guard videosOnly else { return result }
        return InnerTubeSearchResult(items: result.videos,
                                     continuation: result.continuation,
                                     title: result.title)
    }

    /// 播放列表 browse：优先 VL 前缀（标准），网络类错误时回退裸 listID
    /// （部分列表类型如 UU/RD 对 VL 前缀的兼容性不稳定）。
    private func browsePlaylist(_ listID: String, client: InnerTubeClient) async throws -> InnerTubeSearchResult {
        do {
            return InnerTubeParser.collect(
                from: try await client.browse(browseId: "VL\(listID)", params: nil))
        } catch {
            return InnerTubeParser.collect(
                from: try await client.browse(browseId: listID, params: nil))
        }
    }

    /// 翻页：回到原端点带 continuation token（search/browse 均如此，
    /// next 端点仅用于 watch 页相关推荐，不用于搜索翻页）。
    private func continuationPage(route: QueryRoute, query: String, token: String,
                                  client: InnerTubeClient, consumedBefore: Int,
                                  videosOnly: Bool = false) async throws -> InnerTubeSearchResult {
        let json: JSON
        switch route {
        case .keyword:
            json = try await client.search(query: query, continuation: token)
        case .playlist(let listID):
            if let withPrefix = try? await client.browse(browseId: "VL\(listID)", continuation: token) {
                json = withPrefix
            } else {
                json = try await client.browse(browseId: listID, continuation: token)
            }
        case .channelID(let channelID):
            json = try await client.browse(browseId: channelID,
                                           params: InnerTubeBrowseTab.videos.rawValue,
                                           continuation: token)
        case .handle(let path):
            let channelID = try await client.resolveChannelID(handlePath: path)
            json = try await client.browse(browseId: channelID,
                                           params: InnerTubeBrowseTab.videos.rawValue,
                                           continuation: token)
        case .singleVideo:
            return InnerTubeSearchResult(items: [], continuation: nil, title: nil)
        }
        let raw = InnerTubeParser.collect(from: json)
        let result = Self.finalize(raw, videosOnly: videosOnly)
        Self.storeToken(for: query, offset: consumedBefore + result.items.count, token: result.continuation)
        return result
    }

    // MARK: - 查询路由

    enum QueryRoute: Equatable {
        case keyword
        case playlist(listID: String)
        case channelID(String)   // UC…
        case handle(String)      // /@xxx、/c/xxx、/user/xxx
        case singleVideo
    }

    /// URL 形态判定（与 VideoCatalogService.isLikelyListURL 语义对齐：
    /// watch?v=xx&list=yy 混合地址视为单视频）。
    static func route(_ query: String) -> QueryRoute {
        let lowered = query.lowercased()
        guard lowered.hasPrefix("http://") || lowered.hasPrefix("https://") else { return .keyword }
        guard let comps = URLComponents(string: query) else { return .keyword }
        let host = comps.host?.lowercased() ?? ""
        guard host.contains("youtube.com") || host.contains("youtu.be") else { return .keyword }
        let items = comps.queryItems ?? []
        let path = comps.path

        // watch?v=…（无论是否带 list=）→ 单视频
        if let v = items.first(where: { $0.name == "v" })?.value,
           !v.isEmpty, path.hasPrefix("/watch") {
            return .singleVideo
        }
        // youtu.be/<id>
        if host.contains("youtu.be") {
            let id = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !id.isEmpty { return .singleVideo }
        }
        // playlist?list=…（纯播放列表页）
        if let list = items.first(where: { $0.name == "list" })?.value, !list.isEmpty {
            return .playlist(listID: list)
        }
        // /channel/UC…
        if path.hasPrefix("/channel/") {
            let id = String(path.dropFirst("/channel/".count))
            if id.hasPrefix("UC") { return .channelID(id) }
        }
        // /@handle、/c/…、/user/…
        for prefix in ["/@", "/c/", "/user/"] where path.hasPrefix(prefix) {
            let rest = String(path.dropFirst(prefix.count))
            guard !rest.isEmpty else { break }
            let handle = rest.split(separator: "/").first.map(String.init) ?? rest
            return .handle("\(prefix)\(handle)")
        }
        return .keyword
    }
}
