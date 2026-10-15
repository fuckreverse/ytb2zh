import XCTest
@testable import Videx

/// 外部 POT / visitorData 注入行为测试。
///
/// 覆盖两条关键规则：
/// 1. 提供外部 visitorData 时，web 客户端请求体必须带它（POT 与 visitorData 绑定）；
/// 2. 提供外部 GVS POT 时，不能复用 watch 页的 initialPlayerResponse
///    （那是页面自己会话的响应，与收割的 visitorData 不配套）。
final class POTInjectionTests: XCTestCase {

    private static let watchHTML = """
    <html><head><script>
    var ytcfg = {set: function(){}};
    ytcfg.set({"VISITOR_DATA": "page-visitor", "PLAYER_JS_URL": "/s/player/abc/base.js"});
    var ytInitialPlayerResponse = {
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {"videoId": "dQw4w9WgXcQ", "title": "Page Response"},
      "streamingData": {
        "formats": [{"itag": 18, "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"",
                     "url": "https://rr3.googlevideo.com/videoplayback?id=page-18"}]
      }
    };
    </script></head><body></body></html>
    """

    /// web 客户端的 player API 响应：itag 18（豁免 POT）+ itag 140（需 POT）。
    /// 刻意不带 `n` 参数——n 挑战属 JSC 求解路径，离线 fixture 无法产出 base.js；
    /// 本测试关注 POT / visitorData 注入，不应与 n 策略耦合。
    private static let webPlayerJSON = """
    {
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {"videoId": "dQw4w9WgXcQ", "title": "API Response"},
      "streamingData": {
        "formats": [{"itag": 18, "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"",
                     "url": "https://rr3.googlevideo.com/videoplayback?id=api-18"}],
        "adaptiveFormats": [{"itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
                             "url": "https://rr3.googlevideo.com/videoplayback?id=api-140",
                             "averageBitrate": 129000}]
      }
    }
    """

    private func makeContext(http: HTTPFetching, tokens: [String: String], visitor: String?) -> ExtractionContext {
        var options = ExtractionOptions(youtubePoTokens: tokens, youtubeVisitorData: visitor)
        if ProcessInfo.processInfo.environment["POT_TEST_DEBUG"] == "1" {
            options.log = StderrLogSink(minLevel: .debug)
        }
        return ExtractionContext.make(options: options, httpFactory: { _ in http }, js: JavaScriptCoreRuntime())
    }

    // MARK: - Options → Context 传递

    func testOptionsCarryVisitorDataIntoContext() {
        let options = ExtractionOptions(youtubePoTokens: ["web.gvs": "POT"], youtubeVisitorData: "VD")
        let context = ExtractionContext.make(options: options, httpFactory: { _ in StubRecordingHTTP() })
        XCTAssertEqual(context.youtubeVisitorData, "VD")
        XCTAssertEqual(context.youtubePoTokens["web.gvs"], "POT")
    }

    func testVisitorDataDefaultsToNil() {
        let context = ExtractionContext.make(options: ExtractionOptions(), httpFactory: { _ in StubRecordingHTTP() })
        XCTAssertNil(context.youtubeVisitorData)
    }

    // MARK: - 无 token：复用页面 initialPlayer（保持原行为）

    func testWithoutTokensWebReusesPageResponse() async throws {
        let http = StubRecordingHTTP(watchHTML: Self.watchHTML, playerJSON: Self.webPlayerJSON)
        let extractor = YouTubeExtractor(clientOrder: [InnerTubeClient.web])
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        _ = try await extractor.extract(url, context: makeContext(http: http, tokens: [:], visitor: nil))

        let requests = await http.requests
        XCTAssertFalse(requests.contains { $0.headers["X-YouTube-Client-Name"] == "1" },
                       "无外部 token 时不应发起 web player API 请求（应复用页面响应）")
    }

    // MARK: - 有 token：走 player API 且带上收割的 visitorData

