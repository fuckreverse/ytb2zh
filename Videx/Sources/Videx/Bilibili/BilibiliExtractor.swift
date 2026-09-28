// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// Bilibili 提取器：view API → playurl(DASH) → 字幕。
public struct BilibiliExtractor: Extractor {
    public static let extractorID = "bilibili"
    public var id: String { Self.extractorID }
    public var displayName: String { "Bilibili" }

    static let apiBase = "https://api.bilibili.com"

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        BilibiliURL.videoRef(from: url) != nil
    }

    public func extract(_ url: URL, context: ExtractionContext) async throws -> MediaInfo {
        context.log.log(.info, "Bilibili: 提取 \(url.absoluteString)")

        // 1. 短链重定向
        var workingURL = url
        if BilibiliURL.isShortLink(url) {
            workingURL = try await resolveShortLink(url, context: context)
        }
        guard var ref = BilibiliURL.videoRef(from: workingURL) else {
            throw ExtractionError.malformedURL(url.absoluteString)
        }

        let client = BilibiliAPIClient(http: context.http, cookies: context.cookies)

        // 2. view API（含 WBI）
        let view = try await client.view(bvid: ref.bvid, aid: ref.aid, log: context.log)
        let bvid = view["bvid"].string ?? ref.bvid
        let aid = view["aid"].int64.map(String.init) ?? ref.aid
        if bvid != nil { ref.bvid = bvid }

        guard let code = view["code"].int, code == 0 else {
            let message = view["message"].string ?? "unknown"
            if message.contains("鉴权") || message.contains("登录") {
                throw ExtractionError.loginRequired(site: Self.extractorID, reason: message)
            }
            throw ExtractionError.siteError(site: Self.extractorID, code: view["code"].int ?? -1, reason: message)
        }

        // 3. 选分页 cid
        let pages = view["data"]["pages"].array
        let pageIndex = max(0, min(ref.page - 1, max(0, pages.count - 1)))
        let page = pages[pageIndex]
        guard let cid = page["cid"].int64 else {
            throw ExtractionError.parse("view 响应缺少 cid")
        }

        // 4. playurl（DASH 优先）
        let playurl = try await client.playurl(bvid: bvid, aid: aid, cid: String(cid), log: context.log)
        guard playurl["code"].int == 0 else {
            let message = playurl["message"].string ?? "unknown"
            let code = playurl["code"].int ?? -1
            if code == -101 {
                throw ExtractionError.loginRequired(site: Self.extractorID, reason: message)
            }
            throw ExtractionError.siteError(site: Self.extractorID, code: code, reason: message)
        }

        let formats = try parseFormats(playurl["data"])
        context.log.log(.info, "Bilibili: \(formats.count) 条流")

        // 5. 字幕（player/v2，失败不阻塞）
        let subtitles = await loadSubtitles(client: client, bvid: bvid, aid: aid, cid: String(cid), log: context.log)

        return buildMediaInfo(
            view: view["data"],
            page: page,
            pageIndex: ref.page,
            formats: formats.sortedForDisplay(),
            subtitles: subtitles
        )
    }

    // MARK: - 短链

    private func resolveShortLink(_ url: URL, context: ExtractionContext) async throws -> URL {
        // URLSession 默认跟随重定向，finalURL 即落地页。
        let response = try await context.http.fetch(.get(url))
        guard response.isOK else {
            throw ExtractionError.network("短链解析 HTTP \(response.status)")
        }
        return response.finalURL ?? url
    }

    // MARK: - Formats

    func parseFormats(_ data: JSON) throws -> [MediaFormat] {
        var formats: [MediaFormat] = []

        // DASH
        let dash = data["dash"]
        if dash.exists {
            for video in dash["video"].array {
                guard let urlString = video["baseUrl"].string ?? video["base_url"].string,
                      let url = URL(string: urlString) else { continue }
                let qualityID = video["id"].int ?? 0
                let backups = (video["backupUrl"].array + video["backup_url"].array)
                    .compactMap { $0.string }.compactMap(URL.init)
                formats.append(MediaFormat(
                    formatID: "v-\(qualityID)",
                    kind: .videoOnly,
                    url: url,
                    container: containerFromMime(video["mimeType"].string ?? video["mimetype"].string) ?? "m4s",
                    videoCodec: video["codecs"].string,
                    width: video["width"].int,
                    height: video["height"].int,
                    fps: video["frameRate"].string.flatMap { Double($0) }.map { Int($0.rounded()) },
                    averageBitrate: video["bandwidth"].int,
                    protocolType: .https,
                    qualityLabel: BilibiliQuality.label(for: qualityID),
                    backupURLs: backups.isEmpty ? nil : backups
                ))
            }
            for audio in dash["audio"].array {
                guard let urlString = audio["baseUrl"].string ?? audio["base_url"].string,
                      let url = URL(string: urlString) else { continue }
                let audioID = audio["id"].int ?? 0
                let backups = (audio["backupUrl"].array + audio["backup_url"].array)
                    .compactMap { $0.string }.compactMap(URL.init)
                formats.append(MediaFormat(
                    formatID: "a-\(audioID)",
                    kind: .audioOnly,
                    url: url,
                    container: containerFromMime(audio["mimeType"].string ?? audio["mimetype"].string) ?? "m4s",
                    audioCodec: audio["codecs"].string,
                    averageBitrate: audio["bandwidth"].int,
                    protocolType: .https,
                    language: audio["lang"].string,
                    qualityLabel: BilibiliQuality.audioLabel(for: audioID),
                    backupURLs: backups.isEmpty ? nil : backups
                ))
            }
            // 杜比全景声 / Hi-Res 独立字段
            for (key, label) in [("dolby", "Dolby Atmos"), ("flac", "Hi-Res 无损")] {
                let node = dash[key]
                guard node.exists else { continue }
                let streams = key == "dolby" ? node["audio"].array : [node["audio"]]
                for audio in streams {
                    guard let urlString = audio["baseUrl"].string ?? audio["base_url"].string,
                          let url = URL(string: urlString) else { continue }
                    formats.append(MediaFormat(
                        formatID: "a-\(key)",
                        kind: .audioOnly,
                        url: url,
                        container: containerFromMime(audio["mimeType"].string) ?? "m4s",
                        audioCodec: audio["codecs"].string,
                        averageBitrate: audio["bandwidth"].int,
                        protocolType: .https,
                        qualityLabel: label
                    ))
                }
            }
        }

        // durl 旧格式（mp4/m4s 直链，通常 480P 以下）
        for segment in data["durl"].array {
            guard let urlString = segment["url"].string, let url = URL(string: urlString) else { continue }
            let size = segment["size"].int64
            formats.append(MediaFormat(
                formatID: "durl-\(formats.count)",
                kind: .muxed,
                url: url,
                container: url.pathExtension.isEmpty ? "flv" : url.pathExtension,
                approximateSize: size,
                protocolType: .https,
                qualityLabel: data["quality"].int.map { BilibiliQuality.label(for: $0) }
            ))
        }

        guard !formats.isEmpty else {
            throw ExtractionError.parse("playurl 无可用流")
        }
        return formats
    }

    private func containerFromMime(_ mime: String?) -> String? {
        guard let mime else { return nil }
        let sub = mime.split(separator: "/").last.map(String.init) ?? ""
        return sub == "mp4" ? "mp4" : (sub.isEmpty ? nil : sub)
    }

    // MARK: - 字幕

    private func loadSubtitles(
        client: BilibiliAPIClient,
        bvid: String?,
        aid: String?,
        cid: String,
        log: LogSink
    ) async -> [SubtitleTrack] {
        do {
            let player = try await client.playerV2(bvid: bvid, aid: aid, cid: cid)
            let tracks = player["data"]["subtitle"]["subtitles"].array.compactMap { sub -> SubtitleTrack? in
                guard var urlString = sub["subtitle_url"].string else { return nil }
                if urlString.hasPrefix("//") { urlString = "https:" + urlString }
                guard let url = URL(string: urlString) else { return nil }
                return SubtitleTrack(
                    language: sub["lan"].string ?? "und",
                    name: sub["lan_doc"].string,
                    isAutoGenerated: false,
                    url: url,
                    formatHint: "bilibili-json"
                )
            }
            return tracks
        } catch {
            log.log(.debug, "字幕获取失败（忽略）: \(error.localizedDescription)")
            return []
        }
    }

    // MARK: - MediaInfo

    func buildMediaInfo(
        view: JSON,
        page: JSON,
        pageIndex: Int,
        formats: [MediaFormat],
        subtitles: [SubtitleTrack]
    ) -> MediaInfo {
        let bvid = view["bvid"].string ?? ""
        var extras: [String: String] = [:]
        if view["pages"].array.count > 1 {
            extras["pages"] = String(view["pages"].array.count)
            extras["page"] = String(pageIndex)
        }
        if let tname = view["tname"].string { extras["category"] = tname }
        if let coins = view["stat"]["coin"].int64.map(String.init) { extras["coins"] = coins }
        if let favorites = view["stat"]["favorite"].int64.map(String.init) { extras["favorites"] = favorites }

        var title = view["title"].string ?? "(untitled)"
        if view["pages"].array.count > 1, let pageTitle = page["part"].string {
            title += " - P\(pageIndex) \(pageTitle)"
        }

        var thumbnail = view["pic"].string.flatMap(URL.init)
        if thumbnail?.scheme == nil { thumbnail = URL(string: "https:" + (view["pic"].string ?? "")) }

        return MediaInfo(
            extractorID: Self.extractorID,
            id: bvid.isEmpty ? (view["aid"].int64.map(String.init) ?? "unknown") : bvid,
            title: title,
            webpageURL: URL(string: "https://www.bilibili.com/video/\(bvid)") ?? URL(fileURLWithPath: "/") ,
            uploader: view["owner"]["name"].string,
            channelID: view["owner"]["mid"].int64.map(String.init),
            duration: page["duration"].double ?? view["duration"].double,
            viewCount: view["stat"]["view"].int64,
            uploadDate: view["pubdate"].int64.map { ts -> String in
                let date = Date(timeIntervalSince1970: TimeInterval(ts))
                return Self.formatter.string(from: date)
            },
            videoDescription: view["desc"].string,
            thumbnailURL: thumbnail,
            formats: formats,
            subtitles: subtitles,
            extras: extras
        )
    }

    static let formatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd"
        f.timeZone = TimeZone(identifier: "Asia/Shanghai")
        return f
    }()
}

