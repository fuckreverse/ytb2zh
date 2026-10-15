import Foundation
import CryptoKit
import Ytb2ZHCore

// MARK: - Edge TTS 线协议（纯 Swift，替代 python -m edge_tts sidecar）
// 协议对齐 rany2/edge-tts（MIT）：WSS 直连微软 Edge 朗读端点。
// 鉴权：Sec-MS-GEC = SHA256(Windows文件时间取整5分钟 + TrustedClientToken)，十六进制大写。

enum EdgeTTSWire {
    static let trustedClientToken = "6A5AA1D4EAFF4E9FB37E23D68491D6F4"
    static let chromiumFullVersion = "143.0.3650.75"
    static let secMsGecVersion = "1-\(chromiumFullVersion)"
    static let wssBase = "wss://speech.platform.bing.com/consumer/speech/synthesize/readaloud/edge/v1?TrustedClientToken=\(trustedClientToken)"
    static let userAgent = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/143.0.0.0 Safari/537.36 Edg/143.0.0.0"
    static let origin = "chrome-extension://jdiccldimpdaibmpdkjnbmckianbfold"
    static let winEpoch: Int64 = 11_644_473_600

    /// DRM Sec-MS-GEC 令牌。
    /// python 参考：ticks = unix + WIN_EPOCH; ticks -= ticks % 300; ticks *= 1e7;
    /// sha256(f"{ticks:.0f}{token}").hexdigest().upper()
    static func secMsGec(unixSeconds: Double) -> String {
        var ticks = Int64(unixSeconds) + winEpoch
        ticks -= ticks % 300
        ticks *= 10_000_000
        let str = "\(ticks)\(trustedClientToken)"
        let digest = SHA256.hash(data: Data(str.utf8))
        return digest.map { String(format: "%02X", $0) }.joined()
    }

    static func wssURL(connectID: String, gec: String) -> URL {
        URL(string: "\(wssBase)&ConnectionId=\(connectID)&Sec-MS-GEC=\(gec)&Sec-MS-GEC-Version=\(secMsGecVersion)")!
    }

    static func connectID() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// 随机 MUID（Cookie: muid=...;），32 位大写十六进制
    static func muid() -> String {
        let hex = "0123456789ABCDEF"
        return String((0..<32).map { _ in hex.randomElement()! })
    }

