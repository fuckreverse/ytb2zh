import XCTest
import CryptoKit
@testable import Videx

final class AwemeTests: XCTestCase {

    // MARK: - URL 解析

    func testDouyinURLParsing() throws {
        let video = URL(string: "https://www.douyin.com/video/6961737553342991651")!
        XCTAssertEqual(DouyinURL.videoRef(from: video)?.awemeID, "6961737553342991651")

        let note = URL(string: "https://www.douyin.com/note/7240000000000000000?x=1")!
        XCTAssertEqual(DouyinURL.videoRef(from: note)?.awemeID, "7240000000000000000")

        let share = URL(string: "https://www.iesdouyin.com/share/video/7123456789012345678/?region=CN")!
        XCTAssertEqual(DouyinURL.videoRef(from: share)?.awemeID, "7123456789012345678")

        let short = URL(string: "https://v.douyin.com/iRNBho6u/")!
        XCTAssertEqual(DouyinURL.videoRef(from: short)?.awemeID, nil)

        // 非抖音 URL
        XCTAssertNil(DouyinURL.videoRef(from: URL(string: "https://example.com/video/123")!))

        // canHandle 判定
        let douyin = DouyinExtractor()
        XCTAssertTrue(douyin.canHandle(video))
        XCTAssertTrue(douyin.canHandle(short))
        XCTAssertFalse(douyin.canHandle(URL(string: "https://example.com/video/123")!))
    }

    func testTikTokURLParsing() throws {
        let standard = URL(string: "https://www.tiktok.com/@patroxofficial/video/6742501081818877190")!
        let ref = TikTokURL.videoRef(from: standard)
        XCTAssertEqual(ref?.videoID, "6742501081818877190")
        XCTAssertEqual(ref?.userHandle, "patroxofficial")

        let noUser = URL(string: "https://www.tiktok.com/embed/6742501081818877190")!
        XCTAssertEqual(TikTokURL.videoRef(from: noUser)?.videoID, "6742501081818877190")

        let short = URL(string: "https://vm.tiktok.com/ZMhqkVrZp/")!
        XCTAssertEqual(TikTokURL.videoRef(from: short)?.videoID, nil)

        // 规范化 URL
        let canonical = TikTokURL.canonicalURL(videoID: "123", userHandle: nil)
        XCTAssertEqual(canonical.absoluteString, "https://www.tiktok.com/@_/video/123")

        // canHandle 判定
        let extractor = TikTokExtractor()
        XCTAssertTrue(extractor.canHandle(standard))
        XCTAssertTrue(extractor.canHandle(short))
        XCTAssertFalse(extractor.canHandle(URL(string: "https://www.douyin.com/video/123")!))
    }

    // MARK: - URL Key 解析

    func testAwemeURLKeyParsing() {
        let key = AwemeURLKey.parse("v09044cc0000bm92pg3l96b4aifucvt0_h264_540p_800567")
        XCTAssertEqual(key?.formatID, "h264_540p_800567")
        XCTAssertEqual(key?.codec, "h264")
        XCTAssertEqual(key?.videoCodec, "h264")
        XCTAssertEqual(key?.resolution, "540p")
        XCTAssertEqual(key?.height, 540)
        XCTAssertEqual(key?.bitrateKbps, 800567)

        let bytevc1 = AwemeURLKey.parse("v0d00fg10000abcd_bytevc1_1080p_2540397")
        XCTAssertEqual(bytevc1?.videoCodec, "h265")

        XCTAssertNil(AwemeURLKey.parse(nil))
        XCTAssertNil(AwemeURLKey.parse("no-match-here"))
    }

    // MARK: - TikTok web itemStruct 解析（fixture：真实抓取的 2026 响应）

    func testTikTokWebItemParsing() throws {
        let data = try Self.fixtureData("tiktok_itemstruct")
        let json = try JSON(data: data)
        let info = AwemeParser.makeMediaInfo(
            webItem: json,
            webpageURL: URL(string: "https://www.tiktok.com/@patroxofficial/video/6742501081818877190")!,
            extractorID: "tiktok")

        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, "6742501081818877190")
        XCTAssertTrue(info!.title.contains("Tag 1 Friend"))
        XCTAssertEqual(info?.uploader, "patroX")
        XCTAssertEqual(info?.duration, 27)
        XCTAssertEqual(info?.uploadDate, "20190930")

        // 码率档：h264 540p 三个档（bitrateInfo），全部应解析为 muxed mp4
        let muxed = info!.formats
        XCTAssertFalse(muxed.isEmpty)
        XCTAssertTrue(muxed.allSatisfy { $0.kind == .muxed && $0.container == "mp4" })
        XCTAssertTrue(muxed.allSatisfy { $0.videoCodec == "h264" || $0.videoCodec == "h265" })

        // download_addr（水印）应存在且带标记
        XCTAssertTrue(muxed.contains { $0.formatID == "download_addr" })

        // 尺寸/码率字段
        let withHeight = muxed.filter { $0.height != nil }
        XCTAssertFalse(withHeight.isEmpty)

