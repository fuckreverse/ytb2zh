import XCTest
@testable import Ytb2ZHEngines
import Videx

/// WebView POT 收割的**联网**验证（默认跳过，避免 CI 触网/污染缓存）。
///
/// 运行：`POT_LIVE=1 swift test --disable-sandbox --filter WebPoTokenLiveTests`
///
/// 该测试会真实加载 youtube.com、下载 interpreter、执行 BotGuard 并铸 token，
/// 并把结果写入 `~/.ytb2zh/pot.json` 缓存 —— 与 App 生产路径完全一致。
final class WebPoTokenLiveTests: XCTestCase {

    private var enabled: Bool { ProcessInfo.processInfo.environment["POT_LIVE"] == "1" }

    func testHarvestLiveTokens() async throws {
        try XCTSkipUnless(enabled, "需要 POT_LIVE=1（联网收割）")

        let token = try await WebPoTokenProvider.harvest(videoID: "dQw4w9WgXcQ", timeout: 90, bypassThrottle: true) { line in
            FileHandle.standardError.write(Data((line + "\n").utf8))
        }
        XCTAssertFalse(token.visitorData.isEmpty)
        XCTAssertGreaterThan(token.poToken.count, 100, "POT 长度异常（应 ~700+）")
        XCTAssertFalse(try XCTUnwrap(token.videoPoToken).isEmpty)
        XCTAssertFalse(token.tokens(for: "dQw4w9WgXcQ").isEmpty)
        XCTAssertTrue(token.tokens(for: "jNQXAC9IVRw").isEmpty)
        XCTAssertTrue(token.isFresh(), "缓存应处于有效期内")

        // 缓存往返
        let cached = try XCTUnwrap(WebPoTokenProvider.cached(scope: WebPoTokenProvider.scope(videoID: "dQw4w9WgXcQ", proxy: nil, cookies: CookieJar())))
        XCTAssertEqual(cached.visitorData, token.visitorData)
        XCTAssertEqual(cached.poToken, token.poToken)
    }

    /// 用收割到的 token 走一次真实提取：POT 有效时会解锁 web 客户端全量格式。
    ///
    /// 出口 IP 被 YouTube 标注（LOGIN_REQUIRED，所有客户端一致）时跳过——这是网络
    /// 环境阻塞而非实现失败（POT 不能绕过基于 IP 的登录限制，见 bgutil 说明）；
    /// 其余失败（notExtractable 等）仍视为真实失败。
    func testExtractionWithHarvestedTokens() async throws {
        try XCTSkipUnless(enabled, "需要 POT_LIVE=1（联网提取）")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POT_LIVE_EXTRACT"] == "1",
                          "需要 POT_LIVE_EXTRACT=1（真正跑一次提取）")

        let token = try await WebPoTokenProvider.harvest(videoID: "dQw4w9WgXcQ", timeout: 90, bypassThrottle: true)
        var options = ExtractionOptions()
        options.youtubeVisitorData = token.visitorData
        options.youtubePoTokens = token.tokens(for: "dQw4w9WgXcQ")
        options.cookies = token.cookies ?? CookieJar()
        options.log = StderrLogSink(minLevel: .debug)

        let url = URL(string: ProcessInfo.processInfo.environment["POT_LIVE_URL"]
            ?? "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!
        do {
            let info = try await ExtractorRegistry.standard.extract(url: url, options: options)
            XCTAssertFalse(info.formats.isEmpty, "带 POT 的 web 客户端应返回格式")
            print("[live] title=\(info.title) formats=\(info.formats.count)")
        } catch ExtractionError.loginRequired(let site, let reason) {
            throw XCTSkip("出口 IP 被标注（\(site): \(reason.prefix(80))）——待干净出口复验")
        }
    }

    func testWebOnlySABRDownloadWithNativeProvider() async throws {
        try XCTSkipUnless(enabled && ProcessInfo.processInfo.environment["POT_LIVE_DOWNLOAD"] == "1", "Requires POT_LIVE_DOWNLOAD=1")
        let videoID = ProcessInfo.processInfo.environment["POT_VIDEO_ID"] ?? "dQw4w9WgXcQ"
        let token = try await WebPoTokenProvider.harvest(videoID: videoID, timeout:90)
        let options = ExtractionOptions(cookies:token.cookies ?? CookieJar(),youtubePoTokens:token.tokens(for:videoID),youtubeVisitorData:token.visitorData)
        let context = ExtractionContext.make(options:options,httpFactory:{ options in
            PoTokenSessionHTTPClient(base:URLSessionHTTPClient(proxy:options.proxy),userAgent:token.userAgent ?? "")
        })
        let info = try await YouTubeExtractor(clientOrder:[InnerTubeClient.web]).extract(URL(string:"https://www.youtube.com/watch?v=" + videoID)!,context:context)
        // Compare the same non-SABR media format with yt-dlp as well.
        if let sharedFormat = info.formats.first(where: { $0.formatID == "18" && $0.protocolType == .https }) {
            var headers = sharedFormat.requestHeaders ?? [:]; headers["Range"] = "bytes=0-65535"
            var request = HTTPRequest.get(sharedFormat.url,headers:headers); request.maximumResponseBytes = 65537
            let response = try await context.http.fetch(request)
            XCTAssertEqual(response.status,206)
            XCTAssertEqual(response.body.count,65536)
            print("[pot] shared HTTPS itag=18 status=\(response.status), bytes=\(response.body.count)")
        }
        let format = try XCTUnwrap(info.formats.first { $0.protocolType == .sabr && $0.kind == .audioOnly })
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("native-pot-sabr-" + UUID().uuidString)
        defer { for ext in ["", "part", "sabr-state.json"] { try? FileManager.default.removeItem(at:ext.isEmpty ? path : path.appendingPathExtension(ext)) } }
        _ = try await SABRDownloader.download(format:format,to:path,http:context.http,options:SABRDownloadOptions(durationSeconds:2,retries:0))
        XCTAssertGreaterThan(try Data(contentsOf:path).count,1000)
        print("[pot] WEB-only SABR transfer verified: " + videoID)
        if let track = info.subtitles.first(where: { $0.isTranslated != true }) {
            let response = try await context.http.fetch(.get(track.url,headers:track.requestHeaders ?? [:]))
            XCTAssertEqual(response.status,200)
            let captions = try JSON(data:response.body)
            XCTAssertFalse(captions["events"].array.isEmpty,"Subtitle response must contain actual timed events")
            print("[pot] subtitle status=\(response.status), bytes=\(response.body.count)")
        }
    }

