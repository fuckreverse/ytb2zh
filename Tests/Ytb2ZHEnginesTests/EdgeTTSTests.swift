import XCTest
@testable import Ytb2ZHEngines
import Ytb2ZHCore

/// Edge TTS 纯 Swift 协议实现测试
/// DRM 测试向量由 python hashlib 按 edge-tts 官方算法预生成（ticks 取整 5 分钟 → 100ns → SHA256 大写）
final class EdgeTTSTests: XCTestCase {

    // MARK: - DRM Sec-MS-GEC 令牌

    func testSecMsGecKnownVectors() {
        XCTAssertEqual(
            EdgeTTSWire.secMsGec(unixSeconds: 0),
            "7ECB79D14E3AA576D2D79E6D487A1388156D91E614B1BE11C64226A29BC8DD8C")
        XCTAssertEqual(
            EdgeTTSWire.secMsGec(unixSeconds: 1_727_510_400),
            "BC59A72AC184A4A652D627029991D2112C5F021A7A8CFEB0AF0AB541079C452B")
        // 1789000000 % 300 = 100 → 向下取整到 1788999900，验证取整逻辑
        XCTAssertEqual(
            EdgeTTSWire.secMsGec(unixSeconds: 1_789_000_000),
            "D2D305CA876E85D58702947E9D169DEFAF871FD79C00F0B016C920DABAADCE60")
    }

    func testWSSURLContainsAuthParams() {
        let url = EdgeTTSWire.wssURL(connectID: "abc123", gec: "DEADBEEF")
        XCTAssertEqual(url.scheme, "wss")
        XCTAssertEqual(url.host, "speech.platform.bing.com")
        let q = url.query ?? ""
        XCTAssertTrue(q.contains("TrustedClientToken=\(EdgeTTSWire.trustedClientToken)"))
        XCTAssertTrue(q.contains("ConnectionId=abc123"))
        XCTAssertTrue(q.contains("Sec-MS-GEC=DEADBEEF"))
        XCTAssertTrue(q.contains("Sec-MS-GEC-Version=\(EdgeTTSWire.secMsGecVersion)"))
    }

    // MARK: - 消息构造

    func testSpeechConfigMessage() {
        let m = EdgeTTSWire.speechConfigMessage(timestamp: "FIXED")
        XCTAssertTrue(m.hasPrefix("X-Timestamp:FIXED\r\n"))
        XCTAssertTrue(m.contains("Content-Type:application/json; charset=utf-8\r\n"))
        XCTAssertTrue(m.contains("Path:speech.config\r\n\r\n"))
        XCTAssertTrue(m.contains("\"sentenceBoundaryEnabled\":\"true\""))
        XCTAssertTrue(m.contains("\"wordBoundaryEnabled\":\"false\""))
        XCTAssertTrue(m.contains("audio-24khz-48kbitrate-mono-mp3"))
        XCTAssertTrue(m.hasSuffix("\r\n"))
    }

    func testSSMLMessageEscapesAndFormat() {
        let m = EdgeTTSWire.ssmlMessage(requestID: "REQ1", timestamp: "TS",
                                        voice: "zh-CN-XiaoxiaoNeural", escapedText: "a &amp; b")
        XCTAssertTrue(m.hasPrefix("X-RequestId:REQ1\r\n"))
        XCTAssertTrue(m.contains("Content-Type:application/ssml+xml\r\n"))
        XCTAssertTrue(m.contains("X-Timestamp:TS\r\n"))
        XCTAssertTrue(m.contains("Path:ssml\r\n\r\n"))
        XCTAssertTrue(m.contains("<voice name='zh-CN-XiaoxiaoNeural'>"))
        XCTAssertTrue(m.contains("<prosody pitch='+0Hz' rate='+0%' volume='+0%'>a &amp; b</prosody>"))
        XCTAssertTrue(m.hasSuffix("</voice></speak>"))
    }

