import XCTest
@testable import Ytb2ZHEngines

final class OrigStreamServerTests: XCTestCase {

    // MARK: b64url 往返

    func testB64URLRoundtrip() {
        let samples = [
            "https://rr5---sn.googlevideo.com/videoplayback/id/abc/seg.ts",
            "https://example.com/a?b=1&c=中文",
            "x+y/z=w",
        ]
        for s in samples {
            XCTAssertEqual(OrigStreamServer.unb64url(OrigStreamServer.b64url(s)), s)
        }
        // b64url 字符集不含 + / =（可安全放进 URL query）
        let enc = OrigStreamServer.b64url("a+b/c=d")
        XCTAssertFalse(enc.contains("+")); XCTAssertFalse(enc.contains("/")); XCTAssertFalse(enc.contains("="))
    }

    // MARK: rewriteM3U8 —— CRLF 行尾必须被正确处理（回归：\r 混入 URL 导致上游 4xx）

    /// 模拟 googlevideo 真实 media playlist：CRLF 行尾 + 绝对分片 URL
    func testRewriteM3U8WithCRLF() {
        let seg = "https://rr5---sn.googlevideo.com/videoplayback/id/b10a2f6bef684dad/file/seg.ts"
        let crlf = "#EXTM3U\r\n#EXTINF:5.2,\r\n\(seg)\r\n"
        let out = OrigStreamServer.rewriteM3U8(crlf, baseURL: URL(string: "https://manifest.googlevideo.com/x.m3u8")!,
                                               prefix: "http://127.0.0.1:12345", token: "tok")
        // 分片行被改写为本地 /p?u= 且不残留 %0D
        XCTAssertTrue(out.contains("http://127.0.0.1:12345/p?u="))
        XCTAssertFalse(out.contains("%0D"), "改写后的 URI 不得残留 \\r（%0D）")
        XCTAssertFalse(out.contains(seg), "裸 googlevideo 分片地址必须被改写（否则 AVPlayer 直连不走代理）")
        // 解码回原地址验证无损
        let line = out.split(separator: "\n").first { $0.contains("/p?u=") }!
        let raw = line.split(separator: "?").last!.dropFirst(2).split(separator: "&").first!
        XCTAssertEqual(OrigStreamServer.unb64url(String(raw)), seg)
    }

    /// LF 行尾同样正确
    func testRewriteM3U8WithLF() {
        let seg = "https://example.com/a.ts"
        let out = OrigStreamServer.rewriteM3U8("#EXTINF:5.2,\n\(seg)\n",
                                               baseURL: URL(string: "https://e.com/m.m3u8")!,
                                               prefix: "http://127.0.0.1:1", token: "tok")
        XCTAssertTrue(out.contains("http://127.0.0.1:1/p?u="))
    }

    /// EXT-X-MEDIA 等标签里的 URI="…" 属性也要改写
    func testRewriteM3U8RewritesURIAttribute() {
        let audio = "https://example.com/audio.m3u8"
        let text = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"aud\",NAME=\"A\",URI=\"\(audio)\"\n"
        let out = OrigStreamServer.rewriteM3U8(text, baseURL: URL(string: "https://e.com/m.m3u8")!,
                                               prefix: "http://127.0.0.1:2", token: "tok")
        XCTAssertTrue(out.contains("URI=\"http://127.0.0.1:2/p?u="))
        XCTAssertFalse(out.contains(audio))
    }

    /// 相对 URI 以 baseURL 解析
    func testRewriteM3U8ResolvesRelative() {
        let out = OrigStreamServer.rewriteM3U8("seg/001.ts\n",
                                               baseURL: URL(string: "https://e.com/hls/m.m3u8")!,
                                               prefix: "http://127.0.0.1:3", token: "tok")
        let line = out.split(separator: "\n").first { $0.contains("/p?u=") }!
        let raw = line.split(separator: "?").last!.dropFirst(2).split(separator: "&").first!
        XCTAssertEqual(OrigStreamServer.unb64url(String(raw)), "https://e.com/hls/seg/001.ts")
    }

    // MARK: master 合成

    func testMasterM3U8ContainsAudioGroupAndVideoURI() {
        let m = OrigStreamServer.masterM3U8(videoProxied: "http://127.0.0.1:1/p?u=V",
                                            audioProxied: "http://127.0.0.1:1/p?u=A",
                                            height: 360)
        XCTAssertTrue(m.hasPrefix("#EXTM3U"))
        XCTAssertTrue(m.contains(#"TYPE=AUDIO,GROUP-ID="aud""#))
        XCTAssertTrue(m.contains("URI=\"http://127.0.0.1:1/p?u=A\""))
        XCTAssertTrue(m.contains("RESOLUTION=640x360"))
        XCTAssertTrue(m.contains("\nhttp://127.0.0.1:1/p?u=V"))
    }

    func testMasterM3U8WithoutHeightOmitsResolution() {
        let m = OrigStreamServer.masterM3U8(videoProxied: "V", audioProxied: "A", height: 0)
        XCTAssertFalse(m.contains("RESOLUTION"))
    }

    // MARK: 本地反代真实起服（loopback，无外网）：master 请求返回合成内容 + token 校验

    func testServerServesMasterAndRejectsBadToken() throws {
        OrigStreamServer.debugLog = { print("PROBE:", $0) }
        defer { OrigStreamServer.debugLog = nil }
        let server = OrigStreamServer(kind: .hls(video: "https://up/v.m3u8", audio: "https://up/a.m3u8"),
                                      proxy: "")
        try server.start()
        defer { server.stop() }
        guard let play = server.localPlayURL else { return XCTFail("localPlayURL 为空") }

        let exp = expectation(description: "master")
        var masterBody = ""
        let s = URLSession.shared
        s.dataTask(with: play) { data, resp, _ in
            masterBody = String(decoding: data ?? Data(), as: UTF8.self)
            exp.fulfill()
        }.resume()
        wait(for: [exp], timeout: 5)
        XCTAssertTrue(masterBody.contains("TYPE=AUDIO"))
        XCTAssertTrue(masterBody.contains("/p?u="))

        // 错误 token → 拒绝
        let bad = expectation(description: "bad token")
        var badStatus = 0
        var comp = URLComponents(url: play, resolvingAgainstBaseURL: false)!
        comp.queryItems = [URLQueryItem(name: "t", value: "wrong")]
        s.dataTask(with: comp.url!) { _, resp, _ in
            badStatus = (resp as? HTTPURLResponse)?.statusCode ?? 0
            bad.fulfill()
        }.resume()
        wait(for: [bad], timeout: 5)
        XCTAssertNotEqual(badStatus, 200)
    }
}
