import Foundation

// MARK: - URL Key 解析

/// aweme 流地址的 url_key 形如：
/// `v09044cc0000bm92pg3l96b4aifucvt0_h264_540p_800567`
/// 解析出格式 ID、编码、分辨率档、码率。
struct AwemeURLKey: Equatable {
    let formatID: String
    let codec: String?      // h264 / bytevc1 / bytevc2 …
    let resolution: String? // "540p"
    let bitrateKbps: Int?

    var videoCodec: String? {
        switch codec {
        case "bytevc1": return "h265"
        case "bytevc2": return "h266"   // 字节自研 VVC，暂不可播
        default: return codec
        }
    }

    var height: Int? {
        guard let resolution, resolution.hasSuffix("p"),
              let value = Int(resolution.dropLast()) else { return nil }
        return value
    }

    static func parse(_ key: String?) -> AwemeURLKey? {
        guard let key else { return nil }
        // 结构：vXXXX_<codec>_<res>p_<bitrate>
        guard let match = key.range(of: #"(?<id>[^_]+_(?<res>\d+p)_(?<br>\d+))$"#, options: .regularExpression) else {
            return nil
        }
        let id = String(key[match])
        let parts = id.split(separator: "_")
        guard parts.count >= 3 else { return nil }
        let codec = String(parts[parts.count - 3])
        let res = String(parts[parts.count - 2])
        let br = Int(parts[parts.count - 1])
        return AwemeURLKey(formatID: id, codec: codec, resolution: res, bitrateKbps: br)
    }
}

// MARK: - Aweme 解析器

/// 字节系（TikTok / 抖音）aweme 详情的统一解析。
///
/// 两端字段风格不同：app API 是 snake_case（play_addr / bit_rate / statistics），
/// web 页面数据是 CamelCase（playAddr / bitrateInfo / stats）。
/// 这里统一归一化后再组装 MediaInfo，供两个站点插件复用。
public enum AwemeParser {

    /// app API 的 aweme_detail → MediaInfo（时长字段为毫秒）。
    public static func makeMediaInfo(
        appStyle detail: JSON,
        webpageURL: URL,
        extractorID: String
    ) -> MediaInfo? {
        guard let awemeID = detail.anyKey("aweme_id").string else { return nil }
        return assemble(detail: detail, awemeID: awemeID, webpageURL: webpageURL,
                        extractorID: extractorID, durationInMs: true)
    }

    /// web 页面 itemStruct → MediaInfo（时长字段为秒）。
    public static func makeMediaInfo(
        webItem item: JSON,
        webpageURL: URL,
        extractorID: String
    ) -> MediaInfo? {
        guard let awemeID = item.anyKey("id").string else { return nil }
        return assemble(detail: item, awemeID: awemeID, webpageURL: webpageURL,
                        extractorID: extractorID, durationInMs: false)
    }

    // MARK: 组装

