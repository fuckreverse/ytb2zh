import XCTest
import Videx
@testable import Ytb2ZHEngines

final class WebPoTokenTests: XCTestCase {
    private func token() -> HarvestedPoToken {
        var token = HarvestedPoToken(visitorData: "visitor", poToken: "session", harvestedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        token.videoID = "dQw4w9WgXcQ"; token.videoPoToken = "content"; token.sessionPoToken = "session"
        return token
    }
    func testContextsUseCorrectBindingsAndNeverCrossVideos() throws {
        var token = token()
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.gvs"], "session")
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.player"], "content")
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.subs"], "content")
        XCTAssertTrue(token.tokens(for: "jNQXAC9IVRw").isEmpty)
        token.gvsBoundToVideo = true
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.gvs"], "content")
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.gvs_session"], "session")
        XCTAssertEqual(token.tokens(for: "dQw4w9WgXcQ")["web.gvs_video"], "content")
    }
    func testLegacyVisitorOnlyCacheCannotBecomePlayerToken() throws {
        let original = HarvestedPoToken(visitorData: "visitor", poToken: "old", harvestedAt: Date(), expiresAt: Date().addingTimeInterval(3600))
        let decoded = try JSONDecoder().decode(HarvestedPoToken.self, from: JSONEncoder().encode(original))
        XCTAssertTrue(decoded.tokens(for: "dQw4w9WgXcQ").isEmpty)
    }
    func testScopeIncludesVideoProxyAndAccountButNotCookieOrder() {
        let a = SiteCookie(name:"SAPISID",value:"a",domain:".youtube.com")
        let b = SiteCookie(name:"LOGIN_INFO",value:"b",domain:".youtube.com")
        let jar = CookieJar(cookies:[a,b])
        let key = WebPoTokenProvider.scope(videoID:"a",proxy:nil,cookies:jar)
        XCTAssertEqual(key, WebPoTokenProvider.scope(videoID:"a",proxy:nil,cookies:CookieJar(cookies:[b,a])))
        XCTAssertNotEqual(key, WebPoTokenProvider.scope(videoID:"b",proxy:nil,cookies:jar))
        XCTAssertNotEqual(key, WebPoTokenProvider.scope(videoID:"a",proxy:"http://localhost:7890",cookies:jar))
        XCTAssertNotEqual(key, WebPoTokenProvider.scope(videoID:"a",proxy:nil,cookies:CookieJar()))
    }
    func testOriginalPlaybackPreservesRouteAndBrowserHeaders() throws {
        let media = MediaFormat(formatID:"18",kind:.muxed,url:URL(string:"https://media.example/video")!,height:360,requestHeaders:["User-Agent":"WK","Cookie":"session=1"])
        var info = MediaInfo(extractorID:"youtube",id:"video",title:"test",webpageURL:URL(string:"https://youtube.com")!,formats:[media])
        info.extras["videx_proxy"] = ""
        let playable = try XCTUnwrap(VidexBridge.playableStream(info))
        XCTAssertEqual(playable.proxyOverride,"")
        let server = OrigStreamServer(kind:playable.kind,proxy:playable.proxyOverride ?? "wrong",requestHeaders:playable.requestHeaders)
        XCTAssertEqual(server.proxyValue(),"")
        XCTAssertEqual(server.upstreamHeaders(for:media.url)["Cookie"],"session=1")
        XCTAssertNil(server.upstreamHeaders(for:URL(string:"https://other.example/segment")!)["Cookie"])
        XCTAssertEqual(server.upstreamHeaders(for:URL(string:"https://other.example/segment")!)["User-Agent"],"WK")
    }
    func testAccountBindingPreservesWholeDataSyncID() throws {
        let js = JavaScriptCoreRuntime()
        let function = "(" + WebPoTokenScripts.sessionBinding + ")"
        XCTAssertEqual(try js.evaluate(code:"",globalStubs:[:],expression:function + "(true, 'channel||user', 'visitor')"),"channel||user")
        XCTAssertEqual(try js.evaluate(code:"",globalStubs:[:],expression:function + "(true, 'user||', 'visitor')"),"user||")
        XCTAssertEqual(try js.evaluate(code:"",globalStubs:[:],expression:function + "(false, '', 'visitor')"),"visitor")
        XCTAssertThrowsError(try js.evaluate(code:"",globalStubs:[:],expression:function + "(true, '', 'visitor')"))
    }
    func testExpiredTokenIsNotFresh() {
        let now = Date(); var value = token(); value.expiresAt = now
        XCTAssertFalse(value.isFresh(now:now))
    }
    func testConcurrentRequestsShareOneHarvest() async throws {
        let coordinator = PoTokenHarvestCoordinator(), counter = HarvestCounter()
        let value = token()
        let operation: @Sendable () async throws -> HarvestedPoToken = {
            await counter.increment(); try await Task.sleep(for:.milliseconds(50)); return value
        }
        async let a = coordinator.run(key:"same",operation:operation)
        async let b = coordinator.run(key:"same",operation:operation)
        let results = try await [a,b]
        XCTAssertEqual(results[0],results[1])
        let calls = await counter.value; XCTAssertEqual(calls,1)
    }
    func testBrowserIdentityPropagatesIntoWebRequestBody() async throws {
        let recorder = PotRequestRecorder()
        let http = PoTokenSessionHTTPClient(base:recorder,userAgent:"WK identity")
        var request = try HTTPRequest.post(URL(string:"https://www.youtube.com/youtubei/v1/player")!,json:["context":["client":["clientName":"WEB"]]])
        request.headers["X-YouTube-Client-Name"] = "1"
        _ = try await http.fetch(request)
        let recorded = await recorder.last()
        let sent = try XCTUnwrap(recorded)
        XCTAssertEqual(sent.headers["User-Agent"],"WK identity")
        let body = try JSON(data:XCTUnwrap(sent.body))
        XCTAssertEqual(body["context"]["client"]["userAgent"].string,"WK identity")
        request.headers["X-YouTube-Client-Name"] = "7"; request.headers["User-Agent"] = "TV"
        _ = try await http.fetch(request)
        let tv = await recorder.last(); XCTAssertEqual(tv?.headers["User-Agent"],"TV")
    }
}
private actor HarvestCounter { var value = 0; func increment() { value += 1 } }
private actor PotRequestRecorder: HTTPFetching {
    var request: HTTPRequest?
    func last() -> HTTPRequest? { request }
    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse { self.request = request; return HTTPResponse(status:200,headers:[:],body:Data()) }
}
