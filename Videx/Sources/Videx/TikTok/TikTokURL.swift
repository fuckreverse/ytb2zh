import Foundation

/// TikTok 视频 URL 解析：
/// - `https://www.tiktok.com/@user/video/<id>`
/// - `https://www.tiktok.com/embed/<id>`
/// - `https://vm.tiktok.com/xxxx`、`https://vt.tiktok.com/xxxx`、`https://www.tiktok.com/t/xxxx`（短链）
public enum TikTokURL {

    public struct VideoRef: Equatable, Sendable {
        /// 数字视频 ID；短链场景为空，需先解析重定向。
        public var videoID: String?
        /// 页面路径中的用户名（可空）。
        public var userHandle: String?
    }

    public static let hostSuffixes = ["tiktok.com", "vm.tiktok.com", "vt.tiktok.com"]

    /// 静态解析；短链返回空 ID 的 ref，由 extractor 内部走重定向。
    public static func videoRef(from url: URL) -> VideoRef? {
        guard let host = url.host?.lowercased() else { return nil }
        guard hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

        let path = url.path
        // /@user/video/123 或 /@_/video/123 或 /@/video/123（短链重定向后用户名可能为空）
        // 注意 RegexKit 会丢弃 nil 捕获组，故用 last 取视频 ID
        if let groups = RegexKit.firstMatch(pattern: #"/@(?:([\w\.-]+))?/video/(\d+)"#, in: path),
           let videoID = groups.last, groups.count >= 2 {
            let handle = groups.count > 2 ? groups[1] : nil
            return VideoRef(videoID: videoID, userHandle: handle)
        }
        if let groups = RegexKit.firstMatch(pattern: #"/embed/(\d+)"#, in: path), groups.count > 1 {
            return VideoRef(videoID: groups[1], userHandle: nil)
        }
        // 短链（vm/vt.tiktok.com、/t/）
        return VideoRef(videoID: nil, userHandle: nil)
    }

    /// 规范视频页 URL（用户名缺失时用 "_"）。
    public static func canonicalURL(videoID: String, userHandle: String?) -> URL {
        let handle = (userHandle?.isEmpty == false) ? userHandle! : "_"
        return URL(string: "https://www.tiktok.com/@\(handle)/video/\(videoID)")!
    }
}
