import XCTest
@testable import Videx

/// 真机集成测试（可选，默认跳过）：
///   VIDEX_LIVE=1 VIDEX_PROXY=http://127.0.0.1:7890 swift test --filter LiveSmokeTests
final class LiveSmokeTests: XCTestCase {
    private var proxy: String? {
        ProcessInfo.processInfo.environment["VIDEX_PROXY"]
    }

    private func makeContext() -> ExtractionContext {
        var options = ExtractionOptions(proxy: proxy)
        options.log = StderrLogSink(minLevel: .info)
        return .make(options: options)
    }

    private func requireLive() throws {
        guard ProcessInfo.processInfo.environment["VIDEX_LIVE"] == "1" else {
            throw XCTSkip("设置 VIDEX_LIVE=1 以启用真机冒烟测试")
        }
    }

    /// 验证 JSC 能解真实 base.js：从 watch 页动态定位 player JS，
    /// 提取 decipher/nsig 并求解；结果校验确定性与长度不变性。
    func testRealPlayerJSChallenge() async throws {
        try requireLive()
        let context = makeContext()
        let innertube = InnerTubeClient(http: context.http, cookies: context.cookies)
        let html = try await innertube.watchPage(videoID: "dQw4w9WgXcQ")
        // HTML/JSON 里斜杠常被转义为 \/，先取所有 "js" 值再反转义筛选
        let candidates = RegexKit.allMatches(pattern: #""js(?:Url)?"\s*:\s*"([^"]+)""#, in: html)
            .map { $0.replacingOccurrences(of: "\\/", with: "/") }
            .filter { $0.contains("/s/player/") && $0.contains(".js") }
        let path = try XCTUnwrap(candidates.first, "watch 页未找到 player JS 路径")
        let jsURL = try XCTUnwrap(URL(string: path.hasPrefix("http") ? path : "https://www.youtube.com" + path.replacingOccurrences(of: "\\/", with: "/")))
        let response = try await context.http.fetch(.get(jsURL))
        guard response.isOK else {
            throw XCTSkip("player base.js HTTP \(response.status)")
        }
        let js = response.text
        // 2026 起 YouTube 陆续将 decipher/nsig 迁移到 WASM，新版 player JS
        // 可能不含经典 JS 挑战——此时跳过而非失败（JSC 求解器对旧版仍有效）。
        guard let challenge = PlayerChallenge.extract(from: js) else {
            throw XCTSkip("当前 player JS 无法提取任何挑战（站点改版？）")
        }
        context.log.log(.info, "decipher=\(challenge.decipherFunctionName ?? "-") nsig=\(challenge.nsigFunctionName ?? "-") modern=\(challenge.modern != nil ? "\(challenge.modern!.candidates.count) candidates" : "-")")

        // 现代协议（URL 变换 + alr/yes 标记）：验证候选提取与求解确定性
        if let modern = challenge.modern {
            XCTAssertFalse(modern.candidates.isEmpty, "现代挑战应至少提取到一个候选")
            let n1 = try ModernChallenge.solve(modern, n: "AbC123xyz000", sig: nil, js: context.js)
            let n2 = try ModernChallenge.solve(modern, n: "AbC123xyz000", sig: nil, js: context.js)
            XCTAssertEqual(n1.n, n2.n, "现代 nsig 应确定性")
            XCTAssertFalse(n1.n?.isEmpty ?? true, "现代 nsig 结果不应为空")
            context.log.log(.info, "modern nsig(AbC123xyz000) = \(n1.n ?? "-")")
        } else {
            XCTAssertNotNil(challenge.decipherFunctionName, "无现代挑战时 decipher 函数应能定位（旧协议）")
        }

        // 旧协议路径（若当前 player 仍保留）
        if let name = challenge.decipherFunctionName {
            let solved1 = try challenge.decipher("abcdefghijklmnopqrstuvwxyz", js: context.js)
            let solved2 = try challenge.decipher("abcdefghijklmnopqrstuvwxyz", js: context.js)
            XCTAssertEqual(solved1, solved2, "decipher 应确定性")
            XCTAssertEqual(solved1.count, 26, "decipher 是重排+变换，长度应不变")
            context.log.log(.info, "\(name)(sig) = \(solved1)")
        }
        if let nsigName = challenge.nsigFunctionName {
            let n1 = try challenge.solveNsig("AbC123xyz000", js: context.js)
            let n2 = try challenge.solveNsig("AbC123xyz000", js: context.js)
            XCTAssertEqual(n1, n2, "nsig 应确定性")
            XCTAssertFalse(n1.isEmpty)
            context.log.log(.info, "\(nsigName)(n) = \(n1)")
        }
    }

    /// 端到端：YouTube iOS 客户端提取 + 流地址前 64KB 下载。
    func testYouTubeEndToEnd() async throws {
        try requireLive()
        let registry = ExtractorRegistry.standard
        let info = try await registry.extract(
            url: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!,
            options: ExtractionOptions(proxy: proxy)
        )
        XCTAssertTrue(info.formats.count > 5)
        let audio = try XCTUnwrap(info.bestAudioOnly)
        // Range 请求验证流地址真实可用
        let client = URLSessionHTTPClient(proxy: proxy)
        var request = HTTPRequest.get(audio.url)
        request.headers["Range"] = "bytes=0-65535"
        let response = try await client.fetch(request)
        XCTAssertEqual(response.status, 206, "流地址应支持 Range 下载")
        XCTAssertGreaterThan(response.body.count, 10000)
    }

    /// 端到端：B 站 DASH 提取 + 音频流前 64KB 下载。
    func testBilibiliEndToEnd() async throws {
        try requireLive()
        let registry = ExtractorRegistry.standard
        let info = try await registry.extract(
            url: URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7")!
        )
        XCTAssertFalse(info.formats.isEmpty)
        let audio = try XCTUnwrap(info.bestAudioOnly)
        let client = URLSessionHTTPClient()
        var request = HTTPRequest.get(audio.url)
        request.headers["Range"] = "bytes=0-65535"
        request.headers["Referer"] = "https://www.bilibili.com/"
        let response = try await client.fetch(request)
        XCTAssertEqual(response.status, 206)
        XCTAssertGreaterThan(response.body.count, 10000)
    }

    /// b23.tv 短链端到端。
    func testBilibiliShortLink() async throws {
        try requireLive()
        let registry = ExtractorRegistry.standard
        let info = try await registry.extract(
            url: URL(string: "https://b23.tv/BV1GJ411x7h7")!
        )
        XCTAssertEqual(info.extractorID, "bilibili")
        XCTAssertEqual(info.id, "BV1GJ411x7h7")
    }
}

// MARK: - Douyin / TikTok 真机冒烟

extension LiveSmokeTests {

