import Foundation

/// B 站 URL 解析：BV/av 号、b23.tv 短链、多 P 分页。
public enum BilibiliURL {
    public static let hostSuffixes = [
        "bilibili.com", "www.bilibili.com", "m.bilibili.com",
        "b23.tv", "bili2233.cn", "bilibili.tv",
    ]

    public struct VideoRef: Equatable, Sendable {
        public var bvid: String?
        public var aid: String?
        public var page: Int

        public init(bvid: String? = nil, aid: String? = nil, page: Int = 1) {
            self.bvid = bvid
            self.aid = aid
            self.page = page
        }
    }

    /// 静态解析；b23.tv 短链需要网络跟随重定向，这里返回 nil，
    /// 由 extractor 内部走 resolveShortLink。
    public static func videoRef(from url: URL) -> VideoRef? {
        guard let host = url.host?.lowercased() else { return nil }
        guard hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

        let params = QueryString.parse(url.query ?? "")
        let page = Int(params["p"] ?? "1") ?? 1

        // /video/BVxxxx 或 /video/av123
        let segments = url.path.split(separator: "/").map(String.init)
        if segments.first == "video", segments.count >= 2 {
            let ref = segments[1]
            if ref.hasPrefix("BV"), ref.count >= 10 {
                return VideoRef(bvid: ref, aid: params["aid"], page: page)
            }
            if ref.lowercased().hasPrefix("av"), let aid = Int(ref.dropFirst(2)).map(String.init) {
                return VideoRef(aid: aid, page: page)
            }
        }
        // 查询参数兜底
        if let bvid = params["bvid"], bvid.hasPrefix("BV") {
            return VideoRef(bvid: bvid, page: page)
        }
        if let aid = params["aid"] {
            return VideoRef(aid: aid, page: page)
        }
        // b23.tv/<code> 短链
        if host == "b23.tv" || host.hasSuffix(".b23.tv") || host == "bili2233.cn" {
            return VideoRef(page: page) // 仅标记"是 B 站链接"，code 靠重定向解析
        }
        return nil
    }

    /// b23.tv 短链是否需要重定向解析。
    public static func isShortLink(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return host == "b23.tv" || host.hasSuffix(".b23.tv") || host == "bili2233.cn"
    }
}

// MARK: - 画质映射

/// B 站 DASH 清晰度 ID → 标签（来自公开的 playurl 文档）。
public enum BilibiliQuality {
    public static let labels: [Int: String] = [
        127: "8K 超高清",
        126: "杜比视界",
        125: "HDR 真彩",
        120: "4K 超清",
        116: "1080P 60帧",
        112: "1080P 高码率",
        100: "智能修复",
        80: "1080P 高清",
        74: "720P 60帧",
        64: "720P 高清",
        48: "720P 高清(手机)",
        32: "480P 清晰",
        16: "360P 流畅",
        15: "360P 水印",
        6: "240P 极速",
        5: "144P 流畅",
    ]

    public static func label(for id: Int) -> String {
        labels[id] ?? "画质\(id)"
    }

    /// 音频流 ID → 标签。
    public static let audioLabels: [Int: String] = [
        30251: "Hi-Res 无损",
        30255: "Audio Dolby",
        30250: "Dolby Atmos",
        30280: "高清音频",
        30232: "高码率",
        30216: "中码率",
        30214: "低码率",
    ]

    public static func audioLabel(for id: Int) -> String {
        audioLabels[id] ?? "音频\(id)"
    }
}
