import XCTest
@testable import Videx

/// YouTube 原生搜索（InnerTube search/browse/next）真机验证（可选，默认跳过）：
///   VIDEX_LIVE=1 VIDEX_PROXY=http://127.0.0.1:7890 swift test --filter InnerTubeSearchTests
final class InnerTubeSearchTests: XCTestCase {

    private func makeService(proxy: String) -> YouTubeSearchService {
        YouTubeSearchService()
    }

    private var proxy: String {
        ProcessInfo.processInfo.environment["VIDEX_PROXY"] ?? ""
    }

    private var liveEnabled: Bool {
        ProcessInfo.processInfo.environment["VIDEX_LIVE"] == "1"
    }

    func testKeywordSearch() async throws {
        guard liveEnabled else { throw XCTSkip("设置 VIDEX_LIVE=1 以启用搜索真机测试") }
        print("PROXY-VALUE:", ProcessInfo.processInfo.environment["VIDEX_PROXY"] ?? "<nil>")
        let service = makeService(proxy: proxy)
        let page = try await service.fetchPage(query: "lo fi hip hop", proxy: proxy)
        XCTAssertFalse(page.items.isEmpty, "关键词搜索应有结果")
        let videos = page.videos
        XCTAssertFalse(videos.isEmpty, "应包含视频结果")
        for v in videos.prefix(5) {
            XCTAssertFalse(v.title.isEmpty)
            XCTAssertTrue(v.id.count == 11, "videoId 应为 11 位：\(v.id)")
            XCTAssertNotNil(v.thumbnailURL)
        }
        XCTAssertNotNil(page.continuation, "搜索应有下一页 token")
        print("搜索首页 \(page.items.count) 条，视频 \(videos.count) 条，示例：\(videos.first!.debugDescription)")
    }

    func testKeywordSearchPagination() async throws {
        guard liveEnabled else { throw XCTSkip("设置 VIDEX_LIVE=1 以启用搜索真机测试") }
        let service = makeService(proxy: proxy)
        let first = try await service.fetchPage(query: "swift programming", proxy: proxy)
        let second = try await service.fetchPage(query: "swift programming",
                                                 offset: first.items.count, proxy: proxy)
        XCTAssertFalse(second.items.isEmpty, "第二页应有结果")
        let firstIDs = Set(first.items.map(\.id))
        let overlap = second.items.filter { firstIDs.contains($0.id) }
        XCTAssertTrue(overlap.count < second.items.count / 2, "翻页结果与首页重复度不应过高")
        print("第二页 \(second.items.count) 条，与首页重复 \(overlap.count) 条")
    }

    func testPlaylistBrowse() async throws {
        guard liveEnabled else { throw XCTSkip("设置 VIDEX_LIVE=1 以启用搜索真机测试") }
        // 真实存在的公开播放列表（browse 端点对 UU 系统列表返回 400，须用 PL 列表）
        let service = makeService(proxy: proxy)
        let page = try await service.fetchPage(
            query: "https://www.youtube.com/playlist?list=PLbpi6ZahtOH6Blw3RGYpWkSByi_T7Rygb",
            proxy: proxy)
        print("播放列表条目 \(page.items.count) 条，标题：\(page.title ?? "-")")
        XCTAssertFalse(page.items.isEmpty, "频道上传列表应有视频")
        if let first = page.items.first {
            XCTAssertEqual(first.kind, .video)
            XCTAssertFalse(first.title.isEmpty)
        }
    }

    func testChannelBrowseByHandle() async throws {
        guard liveEnabled else { throw XCTSkip("设置 VIDEX_LIVE=1 以启用搜索真机测试") }
        let service = makeService(proxy: proxy)
        let page = try await service.fetchPage(
            query: "https://www.youtube.com/@MrBeast/videos", proxy: proxy)
        print("频道视频 \(page.items.count) 条，标题：\(page.title ?? "-")")
        let videos = page.videos
        XCTAssertGreaterThan(videos.count, 10, "频道 Videos 页签应返回大量视频（lockupViewModel 解析）")
        if let first = videos.first {
            XCTAssertFalse(first.title.isEmpty)
            XCTAssertNotNil(first.thumbnailURL)
            print("首个视频：\(first.debugDescription)")
        }
    }

