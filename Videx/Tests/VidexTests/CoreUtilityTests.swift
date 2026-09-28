import XCTest
@testable import Videx

final class CoreUtilityTests: XCTestCase {
    func testQueryStringRoundTrip() {
        let params = QueryString.parse("a=1&b=hello%20world&c=&flag")
        XCTAssertEqual(params["a"], "1")
        XCTAssertEqual(params["b"], "hello world")
        XCTAssertEqual(params["c"], "")
        XCTAssertEqual(params["flag"], "")

        let encoded = QueryString.encode(["k": "a b", "z": "x&y"])
        XCTAssertEqual(encoded, "k=a%20b&z=x%26y")
    }

    func testURLEncodeMatchesJSRules() {
        XCTAssertEqual(QueryString.urlEncode("a!b'c(d)e~f*g"), "a!b'c(d)e~f*g")
        XCTAssertTrue(QueryString.urlEncode("a b").contains("%20"))
    }

    func testCookieJarDomainMatching() {
        var jar = CookieJar()
        jar.set(SiteCookie(name: "SESSDATA", value: "abc", domain: ".bilibili.com"))
        jar.set(SiteCookie(name: "VISITOR_INFO1_LIVE", value: "xyz", domain: ".youtube.com"))

        XCTAssertNotNil(jar.header(for: URL(string: "https://www.bilibili.com/video/x")!))
        XCTAssertNotNil(jar.header(for: URL(string: "https://api.bilibili.com/x/view")!))
        XCTAssertNotNil(jar.header(for: URL(string: "https://www.youtube.com/watch?v=1")!))
        XCTAssertNil(jar.header(for: URL(string: "https://example.com/")!))
        XCTAssertEqual(
            jar.value(named: "SESSDATA", forDomain: "bilibili.com"),
            "abc"
        )
    }

    func testSRTTimeFormatting() {
        XCTAssertEqual(SubtitleConverter.srtTime(0), "00:00:00,000")
        XCTAssertEqual(SubtitleConverter.srtTime(3661.5), "01:01:01,500")
        XCTAssertEqual(SubtitleConverter.srtTime(-1), "00:00:00,000")
    }

    func testYouTubeJSON3ToSRT() throws {
        let json = try JSON(data: Data("""
        {"events": [
          {"tStartMs": 0, "dDurationMs": 2000, "segs": [{"utf8": "Hello "}, {"utf8": "world"}]},
          {"tStartMs": 2500, "dDurationMs": 1500, "segs": [{"utf8": "  "}]},
          {"tStartMs": 4500, "dDurationMs": 3000, "segs": [{"utf8": "Second line"}]}
        ]}
        """.utf8))
        let srt = SubtitleConverter.srtFromYouTubeJSON3(json)
        XCTAssertTrue(srt.contains("00:00:00,000 --> 00:00:02,000"))
        XCTAssertTrue(srt.contains("Hello world"))
        // 空白字幕应被剔除，编号连续
        XCTAssertTrue(srt.contains("2\n00:00:04,500"))
        XCTAssertFalse(srt.contains("00:00:02,500"))
    }

    func testBilibiliJSONToSRT() throws {
        let json = try JSON(data: Data("""
        {"body": [{"from": 1.5, "to": 3.2, "content": "第一句"}, {"from": 4.0, "to": 6.0, "content": "第二句"}]}
        """.utf8))
        let srt = SubtitleConverter.srtFromBilibiliJSON(json)
        XCTAssertTrue(srt.contains("00:00:01,500 --> 00:00:03,200"))
        XCTAssertTrue(srt.contains("第一句"))
        XCTAssertTrue(srt.contains("第二句"))
    }

    func testExtractorRegistryRouting() async throws {
        let registry = ExtractorRegistry.standard
        XCTAssertEqual(registry.allExtractorIDs.sorted(), ["bilibili", "douyin", "tiktok", "youtube"])

        XCTAssertNotNil(registry.extractor(for: URL(string: "https://www.youtube.com/watch?v=abcdefghijk")!))
        XCTAssertNotNil(registry.extractor(for: URL(string: "https://youtu.be/abcdefghijk")!))
        XCTAssertNotNil(registry.extractor(for: URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7")!))
        XCTAssertNotNil(registry.extractor(for: URL(string: "https://b23.tv/xyz")!))
        XCTAssertNil(registry.extractor(for: URL(string: "https://vimeo.com/123")!))

        // 不支持站点应抛 unsupportedURL
        do {
            _ = try await registry.extract(url: URL(string: "https://vimeo.com/123")!)
            XCTFail("应抛错")
        } catch let error as ExtractionError {
            guard case .unsupportedURL = error else { return XCTFail("错误类型不符: \(error)") }
        }
    }

    func testProxyDictionaryParsing() {
        let http = URLSessionHTTPClient.proxyDictionary(from: "http://127.0.0.1:7890")
        XCTAssertEqual(http["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(http["HTTPPort"] as? Int, 7890)
        XCTAssertEqual(http["HTTPSProxy"] as? String, "127.0.0.1")

        let socks = URLSessionHTTPClient.proxyDictionary(from: "socks5://10.0.0.1:1080")
        XCTAssertEqual(socks[kCFStreamPropertySOCKSProxyHost as String] as? String, "10.0.0.1")
        XCTAssertEqual(socks[kCFStreamPropertySOCKSProxyPort as String] as? Int, 1080)

        XCTAssertTrue(URLSessionHTTPClient.proxyDictionary(from: "not-a-proxy").isEmpty)
    }

    func testMediaInfoBestAccessors() {
        var info = MediaInfo(extractorID: "t", id: "1", title: "T", webpageURL: URL(fileURLWithPath: "/"))
        info.formats = [
            MediaFormat(formatID: "v720", kind: .videoOnly, url: URL(fileURLWithPath: "/a"), height: 720),
            MediaFormat(formatID: "v1080", kind: .videoOnly, url: URL(fileURLWithPath: "/b"), height: 1080),
            MediaFormat(formatID: "a1", kind: .audioOnly, url: URL(fileURLWithPath: "/c"), averageBitrate: 100),
            MediaFormat(formatID: "a2", kind: .audioOnly, url: URL(fileURLWithPath: "/d"), averageBitrate: 300),
            MediaFormat(formatID: "m", kind: .muxed, url: URL(fileURLWithPath: "/e"), height: 360),
        ]
        XCTAssertEqual(info.bestVideoOnly?.formatID, "v1080")
        XCTAssertEqual(info.bestAudioOnly?.formatID, "a2")
        XCTAssertEqual(info.bestMuxed?.formatID, "m")
        // 排序展示：muxed 优先
        XCTAssertEqual(info.formats.sortedForDisplay().first?.kind, .muxed)
    }
}