    /// 抖音：ttwid 注册 → detail API → DASH 混合流 + Range 下载验证。
    func testDouyinEndToEnd() async throws {
        try requireLive()
        let context = makeContext()
        let extractor = DouyinExtractor()
        let info = try await extractor.extract(
            URL(string: "https://www.douyin.com/video/6961737553342991651")!,
            context: context)
        XCTAssertFalse(info.formats.isEmpty, "应至少解析出一个流")
        let best = info.formats.first!
        XCTAssertNotNil(best.url.absoluteString)
        context.log.log(.info, "抖音：\(info.title) | \(info.formats.count) 流 | 最佳 \(best.qualityLabel ?? "-")")

        // Range 下载验证（100KB 足够证明签名有效）
        var request = HTTPRequest.get(best.url, headers: [
            "User-Agent": "Mozilla/5.0",
            "Referer": "https://www.douyin.com/",
        ])
        request.headers["Range"] = "bytes=0-102399"
        let response = try await context.http.fetch(request)
        XCTAssertEqual(response.status, 206, "流地址应支持 Range 下载（ Got HTTP \(response.status)）")
        XCTAssertGreaterThan(response.body.count, 10000)
    }

    /// 抖音短链：v.douyin.com 重定向解析（只验证重定向与 ID 提取，
    /// 不拉 detail —— 短链指向的视频可能随时被设为私密）。
    func testDouyinShortLink() async throws {
        try requireLive()
        let context = makeContext()
        let response = try await context.http.fetch(
            .get(URL(string: "https://v.douyin.com/iRNBho6u/")!,
                 headers: ["User-Agent": "Mozilla/5.0"]))
        let final = try XCTUnwrap(response.finalURL)
        let ref = DouyinURL.videoRef(from: final)
        XCTAssertNotNil(ref?.awemeID, "短链重定向后应能提取视频 ID：\(final.absoluteString)")
        context.log.log(.info, "抖音短链 → \(ref?.awemeID ?? "-")")
    }

    /// TikTok：WAF PoW 求解 → universal data → 流地址 play 端点验证。
    func testTikTokEndToEnd() async throws {
        try requireLive()
        let context = makeContext()
        let extractor = TikTokExtractor()
        let info = try await extractor.extract(
            URL(string: "https://www.tiktok.com/@patroxofficial/video/6742501081818877190")!,
            context: context)
        XCTAssertFalse(info.formats.isEmpty, "应至少解析出一个流")
        let best = info.formats.first!
        context.log.log(.info, "TikTok：\(info.title) | \(info.formats.count) 流 | 最佳 \(best.qualityLabel ?? "-")")

        // play 端点（302 → 签名 CDN）应可 Range 下载
        var request = HTTPRequest.get(best.url, headers: [
            "User-Agent": "Mozilla/5.0",
            "Referer": "https://www.tiktok.com/",
        ])
        request.headers["Range"] = "bytes=0-102399"
        let response = try await context.http.fetch(request)
        XCTAssertEqual(response.status, 206, "流地址应支持 Range 下载（Got HTTP \(response.status)）")
        XCTAssertGreaterThan(response.body.count, 10000)
    }

    /// TikTok 短链：vt.tiktok.com 重定向 + 完整提取（WAF 求解全链路）。
    func testTikTokShortLink() async throws {
        try requireLive()
        let context = makeContext()
        let extractor = TikTokExtractor()
        let info = try await extractor.extract(
            URL(string: "https://vt.tiktok.com/ZS6hTRquK/")!,
            context: context)
        XCTAssertEqual(info.extractorID, "tiktok")
        XCTAssertEqual(info.id, "7064610634675014913")
        XCTAssertFalse(info.formats.isEmpty)
        context.log.log(.info, "TikTok 短链：\(info.title) | \(info.formats.count) 流")
    }
}