    func testWithGVSStokenWebCallsAPIWithHarvestedVisitor() async throws {
        let http = StubRecordingHTTP(watchHTML: Self.watchHTML, playerJSON: Self.webPlayerJSON)
        let extractor = YouTubeExtractor(clientOrder: [InnerTubeClient.web])
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let context = makeContext(http: http,
                                  tokens: ["web.gvs": "POT-GVS", "web.player": "POT-PLAYER"],
                                  visitor: "harvested-visitor")
        let info = try await extractor.extract(url, context: context)

        let requests = await http.requests
        let webCall = try XCTUnwrap(requests.first { $0.headers["X-YouTube-Client-Name"] == "1" },
                                    "有 GVS POT 时必须走 player API，不能复用页面响应")
        let body = try JSON(data: XCTUnwrap(webCall.body))
        XCTAssertEqual(body["context"]["client"]["visitorData"].string, "harvested-visitor")
        XCTAssertEqual(body["serviceIntegrityDimensions"]["poToken"].string, "POT-PLAYER")
        XCTAssertEqual(webCall.headers["X-Goog-Visitor-Id"], "harvested-visitor")

        // GVS POT 追加到格式 URL（itag 140 此前会因缺 POT 被丢弃）
        let urls = info.formats.map { $0.url.absoluteString }
        XCTAssertTrue(urls.contains { $0.contains("id=api-140") && $0.contains("pot=POT-GVS") },
                      "itag 140 应保留且带 pot 参数，实际: \(urls)")
        XCTAssertFalse(urls.contains { $0.contains("id=page-18") }, "不应混入页面响应格式")
    }

    func testGVSExperimentChoosesContentTokenAndSubsUseOwnContext() async throws {
        for videoBound in [false, true] {
            let config = "ytcfg.set({\"WEB_PLAYER_CONTEXT_CONFIGS\":{\"main\":{\"serializedExperimentFlags\":\"html5_generate_content_po_token=" + String(videoBound) + "\"}}});"
            let html = Self.watchHTML.replacingOccurrences(of:"</script>",with:config + "</script>")
            var response = try JSONSerialization.jsonObject(with:Data(Self.webPlayerJSON.utf8)) as! [String:Any]
            response["captions"] = ["playerCaptionsTracklistRenderer":["captionTracks":[["baseUrl":"https://www.youtube.com/api/timedtext?lang=en&pot=old", "languageCode":"en"]]]]
            let http = StubRecordingHTTP(watchHTML:html,playerJSON:String(data:try JSONSerialization.data(withJSONObject:response),encoding:.utf8)!)
            let tokens = ["web.gvs":"old", "web.gvs_session":"session", "web.gvs_video":"content", "web.player":"player", "web.subs":"subtitle"]
            let info = try await YouTubeExtractor(clientOrder:[InnerTubeClient.web]).extract(URL(string:"https://youtube.com/watch?v=dQw4w9WgXcQ")!,context:makeContext(http:http,tokens:tokens,visitor:"visitor"))
            let media = try XCTUnwrap(info.formats.first { $0.formatID == "140" })
            XCTAssertEqual(URLComponents(url:media.url,resolvingAgainstBaseURL:false)?.queryItems?.first { $0.name == "pot" }?.value,videoBound ? "content" : "session")
            let subtitle = try XCTUnwrap(info.subtitles.first)
            let query = URLComponents(url:subtitle.url,resolvingAgainstBaseURL:false)?.queryItems ?? []
            XCTAssertEqual(query.filter { $0.name == "pot" }.map(\.value),["subtitle"])
            XCTAssertEqual(query.first { $0.name == "potc" }?.value,"1")
            XCTAssertEqual(query.first { $0.name == "c" }?.value,"WEB")
        }
    }

    // MARK: - 无 token 时 itag 140 仍被 POT 规则丢弃（回归保护）

    func testWithoutTokenFormatsRequiringPOTAreDropped() async throws {
        let http = StubRecordingHTTP(watchHTML: Self.watchHTML, playerJSON: Self.webPlayerJSON)
        let extractor = YouTubeExtractor(clientOrder: [InnerTubeClient.web])
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        let info = try await extractor.extract(url, context: makeContext(http: http, tokens: [:], visitor: nil))
        let itags = info.formats.map(\.formatID)
        XCTAssertFalse(itags.contains("140"), "缺 POT 时 itag 140 应被丢弃")
        XCTAssertTrue(itags.contains("18"), "itag 18 为豁免格式，应保留")
    }
}

// MARK: - 记录型 Stub

/// 记录所有请求；watch 页与 player API 分别返回固定夹具（离线，不触网）。
actor StubRecordingHTTP: HTTPFetching {
    private(set) var requests: [HTTPRequest] = []
    private let watchHTML: String
    private let playerJSON: String

    init(watchHTML: String = "<html></html>", playerJSON: String = "{}") {
        self.watchHTML = watchHTML
        self.playerJSON = playerJSON
    }

    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url.path.contains("watch") || request.url.path.contains("embed") {
            return HTTPResponse(status: 200, headers: [:], body: Data(watchHTML.utf8))
        }
        if request.url.path.contains("youtubei/v1/player") {
            return HTTPResponse(status: 200, headers: [:], body: Data(playerJSON.utf8))
        }
        // base.js 等其余请求：返回空 HTML，挑战提取失败不影响 URL 直链格式
        return HTTPResponse(status: 200, headers: [:], body: Data("<html></html>".utf8))
    }
}
