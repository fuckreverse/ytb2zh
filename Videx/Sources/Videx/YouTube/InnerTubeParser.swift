// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

// MARK: - InnerTube 响应解析器
//
// search / browse / next 的响应都是深层嵌套的 renderer 树，
// 结构随版本频繁变动。这里采用递归收集策略：遍历整棵 JSON 树，
// 按已知的 renderer key 拉取条目，不依赖固定路径——上游改动
// 中间层的容器名时仍能正确提取。

enum InnerTubeParser {

    /// 递归遍历 JSON 树，收集所有视频/频道/播放列表条目与分页 token
    static func collect(from json: JSON) -> InnerTubeSearchResult {
        var videos: [InnerTubeListItem] = []
        var channels: [InnerTubeListItem] = []
        var playlists: [InnerTubeListItem] = []
        var continuation: String?
        var pageTitle: String?

        walk(json) { key, node in
            switch key {
            case "videoRenderer", "gridVideoRenderer":
                if let item = parseVideo(node) { videos.append(item) }
            case "playlistVideoRenderer":
                if let item = parsePlaylistVideo(node) { videos.append(item) }
            case "channelRenderer":
                if let item = parseChannel(node) { channels.append(item) }
            case "playlistRenderer", "gridPlaylistRenderer":
                if let item = parsePlaylist(node) { playlists.append(item) }
            case "lockupViewModel":
                // 新版 UI（2025+）频道/搜索页改用 lockupViewModel 承载条目，
                // 按 contentType 区分视频/播放列表
                if let item = parseLockup(node) {
                    switch item.kind {
                    case .video: videos.append(item)
                    case .channel: channels.append(item)
                    case .playlist: playlists.append(item)
                    }
                }
            case "continuationItemRenderer":
                let token = node["continuationEndpoint"]["continuationCommand"]["token"].string
                    ?? node["button"]["buttonRenderer"]["command"]["continuationCommand"]["token"].string
                if let token, continuation == nil { continuation = token }
            case "channelMetadataRenderer":
                // 频道 browse 页的元信息（标题）
                if let title = node["title"].string, pageTitle == nil { pageTitle = title }
            case "playlistHeaderRenderer", "pageHeaderRenderer":
                if let title = node["title"].string ?? node["pageTitle"].string, pageTitle == nil {
                    pageTitle = title
                }
            default:
                break
            }
        }

        // 去重（递归可能重复进入同一节点）
        func dedup(_ items: [InnerTubeListItem]) -> [InnerTubeListItem] {
            var seen = Set<String>()
            return items.filter { seen.insert($0.id).inserted }
        }
        return InnerTubeSearchResult(
            items: dedup(videos + channels + playlists),
            continuation: continuation,
            title: pageTitle)
    }

    // MARK: - 递归遍历

    /// 深度优先遍历 JSON 树，对每个 {key: {...}} 形式的节点回调
    private static func walk(_ json: JSON, _ visit: (String, JSON) -> Void) {
        guard let raw = json.raw else { return }
        if let dict = raw as? [String: Any] {
            for (key, value) in dict {
                let node = JSON(value)
                visit(key, node)
                walk(node, visit)
            }
        } else if let array = raw as? [Any] {
            for element in array { walk(JSON(element), visit) }
        }
    }

    // MARK: - 单条解析

    private static func parseVideo(_ node: JSON) -> InnerTubeListItem? {
        guard let videoID = node["videoId"].string, !videoID.isEmpty else { return nil }
        let title = runsText(node["title"]) ?? node["headline"].string ?? ""
        guard !title.isEmpty else { return nil }

        let thumbnails = node["thumbnail"]["thumbnails"].array
        let thumb = thumbnails.last?["url"].string

        // 频道信息（ownerText / longBylineText / shortBylineText 结构相同）
        let byline = node["ownerText"].exists ? node["ownerText"] : (
            node["longBylineText"].exists ? node["longBylineText"] : node["shortBylineText"])
        let channelTitle = runsText(byline)
        let channelID = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string
        let channelURL = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["canonicalBaseUrl"].string
            .map { "https://www.youtube.com\($0)" }

        let views = parseViewCount(node["viewCountText"].string
            ?? runsText(node["viewCountText"])
            ?? node["shortViewCountText"].string)
        let length = parseDuration(node["lengthText"].string ?? runsText(node["lengthText"]))
        let published = runsText(node["publishedTimeText"])
        let live = isLive(node)

        return InnerTubeListItem(
            kind: .video, id: videoID, title: title, thumbnailURL: thumb,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            channelTitle: channelTitle, channelID: channelID, channelURL: channelURL,
            viewCount: views, lengthSeconds: length, publishedTimeText: published, live: live)
    }

