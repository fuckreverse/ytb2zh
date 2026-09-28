import Foundation

/// 抖音视频 URL 解析：
/// - `https://www.douyin.com/video/<aweme_id>`
/// - `https://www.douyin.com/note/<aweme_id>`
/// - `https://www.iesdouyin.com/share/video/<aweme_id>/...`
/// - `https://v.douyin.com/xxxx/`（短链，需重定向解析）
public enum DouyinURL {

    public static let hostSuffixes = ["douyin.com", "iesdouyin.com", "v.douyin.com"]

    public struct VideoRef: Equatable, Sendable {
        /// aweme 数字 ID；短链场景为空，需先解析重定向。
        public var awemeID: String?
    }

    /// 静态解析；v.douyin.com 短链返回空 ID 的 ref，
    /// 由 extractor 内部走重定向解析。
    public static func videoRef(from url: URL) -> VideoRef? {
        guard let host = url.host?.lowercased() else { return nil }
        guard hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

        // /video/123456、/note/123456、/share/video/123456
        if let groups = RegexKit.firstMatch(pattern: #"/(?:video|note)/(\d+)"#, in: url.path),
           groups.count > 1 {
            return VideoRef(awemeID: groups[1])
        }
        // 查询参数兜底（部分分享链为 /?item_ids=...）
        let params = QueryString.parse(url.query ?? "")
        if let id = params["aweme_id"] ?? params["item_ids"] {
            return VideoRef(awemeID: id)
        }
        // 短链或无法识别的页面路径
        return VideoRef(awemeID: nil)
    }
}
