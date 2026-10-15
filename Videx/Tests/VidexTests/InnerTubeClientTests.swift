import XCTest
@testable import Videx

/// InnerTube 客户端矩阵测试：锁定与 yt-dlp master（2026.10）的同步状态。
/// 版本号/POT 标注如有变更，应有意识更新这里，防止无意回退。
final class InnerTubeClientTests: XCTestCase {

    // MARK: - 默认轮询顺序（对齐 yt-dlp _DEFAULT_CLIENTS / _DEFAULT_AUTHED_CLIENTS）

    func testDefaultClientOrderMatchesUpstream() {
        XCTAssertEqual(InnerTubeClient.defaultClientOrder.map(\.clientName),
                       ["TVHTML5", "VISIONOS", "WEB"])
        XCTAssertEqual(InnerTubeClient.defaultClientOrder.map(\.clientVersion),
                       ["5.20260707", "1.02", "2.20260708.00.00"])
    }

    func testAuthedOrderPutsWebEmbeddedFirst() {
        var jar = CookieJar()
        jar.set(SiteCookie(name: "LOGIN_INFO", value: "x", domain: ".youtube.com"))
        jar.set(SiteCookie(name: "SAPISID", value: "x", domain: ".youtube.com"))
        XCTAssertEqual(InnerTubeClient.defaultClientOrder(cookies: jar).map(\.clientName),
                       ["WEB_EMBEDDED_PLAYER", "TVHTML5", "WEB"])
        XCTAssertEqual(InnerTubeClient.defaultClientOrder(cookies: CookieJar()).map(\.clientName),
                       ["TVHTML5", "VISIONOS", "WEB"])
    }

    // MARK: - POT 标注（对齐 GvsPoTokenPolicy.required）

    func testPoTokenFlags() {
        // 免 POT：电视/嵌入式/visionos
        XCTAssertFalse(InnerTubeClient.tvSamsung.gvsPoTokenRequired)
        XCTAssertFalse(InnerTubeClient.visionos.gvsPoTokenRequired)
        XCTAssertFalse(InnerTubeClient.webEmbedded.gvsPoTokenRequired)
        XCTAssertFalse(InnerTubeClient.tvDowngraded.gvsPoTokenRequired)
        // 需 POT：web 系 / 移动端 / tv_simply / android_vr
        XCTAssertTrue(InnerTubeClient.web.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.webSafari.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.mweb.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.ios.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.android.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.androidVr.gvsPoTokenRequired)
        XCTAssertTrue(InnerTubeClient.tvSimply.gvsPoTokenRequired)
    }

    // MARK: - JS player 需求（对齐 REQUIRE_JS_PLAYER）

    func testRequiresJSPlayerFlags() {
        XCTAssertTrue(InnerTubeClient.web.requiresJSPlayer)
        XCTAssertTrue(InnerTubeClient.webSafari.requiresJSPlayer)
        XCTAssertTrue(InnerTubeClient.webEmbedded.requiresJSPlayer)
        XCTAssertTrue(InnerTubeClient.mweb.requiresJSPlayer)
        // 直链客户端：免 JS 挑战（visionos 是上游唯一 js-less 默认客户端）
        XCTAssertTrue(InnerTubeClient.tvSamsung.requiresJSPlayer)
        XCTAssertFalse(InnerTubeClient.visionos.requiresJSPlayer)
        XCTAssertTrue(InnerTubeClient.tvDowngraded.requiresJSPlayer)
        XCTAssertFalse(InnerTubeClient.ios.requiresJSPlayer)
        XCTAssertFalse(InnerTubeClient.android.requiresJSPlayer)
        XCTAssertFalse(InnerTubeClient.androidVr.requiresJSPlayer)
    }

    // MARK: - 版本锁定

    func testClientVersionsLocked() {
        XCTAssertEqual(InnerTubeClient.ios.clientVersion, "21.26.4")
        XCTAssertEqual(InnerTubeClient.android.clientVersion, "21.26.364")
        XCTAssertEqual(InnerTubeClient.web.clientVersion, "2.20260708.00.00")
        XCTAssertEqual(InnerTubeClient.webSafari.clientVersion, "2.20260708.00.00")
        XCTAssertEqual(InnerTubeClient.webEmbedded.clientVersion, "2.20260708.00.00")
        XCTAssertEqual(InnerTubeClient.mweb.clientVersion, "2.20260708.05.00")
        XCTAssertEqual(InnerTubeClient.tvSamsung.clientVersion, "5.20260707")
        XCTAssertEqual(InnerTubeClient.tvDowngraded.clientVersion, "5.20260707")
        XCTAssertEqual(InnerTubeClient.visionos.clientVersion, "1.02")
        XCTAssertEqual(InnerTubeClient.androidVr.clientVersion, "1.65.10")
    }

    func testClientIDHeaders() {
        XCTAssertEqual(InnerTubeClient.web.clientIDHeader, "1")
        XCTAssertEqual(InnerTubeClient.webEmbedded.clientIDHeader, "56")
        XCTAssertEqual(InnerTubeClient.tvSamsung.clientIDHeader, "7")
        XCTAssertEqual(InnerTubeClient.visionos.clientIDHeader, "101")
        XCTAssertEqual(InnerTubeClient.ios.clientIDHeader, "5")
        XCTAssertEqual(InnerTubeClient.android.clientIDHeader, "3")
    }

    // MARK: - context JSON 设备字段

    func testTvSamsungContextJSON() throws {
        let ctx = InnerTubeClient.tvSamsung.contextJSON()
        let client = try XCTUnwrap(ctx["client"] as? [String: Any])
        XCTAssertEqual(client["clientName"] as? String, "TVHTML5")
        XCTAssertEqual(client["clientVersion"] as? String, "5.20260707")
        XCTAssertEqual(client["deviceMake"] as? String, "Samsung")
        XCTAssertEqual(client["deviceModel"] as? String, "UKS9800")
        XCTAssertEqual(client["osName"] as? String, "Tizen")
        XCTAssertEqual(client["osVersion"] as? String, "2.4.0")
        XCTAssertEqual(client["userAgent"] as? String, InnerTubeClient.tvSamsung.userAgent)
    }

    func testVisionosContextJSON() throws {
        let ctx = InnerTubeClient.visionos.contextJSON()
        let client = try XCTUnwrap(ctx["client"] as? [String: Any])
        XCTAssertEqual(client["clientName"] as? String, "VISIONOS")
        XCTAssertEqual(client["deviceModel"] as? String, "RealityDevice17,1")
        XCTAssertEqual(client["osName"] as? String, "visionOS")
        XCTAssertEqual(client["osVersion"] as? String, "26.5.23O471")
    }

    func testWebEmbeddedThirdParty() throws {
        let ctx = InnerTubeClient.webEmbedded.contextJSON()
        let thirdParty = try XCTUnwrap(ctx["thirdParty"] as? [String: Any])
        XCTAssertEqual(thirdParty["embedUrl"] as? String, "https://www.youtube.com/")
    }
}
