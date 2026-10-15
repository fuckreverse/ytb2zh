import XCTest
@testable import Videx

final class YouTubeParityTests: XCTestCase {
    func testHLSVariantsExternalAudioAndRelativeURLs() {
        let text = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English, original",LANGUAGE="en",URI="audio/itag/140/index.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=2000000,AVERAGE-BANDWIDTH=1500000,RESOLUTION=1280x720,FRAME-RATE=59.94,CODECS="avc1.640020,mp4a.40.2",AUDIO="aud"
        video/itag/136/index.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=800000,RESOLUTION=640x360,CODECS="avc1.42001e,mp4a.40.2"
        /itag/18/index.m3u8
        """
        let formats = HLSParser.formats(text.replacingOccurrences(of: "\n", with: "\r\n"), url: URL(string: "https://example.com/master/index.m3u8")!)
        XCTAssertEqual(formats.count, 3)
        XCTAssertEqual(formats[0].formatID, "140-hls")
        XCTAssertEqual(formats[0].qualityLabel, "English, original")
        XCTAssertEqual(formats[1].kind, .videoOnly)
        XCTAssertNil(formats[1].audioCodec)
        XCTAssertEqual(formats[1].fps, 60)
        XCTAssertEqual(formats[1].url.absoluteString, "https://example.com/master/video/itag/136/index.m3u8")
        XCTAssertEqual(formats[2].kind, .muxed)
        XCTAssertEqual(formats[2].audioCodec, "mp4a.40.2")
    }

    func testHLSMediaPlaylistAndDRM() {
        let base = URL(string: "https://example.com/video.m3u8")!
        let text = "#EXTM3U\n#EXT-X-KEY:METHOD=AES-128,URI=\"key\"\n#EXTINF:10,\nsegment.ts"
        XCTAssertEqual(HLSParser.formats(text, url: base).first?.url, base)
        XCTAssertTrue(HLSParser.formats(text.replacingOccurrences(of: "AES-128", with: "SAMPLE-AES"), url: base).isEmpty)
        XCTAssertTrue(HLSParser.formats("<html>Forbidden</html>", url: base).isEmpty)
    }

    func testWebpageStateAndVideoIDValidation() {
        let html = """
        ytcfg.set({"VISITOR_DATA":"visitor", "STS":12345,"PLAYER_JS_URL":"/s/player/abc/base.js"});
        ytcfg.set({"SESSION_INDEX":2,"DATASYNC_ID":"channel||user", "LOGGED_IN":true});
        var ytInitialPlayerResponse = {"videoDetails":{"videoId":"dQw4w9WgXcQ","title":"a } title"},"playabilityStatus":{"status":"OK"}};
        """
        let state = YouTubeSession.parse(html, videoID: "dQw4w9WgXcQ")
        XCTAssertEqual(state.visitorData, "visitor")
        XCTAssertEqual(state.signatureTimestamp, 12345)
        XCTAssertEqual(state.initialPlayer?["videoDetails"]["title"].string, "a } title")
        XCTAssertEqual(state.headers(cookies: CookieJar())["X-Goog-AuthUser"], "2")
        XCTAssertEqual(state.headers(cookies: CookieJar())["X-Goog-PageId"], "channel")
        XCTAssertNil(YouTubeSession.parse(html, videoID: "OTHER_VIDEO").initialPlayer)
    }

    func testCookieAuthenticationHashAndGuestDetection() {
        var jar = CookieJar(cookies: [SiteCookie(name: "SOCS", value: "CAI", domain: ".youtube.com")])
        XCTAssertFalse(jar.hasYouTubeAuthentication)
        XCTAssertEqual(InnerTubeClient.defaultClientOrder(cookies: jar).first?.key, "tv_samsung")
        jar.set(SiteCookie(name: "SAPISID", value: "test-sid", domain: ".youtube.com"))
        jar.set(SiteCookie(name: "LOGIN_INFO", value: "test-login", domain: ".youtube.com"))
        XCTAssertTrue(jar.hasYouTubeAuthentication)
        XCTAssertEqual(YouTubeSession().headers(cookies: jar, timestamp: 1700000000)["Authorization"],
                       "SAPISIDHASH 1700000000_d0d4e0189fe9525f33c6af9b38d05f54a61c69bd")
        let impostor = CookieJar(cookies: [SiteCookie(name: "SAPISID", value: "fake", domain: ".evilyoutube.com")])
        XCTAssertNil(YouTubeSession().headers(cookies: impostor)["Authorization"])
    }

    func testNetscapeCookiesHandlesHttpOnlyAndExpiry() throws {
        let text = "#HttpOnly_.youtube.com\tTRUE\t/\tTRUE\t0\tSAPISID\tsecret\n.youtube.com\tTRUE\t/\tTRUE\t999\tEXPIRED\told\n.youtube.com\tTRUE\t/\tTRUE\t9999999999\tLOGIN_INFO\tlogin"
        let jar = try CookieJar(netscape: text, now: 1000)
        XCTAssertTrue(jar.hasYouTubeAuthentication)
        XCTAssertNil(jar.value(named: "EXPIRED", forDomain: "youtube.com"))
        XCTAssertThrowsError(try CookieJar(netscape: "not a cookie file"))
    }

    func testCookieScopeAndEmptyValueImport() throws {
        let jar = try CookieJar(netscape: ".youtube.com\tTRUE\t/private\tTRUE\t0\tEMPTY\t\n")
        XCTAssertEqual(jar.cookies.count, 1)
        XCTAssertNil(jar.header(for: URL(string: "https://www.youtube.com/watch")!))
        XCTAssertNil(jar.header(for: URL(string: "http://www.youtube.com/private/video")!))
        XCTAssertEqual(jar.header(for: URL(string: "https://www.youtube.com/private/video")!), "EMPTY=")
        XCTAssertNil(jar.header(for: URL(string: "https://www.youtube.com/private-other")!))
    }

    func testMergesClientsDeduplicatesAndRetainsBackups() async throws {
        let info = try await YouTubeExtractor(clientOrder: [InnerTubeClient.visionos, InnerTubeClient.web])
            .extract(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, context: ExtractionContext(http: ParityHTTP(), js: JavaScriptCoreRuntime(), youtubePoTokens: ["web.gvs": "test-pot"]))
        XCTAssertEqual(Set(info.formats.map(\.formatID)), Set(["18", "140", "136-hls"]))
        XCTAssertEqual(info.formats.filter { $0.formatID == "140" }.count, 1)
        XCTAssertEqual(info.formats.first { $0.formatID == "140" }?.backupURLs?.count, 1)
        let muxed = try XCTUnwrap(info.formats.first { $0.formatID == "18" })
        XCTAssertEqual(muxed.videoCodec, "avc1.42001E")
        XCTAssertEqual(muxed.audioCodec, "mp4a.40.2")
        XCTAssertTrue(muxed.url.absoluteString.contains("pot=test-pot"))
    }

    func testSuccessfulClientSurvivesLaterFailure() async throws {
        let info = try await YouTubeExtractor(clientOrder: [InnerTubeClient.visionos, InnerTubeClient.web])
            .extract(URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, context: ExtractionContext(http: ParityHTTP(failWeb: true), js: JavaScriptCoreRuntime()))
        XCTAssertEqual(info.formats.map(\.formatID), ["140"])
    }

    func testPlayerRequestCarriesSessionAndToken() async throws {
        let http = ParityHTTP()
        var state = YouTubeSession()
        state.visitorData = "visitor-data"
        state.signatureTimestamp = 12345
        _ = try await InnerTubeClient(http: http, cookies: CookieJar()).player(videoID: "dQw4w9WgXcQ", client: InnerTubeClient.web, session: state, playerPoToken: "player-token")
        let requests = await http.requests
        let request = try XCTUnwrap(requests.first)
        let body = try JSON(data: XCTUnwrap(request.body))
        XCTAssertEqual(request.headers["X-Goog-Visitor-Id"], "visitor-data")
        XCTAssertEqual(body["playbackContext"]["contentPlaybackContext"]["signatureTimestamp"].int, 12345)
        XCTAssertEqual(body["serviceIntegrityDimensions"]["poToken"].string, "player-token")
    }
}

private actor ParityHTTP: HTTPFetching {
    var requests: [HTTPRequest] = []
    let failWeb: Bool
    init(failWeb: Bool = false) { self.failWeb = failWeb }
    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        if request.url.path.contains("watch") { return HTTPResponse(status: 200, headers: [:], body: Data("<html></html>".utf8)) }
        if request.url.path.contains(".m3u8") {
            return HTTPResponse(status: 200, headers: [:], body: Data("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1000000,RESOLUTION=1280x720,CODECS=\"avc1.64001f\"\n/itag/136/index.m3u8".utf8))
        }
        let web = request.headers["X-YouTube-Client-Name"] == "1"
        if web && failWeb { return HTTPResponse(status: 200, headers: [:], body: Data("{\"playabilityStatus\":{\"status\":\"LOGIN_REQUIRED\",\"reason\":\"Sign in\"}}".utf8)) }
        let json: [String: Any] = [
            "playabilityStatus": ["status": "OK"],
            "videoDetails": ["videoId": "dQw4w9WgXcQ", "title": "Test"],
            "streamingData": [
                "formats": web ? [["itag":18,"mimeType":"video/mp4; codecs=\"avc1.42001E, mp4a.40.2\"", "url":"https://example.com/muxed"]] : [],
                "adaptiveFormats": [["itag":140, "mimeType":"audio/mp4; codecs=\"mp4a.40.2\"", "url":"https://example.com/audio?client=\(web ? "web" : "visionos")"]],
                "hlsManifestUrl": web ? "https://example.com/master.m3u8" : NSNull(),
            ],
        ]
        return HTTPResponse(status: 200, headers: [:], body: try JSONSerialization.data(withJSONObject: json))
    }
}