    func testSSMLRateProsody() {
        // rate≠1.0 经 prosody rate 兑现原生语速（+20% = 快 20%）
        let fast = EdgeTTSWire.ssml(voice: "v", escapedText: "你好", rate: 1.2)
        XCTAssertTrue(fast.contains("<prosody pitch='+0Hz' rate='+20%' volume='+0%'>你好</prosody>"), fast)
        let slow = EdgeTTSWire.ssml(voice: "v", escapedText: "你好", rate: 0.8)
        XCTAssertTrue(slow.contains("rate='-20%'"), slow)
        // 默认 1.0 与历史行为一致（+0%）
        XCTAssertTrue(EdgeTTSWire.ssml(voice: "v", escapedText: "x").contains("rate='+0%'"))
        // ssmlMessage 透传 rate
        let m = EdgeTTSWire.ssmlMessage(requestID: "R", timestamp: "T", voice: "v",
                                        escapedText: "x", rate: 1.5)
        XCTAssertTrue(m.contains("rate='+50%'"), m)
    }

    func testEscapeXMLAndSanitize() {
        XCTAssertEqual(EdgeTTSWire.escapeXML("a<b>&c"), "a&lt;b&gt;&amp;c")
        // 垂直制表符(11)与控制字符(1、31)替换为空格，\t(9)\n(10) 保留
        XCTAssertEqual(EdgeTTSWire.sanitize("a\u{01}b\u{0B}c\u{1F}d\te\nf"), "a b c d\te\nf")
    }

    func testJSTimestampFormat() {
        var comps = DateComponents()
        comps.timeZone = TimeZone(identifier: "UTC")
        comps.year = 2026; comps.month = 1; comps.day = 2
        comps.hour = 3; comps.minute = 4; comps.second = 5
        let date = Calendar(identifier: .gregorian).date(from: comps)!
        XCTAssertEqual(EdgeTTSWire.jsTimestamp(date),
                       "Fri Jan 02 2026 03:04:05 GMT+0000 (Coordinated Universal Time)Z")
    }

    // MARK: - 二进制帧解析

    private func binaryFrame(_ headers: String, _ payload: [UInt8]) -> Data {
        // 头长（含 2 字节前缀自身）= 2 + 头行区（不含终结 \r\n）
        let headerText = headers.data(using: .utf8)!
        let len = 2 + headerText.count
        var d = Data([UInt8(len >> 8 & 0xFF), UInt8(len & 0xFF)])
        d.append(headerText)
        d.append(contentsOf: [0x0D, 0x0A])  // 终结符（被 data[header_length+2:] 跳过的部分）
        d.append(contentsOf: payload)
        return d
    }

