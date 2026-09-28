import Foundation

/// YouTube 提取器：InnerTube 多客户端轮询 + JSC 挑战求解。
public struct YouTubeExtractor: Extractor {
    public static let extractorID = "youtube"
    public var id: String { Self.extractorID }
    public var displayName: String { "YouTube" }

    /// 客户端轮询顺序（可在 init 覆盖，便于测试）。
    public let clientOrder: [InnerTubeClient.ClientConfig]

    /// player base.js 的进程内缓存：playerPath → 挑战。
    /// 上层如需跨进程缓存可包一层自定义 JSRuntime/HTTP 层。
    static let challengeCache = ChallengeCache()

    public init(clientOrder: [InnerTubeClient.ClientConfig]? = nil) {
        self.clientOrder = clientOrder ?? InnerTubeClient.defaultClientOrder
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

        // 1. 多客户端轮询，取第一个可播放且有格式的响应
        var chosen: (client: InnerTubeClient.ClientConfig, response: JSON)?
        var lastFailure: ExtractionError?

        for client in clientOrder {
            do {
                let response = try await innertube.player(videoID: videoID, client: client)
                let status = response["playabilityStatus"]["status"].string ?? "UNKNOWN"
                context.log.log(.debug, "client=\(client.clientName) status=\(status) formats=\(countFormats(response))")

                if status == "OK", hasFormats(response) {
                    chosen = (client, response)
                    break
                }
                if let reason = playabilityReason(response) {
                    lastFailure = reason
                }
            } catch let error as ExtractionError {
                lastFailure = error
                context.log.log(.debug, "client=\(client.clientName) 失败: \(error.localizedDescription)")
            }
        }

        guard let (client, response) = chosen else {
            if let failure = lastFailure { throw failure }
            throw ExtractionError.notExtractable(site: "youtube", reason: "所有客户端均未返回可播放格式")
        }
        context.log.log(.info, "YouTube: 命中客户端 \(client.clientName)")

        // 2. 解挑战（signatureCipher / n 节流）
        let solver = StreamURLSolver(context: context)
        let formats = try await buildFormats(response: response, solver: solver, client: client, videoID: videoID, innertube: innertube)

        // 3. 元数据 + 字幕
        let info = buildMediaInfo(
            videoID: videoID,
            response: response,
            formats: formats.sortedForDisplay()
        )
        return info
    }

    // MARK: - Formats

    private func countFormats(_ response: JSON) -> Int {
        response["streamingData"]["formats"].array.count
            + response["streamingData"]["adaptiveFormats"].array.count
    }

    private func hasFormats(_ response: JSON) -> Bool {
        countFormats(response) > 0
    }

    func playabilityReason(_ response: JSON) -> ExtractionError? {
        let status = response["playabilityStatus"]
        guard let statusName = status["status"].string, statusName != "OK" else { return nil }
        let reason = status["reason"].string ?? "unknown"
        let subReason = status["errorScreen"]["playerErrorMessageRenderer"]["subreason"]["runs"][0]["text"].string
        let detail = subReason.map { "\(reason) — \($0)" } ?? reason
        switch statusName {
        case "LOGIN_REQUIRED":
            return .loginRequired(site: "youtube", reason: detail)
        case "UNPLAYABLE", "ERROR":
            return .notExtractable(site: "youtube", reason: detail)
        default:
            return .siteError(site: "youtube", code: 0, reason: detail)
        }
    }

