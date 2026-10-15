import XCTest
@testable import Videx

final class YouTubeParseTests: XCTestCase {
    /// web 风格 player response：signatureCipher + assets.js
    static let webStyleFixture = """
    {
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {
        "videoId": "dQw4w9WgXcQ", "title": "Test Video", "author": "Tester",
        "channelId": "UC123", "lengthSeconds": "212", "viewCount": "999",
        "shortDescription": "desc",
        "thumbnail": {"thumbnails": [{"url": "https://i.ytimg.com/vi/x/mq1.jpg", "width": 320}]}
      },
      "assets": {"js": "/s/player/abc123/base.js"},
      "streamingData": {
        "formats": [
          {"itag": 18, "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"",
           "signatureCipher": "s=ENCRYPTED_SIG&sp=sig&url=https%3A%2F%2Frr3.googlevideo.com%2Fvideoplayback%3Fid%3Do-x%26n%3DnExp1"}
        ],
        "adaptiveFormats": [
          {"itag": 137, "mimeType": "video/mp4; codecs=\\"avc1.640028\\"",
           "signatureCipher": "s=SIG2&sp=sig&url=https%3A%2F%2Frr3.googlevideo.com%2Fvideoplayback%3Fid%3Do-y",
           "width": 1920, "height": 1080, "fps": 30, "bitrate": 4500000, "contentLength": "123456789"},
          {"itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
           "url": "https://rr3.googlevideo.com/videoplayback?id=o-z",
           "averageBitrate": 129000}
        ]
      },
      "captions": {"playerCaptionsTracklistRenderer": {"captionTracks": [
        {"baseUrl": "https://www.youtube.com/api/timedtext?v=x&lang=en", "languageCode": "en",
         "name": {"runs": [{"text": "English"}]}, "kind": "asr"}
      ]}}
    }
    """

    /// POT / SABR 测试夹具：两条直链格式（itag 18 豁免 POT；itag 140 不豁免）
    /// + 一条既无 url 又无 signatureCipher 的 SABR-only 格式（itag 251）。
    static let potFixture = """
    {
      "playabilityStatus": {"status": "OK"},
      "videoDetails": {
        "videoId": "dQw4w9WgXcQ", "title": "Test Video", "author": "Tester",
        "channelId": "UC123", "lengthSeconds": "212", "viewCount": "999"
      },
      "streamingData": {
        "formats": [
          {"itag": 18, "mimeType": "video/mp4; codecs=\\"avc1.42001E, mp4a.40.2\\"",
           "url": "https://rr3.googlevideo.com/videoplayback?id=o-18"}
        ],
        "adaptiveFormats": [
          {"itag": 140, "mimeType": "audio/mp4; codecs=\\"mp4a.40.2\\"",
           "url": "https://rr3.googlevideo.com/videoplayback?id=o-140",
           "averageBitrate": 129000},
          {"itag": 251, "mimeType": "audio/webm; codecs=\\"opus\\"",
           "averageBitrate": 160000}
        ]
      }
    }
    """

    func testParseWebStyleFormats() async throws {
        let json = try JSON(data: Data(Self.webStyleFixture.utf8))
        // 免 POT 客户端（tv_samsung）：无挑战时应跳过 signatureCipher 格式、保留直链格式
        let context = ExtractionContext(http: StubHTTP(), js: JavaScriptCoreRuntime())
        let formats = StreamURLSolver(context: context).formats(
            from: json, client: InnerTubeClient.tvSamsung, challenge: nil
        )
        XCTAssertEqual(formats.count, 1)
        XCTAssertEqual(formats[0].kind, .audioOnly)
        XCTAssertEqual(formats[0].formatID, "140")
        XCTAssertEqual(formats[0].audioCodec, "mp4a.40.2")
        XCTAssertEqual(formats[0].container, "mp4")
    }

    /// POT 过滤：需 POT 的客户端（web）在无 Token 且未开逃生开关时，
    /// 仅保留 itag 18（上游同样豁免），其余 https/dash 格式丢弃。
    func testPoTokenRequiredClientKeepsOnlyExemptFormats() throws {
        let json = try JSON(data: Data(Self.potFixture.utf8))
        let context = ExtractionContext(http: StubHTTP(), js: JavaScriptCoreRuntime())
        let formats = StreamURLSolver(context: context).formats(
            from: json, client: InnerTubeClient.web, challenge: nil
        )
        XCTAssertEqual(formats.map(\.formatID), ["18"])
    }

    /// 免 POT 客户端不过滤，但 SABR-only（itag 251）仍被跳过。
    func testPotFreeClientKeepsDirectFormatsAndSkipsSABR() throws {
        let json = try JSON(data: Data(Self.potFixture.utf8))
        let context = ExtractionContext(http: StubHTTP(), js: JavaScriptCoreRuntime())
        let formats = StreamURLSolver(context: context).formats(
            from: json, client: InnerTubeClient.tvSamsung, challenge: nil
        )
        XCTAssertEqual(formats.map(\.formatID), ["18", "140"])
        XCTAssertFalse(formats.contains { $0.formatID == "251" }, "SABR-only 格式应被跳过")
    }