    private static func assemble(detail: JSON, awemeID: String, webpageURL: URL, extractorID: String, durationInMs: Bool) -> MediaInfo {
        let video = detail.anyKey("video") ?? JSON(nil)
        let preferPlayEndpoint = extractorID == "tiktok"   // TikTok 直连 webapp CDN 常被拒，play 端点更稳

        var formats: [MediaFormat] = []
        formats += bitrateGearFormats(video: video, preferPlayEndpoint: preferPlayEndpoint)
        formats += addrFormats(
            addr: normalizedAddr(video.anyKey("play_addr", "playAddr", "PlayAddrStruct")),
            formatID: "play_addr", note: nil, watermark: false,
            video: video, preferPlayEndpoint: preferPlayEndpoint)
        formats += addrFormats(
            addr: normalizedAddr(video.anyKey("download_addr", "downloadAddr")),
            formatID: "download_addr", note: "水印", watermark: true,
            video: video, preferPlayEndpoint: preferPlayEndpoint)

        formats = dedupe(formats)
        formats.sort { ($0.height ?? 0, $0.averageBitrate ?? 0) > ($1.height ?? 0, $1.averageBitrate ?? 0) }

        // 字幕：优先 video.subtitleInfos，其次 cla_info.caption_infos
        let subtitles = subtitleTracks(video)

        let author = detail.anyKey("author", "authorInfo") ?? JSON(nil)
        let stats = detail.anyKey("statistics", "stats") ?? JSON(nil)
        let music = detail.anyKey("music") ?? JSON(nil)

        let desc = detail.anyKey("desc").string ?? ""
        let title = desc.count > 72 ? String(desc.prefix(72)) + "…" : desc

        var extras: [String: String] = [:]
        if let like = stats.anyKey("digg_count", "diggCount").int64 { extras["likeCount"] = String(like) }
        if let comment = stats.anyKey("comment_count", "commentCount").int64 { extras["commentCount"] = String(comment) }
        if let share = stats.anyKey("share_count", "shareCount").int64 { extras["shareCount"] = String(share) }
        if let musicTitle = music.anyKey("title").string { extras["musicTitle"] = musicTitle }
        if let musicAuthor = music.anyKey("author", "authorName").string { extras["musicAuthor"] = musicAuthor }

        // 时长：app 端毫秒，web 端秒
        var duration: TimeInterval?
        if let value = video.anyKey("duration").double, value > 0 {
            duration = durationInMs ? value / 1000 : value
        }

        // 上传日期：create_time / createTime（unix 秒）→ yyyyMMdd
        var uploadDate: String?
        if let ts = detail.anyKey("create_time", "createTime").int64, ts > 0 {
            let date = Date(timeIntervalSince1970: TimeInterval(ts))
            uploadDate = Self.yyyyMMdd.string(from: date)
        }

        let thumbnail = video
            .anyKey("cover", "originCover", "dynamicCover")
            .anyKey("url_list", "UrlList").array
            .compactMap(\.string).first
            ?? video.anyKey("cover", "originCover", "dynamicCover").string

        return MediaInfo(
            extractorID: extractorID,
            id: awemeID,
            title: title.isEmpty ? "TikTok/抖音视频 \(awemeID)" : title,
            webpageURL: webpageURL,
            uploader: author.anyKey("nickname").string,
            channelID: author.anyKey("unique_id", "uniqueId", "sec_uid", "authorSecId").string,
            duration: duration,
            viewCount: stats.anyKey("play_count", "playCount").int64,
            uploadDate: uploadDate,
            videoDescription: desc.isEmpty ? nil : desc,
            thumbnailURL: thumbnail.flatMap(URL.init(string:)),
            formats: formats,
            subtitles: subtitles,
            extras: extras
        )
    }

    // MARK: 码率档（bit_rate / bitrateInfo）

    private static func bitrateGearFormats(video: JSON, preferPlayEndpoint: Bool) -> [MediaFormat] {
        let gears = video.anyKey("bit_rate", "bitrateInfo").array
        var result: [MediaFormat] = []
        for gear in gears {
            let addr = gear.anyKey("play_addr", "PlayAddr")
            guard !addr.anyKey("url_list", "UrlList").array.isEmpty else { continue }
            let key = addr.anyKey("url_key", "UrlKey").string
            let parsed = AwemeURLKey.parse(key)
            let codec = gear.anyKey("is_bytevc1", "is_h265").int == 1 ? "h265" : nil
            let formatID = gear.anyKey("gear_name", "GearName").string ?? parsed?.formatID ?? "gear"
            let fps = gear.anyKey("FPS", "BitrateFPS").int
            let bitrate = gear.anyKey("bit_rate", "Bitrate").double.map { Int($0 / 1000) } ?? parsed?.bitrateKbps

            result += makeFormats(
                addr: addr,
                formatID: formatID,
                qualityLabel: parsed?.resolution,
                videoCodec: parsed?.videoCodec ?? codec,
                fps: fps,
                bitrateKbps: bitrate,
                preferPlayEndpoint: preferPlayEndpoint)
        }
        return result
    }

    // MARK: 独立地址（play_addr / download_addr）

    private static func addrFormats(
        addr: JSON?, formatID: String, note: String?, watermark: Bool,
        video: JSON, preferPlayEndpoint: Bool
    ) -> [MediaFormat] {
        guard let addr, !addr.anyKey("url_list", "UrlList").array.isEmpty else { return [] }
        let parsed = AwemeURLKey.parse(addr.anyKey("url_key", "UrlKey").string)
        var label = parsed?.resolution.map { $0 + (watermark ? "（水印）" : "") } ?? formatID
        if let note { label = "\(label) \(note)" }
        let width = addr.anyKey("width", "Width").int ?? video.anyKey("width", "Width").int
        let height = addr.anyKey("height", "Height").int
            ?? parsed?.height
            ?? video.anyKey("height", "Height").int
        let codec = video.anyKey("is_bytevc1", "is_h265").int == 1 ? "h265" : "h264"
        return makeFormats(
            addr: addr,
            formatID: formatID,
            qualityLabel: label,
            videoCodec: parsed?.videoCodec ?? codec,
            fps: nil,
            bitrateKbps: parsed?.bitrateKbps,
            width: width,
            height: height,
            preferPlayEndpoint: preferPlayEndpoint)
    }