    func testParseBinaryAudioFrame() {
        let frame = binaryFrame("X-RequestId:ABC\r\nContent-Type:audio/mpeg\r\nPath:audio\r\n",
                                [0xFF, 0xFB, 0x90, 0x00])
        let parsed = EdgeTTSWire.parseBinaryFrame(frame)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.path, "audio")
        XCTAssertEqual([UInt8](parsed?.payload ?? Data()), [0xFF, 0xFB, 0x90, 0x00])
    }

    func testParseBinaryTerminationFrameEmptyPayload() {
        let frame = binaryFrame("Path:audio\r\n", [])
        let parsed = EdgeTTSWire.parseBinaryFrame(frame)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(parsed?.path, "audio")
        XCTAssertEqual(parsed?.payload.isEmpty, true)
    }

    func testParseBinaryFrameRejectsGarbage() {
        XCTAssertNil(EdgeTTSWire.parseBinaryFrame(Data([0x00])))           // 过短
        XCTAssertNil(EdgeTTSWire.parseBinaryFrame(Data([0x00, 0x02, 0x41])))  // 头长越界
        // 头区没有 Path 头
        XCTAssertNil(EdgeTTSWire.parseBinaryFrame(binaryFrame("Content-Type:audio/mpeg\r\n", [1])))
    }

    // MARK: - 文本帧 Path 提取

    func testPathOfTextFrame() {
        XCTAssertEqual(EdgeTTSWire.path(ofTextFrame: "X-RequestId:1\r\nPath:turn.start\r\n\r\n{}"), "turn.start")
        XCTAssertEqual(EdgeTTSWire.path(ofTextFrame: "Path:turn.end\r\n\r\n"), "turn.end")
        XCTAssertNil(EdgeTTSWire.path(ofTextFrame: "no path here"))
    }

    // MARK: - 超长切块

    func testChunksShortPassthrough() {
        XCTAssertEqual(EdgeTTSWire.chunks(of: "你好世界"), ["你好世界"])
    }

    func testChunksSplitsByEscapedByteLimit() {
        // 每个中文字符 3 字节：1300 字 = 3900 字节 ≤ 4096 不切；1500 字 = 4500 字节必切
        let long = String(repeating: "测", count: 1500)
        let chunks = EdgeTTSWire.chunks(of: long)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            XCTAssertLessThanOrEqual(EdgeTTSWire.escapeXML(c).utf8.count, 4096)
        }
        XCTAssertEqual(chunks.joined().count, 1500)  // 无字符丢失
    }

    func testChunksDoesNotSplitXMLEntity() {
        // 大量 &amp; 实体（每字符转义后 5 字节），切块不得落入实体中间
        let long = String(repeating: "&", count: 3000)  // 转义后 15000 字节
        let chunks = EdgeTTSWire.chunks(of: long)
        XCTAssertGreaterThan(chunks.count, 1)
        for c in chunks {
            let esc = EdgeTTSWire.escapeXML(c)
            XCTAssertLessThanOrEqual(esc.utf8.count, 4096)
            // 转义后每个 & 都必须是完整 &amp; 实体（即没有被切进实体中间）
            XCTAssertEqual(esc.filter { $0 == "&" }.count,
                           esc.components(separatedBy: "&amp;").count - 1)
        }
    }

    // MARK: - 代理字典

    func testProxyDictionary() {
        XCTAssertTrue(EdgeTTSProxy.dictionary(from: "").isEmpty)
        let http = EdgeTTSProxy.dictionary(from: "http://127.0.0.1:7890")
        XCTAssertEqual(http["HTTPProxy"] as? String, "127.0.0.1")
        XCTAssertEqual(http["HTTPPort"] as? Int, 7890)
        XCTAssertEqual(http["HTTPSEnable"] as? Bool, true)
        let socks = EdgeTTSProxy.dictionary(from: "socks5://10.0.0.1:1080")
        XCTAssertEqual(socks["SOCKSProxy"] as? String, "10.0.0.1")
        XCTAssertEqual(socks["SOCKSPort"] as? Int, 1080)
    }

    // MARK: - 真机冒烟（默认跳过：设 YTB2ZH_EDGE_SMOKE=1 启用，需可直连微软端点）

    func testRealSynthesizeSmoke() async throws {
        guard ProcessInfo.processInfo.environment["YTB2ZH_EDGE_SMOKE"] == "1" else {
            throw XCTSkip("设 YTB2ZH_EDGE_SMOKE=1 启用真机冒烟")
        }
        // 走完整引擎路径：落盘 + ffprobe 时长探测 + 缓存命中
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edge_smoke_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        var opts = SynthOptions()
        opts.edgeVoice = "zh-CN-XiaoxiaoNeural"
        let (url, dur) = try await EdgeTTSEngine().synthesize(
            text: "你好，世界。这是一个内置测试。", cacheKey: "smoke", cacheDir: dir,
            options: opts)
        XCTAssertGreaterThan(dur, 1.0)
        let cached = try await EdgeTTSEngine().synthesize(
            text: "你好，世界。这是一个内置测试。", cacheKey: "smoke", cacheDir: dir,
            options: opts)
        XCTAssertEqual(cached.url, url)  // 二次调用命中缓存
        try? FileManager.default.removeItem(at: dir)
    }
}
