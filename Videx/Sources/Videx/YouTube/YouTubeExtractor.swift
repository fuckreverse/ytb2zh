// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// YouTube 提取器：InnerTube 多客户端轮询 + JSC 挑战求解。
public struct YouTubeExtractor: Extractor {
    public static let extractorID = "youtube"
    public var id: String { Self.extractorID }
    public var displayName: String { "YouTube" }

    /// 客户端轮询顺序。nil = 按会话有无 Cookie 自动选择
    /// （InnerTubeClient.defaultClientOrder(cookies:)）。
    public let clientOrder: [InnerTubeClient.ClientConfig]?

    /// player base.js 的进程内缓存：playerPath → 挑战。
    /// 上层如需跨进程缓存可包一层自定义 JSRuntime/HTTP 层。
    static let challengeCache = ChallengeCache()

    public init(clientOrder: [InnerTubeClient.ClientConfig]? = nil) {
        self.clientOrder = clientOrder
    }

    public func canHandle(_ url: URL) -> Bool {
        YouTubeURL.videoID(from: url) != nil
    }

    public func extract(_ url: URL, context: ExtractionContext) async throws -> MediaInfo {
        guard let videoID = YouTubeURL.videoID(from: url) else {
            throw ExtractionError.malformedURL(url.absoluteString)
        }
        context.log.log(.info, "YouTube: 提取 \(videoID)")
        let innertube = InnerTubeClient(http: context.http, cookies: context.cookies)
        var order = clientOrder ?? InnerTubeClient.defaultClientOrder(cookies: context.cookies)
        var session = YouTubeSession()
        do {
            session = YouTubeSession.parse(try await innertube.watchPage(videoID: videoID), videoID: videoID)
        } catch {
            context.log.log(.debug, "watch 页面不可用，继续 player API")
        }
        // 外部收割的 visitorData 优先：PO Token 与 visitorData 绑定，两者必须配套
        if let harvested = context.youtubeVisitorData, !harvested.isEmpty {
            context.log.log(.debug, "使用外部 visitorData（POT 配套）")
            session.visitorData = harvested
        }
        var collected: [MediaFormat] = []
        var metadata = session.initialPlayer
        var metadataClient = InnerTubeClient.web
        var lastFailure: ExtractionError?
        var attempts: [String] = []
        var index = 0
        while index < order.count {
            let client = order[index]
            index += 1
            if context.cookies.hasYouTubeAuthentication && !client.supportsCookies {
                attempts.append("\(client.key)=不支持登录 Cookie，已跳过")
                continue
            }
            do {
                var poConfig = session.config
                if client.clientName == "WEB_EMBEDDED_PLAYER" {
                    if let html = try? await innertube.watchPage(videoID: videoID, embedded: true) {
                        let embedded = YouTubeSession.parse(html, videoID: videoID)
                        poConfig = embedded.config
                        session.encryptedHostFlags = embedded.encryptedHostFlags
                        session.playerPath = session.playerPath ?? embedded.playerPath
                    }
                }
                if client.requiresJSPlayer, session.playerSource == nil, let path = session.playerPath,
                   let playerURL = URL(string: path, relativeTo: URL(string: "https://www.youtube.com"))?.absoluteURL {
                    if let response = try? await context.http.fetch(.get(playerURL)), response.isOK {
                        session.playerSource = response.text
                        session.signatureTimestamp = session.signatureTimestamp
                            ?? (RegexKit.firstMatch(pattern: #"signatureTimestamp\s*[:=]\s*(\d+)"#, in: response.text)?[1]).flatMap(Int.init)
                    }
                }
                var clientContext = context
                let flags = poConfig["WEB_PLAYER_CONTEXT_CONFIGS"].dict?.values.compactMap { $0["serializedExperimentFlags"].string } ?? []
                let videoBound = flags.contains { value in
                    URLComponents(string: "https://youtube.com/?" + value)?.queryItems?.last(where: { $0.name == "html5_generate_content_po_token" })?.value == "true"
                }
                let boundKey = client.key + (videoBound ? ".gvs_video" : ".gvs_session")
                if let token = context.youtubePoTokens[boundKey] { clientContext.youtubePoTokens[client.key + ".gvs"] = token }
                let solver = StreamURLSolver(context: clientContext)
                // Reuse the webpage WEB response, as yt-dlp does (avoids an extra player request/token).
                // 例外：提供外部 GVS POT 时不能复用——页面响应属于页面自己的
                // visitorData 会话，与收割 token 的 visitorData 不匹配会 403。
                let response: JSON
                let hasExternalGVS = context.youtubePoTokens[client.key + ".gvs"] != nil
                if client.key == "web", let initial = session.initialPlayer, !hasExternalGVS {
                    response = initial
                } else {
                    response = try await innertube.player(videoID: videoID, client: client, session: session,
                        playerPoToken: context.youtubePoTokens[client.key + ".player"])
                }
                if let returnedID = response["videoDetails"]["videoId"].string, returnedID != videoID {
                    attempts.append("\(client.key)=错误视频响应，已跳过")
                    continue
                }
                let status = response["playabilityStatus"]["status"].string ?? "UNKNOWN"
                context.log.log(.debug, "client=\(client.key) status=\(status) formats=\(countFormats(response))")
                if status == "OK" {
                    let formats = try await buildFormats(response: response, solver: solver, client: client,
                        videoID: videoID, innertube: innertube, session: session)
                    collected.append(contentsOf: formats)
                    if metadata == nil || metadata?["videoDetails"]["title"].string == nil {
                        metadata = response
                        metadataClient = client
                    }
                    // Keep the response with the most caption tracks, even if another client supplied media.
                    if response["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array.count
                        > (metadata?["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array.count ?? 0) {
                        metadata = response
                        metadataClient = client
                    }
                    if formats.isEmpty {
                        lastFailure = .notExtractable(site: "youtube", reason: "\(client.key) 没有可用格式（PO Token/SABR/挑战失败）")
                    }
                    attempts.append("\(client.key)=OK（\(formats.count) 条）")
                } else {
                    let detail = playabilityDetail(response) ?? status
                    attempts.append("\(client.key)=\(status)（\(detail)）")
                    lastFailure = playabilityReason(response) ?? lastFailure
                    let lower = detail.lowercased()
                    let ageGate = lower.contains("confirm your age") || lower.contains("age-restricted")
                        || status == "AGE_CHECK_REQUIRED" || status == "AGE_VERIFICATION_REQUIRED"
                    let madeForKids = response["playabilityStatus"]["reason"].string?.lowercased().contains("made for kids") == true
                        || session.config["PLAYER_VARS"]["video_is_made_for_kids"].bool == true
                    if clientOrder == nil, (ageGate || madeForKids), !order.contains(where: { $0.key == "web_embedded" }) {
                        order.append(InnerTubeClient.webEmbedded)
                    }
                }
            } catch let error as ExtractionError {
                lastFailure = error
                attempts.append("\(client.key)=\(error.localizedDescription)")
            } catch {
                lastFailure = .network(error.localizedDescription)
                attempts.append("\(client.key)=请求失败")
            }
        }
        // Preserve distinct audio tracks/protocols, combine equivalent client URLs as backups.
        var formats: [MediaFormat] = []
        var seen: [String: Int] = [:]
        for format in collected {
            let key = [format.formatID, format.protocolType.rawValue, format.audioTrackID ?? format.language ?? "",
                       format.isDRC == true ? "drc" : "normal", format.videoCodec ?? "", format.audioCodec ?? ""].joined(separator: "|")
            if let i = seen[key] {
                if format.url != formats[i].url {
                    var backups = formats[i].backupURLs ?? []
                    if !backups.contains(format.url) { backups.append(format.url) }
                    formats[i].backupURLs = backups
                }
            } else {
                seen[key] = formats.count
                formats.append(format)
            }
        }
        guard !formats.isEmpty, let response = metadata else {
            throw (lastFailure ?? .notExtractable(site: "youtube", reason: "没有可播放格式"))
                .appendingAttempts(attempts.joined(separator: " | "))
        }
        context.log.log(.info, "YouTube: 合并 \(formats.count) 条可用格式")

        // 元数据 + 字幕
        var info = buildMediaInfo(
            videoID: videoID,
            response: response,
            formats: formats.sortedForDisplay()
        )
        info.subtitles = YouTubeMetadata.withPoToken(info.subtitles, token: context.youtubePoTokens[metadataClient.key + ".subs"], client: metadataClient.clientName)
        for index in info.subtitles.indices {
            var headers = ["User-Agent": metadataClient.userAgent]
            if let cookie = context.cookies.header(for: info.subtitles[index].url) { headers["Cookie"] = cookie }
            info.subtitles[index].requestHeaders = headers
        }
        if let data = session.initialData { YouTubeMetadata.enrich(&info, from: data) }
        return info
    }

    // MARK: - Formats

    private func countFormats(_ response: JSON) -> Int {
        response["streamingData"]["formats"].array.count
            + response["streamingData"]["adaptiveFormats"].array.count
    }

    func playabilityReason(_ response: JSON) -> ExtractionError? {
        let status = response["playabilityStatus"]
        guard let statusName = status["status"].string, statusName != "OK" else { return nil }
        let detail = playabilityDetail(response) ?? status["reason"].string ?? "unknown"
        switch statusName {
        case "LOGIN_REQUIRED":
            return .loginRequired(site: "youtube", reason: detail)
        case "UNPLAYABLE", "ERROR":
            return .notExtractable(site: "youtube", reason: detail)
        default:
            return .siteError(site: "youtube", code: 0, reason: detail)
        }
    }

    /// playabilityStatus 的人话详情（reason + subreason），供错误映射与轮询明细共用。
    func playabilityDetail(_ response: JSON) -> String? {
        let status = response["playabilityStatus"]
        let renderer = status["errorScreen"]["playerErrorMessageRenderer"]
        func text(_ value: JSON) -> String? {
            value["simpleText"].string ?? (value["runs"].array.isEmpty ? nil : value["runs"].array.compactMap { $0["text"].string }.joined())
        }
        let reason = status["reason"].string ?? text(renderer["reason"])
        let subreason = text(renderer["subreason"])
        return [reason, subreason].compactMap { $0 }.joined(separator: " — ").nilIfEmpty

    }

    /// 构建可用 formats：按需加载 player JS 挑战，再交给 solver 走四阶段流水线。
    private func buildFormats(
        response: JSON,
        solver: StreamURLSolver,
        client: InnerTubeClient.ClientConfig,
        videoID: String,
        innertube: InnerTubeClient,
        session: YouTubeSession
    ) async throws -> [MediaFormat] {
        // 需要解挑战吗？存在 signatureCipher，或该客户端本身要求执行 JS player（nsig）
        let needsDecipher = response["streamingData"]["formats"].array.contains { $0["signatureCipher"].exists }
            || response["streamingData"]["adaptiveFormats"].array.contains { $0["signatureCipher"].exists }
        var challenge: PlayerChallenge?
        if needsDecipher || client.requiresJSPlayer {
            challenge = await loadChallenge(response: response, videoID: videoID, innertube: innertube, solver: solver, session: session)
        }
        var formats = solver.formats(from: response, client: client, challenge: challenge)
        if let manifest = response["streamingData"]["hlsManifestUrl"].string,
           var components = URLComponents(string: manifest) {
            // Manifest n challenges live in the path rather than the query string.
            if let n = RegexKit.firstMatch(pattern: #"/n/([^/]+)"#, in: components.path)?[1] {
                if challenge == nil {
                    challenge = await loadChallenge(response: response, videoID: videoID, innertube: innertube, solver: solver, session: session)
                }
                guard let challenge, let solved = challenge.solveNsigBatch([n], js: solver.context.js)[n] else {
                    solver.log(.warn, "HLS n 挑战未解出，跳过清单")
                    return formats
                }
                components.path = components.path.replacingOccurrences(of: "/n/" + n, with: "/n/" + solved)
            }
            if let token = solver.context.youtubePoTokens[client.key + ".gvs"] {
                let suffix = ["/file/index.m3u8", "/playlist/index.m3u8"].first { components.path.hasSuffix($0) } ?? ""
                if !suffix.isEmpty { components.path = String(components.path.dropLast(suffix.count)) }
                components.path += "/pot/" + token + suffix
            }
            if let url = components.url {
                do {
                    let manifestResponse = try await innertube.http.fetch(.get(url, headers: ["User-Agent": client.userAgent]))
                    if manifestResponse.isOK {
                        formats += HLSParser.formats(manifestResponse.text, url: manifestResponse.finalURL ?? url)
                    }
                } catch {
                    solver.log(.warn, "HLS 清单读取失败，保留其他格式")
                }
            }
        }
        if let manifest = response["streamingData"]["dashManifestUrl"].string,
           var components = URLComponents(string: manifest) {
            var usable = true
            if let n = RegexKit.firstMatch(pattern: #"/n/([^/]+)"#, in: components.path)?[1] {
                if challenge == nil { challenge = await loadChallenge(response: response, videoID: videoID, innertube: innertube, solver: solver, session: session) }
                if let solved = challenge?.solveNsigBatch([n], js: solver.context.js)[n] {
                    components.path = components.path.replacingOccurrences(of: "/n/" + n, with: "/n/" + solved)
                } else { usable = false }
            }
            if let token = solver.context.youtubePoTokens[client.key + ".gvs"] {
                components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn:"/"))
                components.path = "/" + components.path + "/pot/" + token
            } else if client.gvsPoTokenRequired && !solver.context.includeFormatsMissingPoToken { usable = false }
            if usable, let manifestURL = components.url {
                do {
                    let result = try await innertube.http.fetch(.get(manifestURL, headers: ["User-Agent": client.userAgent]))
                    if result.isOK { formats += try DASHParser.formats(result.body, url: result.finalURL ?? manifestURL) }
                } catch { solver.log(.warn, "DASH manifest unavailable; keeping other formats") }
            }
        }
        // Keep SABR separately from HTTP/HLS; it is consumed by the native SABR state machine.
        let streaming = response["streamingData"]
        if let endpoint = streaming["serverAbrStreamingUrl"].string, var components = URLComponents(string: endpoint),
           let config = response["playerConfig"]["mediaCommonConfig"]["mediaUstreamerRequestConfig"]["videoPlaybackUstreamerConfig"].string {
            if let n = components.queryItems?.first(where: { $0.name == "n" })?.value {
                if challenge == nil { challenge = await loadChallenge(response: response, videoID: videoID, innertube: innertube, solver: solver, session: session) }
                guard let solved = challenge?.solveNsigBatch([n], js: solver.context.js)[n] else { return formats }
                components.queryItems = components.queryItems?.map { $0.name == "n" ? URLQueryItem(name: "n", value: solved) : $0 }
            }
            if let endpointURL = components.url {
                for raw in streaming["adaptiveFormats"].array {
                    guard let itag = raw["itag"].int, raw["drmFamilies"].array.isEmpty else { continue }
                    if client.gvsPoTokenRequired && solver.context.youtubePoTokens[client.key + ".gvs"] == nil && !solver.context.includeFormatsMissingPoToken { continue }
                    let kind: MediaKind = (raw["mimeType"].string ?? "").hasPrefix("audio/") ? .audioOnly : .videoOnly
                    if var format = solver.mediaFormat(from: raw, kind: kind, urlString: endpointURL.absoluteString, nMap: [:]) {
                        format.formatID += "-sabr"; format.protocolType = .sabr
                        format.sabr = SABRConfiguration(videoID: videoID, itag: itag,
                            lastModified: raw["lastModified"].string.flatMap(UInt64.init), xtags: raw["xtags"].string,
                            ustreamerConfig: config, clientID: Int(client.clientIDHeader) ?? 1,
                            clientVersion: client.clientVersion, userAgent: client.userAgent, visitorData: session.visitorData,
                            poToken: solver.context.youtubePoTokens[client.key + ".gvs"], duration: response["videoDetails"]["lengthSeconds"].double,
                            isLive: response["videoDetails"]["isLive"].bool == true)
                        formats.append(format)
                    }
                }
            }
        }
        for index in formats.indices {
            formats[index].videoID = videoID
            formats[index].requestHeaders = ["User-Agent": client.userAgent]
        }
        return formats
    }

    /// 获取并缓存挑战（decipher + nsig）。
    private func loadChallenge(
        response: JSON,
        videoID: String,
        innertube: InnerTubeClient,
        solver: StreamURLSolver,
        session: YouTubeSession
    ) async -> PlayerChallenge? {
        // player JS 路径：优先 player response 的 assets.js，否则从 watch 页扒
        var playerPath = session.playerPath ?? response["assets"]["js"].string
        if playerPath == nil {
            // HTML/JSON 里斜杠常被转义为 \/，先取值再反转义筛选
            let candidates = (try? await innertube.watchPage(videoID: videoID))
                .map { html in
                    RegexKit.allMatches(pattern: #""js(?:Url)?"\s*:\s*"([^"]+)""#, in: html)
                        .map { $0.replacingOccurrences(of: "\\/", with: "/") }
                        .filter { $0.contains("/s/player/") && $0.contains(".js") }
                } ?? []
            playerPath = candidates.first
        }
        guard var path = playerPath else { return nil }
        path = path.replacingOccurrences(of: "\\/", with: "/")
        if !path.hasPrefix("http") { path = "https://www.youtube.com" + path }

        if let cached = Self.challengeCache.get(path) { return cached }

        do {
            let jsSource: String
            if let source = session.playerSource { jsSource = source }
            else { jsSource = try await innertube.http.fetch(.get(URL(string: path)!)).text }
            guard let challenge = PlayerChallenge.extract(from: jsSource) else {
                solver.log(.warn, "base.js 挑战提取失败（站点改版？）")
                return nil
            }
            Self.challengeCache.set(path, challenge)
            solver.log(.info, "挑战提取成功 decipher=\(challenge.decipherFunctionName ?? "-") nsig=\(challenge.nsigFunctionName ?? "-")")
            return challenge
        } catch {
            solver.log(.warn, "base.js 下载失败: \(error.localizedDescription)")
            return nil
        }
    }

    // MARK: - MediaInfo

    func buildMediaInfo(videoID: String, response: JSON, formats: [MediaFormat]) -> MediaInfo {
        let micro = response["microformat"]["playerMicroformatRenderer"]
        let videoDetails = response["videoDetails"]

        var uploadDate: String?
        if let dateText = micro["publishDate"].string, dateText.count >= 10 {
            uploadDate = dateText.prefix(10).replacingOccurrences(of: "-", with: "")
        }

        let subtitles = YouTubeMetadata.subtitles(from: response)

        var extras: [String: String] = [:]
        let keywords = videoDetails["keywords"].array.compactMap(\.string)
        if !keywords.isEmpty {
            extras["keywords"] = keywords.joined(separator: ",")
        }
        if let live = videoDetails["isLiveContent"].bool { extras["isLiveContent"] = live ? "1" : "0" }
        if let playerPath = response["assets"]["js"].string { extras["playerJSPath"] = playerPath }

        return MediaInfo(
            extractorID: Self.extractorID,
            id: videoID,
            title: videoDetails["title"].string ?? micro["title"]["simpleText"].string ?? "(untitled)",
            webpageURL: YouTubeURL.watchURL(id: videoID),
            uploader: videoDetails["author"].string ?? micro["ownerChannelName"].string,
            channelID: videoDetails["channelId"].string ?? micro["externalChannelId"].string,
            duration: videoDetails["lengthSeconds"].double ?? micro["lengthSeconds"].double,
            viewCount: videoDetails["viewCount"].string.flatMap(Int64.init)
                ?? micro["viewCount"].string.flatMap(Int64.init),
            uploadDate: uploadDate,
            videoDescription: videoDetails["shortDescription"].string,
            thumbnailURL: videoDetails["thumbnail"]["thumbnails"].array.last?["url"].string.flatMap(URL.init),
            formats: formats,
            subtitles: subtitles,
            extras: extras,
            liveStatus: videoDetails["isLive"].bool == true ? "is_live" : (videoDetails["isLiveContent"].bool == true ? "was_live" : "not_live")
        )
    }
}

// MARK: - Challenge Cache

/// 线程安全的挑战缓存（按 player JS 路径）。
final class ChallengeCache: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: PlayerChallenge] = [:]

    func get(_ key: String) -> PlayerChallenge? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    func set(_ key: String, _ value: PlayerChallenge) {
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }
}

// MARK: - Stream URL Solver

/// 把 InnerTube 的单个 format JSON 变成 MediaFormat，
/// 处理 signatureCipher 解签与 n 参数节流。
struct StreamURLSolver: Sendable {
    let context: ExtractionContext