    /// web 端 playAddr/downloadAddr 可能是纯字符串 URL（而非 {UrlList:…} 对象），
    /// 统一包装成 addr 对象形状，方便下游处理。
    private static func normalizedAddr(_ value: JSON?) -> JSON? {
        guard let value, value.exists else { return nil }
        if let urlString = value.string {
            return JSON(["url_list": [urlString]])
        }
        return value
    }

    /// addr（url_list/UrlList + data_size）→ 一条 MediaFormat（主 URL + 备用 CDN）。
    private static func makeFormats(
        addr: JSON,
        formatID: String,
        qualityLabel: String?,
        videoCodec: String?,
        fps: Int?,
        bitrateKbps: Int?,
        width: Int? = nil,
        height: Int? = nil,
        preferPlayEndpoint: Bool
    ) -> [MediaFormat] {
        var urls = addr.anyKey("url_list", "UrlList").array.compactMap(\.string).compactMap(URL.init(string:))
        guard !urls.isEmpty else { return [] }
        if preferPlayEndpoint {
            // play 端点（/aweme/v1/play/）302 到签名 CDN，成功率最高，排最前
            urls.sort {
                let a = $0.absoluteString.contains("/aweme/v1/play")
                let b = $1.absoluteString.contains("/aweme/v1/play")
                if a != b { return a }
                return false
            }
        }
        let size = addr.anyKey("data_size", "DataSize").int64
        let w = width ?? addr.anyKey("width", "Width").int
        let h = height ?? addr.anyKey("height", "Height").int
        let backups = Array(urls.dropFirst())
        return [MediaFormat(
            formatID: formatID,
            kind: .muxed,
            url: urls[0],
            container: "mp4",
            videoCodec: videoCodec,
            audioCodec: "aac",
            width: w,
            height: h,
            fps: fps,
            averageBitrate: bitrateKbps,
            approximateSize: size,
            qualityLabel: qualityLabel,
            backupURLs: backups.isEmpty ? nil : backups
        )]
    }

    // MARK: 去重（同一内容的多 CDN 地址保留一条）

    private static func dedupe(_ formats: [MediaFormat]) -> [MediaFormat] {
        var seen = Set<String>()
        var result: [MediaFormat] = []
        for format in formats {
            let identity = format.url.absoluteString
            guard seen.insert(identity).inserted else { continue }
            result.append(format)
        }
        return result
    }

    // MARK: 字幕

    private static func subtitleTracks(_ video: JSON) -> [SubtitleTrack] {
        var tracks: [SubtitleTrack] = []

        // subtitleInfos（app/web 同构：LanguageCodeName / Url / Format）
        for info in video.anyKey("subtitleInfos", "SubtitleInfos").array {
            guard let url = info.anyKey("Url", "url").string.flatMap(URL.init(string:)) else { continue }
            let lang = info.anyKey("LanguageCodeName", "language").string ?? "en"
            let fmt = info.anyKey("Format", "format").string ?? "webvtt"
            tracks.append(SubtitleTrack(
                language: lang,
                isAutoGenerated: true,
                url: url,
                formatHint: fmt == "srt" ? "srt" : (fmt == "creator_caption" ? "json" : "vtt")))
        }

        // cla_info.caption_infos / claInfo.captionInfos
        for info in video.anyKey("cla_info", "claInfo").anyKey("caption_infos", "captionInfos").array {
            guard let url = info.anyKey("url", "Url").string.flatMap(URL.init(string:)) else { continue }
            let lang = info.anyKey("lang", "LanguageCodeName").string ?? "en"
            let fmt = info.anyKey("Format", "format").string ?? "webvtt"
            tracks.append(SubtitleTrack(
                language: lang,
                isAutoGenerated: true,
                url: url,
                formatHint: fmt == "srt" ? "srt" : (fmt == "creator_caption" ? "json" : "vtt")))
        }
        return tracks
    }

    private static let yyyyMMdd: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd"
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}

// MARK: - JSON 大小写宽容取值

extension JSON {
    /// 依次尝试多个键名（snake_case / CamelCase 兼容），返回第一个存在的。
    public func anyKey(_ keys: String...) -> JSON {
        for key in keys {
            let value = self[key]
            if value.exists { return value }
        }
        return JSON(nil)
    }
}