// MARK: - API Client

/// B 站 Web API 封装：统一请求头、buvid3 兜底、WBI 签名。
struct BilibiliAPIClient: Sendable {
    let http: HTTPFetching
    let cookies: CookieJar

    func baseHeaders() -> [String: String] {
        var headers = [
            "User-Agent": "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
            "Referer": "https://www.bilibili.com/",
            "Origin": "https://www.bilibili.com",
            "Accept": "application/json, text/plain, */*",
        ]
        var cookieParts: [String] = []
        if let jar = cookies.header(for: URL(string: "https://www.bilibili.com")!) {
            cookieParts.append(jar)
        }
        // 风控兜底：无 buvid3 时生成一个（不回写调用方的 CookieJar）
        if cookies.value(named: "buvid3", forDomain: "bilibili.com") == nil {
            cookieParts.append("buvid3=\(Self.randomBuvid3())")
            cookieParts.append("b_nut=\(String(Int(Date().timeIntervalSince1970)))")
        }
        if !cookieParts.isEmpty {
            headers["Cookie"] = cookieParts.joined(separator: "; ")
        }
        return headers
    }

    static func randomBuvid3() -> String {
        let uuid = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        return String(uuid.prefix(32)) + "infoc"
    }

    /// WBI mixin key（带缓存，nav key 有效期约一天）。
    func mixinKey(log: LogSink) async throws -> String {
        let url = URL(string: "\(BilibiliExtractor.apiBase)/x/web-interface/nav")!
        let nav = try await http.getJSON(url, headers: baseHeaders())
        guard let imgURL = nav["data"]["wbi_img"]["img_url"].string,
              let subURL = nav["data"]["wbi_img"]["sub_url"].string,
              let imgKey = WBISigner.keyFromImageURL(imgURL),
              let subKey = WBISigner.keyFromImageURL(subURL)
        else {
            throw ExtractionError.parse("nav 响应缺少 wbi_img keys")
        }
        let key = WBISigner.mixinKey(imgKey: imgKey, subKey: subKey)
        log.log(.debug, "WBI mixin key=\(key.prefix(8))…")
        return key
    }