    /// JS 风格时间戳："Fri Sep 25 2026 08:00:00 GMT+0000 (Coordinated Universal Time)Z"
    /// 尾部 Z 是 python 库注明的历史遗留（"This is not a mistake, Microsoft Edge bug."），照抄
    static func jsTimestamp(_ date: Date = Date()) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        return f.string(from: date) + "Z"
    }

    /// 去除服务端不支持的字符（0-8、11-12、14-31，含垂直制表符）
    static func sanitize(_ text: String) -> String {
        var scalars = [Unicode.Scalar]()
        scalars.reserveCapacity(text.unicodeScalars.count)
        for s in text.unicodeScalars {
            switch s.value {
            case 0...8, 11...12, 14...31: scalars.append(" ")
            default: scalars.append(s)
            }
        }
        return String(String.UnicodeScalarView(scalars))
    }

    /// XML 转义（对齐 python xml.sax.saxutils.escape：& < >）
    static func escapeXML(_ text: String) -> String {
        text.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
    }

    /// SSML 文档；rate≠1.0 时经 prosody rate 兑现原生语速（+20% = 快 20%）
    static func ssml(voice: String, escapedText: String, rate: Double = 1.0) -> String {
        let pct = String(format: "%+.0f%%", (rate - 1.0) * 100)
        return "<speak version='1.0' xmlns='http://www.w3.org/2001/10/synthesis' xml:lang='en-US'>"
            + "<voice name='\(voice)'>"
            + "<prosody pitch='+0Hz' rate='\(pct)' volume='+0%'>"
            + escapedText
            + "</prosody></voice></speak>"
    }

    /// 第一条消息：speech.config（输出 24kHz 48kbps CBR mp3，句子边界元数据开、词边界关，对齐 python 默认）
    static func speechConfigMessage(timestamp: String = jsTimestamp()) -> String {
        "X-Timestamp:\(timestamp)\r\n"
            + "Content-Type:application/json; charset=utf-8\r\n"
            + "Path:speech.config\r\n\r\n"
            + "{\"context\":{\"synthesis\":{\"audio\":{\"metadataoptions\":{"
            + "\"sentenceBoundaryEnabled\":\"true\",\"wordBoundaryEnabled\":\"false\""
            + "},\"outputFormat\":\"audio-24khz-48kbitrate-mono-mp3\"}}}}\r\n"
    }

    /// 第二条消息：SSML 合成请求
    static func ssmlMessage(requestID: String, timestamp: String, voice: String, escapedText: String,
                            rate: Double = 1.0) -> String {
        "X-RequestId:\(requestID)\r\n"
            + "Content-Type:application/ssml+xml\r\n"
            + "X-Timestamp:\(timestamp)\r\n"
            + "Path:ssml\r\n\r\n"
            + ssml(voice: voice, escapedText: escapedText, rate: rate)
    }

    /// 文本帧 Path 提取（头部以 "\r\n\r\n" 结束）
    static func path(ofTextFrame s: String) -> String? {
        guard let r = s.range(of: "\r\n\r\n") else { return nil }
        for line in s[..<r.lowerBound].split(separator: "\r\n") where line.hasPrefix("Path:") {
            return String(line.dropFirst(5))
        }
        return nil
    }

    /// 二进制帧解析：[2字节大端头长(含前缀自身)] [头行区(不含终结\r\n)] [\r\n终结符] [载荷]
    /// python: headers = data[:header_length].split("\r\n")（首行被前缀污染但无害），
    ///         payload = data[header_length+2:]；终止帧头区无 Content-Type 且载荷为空。
    /// 返回 (path, payload)；结构非法返回 nil。
    static func parseBinaryFrame(_ data: Data) -> (path: String, payload: Data)? {
        guard data.count > 2 else { return nil }
        let bytes = [UInt8](data[data.startIndex..<(data.startIndex + 2)])
        let headerLen = Int(bytes[0]) << 8 | Int(bytes[1])
        guard headerLen >= 2, data.count >= headerLen + 2 else { return nil }
        let headerData = data.subdata(in: (data.startIndex + 2)..<(data.startIndex + headerLen))
        guard let header = String(data: headerData, encoding: .utf8) else { return nil }
        var path: String?
        for line in header.split(separator: "\r\n") where line.hasPrefix("Path:") {
            path = String(line.dropFirst(5))
            break
        }
        guard let p = path else { return nil }
        let payload = data.subdata(in: (data.startIndex + headerLen + 2)..<(data.endIndex))
        return (p, payload)
    }

    /// 按转义后 UTF-8 字节数切块（≤4096，单请求上限；对齐 python split_text_by_byte_length 的简化版：
    /// 优先空格/换行断开；因为按原始字符切块、整字符转义，不会切进 XML 实体中间）
    static func chunks(of raw: String, byteLimit: Int = 4096) -> [String] {
        if escapeXML(raw).utf8.count <= byteLimit { return [raw] }
        var out: [String] = []
        var cur = ""
        var curBytes = 0
        for ch in raw {
            let eb = escapeXML(String(ch)).utf8.count
            if curBytes + eb > byteLimit, !cur.isEmpty {
                // 优先在最后一个空白处断开
                if let ls = cur.lastIndex(where: { $0 == " " || $0 == "\n" }),
                   ls > cur.startIndex {
                    out.append(cur[..<ls].trimmingCharacters(in: .whitespacesAndNewlines))
                    cur = String(cur[ls...]).trimmingCharacters(in: .whitespacesAndNewlines)
                    curBytes = escapeXML(cur).utf8.count
                } else {
                    out.append(cur)
                    cur = ""
                    curBytes = 0
                }
            }
            cur.append(ch)
            curBytes += eb
        }
        if !cur.isEmpty { out.append(cur.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return out.filter { !$0.isEmpty }
    }
}

// MARK: - 代理配置（URLSession 显式代理字典；不读环境变量，对齐"显式传参才可靠"的老经验）

enum EdgeTTSProxy {
    static func dictionary(from spec: String) -> [AnyHashable: Any] {
        guard !spec.isEmpty else { return [:] }
        let normalized = spec.contains("://") ? spec : "http://\(spec)"
        guard let url = URL(string: normalized), let host = url.host else { return [:] }
        let scheme = url.scheme?.lowercased()
        let port = url.port ?? (scheme == "https" ? 443 : 8080)
        switch scheme {
        case "socks", "socks5", "socks5h":
            return ["SOCKSEnable": true, "SOCKSProxy": host, "SOCKSPort": port]
        default:
            return ["HTTPEnable": true, "HTTPProxy": host, "HTTPPort": port,
                    "HTTPSEnable": true, "HTTPSProxy": host, "HTTPSPort": port]
        }
    }
}

// MARK: - WS 客户端

struct EdgeTTSClient {
    var proxy: String = ""
    var timeoutSeconds: TimeInterval = 60

    /// 合成整段文本：超长按 4096 字节切块顺序合成后拼接（mp3 流可直接拼接）
    func synthesize(text: String, voice: String, rate: Double = 1.0) async throws -> Data {
        var all = Data()
        for chunk in EdgeTTSWire.chunks(of: EdgeTTSWire.sanitize(text)) {
            all.append(try await synthesizeChunk(escapedText: EdgeTTSWire.escapeXML(chunk),
                                                 voice: voice, rate: rate))
        }
        guard !all.isEmpty else {
            throw EngineError.engineFailure("Edge TTS 未返回音频")
        }
        return all
    }

    /// 单块合成：WS 连接 → speech.config → ssml → 收二进制音频帧至 turn.end
    private func synthesizeChunk(escapedText: String, voice: String, rate: Double) async throws -> Data {
        let config = URLSessionConfiguration.ephemeral
        let proxyDict = EdgeTTSProxy.dictionary(from: proxy)
        if !proxyDict.isEmpty { config.connectionProxyDictionary = proxyDict }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        let gec = EdgeTTSWire.secMsGec(unixSeconds: Date().timeIntervalSince1970)
        var req = URLRequest(url: EdgeTTSWire.wssURL(connectID: EdgeTTSWire.connectID(), gec: gec))
        req.setValue(EdgeTTSWire.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue(EdgeTTSWire.origin, forHTTPHeaderField: "Origin")
        req.setValue("no-cache", forHTTPHeaderField: "Pragma")
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        req.setValue("muid=\(EdgeTTSWire.muid());", forHTTPHeaderField: "Cookie")

        let task = session.webSocketTask(with: req)
        let state = Mutex((audio: Data(), finished: false, failure: Optional<String>.none))

        task.resume()

        // ① speech.config（输出格式声明）
        try await task.send(.string(EdgeTTSWire.speechConfigMessage()))
        // ② SSML 合成请求
        try await task.send(.string(EdgeTTSWire.ssmlMessage(
            requestID: EdgeTTSWire.connectID(),
            timestamp: EdgeTTSWire.jsTimestamp(),
            voice: voice,
            escapedText: escapedText,
            rate: rate)))

        func receiveLoop() async throws {
            while true {
                if state.wrapped.finished { return }
                let msg = try await task.receive()
                switch msg {
                case .string(let s):
                    switch EdgeTTSWire.path(ofTextFrame: s) {
                    case "turn.end":
                        state.with { $0.finished = true }
                    case "turn.start", "response", "audio.metadata", nil:
                        break  // 正常路径：turn.start/response 空体确认、audio.metadata 词时间戳（暂不消费）
                    case .some(let unknown):
                        throw EngineError.engineFailure("Edge TTS 未知响应路径：\(unknown)")
                    }
                case .data(let d):
                    guard let frame = EdgeTTSWire.parseBinaryFrame(d) else {
                        throw EngineError.engineFailure("Edge TTS 二进制帧解析失败")
                    }
                    guard frame.path == "audio" else {
                        throw EngineError.engineFailure("Edge TTS 二进制帧路径异常：\(frame.path)")
                    }
                    state.with { $0.audio.append(frame.payload) }  // 空载荷终止帧无害
                @unknown default:
                    break  // 连接关闭会从 receive() 抛 URLError 体现
                }
            }
        }

        do {
            let receiver = Task { try await receiveLoop() }
            try await withTimeout(seconds: timeoutSeconds) { try await receiver.value }
        } catch {
            task.cancel(with: .goingAway, reason: nil)
            throw error
        }
        task.cancel(with: .normalClosure, reason: nil)

        let final = state.wrapped
        if let failure = final.failure { throw EngineError.engineFailure("Edge TTS：\(failure)") }
        return final.audio
    }
}
