import XCTest
import CSystemSupport
@testable import Videx

final class NativeExpansionTests: XCTestCase {
    func testEJSRealPlayerOnSystemJSC() throws {
        let player = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures/youtube_golden_player_74edf1a3.js"), encoding: .utf8)
        let solved = try NativeEJSSolver.solve(player: player, channel: "n", inputs: ["native_test_input"], runtime: JavaScriptCoreRuntime())
        XCTAssertFalse(try XCTUnwrap(solved["native_test_input"]).isEmpty)
    }
    func testDASHTemplateAndTimeline() throws {
        let xml = """
        <MPD mediaPresentationDuration="PT6S"><BaseURL>https://cdn.example.com/</BaseURL><Period><AdaptationSet mimeType="video/mp4" codecs="avc1.64001f"><BaseURL>video/</BaseURL><SegmentTemplate timescale="1000" initialization="$RepresentationID$-init.mp4" media="$RepresentationID$-$Number%05d$.m4s"><SegmentTimeline><S t="0" d="2000" r="-1"/></SegmentTimeline></SegmentTemplate><Representation id="137" height="1080" frameRate="30000/1001"/></AdaptationSet></Period></MPD>
        """
        let f = try XCTUnwrap(DASHParser.formats(Data(xml.utf8), url: URL(string: "https://example.com/master.mpd")!).first)
        XCTAssertEqual(f.fragments?.count, 4)
        XCTAssertEqual(f.fragments?[1].url.absoluteString, "https://cdn.example.com/video/137-00001.m4s")
        XCTAssertEqual(f.fragments?.last?.sequence, 3)
        XCTAssertEqual(f.fps, 30)
    }
    func testDASHDynamicWindow() throws {
        let xml = """
        <MPD type="dynamic" availabilityStartTime="2026-10-14T00:00:00Z" publishTime="2026-10-14T00:01:00Z" timeShiftBufferDepth="PT10S"><Period><AdaptationSet mimeType="video/mp4"><SegmentTemplate duration="2" initialization="init.mp4" media="seg-$Number$.m4s"/><Representation id="v"/></AdaptationSet></Period></MPD>
        """
        let f = try XCTUnwrap(DASHParser.formats(Data(xml.utf8), url: URL(string: "https://example.com/master.mpd")!).first)
        XCTAssertEqual(f.fragments?.count, 6)
        XCTAssertEqual(f.fragments?[1].sequence, 26)
        XCTAssertTrue(f.isLive == true)
    }
    func testDASHDRMIsExcluded() throws {
        let xml = "<MPD><Period><AdaptationSet><ContentProtection/><Representation id='x'><BaseURL>https://example.com/x.mp4</BaseURL></Representation></AdaptationSet></Period></MPD>"
        XCTAssertTrue(try DASHParser.formats(Data(xml.utf8), url: URL(string: "https://example.com/m.mpd")!).isEmpty)
    }
    private func format(_ id: String, _ kind: MediaKind, _ height: Int? = nil, _ lang: String? = nil) -> MediaFormat {
        MediaFormat(formatID: id, kind: kind, url: URL(string: "https://example.com/\(id)")!, container: "mp4",
            videoCodec: kind == .audioOnly ? nil : "avc1.64001f", audioCodec: kind == .videoOnly ? nil : "mp4a.40.2", height: height, language: lang)
    }
    func testFormatFallbackMergeAndLanguage() throws {
        let info = MediaInfo(extractorID: "youtube", id: "test", title: "Test", webpageURL: URL(string: "https://youtube.com")!, formats: [format("18", .muxed, 360), format("136", .videoOnly, 720), format("140", .audioOnly, nil, "ja")])
        XCTAssertEqual(try FormatSelector.select(info, expression: "bv[height<=720]+ba[language=ja]/b")[0].formats.map(\.formatID), ["136", "140"])
        XCTAssertEqual(try FormatSelector.select(info, expression: "bv[height>4000]/b")[0].formats.map(\.formatID), ["18"])
        XCTAssertEqual(try FormatSelector.select(info, expression: "136,140").count, 2)
        XCTAssertThrowsError(try FormatSelector.select(info, expression: "bv[height<=]"))
    }
    func testUMPBoundariesAndTruncation() throws {
        for n in [0, 127, 128, 16383, 16384, 2097151, 2097152, 268435455, 268435456, Int(UInt32.max)] {
            XCTAssertEqual(try UMP.decode(UMP.encode(type: n, data: Data([1])))[0].type, n)
        }
        XCTAssertThrowsError(try UMP.decode(Data([20,10,1])))
        XCTAssertThrowsError(try Protobuf.Message(Data([8]) + Data(repeating: 255, count: 9) + Data([2])))
    }
    private func sabrFormat() -> MediaFormat {
        var f = format("140-sabr", .audioOnly); f.protocolType = .sabr
        f.sabr = SABRConfiguration(videoID: "test", itag: 140, lastModified: 1, ustreamerConfig: "AQ==", clientID: 1, clientVersion: "test", userAgent: "test", duration: 2)
        return f
    }
    private func sabrResponse(_ sequence: UInt64, initSegment: Bool) -> HTTPResponse {
        var id = Protobuf.Writer(); id.integer(1, 140); id.integer(2, 1)
        var initMetadata = Protobuf.Writer(); initMetadata.string(1, "test"); initMetadata.bytes(2, id.data); initMetadata.integer(9, 2000); initMetadata.integer(10, 1000)
        var result = UMP.encode(type: 42, data: initMetadata.data)
        func segment(_ header: UInt64, _ initialization: Bool, _ bytes: String) -> Data {
            var message = Protobuf.Writer(); message.integer(1, header); message.bytes(13, id.data); message.integer(8, initialization ? 1 : 0); message.integer(14, UInt64(bytes.count))
            if !initialization { message.integer(9, sequence); message.integer(11, sequence * 1000); message.integer(12, 1000) }
            return UMP.encode(type: 20, data: message.data) + UMP.encode(type: 21, data: Data([UInt8(header)]) + Data(bytes.utf8)) + UMP.encode(type: 22, data: Data([UInt8(header)]))
        }
        if initSegment { result += segment(1, true, "INIT") }
        result += segment(2, false, sequence == 0 ? "ABC" : "DEF")
        return HTTPResponse(status: 200, headers: [:], body: result)
    }
    func testSABRNativeRequestAndSegments() async throws {
        let target = temporary(), http = ExpansionHTTP([sabrResponse(0, initSegment: true), sabrResponse(1, initSegment: false)])
        defer { cleanup(target) }
        _ = try await SABRDownloader.download(format: sabrFormat(), to: target, http: http, options: SABRDownloadOptions(retries: 0))
        XCTAssertEqual(try Data(contentsOf: target), Data("INITABCDEF".utf8))
        let requests = await http.requests
        let message = try Protobuf.Message(XCTUnwrap(requests[1].body))
        XCTAssertEqual(message.integer(4), 1000)
        XCTAssertNotNil(message.bytes(2)); XCTAssertNotNil(message.bytes(3))
    }
    func testSABRResumeAfterOffline() async throws {
        let target = temporary(); defer { cleanup(target) }
        do { _ = try await SABRDownloader.download(format: sabrFormat(), to: target, http: ExpansionHTTP([sabrResponse(0, initSegment: true)]), options: SABRDownloadOptions(retries: 0)); XCTFail("应断网") } catch {}
        _ = try await SABRDownloader.download(format: sabrFormat(), to: target, http: ExpansionHTTP([sabrResponse(1, initSegment: false)]), options: SABRDownloadOptions(retries: 0))
        XCTAssertEqual(try Data(contentsOf: target), Data("INITABCDEF".utf8))
    }
    func testSABRRequiresExternalPOTWithoutGeneratingOne() async throws {
        let target = temporary(); defer { cleanup(target) }
        var message = Protobuf.Writer(); message.integer(1, 3)
        do { _ = try await SABRDownloader.download(format: sabrFormat(), to: target, http: ExpansionHTTP([HTTPResponse(status: 200, headers: [:], body: UMP.encode(type: 58, data: message.data))]), options: SABRDownloadOptions(retries: 0)); XCTFail("应缺 Token") }
        catch let error as ExtractionError { guard case .loginRequired = error else { return XCTFail("错误分类不符") } }
    }
    func testRangeDownloadResumeDoesNotDuplicateBytes() async throws {
        let target = temporary(); defer { cleanup(target) }
        let first = HTTPResponse(status: 206, headers: ["Content-Range":"bytes 0-2/6", "ETag":"same"], body: Data("ABC".utf8))
        let second = HTTPResponse(status: 206, headers: ["Content-Range":"bytes 3-5/6", "ETag":"same"], body: Data("DEF".utf8))
        do { _ = try await NativeMediaDownloader.download(format: format("140", .audioOnly), to: target, http: ExpansionHTTP([first])) } catch {}
        _ = try await NativeMediaDownloader.download(format: format("140", .audioOnly), to: target, http: ExpansionHTTP([second]))
        XCTAssertEqual(try Data(contentsOf: target), Data("ABCDEF".utf8))
    }
    func testConcurrentRangeDownloadAndOutOfOrderResume() async throws {
        let target = temporary(); defer { cleanup(target) }
        let fullPayload = Data("0123456789ABCDEF".utf8) // 16 bytes, 4 chunks of 4 bytes
        let firstRun = RangeMockHTTP(payload: fullPayload, failRange: "bytes=4-7")
        do {
            _ = try await NativeMediaDownloader.downloadFile(
                url: URL(string: "https://example.com/model.bin")!,
                to: target,
                http: firstRun,
                concurrency: 3,
                chunkSize: 4
            )
            XCTFail("首轮下载应在模拟断网处抛错")
        } catch {}
        // 校验 .part 与 .state.json 已保留：0-3 已完成，8-11/12-15 也可能已在并发中完成落盘
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathExtension("part").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.appendingPathExtension("state.json").path))

        let secondRun = RangeMockHTTP(payload: fullPayload, failRange: nil)
        _ = try await NativeMediaDownloader.downloadFile(
            url: URL(string: "https://example.com/model.bin")!,
            to: target,
            http: secondRun,
            concurrency: 3,
            chunkSize: 4
        )
        XCTAssertEqual(try Data(contentsOf: target), fullPayload)
        let secondRanges = await secondRun.requestedRanges
        XCTAssertFalse(secondRanges.contains("bytes=0-3"), "已落盘的首块不应在续传时重复下载")
        XCTAssertTrue(secondRanges.contains("bytes=4-7"), "首轮失败的分块应在续传时补齐")
    }
    func testConcurrentDASHFragmentsCommitInStrictOrder() async throws {
        let target = temporary(); defer { cleanup(target) }
        let urls = (0..<5).map { URL(string: "https://example.com/seg\($0).m4s")! }
        let fragments = urls.enumerated().map { idx, u in
            MediaFragment(url: u, duration: 2.0, isInitialization: idx == 0, sequence: Int64(idx))
        }
        let dashFormat = MediaFormat(
            formatID: "dash-v",
            kind: .videoOnly,
            url: urls[0],
            protocolType: .dash,
            fragments: fragments
        )
        let http = DelayedFragmentHTTP(payloads: [
            urls[0]: Data("INIT-".utf8),
            urls[1]: Data("SEG1-".utf8),
            urls[2]: Data("SEG2-".utf8),
            urls[3]: Data("SEG3-".utf8),
            urls[4]: Data("SEG4".utf8),
        ])
        _ = try await NativeMediaDownloader.download(format: dashFormat, to: target, http: http, concurrency: 4)
        XCTAssertEqual(String(data: try Data(contentsOf: target), encoding: .utf8), "INIT-SEG1-SEG2-SEG3-SEG4")
        let maxInFlight = await http.maxConcurrent
        XCTAssertGreaterThan(maxInFlight, 1, "DASH 分片应多并发拉取")
    }
    func testHLSRangesAndSequence() async throws {
        let target = temporary(); defer { cleanup(target) }
        let text = "#EXTM3U\n#EXT-X-MEDIA-SEQUENCE:12\n#EXT-X-TARGETDURATION:2\n#EXTINF:2,\n#EXT-X-BYTERANGE:3@0\nmedia.mp4\n#EXTINF:2,\n#EXT-X-BYTERANGE:3\nmedia.mp4\n#EXT-X-ENDLIST"
        let http = ExpansionHTTP([HTTPResponse(status: 200, headers: [:], body: Data(text.utf8)), HTTPResponse(status: 206, headers: [:], body: Data("ABC".utf8)), HTTPResponse(status: 206, headers: [:], body: Data("DEF".utf8))])
        var f = format("hls", .muxed); f.protocolType = .hls
        _ = try await NativeHLSDownloader.download(format: f, to: target, http: http)
        XCTAssertEqual(try Data(contentsOf: target), Data("ABCDEF".utf8))
        let requests = await http.requests
        XCTAssertEqual(requests[1].headers["Range"], "bytes=0-2"); XCTAssertEqual(requests[2].headers["Range"], "bytes=3-5")
    }
    func testTranslationsCommentsAndChapterEnrichment() throws {
        let captions = try JSON(data: Data(#"{"captions":{"playerCaptionsTracklistRenderer":{"captionTracks":[{"baseUrl":"https://youtube.com/timedtext?v=x","languageCode":"en","isTranslatable":true}],"translationLanguages":[{"languageCode":"ja"}]}}}"#.utf8))
        let tracks = YouTubeMetadata.subtitles(from: captions)
        XCTAssertEqual(tracks.count, 2); XCTAssertEqual(tracks[1].sourceLanguage, "en"); XCTAssertTrue(tracks[1].url.absoluteString.contains("tlang=ja"))
        let data = try JSON(data: Data(#"{"commentRenderer":{"commentId":"c1","contentText":{"runs":[{"text":"hello "},{"text":"world"}]}},"continuationCommand":{"token":"next"}}"#.utf8))
        let page = YouTubeDiscussionService.parseComments(data)
        XCTAssertEqual(page.comments.first?.text, "hello world"); XCTAssertEqual(page.continuation, "next")
        var info = MediaInfo(extractorID: "youtube", id: "test", title: "Test", webpageURL: URL(string: "https://youtube.com")!, duration: 10)
        YouTubeMetadata.enrich(&info, from: try JSON(data: Data(#"{"chapterRenderer":{"timeRangeStartMillis":5000,"title":{"simpleText":"Next"}}}"#.utf8)))
        XCTAssertEqual(info.chapters?.first?.end, 10)
    }
    func testArchiveValidatesOutputExistence() async throws {
        let file = temporary(), output = temporary(); defer { cleanup(file); cleanup(output); try? FileManager.default.removeItem(at: file.appendingPathExtension("lock")) }
        try Data("media".utf8).write(to: output)
        let archive = DownloadArchive(url: file)
        try await archive.record("youtube test", output: output)
        let exists = try await archive.contains("youtube test"); XCTAssertTrue(exists)
        try FileManager.default.removeItem(at: output)
        let gone = try await archive.contains("youtube test"); XCTAssertFalse(gone)
    }
    func testDynamicDASHRefreshUsesNewManifestURL() async throws {
        let old = URL(string: "https://cdn.example.com/old-manifest")!
        let fresh = URL(string: "https://cdn.example.com/new-manifest")!
        let xml = "<MPD mediaPresentationDuration=\"PT2S\"><Period><AdaptationSet mimeType=\"audio/mp4\"><SegmentTemplate duration=\"2\" initialization=\"init.mp4\" media=\"$Number$.m4s\"/><Representation id=\"140\"/></AdaptationSet></Period></MPD>"
        let http = ExpansionHTTP([HTTPResponse(status:403,headers:[:],body:Data()), HTTPResponse(status:200,headers:[:],body:Data(xml.utf8)), HTTPResponse(status:200,headers:[:],body:Data("INIT".utf8)), HTTPResponse(status:200,headers:[:],body:Data("MEDIA".utf8))])
        let initial = MediaFormat(formatID:"140-dash",kind:.audioOnly,url:old,protocolType:.dash,manifestURL:old,representationID:"140",isLive:true)
        let updated = MediaFormat(formatID:"140-dash",kind:.audioOnly,url:fresh,protocolType:.dash,manifestURL:fresh,representationID:"140",isLive:true)
        let target = temporary(); defer { cleanup(target) }
        _ = try await NativeMediaDownloader.download(format:initial,to:target,http:http,refresh:{ updated },liveFromStart:true)
        XCTAssertEqual(try Data(contentsOf:target),Data("INITMEDIA".utf8))
        let requests = await http.requests
        XCTAssertEqual(requests[1].url,fresh)
    }
    private func temporary() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent("videx-native-\(UUID().uuidString)") }
    private func cleanup(_ url: URL) { for suffix in ["", "part", "state.json", "hls-state.json", "sabr-state.json"] { try? FileManager.default.removeItem(at: suffix.isEmpty ? url : url.appendingPathExtension(suffix)) } }
}
private actor ExpansionHTTP: HTTPFetching {
    var responses: [HTTPResponse]; var requests: [HTTPRequest] = []
    init(_ responses: [HTTPResponse]) { self.responses = responses }
    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse { requests.append(request); guard !responses.isEmpty else { throw ExtractionError.network("simulated offline") }; return responses.removeFirst() }
}

private actor RangeMockHTTP: HTTPFetching {
    let payload: Data
    let failRange: String?
    var requestedRanges: [String] = []

    init(payload: Data, failRange: String?) {
        self.payload = payload
        self.failRange = failRange
    }

    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let rangeHeader = request.headers["Range"],
              rangeHeader.hasPrefix("bytes=") else {
            return HTTPResponse(status: 200, headers: ["ETag": "\"v1\""], body: payload)
        }
        requestedRanges.append(rangeHeader)
        if rangeHeader == failRange {
            throw ExtractionError.network("simulated range failure for \(rangeHeader)")
        }
        let parts = rangeHeader.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let start = parts[0]
        let end = min(payload.count - 1, parts[1])
        let slice = Data(payload[start...end])
        return HTTPResponse(
            status: 206,
            headers: [
                "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                "ETag": "\"v1\"",
            ],
            body: slice
        )
    }
}

private actor DelayedFragmentHTTP: HTTPFetching {
    let payloads: [URL: Data]
    var active = 0
    var maxConcurrent = 0

    init(payloads: [URL: Data]) {
        self.payloads = payloads
    }

    private func endRequest() {
        active -= 1
    }

    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        active += 1
        maxConcurrent = max(maxConcurrent, active)
        // 让后续分片比首分片更快返回，验证乱序返回下的顺序落盘与真实并发度
        let delayMS: UInt64 = request.url.absoluteString.contains("seg1") ? 40 : 10
        try await Task.sleep(for: .milliseconds(delayMS))
        endRequest()
        guard let data = payloads[request.url] else {
            return HTTPResponse(status: 404, headers: [:], body: Data())
        }
        return HTTPResponse(status: 200, headers: [:], body: data)
    }
}