    /// includeFormatsMissingPoToken（等价上游 formats=missing_pot）强制返回全部。
    func testIncludeMissingPoTokenKeepsAll() throws {
        let json = try JSON(data: Data(Self.potFixture.utf8))
        let context = ExtractionContext(
            http: StubHTTP(), js: JavaScriptCoreRuntime(), includeFormatsMissingPoToken: true
        )
        let formats = StreamURLSolver(context: context).formats(
            from: json, client: InnerTubeClient.web, challenge: nil
        )
        XCTAssertEqual(formats.map(\.formatID), ["18", "140"])
    }

    func testSignatureCipherSolvedWithStubChallenge() async throws {
        let json = try JSON(data: Data(Self.webStyleFixture.utf8))
        let context = ExtractionContext(http: StubHTTP(), js: JavaScriptCoreRuntime())
        let solver = StreamURLSolver(context: context)

        // 挑战脚本：恒等逆操作 —— 返回输入原样前缀 + "OK"
        let challenge = PlayerChallenge(
            script: "var sigfn = function(s) { return 'OK' + s; };",
            decipherFunctionName: "sigfn",
            nsigFunctionName: nil,
            modern: nil,
            memo: SolutionMemo()
        )
        let sigMap = challenge.decipherBatch(["ENCRYPTED_SIG"], js: context.js)
        guard let base = solver.baseURL(from: json["streamingData"]["formats"][0], sigMap: sigMap) else {
            return XCTFail("baseURL 解析失败")
        }
        let muxed = solver.mediaFormat(
            from: json["streamingData"]["formats"][0], kind: .muxed, urlString: base, nMap: [:]
        )
        XCTAssertNotNil(muxed)
        XCTAssertTrue(muxed!.url.absoluteString.contains("&sig=OKENCRYPTED_SIG"), "解签参数应拼接: \(muxed!.url)")
        XCTAssertEqual(muxed!.qualityLabel, nil)
    }

    func testPlayabilityErrorMapping() {
        let extractor = YouTubeExtractor()
        let notOK = try? JSON(data: Data("""
        {"playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"}}
        """.utf8))
        let error = extractor.playabilityReasonPublic(notOK!)
        guard case .loginRequired(let site, _)? = error else {
            return XCTFail("应映射为 loginRequired")
        }
        XCTAssertEqual(site, "youtube")
    }

    /// 所有客户端均失败时，错误原因必须带逐客户端轮询明细（诊断用）。
    func testAllClientsFailAggregatesAttempts() async throws {
        let stub = StubHTTP(status: 200, body: Data("""
        {"playabilityStatus": {"status": "LOGIN_REQUIRED", "reason": "Sign in to confirm you're not a bot"}}
        """.utf8))
        let context = ExtractionContext(http: stub, js: JavaScriptCoreRuntime())
        let url = URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        do {
            _ = try await YouTubeExtractor().extract(url, context: context)
            XCTFail("所有客户端 LOGIN_REQUIRED 时应抛出错误")
        } catch let error as ExtractionError {
            guard case .loginRequired(let site, let reason) = error else {
                return XCTFail("应为 loginRequired，实际: \(error)")
            }
            XCTAssertEqual(site, "youtube")
            XCTAssertTrue(reason.contains("轮询明细"), "应包含逐客户端明细: \(reason)")
            for name in ["tv_samsung", "visionos", "web"] {
                XCTAssertTrue(reason.contains(name), "明细应含 \(name): \(reason)")
            }
        }
    }

    func testMediaInfoFromResponse() throws {
        let json = try JSON(data: Data(Self.webStyleFixture.utf8))
        let extractor = YouTubeExtractor()
        let info = extractor.buildMediaInfoPublic(videoID: "dQw4w9WgXcQ", response: json, formats: [])
        XCTAssertEqual(info.title, "Test Video")
        XCTAssertEqual(info.uploader, "Tester")
        XCTAssertEqual(info.duration, 212)
        XCTAssertEqual(info.viewCount, 999)
        XCTAssertEqual(info.subtitles.count, 1)
        XCTAssertEqual(info.subtitles[0].isAutoGenerated, true)
        XCTAssertTrue(info.subtitles[0].url.absoluteString.contains("fmt=json3"))
        XCTAssertEqual(info.extras["playerJSPath"], "/s/player/abc123/base.js")
    }
}

// MARK: - 测试桥接（避免把内部方法转 public）

extension YouTubeExtractor {
    func playabilityReasonPublic(_ response: JSON) -> ExtractionError? {
        playabilityReason(response)
    }

    func buildMediaInfoPublic(videoID: String, response: JSON, formats: [MediaFormat]) -> MediaInfo {
        buildMediaInfo(videoID: videoID, response: response, formats: formats)
    }
}

// MARK: - Stub HTTP（离线测试不触网）

struct StubHTTP: HTTPFetching {
    var status: Int
    var body: Data

    init(status: Int = 599, body: Data = Data("stub".utf8)) {
        self.status = status
        self.body = body
    }

    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(status: status, headers: [:], body: body)
    }
}
