import Foundation

/// 轻量 JSON 访问器：对 JSONSerialization 产物做宽容取值，
/// 避免站点响应结构频繁变动时维护庞大的 Codable 模型。
public struct JSON: @unchecked Sendable {
    public let raw: Any?

    public init(_ raw: Any?) { self.raw = raw }

    public init(data: Data) throws {
        raw = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public subscript(key: String) -> JSON { JSON((raw as? [String: Any])?[key]) }
    public subscript(index: Int) -> JSON { JSON((raw as? [Any])?[safe: index]) }

    /// 字符串；数字也会转成字符串（flat-playlist 场景 duration 可能是 "972"）。
    public var string: String? {
        switch raw {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    public var int: Int? { double.map(Int.init) }
    public var int64: Int64? { double.map(Int64.init) }
    /// 数字或数字字符串均返回值（站点响应字段类型经常二态）。
    public var double: Double? {
        if let n = raw as? NSNumber { return n.doubleValue }
        if let s = raw as? String { return Double(s) }
        return nil
    }
    public var bool: Bool? { (raw as? NSNumber)?.boolValue }
    public var array: [JSON] { (raw as? [Any])?.map(JSON.init) ?? [] }
    public var dict: [String: JSON]? { (raw as? [String: Any])?.mapValues(JSON.init) }
    public var exists: Bool { raw != nil && !(raw is NSNull) }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Query String

public enum QueryString {
    /// 解析 query string（不做 URL 解码以外的前处理）。
    public static func parse(_ query: String) -> [String: String] {
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first.map(String.init) else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            result[key.removingPercentEncoding ?? key] = value.removingPercentEncoding ?? value
        }
        return result
    }

    public static func encode(_ params: [String: String]) -> String {
        params
            .sorted { $0.key < $1.key }
            .map { "\($0.key)=\(urlEncode($0.value))" }
            .joined(separator: "&")
    }

    /// 与 JS encodeURIComponent 行为一致的编码（B 站 WBI 签名需要）。
    public static func urlEncode(_ string: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-_.!~*'()")
        return string.addingPercentEncoding(withAllowedCharacters: allowed) ?? string
    }
}
