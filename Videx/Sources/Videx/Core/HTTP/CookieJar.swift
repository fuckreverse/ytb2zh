import Foundation

/// 站点 Cookie 的最小表达（不依赖 HTTPCookie 的可序列化版本）。
public struct SiteCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    /// 生效域，如 ".bilibili.com"（含前导点表示子域通配）。
    public var domain: String
    public var path: String?
    public var expires: TimeInterval?
    public var secure: Bool?

    public init(name: String, value: String, domain: String, path: String? = nil, expires: TimeInterval? = nil, secure: Bool? = nil) {
        self.name = name
        self.value = value
        self.domain = domain
        self.path = path
        self.expires = expires
        self.secure = secure
    }
}

/// 按域组织的 Cookie 集合，负责为具体请求拼 Cookie 头。
public struct CookieJar: Codable, Sendable, Equatable {
    public var cookies: [SiteCookie]

    public init(cookies: [SiteCookie] = []) {
        self.cookies = cookies
    }

    public mutating func set(_ cookie: SiteCookie) {
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain && ($0.path ?? "/") == (cookie.path ?? "/") }
        cookies.append(cookie)
    }

    /// 返回适用于该 URL 的 Cookie 头值；无匹配返回 nil。
    public func header(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let matched = cookies.filter { cookie in
            if let expiry = cookie.expires, expiry > 0 && expiry <= Date().timeIntervalSince1970 { return false }
            if cookie.secure == true && url.scheme?.lowercased() != "https" { return false }
            let cookiePath = cookie.path ?? "/"
            let requestPath = url.path.isEmpty ? "/" : url.path
            if requestPath != cookiePath && !requestPath.hasPrefix(cookiePath.hasSuffix("/") ? cookiePath : cookiePath + "/") { return false }
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                return host == String(domain.dropFirst()) || host.hasSuffix(domain)
            }
            return host == domain
        }
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    public func value(named name: String, for url: URL) -> String? {
        cookies.filter { $0.name == name }.first { CookieJar(cookies: [$0]).header(for: url) != nil }?.value
    }

    /// 取某个 Cookie 值（按名 + 域后缀匹配）。
    public func value(named name: String, forDomain suffix: String) -> String? {
        cookies
            .filter {
                let domain = $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                let suffix = suffix.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
                return $0.name == name && (domain == suffix || domain.hasSuffix("." + suffix))
            }
            .first?.value
    }
}

public extension CookieJar {
    /// Match yt-dlp: consent/visitor/SID cookies alone do not establish a logged-in session.
    var hasYouTubeAuthentication: Bool {
        value(named: "LOGIN_INFO", for: URL(string: "https://www.youtube.com")!) != nil
            && ["SAPISID", "__Secure-1PAPISID", "__Secure-3PAPISID"].contains {
                value(named: $0, for: URL(string: "https://www.youtube.com")!)?.isEmpty == false
            }
    }

    /// Import an explicitly selected Netscape cookies.txt file. Ignore expired entries.
    init(netscape text: String, now: TimeInterval = Date().timeIntervalSince1970) throws {
        self.init()
        for line in text.components(separatedBy: .newlines) {
            var line = line.trimmingCharacters(in: .newlines)
            if line.hasPrefix("#HttpOnly_") { line = String(line.dropFirst(10)) }
            else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let columns = line.components(separatedBy: "\t")
            guard columns.count == 7, let expiry = Double(columns[4]),
                  !columns[0].isEmpty, !columns[5].isEmpty else {
                throw ExtractionError.parse("Cookie 文件应为 Netscape cookies.txt 格式")
            }
            if expiry > 0 && expiry <= now { continue }
            let domain = columns[1].uppercased() == "TRUE" && !columns[0].hasPrefix(".")
                ? "." + columns[0] : columns[0]
            set(SiteCookie(name: columns[5], value: columns[6], domain: domain,
                           path: columns[2], expires: expiry > 0 ? expiry : nil, secure: columns[3].uppercased() == "TRUE"))
        }
    }
}