    func testRouteClassification() {
        XCTAssertEqual(YouTubeSearchService.route("hello world"), .keyword)
        XCTAssertEqual(YouTubeSearchService.route(
            "https://www.youtube.com/playlist?list=PLabc123"), .playlist(listID: "PLabc123"))
        XCTAssertEqual(YouTubeSearchService.route(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PLabc"), .singleVideo)
        XCTAssertEqual(YouTubeSearchService.route(
            "https://www.youtube.com/watch?v=dQw4w9WgXcQ"), .singleVideo)
        XCTAssertEqual(YouTubeSearchService.route(
            "https://www.youtube.com/channel/UCX6OQ3DkcsbYNE6H8uQQuVA"),
            .channelID("UCX6OQ3DkcsbYNE6H8uQQuVA"))
        XCTAssertEqual(YouTubeSearchService.route(
            "https://www.youtube.com/@mkbhd/videos"), .handle("/@mkbhd"))
        XCTAssertEqual(YouTubeSearchService.route(
            "https://youtu.be/dQw4w9WgXcQ"), .singleVideo)
        // 非 YouTube URL → 关键词（由调用方判定不支持）
        XCTAssertEqual(YouTubeSearchService.route("https://vimeo.com/123"), .keyword)
    }

    /// 诊断：同进程内用裸 URLSession 走代理 POST youtubei（绕过 HTTPRequest 封装）
    func testRawURLSessionPOST() async throws {
        guard liveEnabled else { throw XCTSkip("诊断测试需代理，VIDEX_LIVE=1 启用") }
        let rawProxy = ProcessInfo.processInfo.environment["VIDEX_PROXY"]
        let config = URLSessionConfiguration.ephemeral
        if let rawProxy, let url = URL(string: rawProxy), let host = url.host, let port = url.port {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": host, "HTTPPort": port,
                "HTTPSEnable": 1, "HTTPSProxy": host, "HTTPSPort": port,
            ]
        }
        let session = URLSession(configuration: config)
        let body = try JSONSerialization.data(withJSONObject: [
            "context": ["client": ["clientName": "WEB", "clientVersion": "2.20250312.04.00",
                                   "hl": "en", "gl": "US"]],
            "query": "test",
        ])
        var req = URLRequest(url: URL(string:
            "https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false")!)
        req.httpMethod = "POST"
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // 完整 innertube 头部（与 InnerTubeClient.innertubeCall 一致）
        req.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36", forHTTPHeaderField: "User-Agent")
        req.setValue("1", forHTTPHeaderField: "X-YouTube-Client-Name")
        req.setValue("2.20250312.04.00", forHTTPHeaderField: "X-YouTube-Client-Version")
        req.setValue("https://www.youtube.com", forHTTPHeaderField: "Origin")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.setValue("CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI", forHTTPHeaderField: "Cookie")
        let (data, resp) = try await session.data(for: req)
        print("RAW-POST status:", (resp as? HTTPURLResponse)?.statusCode ?? -1, "bytes:", data.count)
    }

    /// 诊断：经 URLSessionHTTPClient + HTTPRequest.post 走同一请求（ Videx 封装路径）
    func testVidexHTTPClientPOST() async throws {
        guard liveEnabled else { throw XCTSkip("诊断测试需代理，VIDEX_LIVE=1 启用") }
        let proxy = ProcessInfo.processInfo.environment["VIDEX_PROXY"]
        let client = URLSessionHTTPClient(proxy: proxy)
        let request = try HTTPRequest.post(
            URL(string: "https://www.youtube.com/youtubei/v1/search?key=AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8&prettyPrint=false")!,
            json: ["context": ["client": ["clientName": "WEB", "clientVersion": "2.20250312.04.00",
                                          "hl": "en", "gl": "US"]],
                   "query": "test"],
            headers: ["Content-Type": "application/json"])
        let response = try await client.fetch(request)
        print("VIDEX-POST status:", response.status, "bytes:", response.body.count)
    }
}
