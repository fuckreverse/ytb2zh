import XCTest
@testable import Ytb2ZHEngines

final class OrigStreamServiceTests: XCTestCase {

    private func fmt(_ id: String, ext: String = "mp4", height: Int? = nil,
                     v: String? = nil, a: String? = nil, proto: String = "https",
                     abr: Int? = nil) -> [String: Any] {
        var f: [String: Any] = ["format_id": id, "ext": ext,
                                "vcodec": v ?? "none", "acodec": a ?? "none",
                                "protocol": proto, "url": "https://s/\(id)"]
        if let height { f["height"] = height }
        if let abr { f["abr"] = abr }
        return f
    }

    /// 有 progressive（音视频合一）时优先，且取 ≤720p 中最高的
    func testPickProgressivePreferred() {
        let formats = [
            fmt("137", height: 1080, v: "avc1", a: "mp4a", proto: "https"),   // >720 不可用
            fmt("136", height: 720, v: "avc1", a: "mp4a"),
            fmt("134", height: 360, v: "avc1", a: "mp4a"),
            fmt("140", a: "mp4a"),
            fmt("232", height: 720, v: "avc1", proto: "m3u8_native"),
        ]
        XCTAssertEqual(OrigStreamService.pick(formats), .progressive(url: "https://s/136"))
    }

    /// 无 progressive 时退回 HLS 分离流：视频取 ≤720 最高，音频优先 mp4a
    func testPickHLSFallback() {
        let formats = [
            fmt("137", height: 1080, v: "avc1", proto: "m3u8_native"),
            fmt("232", height: 720, v: "avc1", proto: "m3u8_native"),
            fmt("230", height: 360, v: "avc1", proto: "m3u8_native"),
            fmt("251", a: "opus", proto: "m3u8_native", abr: 160),
            fmt("234", a: "mp4a", proto: "m3u8_native", abr: 130),
        ]
        XCTAssertEqual(OrigStreamService.pick(formats),
                       .hls(video: "https://s/232", audio: "https://s/234"))
    }

    /// 音频同为 mp4a 时取最高 abr
    func testPickHLSPrefersHigherAbr() {
        let formats = [
            fmt("232", height: 720, v: "avc1", proto: "m3u8_native"),
            fmt("233", a: "mp4a", proto: "m3u8_native", abr: 70),
            fmt("234", a: "mp4a", proto: "m3u8_native", abr: 130),
        ]
        XCTAssertEqual(OrigStreamService.pick(formats),
                       .hls(video: "https://s/232", audio: "https://s/234"))
    }

    /// 什么都没有返回 nil
    func testPickNothing() {
        XCTAssertNil(OrigStreamService.pick([fmt("sb0", ext: "mhtml", proto: "mhtml")]))
        XCTAssertNil(OrigStreamService.pick([]))
    }

    /// resolveArgs：-j 全量格式 + --no-playlist；代理透传；URL 恒为最后一个参数
    func testResolveArgs() {
        let args = OrigStreamService.resolveArgs(
            url: "https://www.youtube.com/watch?v=abc",
            proxy: "http://127.0.0.1:7890")
        XCTAssertTrue(args.contains("-j"))
        XCTAssertTrue(args.contains("--no-playlist"))
        XCTAssertFalse(args.contains("-f"))   // 全量取格式，本地挑选
        if let pi = args.firstIndex(of: "--proxy") {
            XCTAssertEqual(args[pi + 1], "http://127.0.0.1:7890")
        } else {
            XCTFail("缺少 --proxy")
        }
        XCTAssertEqual(args.last, "https://www.youtube.com/watch?v=abc")

        let bare = OrigStreamService.resolveArgs(url: "https://x/y", proxy: "")
        XCTAssertFalse(bare.contains("--proxy"))
    }
}