    /// playlistVideoRenderer（播放列表内的视频条目，字段名略有不同）
    private static func parsePlaylistVideo(_ node: JSON) -> InnerTubeListItem? {
        guard let videoID = node["videoId"].string, !videoID.isEmpty else { return nil }
        let title = runsText(node["title"]) ?? ""
        guard !title.isEmpty else { return nil }

        let thumb = node["thumbnail"]["thumbnails"].array.last?["url"].string
        let byline = node["shortBylineText"].exists ? node["shortBylineText"] : node["longBylineText"]
        let channelTitle = runsText(byline)
        let channelID = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string

        // playlistVideoRenderer 的时长在 lengthSeconds（直接秒数）或 lengthText
        let length = node["lengthSeconds"].int
            ?? parseDuration(node["lengthText"].string ?? runsText(node["lengthText"]))

        return InnerTubeListItem(
            kind: .video, id: videoID, title: title, thumbnailURL: thumb,
            url: "https://www.youtube.com/watch?v=\(videoID)",
            channelTitle: channelTitle, channelID: channelID,
            lengthSeconds: length)
    }

    // MARK: - lockupViewModel（新版 UI）

    /// 新版 YouTube 界面的通用条目 ViewModel：
    /// contentType = LOCKUP_CONTENT_TYPE_VIDEO / _PLAYLIST / _PODCAST 等，
    /// contentId 即 videoId / playlistId；时长徽章嵌在 thumbnailViewModel 的
    /// overlays 中，频道信息在 metadataRows 的 metadataParts 中。
    private static func parseLockup(_ node: JSON) -> InnerTubeListItem? {
        guard let contentID = node["contentId"].string, !contentID.isEmpty else { return nil }
        let contentType = node["contentType"].string ?? ""

        let metaVM = node["metadata"]["lockupMetadataViewModel"]
        let title = metaVM["title"]["content"].string ?? ""
        guard !title.isEmpty else { return nil }

        let thumbVM = node["contentImage"]["thumbnailViewModel"]
        let thumb = thumbVM["image"]["sources"].array.last?["url"].string
            ?? thumbVM["primaryThumbnail"]["sources"].array.last?["url"].string

        // 时长/直播徽章：overlays[].thumbnailBottomOverlayViewModel.badges[].thumbnailBadgeViewModel.text
        var badgeTexts: [String] = []
        for overlay in thumbVM["overlays"].array {
            for badge in overlay["thumbnailBottomOverlayViewModel"]["badges"].array {
                if let text = badge["thumbnailBadgeViewModel"]["text"].string, !text.isEmpty {
                    badgeTexts.append(text)
                }
            }
        }
        let live = badgeTexts.contains { $0.lowercased().contains("live") }
        let lengthSeconds = badgeTexts.compactMap { parseDuration($0) }.first

        // metadataRows[].metadataParts[]：首个文本通常是频道名，其后是观看数/发布时间；
        // 频道头像（若存在）挂在 part.avatar.decoratedAvatarViewModel，内含 browseEndpoint
        var texts: [String] = []
        var channelID: String?
        var channelURL: String?
        for row in metaVM["metadata"]["contentMetadataViewModel"]["metadataRows"].array {
            for part in row["metadataParts"].array {
                if let text = part["text"]["content"].string, !text.isEmpty {
                    texts.append(text)
                }
                if channelID == nil {
                    let avatar = part["avatar"]["decoratedAvatarViewModel"]
                    let browse = avatar["onTap"]["innertubeCommand"]["browseEndpoint"]
                    channelID = browse["browseId"].string
                    if let base = browse["canonicalBaseUrl"].string {
                        channelURL = "https://www.youtube.com\(base)"
                    }
                }
            }
        }
        let channelTitle = texts.first
        var viewCount: Int?
        var published: String?
        for text in texts.dropFirst() {
            let lowered = text.lowercased()
            if lowered.contains("view") {
                viewCount = viewCount ?? parseViewCount(text)
            } else if published == nil,
                      lowered.contains("ago") || lowered.contains("streamed")
                        || lowered.contains("premiered") {
                published = text
            }
        }

        if contentType.contains("PLAYLIST") {
            return InnerTubeListItem(
                kind: .playlist, id: contentID, title: title, thumbnailURL: thumb,
                url: "https://www.youtube.com/playlist?list=\(contentID)",
                channelTitle: channelTitle, channelID: channelID, channelURL: channelURL)
        }

        // 默认按视频处理（LOCKUP_CONTENT_TYPE_VIDEO 等）
        return InnerTubeListItem(
            kind: .video, id: contentID, title: title, thumbnailURL: thumb,
            url: "https://www.youtube.com/watch?v=\(contentID)",
            channelTitle: channelTitle, channelID: channelID, channelURL: channelURL,
            viewCount: viewCount, lengthSeconds: lengthSeconds,
            publishedTimeText: published, live: live)
    }

