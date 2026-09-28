import Foundation

/// 提取过程中的所有错误类型。
public enum ExtractionError: Error, LocalizedError, Sendable {
    /// URL 不属于任何已注册站点。
    case unsupportedURL(URL)
    /// URL 合法但无法解析出资源 ID。
    case malformedURL(String)
    /// 站点返回业务错误（如 B 站 code != 0、YouTube playabilityStatus != OK）。
    case siteError(site: String, code: Int, reason: String)
    /// 需要登录/Cookie 才能继续。
    case loginRequired(site: String, reason: String)
    /// 视频有 DRM 或其他不可下载原因。
    case notExtractable(site: String, reason: String)
    /// JS 挑战求解失败（decipher/nsig）。
    case jsFailure(String)
    /// 网络或响应解析失败。
    case network(String)
    /// 响应结构不符合预期（站点改版）。
    case parse(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedURL(let url):
            return "不支持的站点: \(url.absoluteString)"
        case .malformedURL(let detail):
            return "无法从 URL 解析资源 ID: \(detail)"
        case .siteError(let site, let code, let reason):
            return "[\(site)] 业务错误 \(code): \(reason)"
        case .loginRequired(let site, let reason):
            return "[\(site)] 需要登录或提供 Cookie: \(reason)"
        case .notExtractable(let site, let reason):
            return "[\(site)] 无法提取: \(reason)"
        case .jsFailure(let detail):
            return "JS 挑战求解失败: \(detail)"
        case .network(let detail):
            return "网络错误: \(detail)"
        case .parse(let detail):
            return "响应解析失败: \(detail)"
        }
    }
}