    func log(_ level: LogLevel, _ message: String) {
        context.log.log(level, message)
    }

    /// 四阶段构建全部 formats：批量 decipher → 解析基础 URL（POT/SABR 过滤）
    /// → 批量 nsig → 组装 MediaFormat。
    ///
    /// POT 过滤对齐 yt-dlp：客户端标记了 gvsPoTokenRequired 且调用方未开启
    /// includeFormatsMissingPoToken 时，其 https/dash 格式被丢弃（下载时会
    /// 403）；itag 18（360p 混合流）上游同样豁免，予以保留。
    /// 既无 url 又无 signatureCipher 的格式是 SABR-only 流（YouTube 对该
    /// 客户端强制 SABR），同样跳过——本库不支持 SABR 协议。
    func formats(
        from response: JSON,
        client: InnerTubeClient.ClientConfig,
        challenge: PlayerChallenge?
    ) -> [MediaFormat] {
        let streaming = response["streamingData"]
        var raw: [(json: JSON, kind: MediaKind)] = []
        for f in streaming["formats"].array { raw.append((f, .muxed)) }
        for f in streaming["adaptiveFormats"].array {
            let mime = f["mimeType"].string ?? ""
            raw.append((f, mime.hasPrefix("audio/") ? .audioOnly : .videoOnly))
        }

        // 阶段一：批量 decipher（一次求值解全部 s 值）
        var sigMap: [String: String] = [:]
        if let challenge {
            let sigs = raw.compactMap { item -> String? in
                guard let cipher = item.json["signatureCipher"].string else { return nil }
                return QueryString.parse(cipher)["s"]
            }
            if !sigs.isEmpty {
                sigMap = challenge.decipherBatch(sigs, js: context.js)
                if sigMap.count < Set(sigs).count {
                    log(.warn, "decipher 部分失败：\(sigMap.count)/\(Set(sigs).count)")
                }
            }
        }

        // 阶段二：解析基础 URL，收集所有 n 参数（含 POT / SABR 过滤）
        var resolved: [(json: JSON, kind: MediaKind, urlString: String)] = []
        var nInputs: [String] = []
        for (json, kind) in raw {
            let itag = json["itag"].string ?? json["itag"].int.map(String.init) ?? "?"
            if json["url"].string == nil, json["signatureCipher"].string == nil {
                // web 系客户端出现 SABR 是常态（debug），其余客户端属异常（warn）
                let level: LogLevel = (client.clientName == "WEB" || client.clientName == "WEB_EMBEDDED_PLAYER") ? .debug : .warn
                log(level, "client \(client.clientName) itag \(itag) 无 url 且无 signatureCipher"
                    + "（YouTube 疑似强制 SABR 流媒体），跳过")
                continue
            }
            if client.gvsPoTokenRequired, context.youtubePoTokens[client.key + ".gvs"] == nil,
               !context.includeFormatsMissingPoToken, itag != "18" {
                log(.debug, "client \(client.clientName) itag \(itag) 需要 GVS PO Token（未提供），跳过；"
                    + "调试可开启 includeFormatsMissingPoToken 强制返回")
                continue
            }
            if var urlString = baseURL(from: json, sigMap: sigMap) {
                if let token = context.youtubePoTokens[client.key + ".gvs"], var url = URLComponents(string: urlString) {
                    url.queryItems = (url.queryItems ?? []).filter { $0.name != "pot" } + [URLQueryItem(name: "pot", value: token)]
                    urlString = url.string ?? urlString
                }
                resolved.append((json, kind, urlString))
                if let n = nParam(of: urlString) {
                    nInputs.append(n)
                }
            }
        }

        // 阶段三：批量 nsig（一次求值解全部 n 值）
        var nMap: [String: String] = [:]
        if let challenge, !nInputs.isEmpty {
            nMap = challenge.solveNsigBatch(nInputs, js: context.js)
        }

        // 阶段四：构建 format（替换已解出的 n）
        var formats: [MediaFormat] = []
        for item in resolved {
            if let n = nParam(of: item.urlString), nMap[n] == nil {
                log(.warn, "n 挑战未解出，跳过无法验证的媒体地址")
                continue
            }
            if let format = mediaFormat(from: item.json, kind: item.kind, urlString: item.urlString, nMap: nMap) {
                formats.append(format)
            }
        }
        return formats
    }