    private static func parseChannel(_ node: JSON) -> InnerTubeListItem? {
        guard let channelID = node["channelId"].string ?? node["browseId"].string else { return nil }
        let title = node["title"].string ?? runsText(node["title"]) ?? ""
        guard !title.isEmpty else { return nil }

        let thumb = node["thumbnail"]["thumbnails"].array.last?["url"].string
        let subs = node["subscriberCountText"].string ?? runsText(node["subscriberCountText"])

        return InnerTubeListItem(
            kind: .channel, id: channelID, title: title, thumbnailURL: thumb,
            url: "https://www.youtube.com/channel/\(channelID)",
            channelTitle: title, channelID: channelID,
            subscriberCountText: subs)
    }

    private static func parsePlaylist(_ node: JSON) -> InnerTubeListItem? {
        guard let playlistID = node["playlistId"].string, !playlistID.isEmpty else { return nil }
        let title = node["title"].string ?? runsText(node["title"]) ?? ""
        guard !title.isEmpty else { return nil }

        // 缩略图可能来自 thumbnails[] 或 thumbnailRenderer
        let thumb = node["thumbnails"].array.last?["thumbnails"].array.last?["url"].string
            ?? node["thumbnailRenderer"]["playlistVideoThumbnailRenderer"]["thumbnail"]["thumbnails"].array.last?["url"].string

        let byline = node["ownerText"].exists ? node["ownerText"]
            : (node["longBylineText"].exists ? node["longBylineText"] : node["shortBylineText"])
        let channelTitle = runsText(byline)
        let channelID = byline["runs"][0]["navigationEndpoint"]["browseEndpoint"]["browseId"].string

        let videoCount = parseCount(node["videoCountText"].string ?? runsText(node["videoCountText"]))

        return InnerTubeListItem(
            kind: .playlist, id: playlistID, title: title, thumbnailURL: thumb,
            url: "https://www.youtube.com/playlist?list=\(playlistID)",
            channelTitle: channelTitle, channelID: channelID,
            videoCount: videoCount)
    }

    // MARK: - 工具

    /// runs[].text 拼接（InnerTube 富文本标准结构）
    private static func runsText(_ node: JSON) -> String? {
        let runs = node["runs"].array
        if !runs.isEmpty {
            let text = runs.compactMap { $0["text"].string }.joined()
            return text.isEmpty ? nil : text
        }
        return node["simpleText"].string
    }

    /// "1,234,567 views" / "No views" / "123 watching" → Int?（观看中返回 nil）
    static func parseViewCount(_ text: String?) -> Int? {
        guard let text, !text.isEmpty else { return nil }
        let lowered = text.lowercased()
        guard !lowered.contains("watching"), !lowered.contains("no view") else { return nil }
        return parseCount(text)
    }

    /// 从文本提取数字（去逗号/空格），"50 videos" → 50
    static func parseCount(_ text: String?) -> Int? {
        guard let text else { return nil }
        let digits = text.unicodeScalars.filter { CharacterSet.decimalDigits.contains($0) }
        guard !digits.isEmpty else { return nil }
        return Int(String(String.UnicodeScalarView(digits)))
    }

    /// "3:45" / "1:23:45" → 秒
    static func parseDuration(_ text: String?) -> Int? {
        guard let text else { return nil }
        let parts = text.split(separator: ":").compactMap { Int($0) }
        switch parts.count {
        case 1: return parts[0]
        case 2: return parts[0] * 60 + parts[1]
        case 3: return parts[0] * 3600 + parts[1] * 60 + parts[2]
        default: return nil
        }
    }

    /// LIVE 标记检测（badges / thumbnailOverlays）
    private static func isLive(_ node: JSON) -> Bool {
        for badge in node["badges"].array {
            if badge["metadataBadgeRenderer"]["style"].string?.contains("LIVE") == true { return true }
        }
        for overlay in node["thumbnailOverlays"].array {
            let style = overlay["thumbnailOverlayBadgeViewModel"]["thumbnailBadges"]
            for badge in style.array {
                if badge["thumbnailBadgeViewModel"]["text"].string?.lowercased().contains("live") == true {
                    return true
                }
            }
            if overlay["thumbnailOverlayTimeStatusRenderer"]["style"].string?.contains("LIVE") == true {
                return true
            }
        }
        return false
    }
}