    private func buildFormats(
        response: JSON,
        solver: StreamURLSolver,
        client: InnerTubeClient.ClientConfig,
        videoID: String,
        innertube: InnerTubeClient
    ) async throws -> [MediaFormat] {
        let streaming = response["streamingData"]
        var raw: [(json: JSON, kind: MediaKind)] = []
        for f in streaming["formats"].array { raw.append((f, .muxed)) }
        for f in streaming["adaptiveFormats"].array {
            let mime = f["mimeType"].string ?? ""
            raw.append((f, mime.hasPrefix("audio/") ? .audioOnly : .videoOnly))
        }

        // 需要解挑战吗？
        let needsDecipher = raw.contains { $0.json["signatureCipher"].exists }
        var challenge: PlayerChallenge?
        if needsDecipher || client.clientName == "WEB" {
            challenge = await loadChallenge(response: response, videoID: videoID, innertube: innertube, solver: solver)
        }

        // 阶段一：批量 decipher（一次求值解全部 s 值）
        var sigMap: [String: String] = [:]
        if let challenge {
            let sigs = raw.compactMap { item -> String? in
                guard let cipher = item.json["signatureCipher"].string else { return nil }
                return QueryString.parse(cipher)["s"]
            }
            if !sigs.isEmpty {
                sigMap = challenge.decipherBatch(sigs, js: solver.context.js)
                if sigMap.count < Set(sigs).count {
                    solver.log(.warn, "decipher 部分失败：\(sigMap.count)/\(Set(sigs).count)")
                }
            }
        }

        // 阶段二：解析基础 URL，收集所有 n 参数
        var resolved: [(json: JSON, kind: MediaKind, urlString: String)] = []
        var nInputs: [String] = []
        for (json, kind) in raw {
            if let urlString = solver.baseURL(from: json, sigMap: sigMap) {
                resolved.append((json, kind, urlString))
                if let n = solver.nParam(of: urlString) {
                    nInputs.append(n)
                }
            }
        }

        // 阶段三：批量 nsig（一次求值解全部 n 值）
        var nMap: [String: String] = [:]
        if let challenge, !nInputs.isEmpty {
            nMap = challenge.solveNsigBatch(nInputs, js: solver.context.js)
        }

        // 阶段四：构建 format（替换已解出的 n）
        var formats: [MediaFormat] = []
        for item in resolved {
            if let format = solver.mediaFormat(from: item.json, kind: item.kind, urlString: item.urlString, nMap: nMap) {
                formats.append(format)
            }
        }
        return formats
    }

    /// 获取并缓存挑战（decipher + nsig）。
    private func loadChallenge(
        response: JSON,
        videoID: String,
        innertube: InnerTubeClient,
        solver: StreamURLSolver
    ) async -> PlayerChallenge? {
        // player JS 路径：优先 player response 的 assets.js，否则从 watch 页扒
        var playerPath = response["assets"]["js"].string
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
            let jsSource = try await innertube.http.fetch(.get(URL(string: path)!)).text
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

        let subtitles = response["captions"]["playerCaptionsTracklistRenderer"]["captionTracks"].array
            .compactMap { track -> SubtitleTrack? in
                guard let base = track["baseUrl"].string else { return nil }
                let urlString = base + "&fmt=json3"
                guard let trackURL = URL(string: urlString) else { return nil }
                let kind = track["kind"].string
                return SubtitleTrack(
                    language: track["languageCode"].string ?? "und",
                    name: track["name"]["runs"][0]["text"].string,
                    isAutoGenerated: kind == "asr",
                    url: trackURL,
                    formatHint: "youtube-json3"
                )
            }

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
            extras: extras
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
            videoCodec: kind == .audioOnly ? nil : codecFrom(mime: mime),
            audioCodec: kind == .videoOnly ? nil : codecFrom(mime: mime),
            width: json["width"].int,
            height: json["height"].int,
            fps: fps,
            averageBitrate: json["averageBitrate"].int ?? json["bitrate"].int,
            approximateSize: json["contentLength"].int64,
            protocolType: .https,
            language: json["language"].string,
            qualityLabel: quality
        )
    }

    private func codecFrom(mime: String) -> String? {
        // "video/mp4; codecs="avc1.640028"" → avc1.640028
        guard let codecsPart = mime.split(separator: ";").first(where: { $0.contains("codecs") }) else { return nil }
        let inner = codecsPart.split(separator: "=").dropFirst().joined(separator: "=")
        return inner.trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
    }
}
