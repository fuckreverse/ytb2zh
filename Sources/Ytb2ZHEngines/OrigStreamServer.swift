import Foundation
import Network
import Ytb2ZHCore

// MARK: - 本地回环反代：AVPlayer → 127.0.0.1 → URLSession(带全局代理) → 视频流
// progressive：Range 头透传，支持任意拖动进度；
// HLS：本地合成 master m3u8（音频走 rendition 组），m3u8 内 URI 全部改写回本反代，段落经代理转发。
// token 校验防本机其他进程滥用端口。
// 放在 Engines 层以便 CLI（orig-probe）与单测直接复用，GUI 只消费。

public final class OrigStreamServer: @unchecked Sendable {
    /// 调试钩子：CLI/单测可注入打印（生产为 nil，零开销）
    nonisolated(unsafe) public static var debugLog: ((String) -> Void)?
    static func dlog(_ s: String) { debugLog?(s) }

    public let token = UUID().uuidString.lowercased()
    private let kind: OrigStreamKind
    private let proxy: String
    private let queue = DispatchQueue(label: "ytb2zh.origstream")
    private var listener: NWListener?
    private(set) public var port: UInt16 = 0

    public init(kind: OrigStreamKind, proxy: String) {
        self.kind = kind
        self.proxy = proxy
    }

    /// URLSession connectionProxyDictionary 键（kCFStream 系，HTTP/HTTPS 都要给）
    public static func proxyDict(_ proxy: String) -> [String: Any]? {
        let s = proxy.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty,
              let url = URL(string: s.hasPrefix("http") ? s : "http://" + s),
              let host = url.host else { return nil }
        let port = url.port ?? 8080
        return [
            kCFStreamPropertyHTTPProxyHost as String: host,
            kCFStreamPropertyHTTPProxyPort as String: port,
            kCFStreamPropertyHTTPSProxyHost as String: host,
            kCFStreamPropertyHTTPSProxyPort as String: port,
        ]
    }

    public static func sessionConfig() -> URLSessionConfiguration {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        cfg.timeoutIntervalForRequest = 60
        return cfg
    }

    // MARK: base64url（m3u8 代理参数编码）