    /// Explicit, non-skipping validation: fresh provider, alternative WebPO clients,
    /// then a complete muxed media download. No token/cookie/media URL is logged.
    func testPublicVideoProviderClientDownloads() async throws {
        try XCTSkipUnless(enabled && ProcessInfo.processInfo.environment["POT_LIVE_FULL_DOWNLOAD"] == "1",
                          "Requires POT_LIVE_FULL_DOWNLOAD=1")
        let videoID = ProcessInfo.processInfo.environment["POT_VIDEO_ID"] ?? "dQw4w9WgXcQ"
        let proxy = ProcessInfo.processInfo.environment["POT_PROXY"]
        let token: HarvestedPoToken
        if ProcessInfo.processInfo.environment["POT_METHOD"] == "wpc" {
            token = try await WebKitPotHarvester(videoID: videoID, cookies: CookieJar(), proxy: proxy,
                useNativeClient: true, log: { _ in }).run()
        } else {
            token = try await WebPoTokenProvider.harvest(videoID: videoID, proxy: proxy, timeout: 90, bypassThrottle: true)
        }
        let options = ExtractionOptions(proxy: proxy, cookies: token.cookies ?? CookieJar(),
            youtubePoTokens: token.tokens(for: videoID), youtubeVisitorData: token.visitorData)
        let context = ExtractionContext.make(options: options, httpFactory: { options in
            PoTokenSessionHTTPClient(base: URLSessionHTTPClient(proxy: options.proxy), userAgent: token.userAgent ?? "")
        })
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("videx-provider-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var downloads = 0
        for client in [InnerTubeClient.mweb, InnerTubeClient.webSafari, InnerTubeClient.web] {
            do {
                let info = try await YouTubeExtractor(clientOrder: [client]).extract(
                    URL(string: "https://www.youtube.com/watch?v=" + videoID)!, context: context)
                guard let format = info.formats.first(where: { $0.kind == .muxed && $0.protocolType == .https }) else {
                    print("[provider-validation] \(videoID) \(client.key): no muxed HTTPS format; formats=\(info.formats.count)")
                    continue
                }
                let file = directory.appendingPathComponent(videoID + "-" + client.key + ".mp4")
                _ = try await NativeMediaDownloader.download(format: format, to: file, http: context.http)
                let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                XCTAssertGreaterThan(size, 100_000)
                downloads += 1
                print("[provider-validation] \(videoID) \(client.key): complete download bytes=\(size) file=\(file.path)")
            } catch ExtractionError.loginRequired {
                print("[provider-validation] \(videoID) \(client.key): LOGIN_REQUIRED")
            } catch {
                // Do not log errors that can contain signed media URLs.
                print("[provider-validation] \(videoID) \(client.key): failed type=\(type(of: error))")
            }
        }
        XCTAssertGreaterThan(downloads, 0, "No client completed a native media download; this is a failure, not a skipped bot check")
    }

    /// 生产路径：VidexBridge 的「缓存 POT → 失败 → 收割 → 重试」整链。
    /// 关注的是链路被真实走到（日志可见 visitor/token 注入与收割尝试），
    /// 而非当前网络能否成功。
    func testBridgeHarvestRetryPath() async throws {
        try XCTSkipUnless(enabled, "需要 POT_LIVE=1（联网提取）")
        try XCTSkipUnless(ProcessInfo.processInfo.environment["POT_LIVE_EXTRACT"] == "1",
                          "需要 POT_LIVE_EXTRACT=1（真正跑一次提取）")

        let url = ProcessInfo.processInfo.environment["POT_LIVE_URL"]
            ?? "https://www.youtube.com/watch?v=dQw4w9WgXcQ"
        do {
            let info = try await VidexBridge.extract(url, proxy: "")
            XCTAssertFalse(info.formats.isEmpty)
            print("[live] bridge OK：title=\(info.title) formats=\(info.formats.count)")
        } catch ExtractionError.loginRequired(let site, let reason) {
            throw XCTSkip("出口 IP 被标注（\(site): \(reason.prefix(80))）——待干净出口复验")
        }
    }
}