    /// 阶段一：解析 format 的基础 URL（直接 URL，或用批量 decipher 结果
    /// 解开 signatureCipher）。返回 nil 表示该 format 不可用。
    func baseURL(from json: JSON, sigMap: [String: String]) -> String? {
        // 1. 直接 URL（ios/android 客户端常见）
        if let url = json["url"].string { return url }

        // 2. signatureCipher（web 客户端常见）
        guard let cipher = json["signatureCipher"].string else { return nil }
        let params = QueryString.parse(cipher)
        guard var base = params["url"], let s = params["s"] else { return nil }
        guard let signature = sigMap[s] else {
            log(.warn, "需要 decipher 但无解签结果，跳过 itag \(json["itag"].string ?? "?")")
            return nil
        }
        let key = params["sp"] ?? "signature"
        base += "&\(key)=\(QueryString.urlEncode(signature))"
        return base
    }

    /// 提取 URL 中的 n 参数值。
    func nParam(of urlString: String) -> String? {
        guard let components = URLComponents(string: urlString),
              let queryItems = components.queryItems else { return nil }
        return queryItems.first(where: { $0.name == "n" })?.value
    }

    /// 阶段四：用批量 nsig 结果替换 n 参数并构建 MediaFormat。
    /// n 未解出时保留原 URL（可能被节流，降级可用）。
    func mediaFormat(
        from json: JSON,
        kind: MediaKind,
        urlString: String,
        nMap: [String: String]
    ) -> MediaFormat? {
        let mime = json["mimeType"].string ?? ""
        let container = mime.split(separator: ";").first.map { $0.split(separator: "/").last.map(String.init) ?? "" }

        var urlString = urlString
        if let nParam = nParam(of: urlString), let solved = nMap[nParam], solved != nParam,
           var components = URLComponents(string: urlString), let items = components.queryItems {
            components.queryItems = items.map {
                $0.name == "n" ? URLQueryItem(name: "n", value: solved) : $0
            }
            urlString = components.string ?? urlString
        }

        guard let url = URL(string: urlString) else { return nil }

        let fps = json["fps"].int
        let quality: String?
        switch kind {
        case .audioOnly:
            quality = json["audioQuality"].string?.split(separator: ".").last.map(String.init)
        default:
            let h = json["height"].int ?? 0
            let label = json["qualityLabel"].string
            quality = label ?? (h > 0 ? "\(h)p" : nil)
        }

        return MediaFormat(
            formatID: json["itag"].string ?? json["itag"].int.map(String.init) ?? "unknown",
            kind: kind,
            url: url,
            container: container,
            videoCodec: kind == .audioOnly ? nil : codecFrom(mime: mime, audio: false),
            audioCodec: kind == .videoOnly ? nil : codecFrom(mime: mime, audio: true),
            width: json["width"].int,
            height: json["height"].int,
            fps: fps,
            averageBitrate: json["averageBitrate"].int ?? json["bitrate"].int,
            approximateSize: json["contentLength"].int64,
            protocolType: .https,
            language: json["language"].string ?? json["audioTrack"]["id"].string?.components(separatedBy: ".").first,
            qualityLabel: quality,
            audioTrackID: json["audioTrack"]["id"].string,
            isDefaultAudio: json["audioTrack"]["audioIsDefault"].bool,
            isDRC: json["isDrc"].bool
        )
    }

    private func codecFrom(mime: String, audio: Bool) -> String? {
        // "video/mp4; codecs="avc1.640028"" → avc1.640028
        guard let codecsPart = mime.split(separator: ";").first(where: { $0.contains("codecs") }) else { return nil }
        let inner = codecsPart.split(separator: "=").dropFirst().joined(separator: "=")
        let codecs = inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        return codecs.first { codec in
            let isAudio = ["mp4a", "opus", "vorbis", "ac-3", "ec-3"].contains { codec.hasPrefix($0) }
            return isAudio == audio
        }
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
