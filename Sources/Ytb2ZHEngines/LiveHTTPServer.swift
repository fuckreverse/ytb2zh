import Foundation
import Network

// MARK: - 伪直播本地 HTTP 服务
// macOS 新版内核的 HLS 内容泵拒绝自定义 scheme（-12881 "custom url not redirect"，
// ResourceLoader 能拦截 playlist/分片但 FigStreamPlayer 拒绝泵送），改走 loopback HTTP：
// AVPlayer 对 http://127.0.0.1 的 EVENT HLS（分片追加、playlist 全量重写轮询）原生支持。

public final class LiveHTTPServer: @unchecked Sendable {
    public static let shared = LiveHTTPServer()

    private var listener: NWListener?
    private var port: UInt16 = 0
    private let lock = NSLock()
    private init() {}

    public var boundPort: UInt16 {
        lock.lock(); defer { lock.unlock() }
        return port
    }

    /// 幂等启动；返回绑定端口（绑定失败返回 0）
    @discardableResult
    public func start() -> UInt16 {
        lock.lock()
        if port != 0 { lock.unlock(); return port }
        lock.unlock()

        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(.loopback), port: .any)
        guard let l = try? NWListener(using: params) else { return 0 }
        listener = l
        let queue = DispatchQueue(label: "ytb2zh.livehttp")
        l.newConnectionHandler = { [weak self] conn in self?.accept(conn, queue: queue) }
        l.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let p = l.port?.rawValue, p != 0 {
                self?.lock.lock()
                self?.port = p
                self?.lock.unlock()
            }
        }
        l.start(queue: queue)
        // 等待端口就绪（最多 2s）
        for _ in 0..<40 {
            lock.lock(); let p = port; lock.unlock()
            if p != 0 { return p }
            usleep(50_000)
        }
        return port
    }

    // MARK: 连接处理（最小 HTTP/1.1：只处理 GET，响应后关闭）

    private func accept(_ conn: NWConnection, queue: DispatchQueue) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data { buf.append(data) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                self.respond(conn, head: head)
                return
            }
            if error != nil || done || buf.count > 64 * 1024 { conn.cancel(); return }
            self.readRequest(conn, buffer: buf)
        }
    }

    private func respond(_ conn: NWConnection, head: String) {
        let requestLine = head.components(separatedBy: "\r\n").first ?? ""
        let parts = requestLine.split(separator: " ").map(String.init)
        guard parts.count >= 2, parts[0] == "GET",
              let url = URL(string: "http://loopback" + parts[1]) else {
            send(conn, status: "400 Bad Request", type: "text/plain", body: Data()); return
        }
        let segs = url.path.split(separator: "/").map(String.init)
        guard segs.count == 2, let dir = LiveMediaStore.shared.dir(for: segs[0]) else {
            send(conn, status: "404 Not Found", type: "text/plain", body: Data()); return
        }
        let name = segs[1]
        guard !name.contains(".."), !name.hasPrefix("/") else {
            send(conn, status: "403 Forbidden", type: "text/plain", body: Data()); return
        }
        let file = dir.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: file) else {
            send(conn, status: "404 Not Found", type: "text/plain", body: Data()); return
        }
        let type: String
        if name.hasSuffix(".m3u8") { type = "application/vnd.apple.mpegurl" }
        else if name.hasSuffix(".ts") { type = "video/mp2t" }
        else { type = "application/octet-stream" }
        send(conn, status: "200 OK", type: type, body: data)
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: Data) {
        let head = "HTTP/1.1 \(status)\r\n"
            + "Content-Type: \(type)\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        var out = Data(head.utf8)
        out.append(body)
        conn.send(content: out, completion: .contentProcessed { _ in conn.cancel() })
    }
}
