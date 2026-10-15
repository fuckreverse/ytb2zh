import Foundation

// MARK: - Request / Response

public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
    public var maximumResponseBytes: Int?

    public init(
        method: String = "GET",
        url: URL,
        headers: [String: String] = [:],
        body: Data? = nil, maximumResponseBytes: Int? = nil
    ) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
        self.maximumResponseBytes = maximumResponseBytes
    }

    public static func get(_ url: URL, headers: [String: String] = [:]) -> HTTPRequest {
        HTTPRequest(method: "GET", url: url, headers: headers)
    }

    public static func post(_ url: URL, json: Any, headers: [String: String] = [:]) throws -> HTTPRequest {
        var req = HTTPRequest(method: "POST", url: url, headers: headers)
        req.headers["Content-Type"] = "application/json"
        req.body = try JSONSerialization.data(withJSONObject: json)
        return req
    }
}

public struct HTTPResponse: Sendable {
    public var status: Int
    public var headers: [String: String]
    public var body: Data
    /// 重定向后的最终 URL（未重定向则等于请求 URL）。
    public var finalURL: URL?

    public init(status: Int, headers: [String: String], body: Data, finalURL: URL? = nil) {
        self.status = status
        self.headers = headers
        self.body = body
        self.finalURL = finalURL
    }

    public var isOK: Bool { (200..<300).contains(status) }

    public var text: String { String(data: body, encoding: .utf8) ?? "" }

    public var json: JSON? {
        try? JSON(data: body)
    }
}

// MARK: - Protocol

/// 网络层抽象：默认实现是 URLSession，测试或特殊场景可替换。
public protocol HTTPFetching: Sendable {
    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse
}

extension HTTPFetching {
    /// GET 并返回 JSON，非 2xx 或解析失败抛错。
    public func getJSON(_ url: URL, headers: [String: String] = [:]) async throws -> JSON {
        let resp = try await fetch(.get(url, headers: headers))
        guard resp.isOK, let json = resp.json else {
            throw ExtractionError.network("HTTP \(resp.status) for \(url.absoluteString)")
        }
        return json
    }
}

// MARK: - URLSession Implementation

/// 基于 URLSession 的默认实现，支持 http/https/socks5 代理。
public final class URLSessionHTTPClient: HTTPFetching, @unchecked Sendable {
    private let session: URLSession

    public init(proxy: String? = nil, timeout: TimeInterval = 30) {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout * 4
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        if let proxy { config.connectionProxyDictionary = Self.proxyDictionary(from: proxy) }
        session = URLSession(configuration: config)
    }

    deinit { session.finishTasksAndInvalidate() }

    /// "http://127.0.0.1:7890"、"socks5://127.0.0.1:7891" → 连接代理字典。
    public static func proxyDictionary(from proxy: String) -> [AnyHashable: Any] {
        guard let url = URL(string: proxy),
              let host = url.host,
              let port = url.port
        else { return [:] }

        if url.scheme?.lowercased().hasPrefix("socks") == true {
            return [
                kCFStreamPropertySOCKSProxyHost as String: host,
                kCFStreamPropertySOCKSProxyPort as String: port,
            ]
        }
        return [
            "HTTPEnable": 1,
            "HTTPProxy": host,
            "HTTPPort": port,
            "HTTPSEnable": 1,
            "HTTPSProxy": host,
            "HTTPSPort": port,
        ]
    }

    public func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (key, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: key)
        }

        let data: Data
        let urlResponse: URLResponse
        do {
            if let maximum = request.maximumResponseBytes {
                let (bytes, response) = try await session.bytes(for: urlRequest)
                var buffered = Data()
                for try await byte in bytes {
                    guard buffered.count < maximum else { throw ExtractionError.network("响应超过请求允许的大小，已停止读取") }
                    buffered.append(byte)
                }
                data = buffered; urlResponse = response
            } else {
                (data, urlResponse) = try await session.data(for: urlRequest)
            }
        } catch {
            throw ExtractionError.network("\(error.localizedDescription) — \(request.url.absoluteString)")
        }
        guard let http = urlResponse as? HTTPURLResponse else {
            throw ExtractionError.network("非 HTTP 响应 — \(request.url.absoluteString)")
        }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields {
            if let k = key as? String, let v = value as? String { headers[k] = v }
        }
        return HTTPResponse(status: http.statusCode, headers: headers, body: data, finalURL: urlResponse.url)
    }
}