    public static func b64url(_ s: String) -> String {
        let d = Data(s.utf8).base64EncodedString()
        return d.replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    public static func unb64url(_ s: String) -> String? {
        var t = s.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        while t.count % 4 != 0 { t += "=" }
        guard let d = Data(base64Encoded: t) else { return nil }
        return String(data: d, encoding: .utf8)
    }

    /// m3u8 文本改写：非注释行（URI）与属性里的 URI="…" 全部指向本地反代 /p?u=<b64url>。
    /// 注意：上游 m3u8 常为 CRLF 行尾。Swift 的 Character 是字素簇，"\r\n" 是单个 Character，
    /// 用 `$0 == "\n"` 永远匹配不到它（残留 \r 会被 URL(string:) 编码成 %0D 混进分片地址）；
    /// 必须用 isNewline（对 CRLF 簇返回 true）。
    public static func rewriteM3U8(_ text: String, baseURL: URL, prefix: String, token: String) -> String {
        func proxied(_ raw: String) -> String? {
            guard let u = URL(string: raw, relativeTo: baseURL) else { return nil }
            return "\(prefix)/p?u=\(b64url(u.absoluteString))&t=\(token)"
        }
        func rewriteAttrs(_ line: String) -> String {
            guard let r = line.range(of: #"URI="([^"]+)""#, options: .regularExpression) else { return line }
            let token = String(line[r])                       // 形如 URI="xxx"
            let inner = token.dropFirst(5).dropLast()         // 去掉 URI=" 与 "
            guard let p = proxied(String(inner)) else { return line }
            return line.replacingCharacters(in: r, with: "URI=\"\(p)\"")
        }
        return text.split(omittingEmptySubsequences: false, whereSeparator: { $0.isNewline })
            .map { orig -> String in
                let line = String(orig)
                guard !line.isEmpty else { return line }
                if line.hasPrefix("#") { return rewriteAttrs(line) }
                return proxied(line) ?? line
            }
            .joined(separator: "\n")
    }

    /// 合成 master：视频主 playlist + 音频 rendition 组，AVPlayer 自动混流双轨
    public static func masterM3U8(videoProxied: String, audioProxied: String, height: Int) -> String {
        let res = height > 0 ? ",RESOLUTION=\(Int(Double(height) * 16 / 9.0))x\(height)" : ""
        return """
        #EXTM3U
        #EXT-X-VERSION:6
        #EXT-X-INDEPENDENT-SEGMENTS
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Audio",DEFAULT=YES,AUTOSELECT=YES,CHANNELS="2",URI="\(audioProxied)"
        #EXT-X-STREAM-INF:BANDWIDTH=2500000\(res),CODECS="avc1.640020,mp4a.40.2",AUDIO="aud"
        \(videoProxied)
        """
    }

    /// 启动监听（阻塞至端口就绪，≤3s）
    public func start() throws {
        let p = NWParameters.tcp
        p.allowLocalEndpointReuse = true
        p.requiredLocalEndpoint = NWEndpoint.hostPort(host: "127.0.0.1", port: .any)
        let l = try NWListener(using: p)
        let ready = DispatchSemaphore(value: 0)
        l.stateUpdateHandler = { [weak self] state in
            OrigStreamServer.dlog("LISTENER \(state)")
            switch state {
            case .ready:
                self?.port = l.port?.rawValue ?? 0
                ready.signal()
            case .failed, .cancelled:
                ready.signal()
            default:
                break
            }
        }
        l.newConnectionHandler = { [weak self] conn in
            OrigStreamServer.dlog("ACCEPT \(conn.endpoint)")
            guard let self else { return }
            let pump = Pump(server: self, conn: conn)
            conn.start(queue: DispatchQueue(label: "ytb2zh.origstream.conn"))
            pump.begin()
        }
        listener = l
        l.start(queue: queue)
        _ = ready.wait(timeout: .now() + 3)
        guard port != 0 else {
            throw EngineError.engineFailure("本地原版流服务启动失败")
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    /// AVPlayer 播放地址（loopback 免 ATS）
    public var localPlayURL: URL? {
        guard port != 0 else { return nil }
        switch kind {
        case .progressive:
            return URL(string: "http://127.0.0.1:\(port)/v.mp4?t=\(token)")
        case .hls:
            return URL(string: "http://127.0.0.1:\(port)/master.m3u8?t=\(token)")
        }
    }

    public func kindOf() -> OrigStreamKind { kind }

    public func proxyValue() -> String { proxy }

    public func localPrefix() -> String { "http://127.0.0.1:\(port)" }
}

// MARK: - 单连接泵：解析请求 → 按模式分发（progressive 转发 / HLS 合成改写）

private final class Pump: @unchecked Sendable {
    let server: OrigStreamServer
    let conn: NWConnection
    var buf = Data()
    var dispatched = false
    var session: URLSession?
    /// 背压信号量：上一块 send 完成处理后才排下一块（初值 1）
    let backpressure = DispatchSemaphore(value: 1)

    init(server: OrigStreamServer, conn: NWConnection) {
        self.server = server
        self.conn = conn
    }

    func begin() {
        OrigStreamServer.dlog("PUMP begin")
        // 注意：必须强持有 self。Pump 只在 newConnectionHandler 里以局部变量创建，
        // 若全部用 [weak self] 会立即释放（app 里 AVPlayer 无限转圈的根因）。
        // 循环引用靠连接 cancel 后 NWConnection 释放 handler 来打破。
        conn.stateUpdateHandler = { state in
            OrigStreamServer.dlog("CONN \(state)")
            switch state {
            case .failed, .cancelled:
                OrigStreamServer.dlog("CONN end, release")
                self.conn.stateUpdateHandler = nil
                self.session?.invalidateAndCancel()
            default:
                break
            }
        }
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
            OrigStreamServer.dlog("RECV data=\(data?.count ?? -1) err=\(error != nil)")
            guard !self.dispatched else { return }
            if let data { self.buf.append(data) }
            if let s = String(data: self.buf, encoding: .utf8),
               let r = s.range(of: "\r\n\r\n") {
                self.dispatched = true
                self.dispatch(head: String(s[..<r.lowerBound]))
                return
            }
            if error == nil { self.receive() }
        }
    }

    private func sendText(_ status: String, body: String, contentType: String) {
        OrigStreamServer.dlog("SEND \(status) \(contentType) \(body.utf8.count)B")
        let head = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\n" +
            "Content-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: (head + body).data(using: .utf8), completion: .contentProcessed { [weak self] _ in
            self?.conn.cancel()
        })
    }

    private func reject(_ why: String) {
        OrigStreamServer.dlog("REJECT \(why)")
        sendText("403 Forbidden", body: why, contentType: "text/plain")
    }

    private func dispatch(head: String) {
        let server = self.server
        let lines = head.split(separator: "\r\n", omittingEmptySubsequences: false).map(String.init)
        guard let first = lines.first else { reject("bad request"); return }
        guard first.contains("t=\(server.token)") else { reject("bad token"); return }
        let parts = first.split(separator: " ")
        let path = parts.count > 1 ? String(parts[1]) : ""

        switch server.kindOf() {
        case .progressive(let up):
            guard let url = URL(string: up) else { reject("bad upstream"); return }
            let headers = Array(lines.dropFirst(1)) as [String]
            forward(upstream: url, head: headers)
        case .hls(let video, let audio):
            if path.hasPrefix("/master") {
                let vp = "\(server.localPrefix())/p?u=\(OrigStreamServer.b64url(video))&t=\(server.token)"
                let ap = "\(server.localPrefix())/p?u=\(OrigStreamServer.b64url(audio))&t=\(server.token)"
                sendText("200 OK",
                         body: OrigStreamServer.masterM3U8(videoProxied: vp, audioProxied: ap, height: 0),
                         contentType: "application/vnd.apple.mpegurl")
            } else if path.hasPrefix("/p") {
                handleProxy(path: path)
            } else {
                reject("not found")
            }
        }
    }

    /// progressive：Range 透传直连转发（委托流式回写）
    private func forward(upstream: URL, head: [String]) {
        var range: String?
        for l in head where l.lowercased().hasPrefix("range:") {
            range = l.split(separator: ":", maxSplits: 1).last
                .map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var req = URLRequest(url: upstream)
        if let range { req.setValue(range, forHTTPHeaderField: "Range") }
        let cfg = OrigStreamServer.sessionConfig()
        if let d = OrigStreamServer.proxyDict(server.proxyValue()) { cfg.connectionProxyDictionary = d }
        let s = URLSession(configuration: cfg, delegate: UpstreamDelegate(pump: self), delegateQueue: nil)
        session = s
        s.dataTask(with: req).resume()
    }

    /// HLS：/p?u= 反代。m3u8 → 改写 URI 回本反代；segment → 缓冲整段回写（切片都很小）
    private func handleProxy(path: String) {
        let server = self.server
        guard let q = path.split(separator: "?").last.map(String.init),
              let comp = URLComponents(string: "http://x?\(q)"),
              let raw = comp.queryItems?.first(where: { $0.name == "u" })?.value,
              let upstream = OrigStreamServer.unb64url(raw),
              let url = URL(string: upstream) else {
            reject("bad u"); return
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 30
        let cfg = OrigStreamServer.sessionConfig()
        if let d = OrigStreamServer.proxyDict(server.proxyValue()) { cfg.connectionProxyDictionary = d }
        let s = URLSession(configuration: cfg)
        session = s
        let done = DispatchSemaphore(value: 0)
        var payload: (data: Data, mime: String, error: String)?
        s.dataTask(with: req) { data, resp, err in
            let mime = (resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
            if let data {
                payload = (data, mime, "")
            } else {
                payload = (Data(), mime, err?.localizedDescription ?? "未知错误")
            }
            done.signal()
        }.resume()
        done.wait()
        guard let p = payload else { reject("no payload"); return }
        if !p.error.isEmpty {
            sendText("502 Bad Gateway", body: p.error, contentType: "text/plain")
            return
        }
        let isList = p.mime.lowercased().contains("mpegurl")
            || (p.data.prefix(7) == Data("#EXTM3U".utf8))
        if isList, let text = String(data: p.data, encoding: .utf8) {
            let out = OrigStreamServer.rewriteM3U8(text, baseURL: url, prefix: server.localPrefix(), token: server.token)
            sendText("200 OK", body: out, contentType: "application/vnd.apple.mpegurl")
        } else {
            let head = "HTTP/1.1 200 OK\r\nContent-Type: \(p.mime.isEmpty ? "application/octet-stream" : p.mime)\r\n" +
                "Content-Length: \(p.data.count)\r\nAccept-Ranges: none\r\nConnection: close\r\n\r\n"
            activeSend(head.data(using: .utf8) ?? Data())
            activeSend(p.data)
            activeSend(Data(), finish: true)
        }
    }

    private func activeSend(_ data: Data, finish: Bool = false) {
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            if finish { self?.conn.cancel() }
        })
    }

    func sendRaw(_ data: Data) {
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in
            self?.backpressure.signal()
        })
    }

    func finish() {
        conn.cancel()
        session?.finishTasksAndInvalidate()
    }
}

// MARK: - 上游 URLSession 委托（仅 progressive 转发用）：响应头回写 + 背压流式转发

private final class UpstreamDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    let pump: Pump

    init(pump: Pump) {
        self.pump = pump
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        defer { completionHandler(.allow) }
        guard let http = response as? HTTPURLResponse else { return }
        var head = "HTTP/1.1 \(http.statusCode) OK\r\n"
        for key in ["Content-Type", "Content-Length", "Content-Range"] {
            if let v = http.value(forHTTPHeaderField: key) { head += "\(key): \(v)\r\n" }
        }
        head += "Accept-Ranges: bytes\r\nConnection: close\r\n\r\n"
        let p = pump
        p.backpressure.wait()
        p.sendRaw(head.data(using: .utf8) ?? Data())
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let p = pump
        p.backpressure.wait()
        p.sendRaw(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        pump.finish()
    }
}