        // 播放统计
        XCTAssertEqual(info?.viewCount, 37200000)
        XCTAssertEqual(info?.extras["likeCount"], "2300000")
        XCTAssertEqual(info?.extras["musicTitle"], "Big Fun")
    }

    // MARK: - 抖音 app 风格 aweme_detail 解析

    func testDouyinDetailParsing() throws {
        let data = try Self.fixtureData("douyin_detail")
        let json = try JSON(data: data)
        let info = AwemeParser.makeMediaInfo(
            appStyle: json["aweme_detail"],
            webpageURL: URL(string: "https://www.douyin.com/video/6961737553342991651")!,
            extractorID: "douyin")

        XCTAssertNotNil(info)
        XCTAssertEqual(info?.id, "6961737553342991651")
        XCTAssertTrue(info!.title.contains("杨超越"))
        XCTAssertEqual(info?.uploader, "杨超越")
        // duration 19782ms → 19.782s（约 19.8，浮点比较）
        XCTAssertEqual(info!.duration ?? 0, 19.782, accuracy: 0.01)
        XCTAssertEqual(info?.uploadDate, "20210513")

        // 4 个码率档（1080/720/540/540）；竖屏视频 1080p 指 width
        let gears = info!.formats.filter { $0.formatID.hasPrefix("normal_") || $0.formatID.hasPrefix("lower_") }
        XCTAssertEqual(gears.count, 4)
        XCTAssertTrue(gears.contains { $0.formatID == "normal_1080_0" && $0.width == 1080 && $0.height == 1920 })
        XCTAssertTrue(gears.contains { $0.formatID == "normal_1080_0" && $0.averageBitrate == 2540 })
        XCTAssertTrue(gears.contains { $0.formatID == "normal_720_0" && $0.videoCodec == "h264" })

        // download_addr：douyin 端无 url_key，仅 720p
        let watermark = info!.formats.first { $0.formatID == "download_addr" }
        XCTAssertNotNil(watermark)
        XCTAssertTrue(watermark!.qualityLabel?.contains("水印") == true)

        // 互动数据
        XCTAssertEqual(info?.extras["likeCount"], "323322")
        XCTAssertEqual(info?.extras["commentCount"], "14297")
        XCTAssertEqual(info?.extras["musicAuthor"], "杨超越")

        // 备用 CDN URL
        let firstGear = gears.first { $0.backupURLs != nil }
        XCTAssertNotNil(firstGear)
    }

    // MARK: - WAF PoW 求解（合成挑战）

    func testWAFChallengeSolve() throws {
        // 1. 构造挑战：seed 随机，proof = "42"，expected = sha256(seed || "42")
        let seed = Data("test-seed-bytes".utf8)
        var hasher = SHA256()
        hasher.update(data: seed)
        hasher.update(data: Data("42".utf8))
        let expected = Data(hasher.finalize())

        let payload: [String: Any] = [
            "v": [
                "a": seed.base64EncodedString(),
                "b": 1790568441,
                "c": expected.base64EncodedString(),
            ],
            "s": "ignored",
        ]
        let payloadData = try JSONSerialization.data(withJSONObject: payload)
        let csValue = payloadData.base64EncodedString()

        let html = """
        <html><body> Please wait...
        <p id="wci" class="_wafchallengeid"></p>
        <p id="cs" class="\(csValue)"></p>
        <p id="rci" class="waforiginalreid"></p>
        <p id="rs" class="abc123"></p>
        </body></html>
        """

        let solution = try WAFChallenge.solve(fromHTML: html)
        XCTAssertNotNil(solution)
        // cookie 名取自 wci 元素的 class
        XCTAssertTrue(solution!.cookies.keys.contains("_wafchallengeid"))
        let cookieValue = solution!.cookies["_wafchallengeid"]!

        // 解码 cookie 值应含 d=base64("42")
        let decoded = WAFChallenge.lenientBase64Decode(cookieValue).flatMap {
            try? JSONSerialization.jsonObject(with: $0) as? [String: Any]
        }
        XCTAssertEqual(decoded?["d"] as? String, Data("42".utf8).base64EncodedString())
        XCTAssertEqual(solution?.cookies["waforiginalreid"], "abc123")
    }

    func testWAFChallengeNormalPageReturnsNil() throws {
        let html = "<html><body>normal page</body></html>"
        XCTAssertNil(try WAFChallenge.solve(fromHTML: html))
    }

    func testWAFChallengeRealFixture() throws {
        // 真实挑战页结构（2026-09 抓取）：只验证 cs 可解码 + 元素提取
        let data = try Self.fixtureData("tiktok_waf_page")
        let html = String(data: data, encoding: .utf8)!
        let solution = try WAFChallenge.solve(fromHTML: html)
        XCTAssertNotNil(solution)
        XCTAssertEqual(solution?.cookies.keys.contains("_wafchallengeid"), true)
    }

    // MARK: - 工具

    static func fixtureData(_ name: String) throws -> Data {
        let bundleURL = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/\(name).json")
        return try Data(contentsOf: bundleURL)
    }
}
