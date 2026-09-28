import Foundation

/// 站点 Cookie 的最小表达（不依赖 HTTPCookie 的可序列化版本）。
public struct SiteCookie: Codable, Sendable, Equatable {
    public var name: String
    public var value: String
    /// 生效域，如 ".bilibili.com"（含前导点表示子域通配）。
    public var domain: String

    public init(name: String, value: String, domain: String) {
        self.name = name
        self.value = value
        self.domain = domain
    }
}

/// 按域组织的 Cookie 集合，负责为具体请求拼 Cookie 头。
public struct CookieJar: Codable, Sendable, Equatable {
    public var cookies: [SiteCookie]

    public init(cookies: [SiteCookie] = []) {
        self.cookies = cookies
    }

    public mutating func set(_ cookie: SiteCookie) {
        cookies.removeAll { $0.name == cookie.name && $0.domain == cookie.domain }
        cookies.append(cookie)
    }

    /// 返回适用于该 URL 的 Cookie 头值；无匹配返回 nil。
    public func header(for url: URL) -> String? {
        let host = url.host?.lowercased() ?? ""
        let matched = cookies.filter { cookie in
            let domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") {
                return host == String(domain.dropFirst()) || host.hasSuffix(domain)
            }
            return host == domain
        }
        guard !matched.isEmpty else { return nil }
        return matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
    }

    /// 取某个 Cookie 值（按名 + 域后缀匹配）。
    public func value(named name: String, forDomain suffix: String) -> String? {
        cookies
            .filter { $0.name == name && $0.domain.lowercased().hasSuffix(suffix.lowercased()) }
            .first?.value
    }
}