    func signedURL(path: String, params: [String: String], log: LogSink) async throws -> URL {
        let key = try await mixinKey(log: log)
        let signed = WBISigner.signedParams(params, mixinKey: key, timestamp: Int(Date().timeIntervalSince1970))
        var components = URLComponents(string: "\(BilibiliExtractor.apiBase)\(path)")!
        components.queryItems = signed.sorted { $0.key < $1.key }
            .map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let url = components.url else {
            throw ExtractionError.parse("URL 构造失败: \(path)")
        }
        return url
    }

    // MARK: Endpoints

    func view(bvid: String?, aid: String?, log: LogSink) async throws -> JSON {
        var params: [String: String] = [:]
        if let bvid { params["bvid"] = bvid }
        else if let aid { params["aid"] = aid }
        else { throw ExtractionError.malformedURL("无 bvid/aid") }
        let url = try await signedURL(path: "/x/web-interface/view", params: params, log: log)
        return try await http.getJSON(url, headers: baseHeaders())
    }

    func playurl(bvid: String?, aid: String?, cid: String, log: LogSink) async throws -> JSON {
        var params: [String: String] = [
            "cid": cid,
            "fnval": "4048",  // DASH + 4K + HDR + Dolby（yt-dlp 同款组合）
            "fnver": "0",
            "fourk": "1",
        ]
        if let bvid { params["bvid"] = bvid }
        if let aid { params["aid"] = aid }
        // 未登录（无 SESSDATA）时必须带 try_look=1，否则 DASH 请求 -400
        if cookies.value(named: "SESSDATA", forDomain: "bilibili.com") == nil {
            params["try_look"] = "1"
        }
        // 注意走 /x/player/wbi/ 路径（非 wbi 路径对 DASH 参数直接 -400）
        let url = try await signedURL(path: "/x/player/wbi/playurl", params: params, log: log)
        return try await http.getJSON(url, headers: baseHeaders())
    }

    func playerV2(bvid: String?, aid: String?, cid: String) async throws -> JSON {
        var params: [String: String] = ["cid": cid]
        if let bvid { params["bvid"] = bvid }
        if let aid { params["aid"] = aid }
        let url = try await signedURL(path: "/x/player/wbi/v2", params: params, log: NullLogSink())
        return try await http.getJSON(url, headers: baseHeaders())
    }
}
