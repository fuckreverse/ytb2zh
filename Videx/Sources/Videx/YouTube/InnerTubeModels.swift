import Foundation

// MARK: - InnerTube 搜索/浏览结果模型
//
// search / browse / next 三个端点共用；递归解析器把嵌套的
// renderer 树拉平成统一的列表项。

public struct InnerTubeListItem: Sendable, Hashable {

    public enum Kind: String, Sendable, Equatable {
        case video, channel, playlist
    }

    public let kind: Kind
    /// videoId / channelId / playlistId
    public let id: String
    public let title: String
    public let thumbnailURL: String?
    public let url: String
    public let channelTitle: String?
    public let channelID: String?
    public let channelURL: String?
    /// 视频：观看次数（纯数字）
    public let viewCount: Int?
    /// 视频：时长秒数
    public let lengthSeconds: Int?
    /// 视频：发布时间文本（"3 days ago"）
    public let publishedTimeText: String?
    /// 视频：直播中
    public let live: Bool
    /// 播放列表：视频数
    public let videoCount: Int?
    /// 频道：订阅数文本
    public let subscriberCountText: String?
    /// 播放列表/频道：可能的列表继续 token（用于展开浏览）
    public let continuation: String?

    public init(kind: Kind, id: String, title: String, thumbnailURL: String? = nil,
                url: String, channelTitle: String? = nil, channelID: String? = nil,
                channelURL: String? = nil, viewCount: Int? = nil, lengthSeconds: Int? = nil,
                publishedTimeText: String? = nil, live: Bool = false,
                videoCount: Int? = nil, subscriberCountText: String? = nil,
                continuation: String? = nil) {
        self.kind = kind
        self.id = id
        self.title = title
        self.thumbnailURL = thumbnailURL
        self.url = url
        self.channelTitle = channelTitle
        self.channelID = channelID
        self.channelURL = channelURL
        self.viewCount = viewCount
        self.lengthSeconds = lengthSeconds
        self.publishedTimeText = publishedTimeText
        self.live = live
        self.videoCount = videoCount
        self.subscriberCountText = subscriberCountText
        self.continuation = continuation
    }

    /// 简要描述（调试/日志用）
    public var debugDescription: String {
        let extra: String
        switch kind {
        case .video:
            extra = lengthSeconds.map { " \($0)s" } ?? ""
        case .playlist:
            extra = videoCount.map { " \($0) videos" } ?? ""
        case .channel:
            extra = subscriberCountText.map { " \($0)" } ?? ""
        }
        return "[\(kind.rawValue)] \(title)\(extra) (\(url))"
    }
}

/// search/browse/next 的统一返回：拉平的列表项 + 分页 token
public struct InnerTubeSearchResult: Sendable {
    public let items: [InnerTubeListItem]
    /// 下一页 token（nil = 没有更多）
    public let continuation: String?
    /// 页面/列表自身标题（频道名/播放列表名）
    public let title: String?

    public init(items: [InnerTubeListItem], continuation: String? = nil, title: String? = nil) {
        self.items = items
        self.continuation = continuation
        self.title = title
    }

    /// 仅视频结果
    public var videos: [InnerTubeListItem] { items.filter { $0.kind == .video } }
}

/// 搜索过滤参数（InnerTube params 字段的 base64 proto 编码）。
public enum InnerTubeSearchFilter: String, Sendable {
    case any = ""
    case videos = "EgIQAQ%3D%3D"
    case channels = "EgIQAg%3D%3D"
    case playlists = "EgIQAw%3D%3D"
    case live = "EgJAAQ%3D%3D"
}

/// 频道 browse 页签 params（protobuf base64）
public enum InnerTubeBrowseTab: String, Sendable {
    /// 频道"视频"页签（按最新排序）
    case videos = "EgZ2aWRlb3PyBgQKAkIA"
    /// 频道"播放列表"页签
    case playlists = "EglwbGF5bGlzdHPyBgQKAkIA"
    /// 频道"直播"页签
    case live = "EgdzdHJlYW1z8gYUCgJAAQ%3D%3D"
}
