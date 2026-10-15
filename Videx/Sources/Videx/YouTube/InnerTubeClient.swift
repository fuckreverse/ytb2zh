// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// InnerTube（YouTube 内部 API）客户端。
///
/// 只封装 player 端点。多客户端轮询策略由 Extractor 决定——不同客户端
/// 的风控状态此消彼长，这里保持数据纯净。
public struct InnerTubeClient: Sendable {
    public struct ClientConfig: Sendable {
        let clientName: String        // InnerTube clientName
        let clientVersion: String
        let userAgent: String
        let clientIDHeader: String    // X-YouTube-Client-Name
        let extraClientFields: [String: JSON]
        /// context.thirdParty（embedded 类客户端必需）。
        var thirdParty: [String: JSON]? = nil
        /// 是否需要执行 player JS（解 nsig 等）。对齐 yt-dlp REQUIRE_JS_PLAYER：
        /// web / tv 系为 true；visionos / ios / android 等直链客户端为 false。
        let requiresJSPlayer: Bool
        /// 该客户端的 https/dash 格式是否强制要求 GVS PO Token（无 Token 时
        /// 下载会 403）。对齐 yt-dlp 2026.10 的 GvsPoTokenPolicy 标注；
        /// tv_samsung / visionos / web_embedded / tv_downgraded 等免 POT。
        /// 注意：itag 18（360p 混合流）上游同样豁免 POT。
        let gvsPoTokenRequired: Bool

        public var supportsCookies: Bool {
            ["WEB", "WEB_EMBEDDED_PLAYER", "MWEB", "TVHTML5"].contains(clientName)
        }

        public var key: String {
            switch clientName {
            case "TVHTML5": return extraClientFields["deviceMake"]?.string == "Samsung" ? "tv_samsung" : "tv_downgraded"
            case "WEB": return userAgent.contains("AppleWebKit/605") ? "web_safari" : "web"
            case "WEB_EMBEDDED_PLAYER": return "web_embedded"
            case "TVHTML5_SIMPLY": return "tv_simply"
            case "ANDROID_VR": return "android_vr"
            default: return clientName.lowercased()
            }
        }

        public func contextJSON() -> [String: Any] {
            var client: [String: Any] = [
                "clientName": clientName,
                "clientVersion": clientVersion,
                "userAgent": userAgent,
                "hl": "en",
                "gl": "US",
                "timeZone": "UTC",
                "utcOffsetMinutes": 0,
            ]
            for (key, value) in extraClientFields {
                if let raw = value.raw { client[key] = raw }
            }
            var context: [String: Any] = [
                "client": client,
                "request": ["internalExperimentFlags": [String](), "useSsl": true],
                "user": ["lockedSafetyMode": false],
            ]
            if let thirdParty {
                context["thirdParty"] = thirdParty.mapValues { $0.raw as Any }
            }
            return context
        }
    }

    // 客户端常量同步自 yt-dlp master（2026.10，_base.py INNERTUBE_CLIENTS）。
    // 版本随上游风控变动，需定期同步；gvsPoTokenRequired 同步上游
    // GvsPoTokenPolicy.required 标注（本库无 POT provider，一律按"无 Token"处理）。

    public static let ios = ClientConfig(
        clientName: "IOS",
        clientVersion: "21.26.4",
        userAgent: "com.google.ios.youtube/21.26.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        clientIDHeader: "5",
        extraClientFields: [
            "deviceMake": JSON("Apple"),
            "deviceModel": JSON("iPhone16,2"),
            "osName": JSON("iPhone"),
            "osVersion": JSON("18.3.2.22D82"),
        ],
        requiresJSPlayer: false,
        gvsPoTokenRequired: true
    )

    public static let android = ClientConfig(
        clientName: "ANDROID",
        clientVersion: "21.26.364",
        userAgent: "com.google.android.youtube/21.26.364 (Linux; U; Android 11) gzip",
        clientIDHeader: "3",
        extraClientFields: [
            "androidSdkVersion": JSON(30),
            "osName": JSON("Android"),
            "osVersion": JSON("11"),
        ],
        requiresJSPlayer: false,
        gvsPoTokenRequired: true
    )

    /// VR 客户端：已基本废弃——上游 2026.08.17 起全格式 403（含 itag 18），
    /// 2026.08 起被移出默认客户端（yt-dlp#17461/#17348）。保留仅供手动指定。
    public static let androidVr = ClientConfig(
        clientName: "ANDROID_VR",
        clientVersion: "1.65.10",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.65.10 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        clientIDHeader: "28",
        extraClientFields: [
            "deviceMake": JSON("Oculus"),
            "deviceModel": JSON("Quest 3"),
            "androidSdkVersion": JSON(32),
            "osName": JSON("Android"),
            "osVersion": JSON("12L"),
        ],
        requiresJSPlayer: false,
        gvsPoTokenRequired: true
    )

    /// TV 嵌入式（tv_simply）：TVHTML5_SIMPLY 变体，需 GVS POT。
    public static let tvSimply = ClientConfig(
        clientName: "TVHTML5_SIMPLY",
        clientVersion: "1.0",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        clientIDHeader: "85",
        extraClientFields: [:],
        thirdParty: ["embedUrl": JSON("https://www.youtube.com/")],
        requiresJSPlayer: true,
        gvsPoTokenRequired: true
    )

    /// 三星 TV 客户端（yt-dlp#17723，2026.10 起为默认客户端 #17805）：
    /// 免 POT 的完整 DASH 通道，替代已烂掉的 android_vr。
    public static let tvSamsung = ClientConfig(
        clientName: "TVHTML5",
        clientVersion: "5.20260707",
        userAgent: "Mozilla/5.0 (SMART-TV; Linux; Tizen 2.4.0) AppleWebKit/538.1 (KHTML, like Gecko) Version/2.4.0 TV Safari/538.1",
        clientIDHeader: "7",
        extraClientFields: [
            "deviceMake": JSON("Samsung"),
            "deviceModel": JSON("UKS9800"),
            "osName": JSON("Tizen"),
            "osVersion": JSON("2.4.0"),
        ],
        requiresJSPlayer: true,
        gvsPoTokenRequired: false
    )

    /// visionOS 客户端（yt-dlp#17184）：免 POT 且 REQUIRE_JS_PLAYER=false，
    /// 上游 _DEFAULT_JSLESS_CLIENTS 唯一成员——无 JS 挑战的纯净直链通道。
    public static let visionos = ClientConfig(
        clientName: "VISIONOS",
        clientVersion: "1.02",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 15_7_3) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.0 Safari/605.1.15",
        clientIDHeader: "101",
        extraClientFields: [
            "deviceMake": JSON("Apple"),
            "deviceModel": JSON("RealityDevice17,1"),
            "osName": JSON("visionOS"),
            "osVersion": JSON("26.5.23O471"),
        ],
        requiresJSPlayer: false,
        gvsPoTokenRequired: false
    )

    /// TV 降级客户端（tv_downgraded）：TVHTML5 + Cobalt UA，免 POT。
    public static let tvDowngraded = ClientConfig(
        clientName: "TVHTML5",
        clientVersion: "5.20260707",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        clientIDHeader: "7",
        extraClientFields: [:],
        requiresJSPlayer: true,
        gvsPoTokenRequired: false
    )

    /// WEB 嵌入式播放器（yt-dlp#16177/#17462/#17684）：Safari UA，
    /// 免 POT；有 Cookie 时上游把它排在默认首位（_DEFAULT_AUTHED_CLIENTS）。
    public static let webEmbedded = ClientConfig(
        clientName: "WEB_EMBEDDED_PLAYER",
        clientVersion: "2.20260708.00.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        clientIDHeader: "56",
        extraClientFields: [:],
        thirdParty: ["embedUrl": JSON("https://www.youtube.com/")],
        requiresJSPlayer: true,
        gvsPoTokenRequired: false
    )

    public static let web = ClientConfig(
        clientName: "WEB",
        clientVersion: "2.20260708.00.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/151.0.0.0 Safari/537.36",
        clientIDHeader: "1",
        extraClientFields: [:],
        requiresJSPlayer: true,
        gvsPoTokenRequired: true
    )

    /// Safari 指纹的 WEB 客户端。上游注释：返回预合并的 HLS 格式
    /// （144p-1080p），但 2026.07 起仅登录/受信会话才有。
    public static let webSafari = ClientConfig(
        clientName: "WEB",
        clientVersion: "2.20260708.00.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        clientIDHeader: "1",
        extraClientFields: [:],
        requiresJSPlayer: true,
        gvsPoTokenRequired: true
    )

    /// 移动 web 客户端：iPad Safari 指纹，需 GVS POT，有 ultralow 格式。
    public static let mweb = ClientConfig(
        clientName: "MWEB",
        clientVersion: "2.20260708.05.00",
        userAgent: "Mozilla/5.0 (iPad; CPU OS 16_7_10 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/16.6 Mobile/15E148 Safari/604.1,gzip(gfe)",
        clientIDHeader: "2",
        extraClientFields: [:],
        requiresJSPlayer: true,
        gvsPoTokenRequired: true
    )

    /// 默认轮询顺序（无 Cookie），对齐 yt-dlp _DEFAULT_CLIENTS：
    /// tv_samsung / visionos 免 POT 且免 JS 挑战，web 作为通用回退
    /// （其 https/dash 格式需 POT，无 provider 时通常只剩 itag 18）。
    public static let defaultClientOrder: [ClientConfig] = [tvSamsung, visionos, web]

    /// 携带有效 YouTube 登录 Cookie 时的默认顺序，对齐 yt-dlp _DEFAULT_AUTHED_CLIENTS：
    /// web_embedded 提前（登录会话下 HLS/格式更全）。
    public static let authedClientOrder: [ClientConfig] = [webEmbedded, tvSamsung, web]

    /// 按会话有无 Cookie 选择默认轮询顺序。
    public static func defaultClientOrder(cookies: CookieJar) -> [ClientConfig] {
        cookies.hasYouTubeAuthentication
            ? authedClientOrder
            : defaultClientOrder
    }

    public let http: HTTPFetching
    public let cookies: CookieJar

    public init(http: HTTPFetching, cookies: CookieJar) {
        self.http = http
        self.cookies = cookies
    }

    /// 请求 player 响应。返回的 JSON 原样透传，解析交给上层。
    func player(videoID: String, client: ClientConfig, session: YouTubeSession = YouTubeSession(),
                playerPoToken: String? = nil) async throws -> JSON {
        var url = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]

        var clientContext = client.contextJSON()
        if var fields = clientContext["client"] as? [String: Any] {
            if let visitor = session.visitorData { fields["visitorData"] = visitor }
            if client.clientName == "WEB", client.userAgent == Self.web.userAgent,
               let version = session.config["INNERTUBE_CONTEXT"]["client"]["clientVersion"].string {
                fields["clientVersion"] = version
            }
            clientContext["client"] = fields
        }
        var playback: [String: Any] = ["html5Preference": "HTML5_PREF_WANTS"]
        if client.requiresJSPlayer, let sts = session.signatureTimestamp { playback["signatureTimestamp"] = sts }
        if client.clientName == "WEB_EMBEDDED_PLAYER", let flags = session.encryptedHostFlags {
            playback["encryptedHostFlags"] = flags
        }
        var body: [String: Any] = [
            "context": clientContext, "videoId": videoID,
            "playbackContext": ["contentPlaybackContext": playback],
            "contentCheckOk": true, "racyCheckOk": true,
        ]
        if let playerPoToken { body["serviceIntegrityDimensions"] = ["poToken": playerPoToken] }

        var headers = [
            "User-Agent": client.userAgent,
            "X-YouTube-Client-Name": client.clientIDHeader,
            "X-YouTube-Client-Version": client.clientVersion,
            "Origin": "https://www.youtube.com",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        headers.merge(session.headers(cookies: cookies)) { _, new in new }
        if let fields = clientContext["client"] as? [String: Any], let version = fields["clientVersion"] as? String {
            headers["X-YouTube-Client-Version"] = version
        }
        // 部分地区（尤其 EU）会撞 consent 墙，预置通过性 Cookie。
        var cookiePairs = ["CONSENT=YES+cb.20210328-17-p0.en+FX+419", "SOCS=CAI"]
        if let jarCookie = cookies.header(for: URL(string: "https://www.youtube.com")!) {
            cookiePairs.append(jarCookie)
        }
        headers["Cookie"] = cookiePairs.joined(separator: "; ")

        let request = try HTTPRequest.post(url.url!, json: body, headers: headers)
        let response = try await http.fetch(request)
        guard response.isOK, let json = response.json else {
            throw ExtractionError.network("InnerTube player HTTP \(response.status) (\(client.clientName))")
        }
        return json
    }

    /// 抓取 watch 页面（主要用于解析 player JS 路径）。
    func watchPage(videoID: String, embedded: Bool = false) async throws -> String {
        var components = URLComponents(string: embedded ? "https://www.youtube.com/embed/\(videoID)?html5=1" : "https://www.youtube.com/watch")!
        components.queryItems = (components.queryItems ?? []) + [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "hl", value: "en"),
        ]
        var request = HTTPRequest.get(components.url!, headers: [
            "User-Agent": Self.web.userAgent,
            "Accept-Language": "en-US,en;q=0.9",
        ])
        request.headers["Cookie"] = ["CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI",
                                     cookies.header(for: components.url!)].compactMap { $0 }.joined(separator: "; ")
        let response = try await http.fetch(request)
        guard response.isOK else {
            throw ExtractionError.network("watch 页 HTTP \(response.status)")
        }
        return response.text
    }

    // MARK: - 搜索/浏览（InnerTube search / browse / next）

    /// WEB 客户端 InnerTube API key（社区通用常量，与 yt-dlp / Invidious 同源；
    /// 若上游轮换可从 base.js 提取新值替换）。
    public static let innertubeAPIKey = "AIzaSyAO_FJ2SlqU8Q4STEHLGCilw_Y9_11qcW8"

    /// InnerTube 通用调用（search/browse/next 共用路径）。
    func innertubeCall(endpoint: String, body: [String: Any],
                               client: ClientConfig) async throws -> JSON {
        var url = URLComponents(string: "https://www.youtube.com/youtubei/v1/\(endpoint)")!
        url.queryItems = [
            URLQueryItem(name: "key", value: Self.innertubeAPIKey),
            URLQueryItem(name: "prettyPrint", value: "false"),
        ]

        var headers = [
            "User-Agent": client.userAgent,
            "X-YouTube-Client-Name": client.clientIDHeader,
            "X-YouTube-Client-Version": client.clientVersion,
            "Origin": "https://www.youtube.com",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        headers.merge(YouTubeSession().headers(cookies: cookies)) { _, new in new }
        var cookiePairs = ["CONSENT=YES+cb.20210328-17-p0.en+FX+419", "SOCS=CAI"]
        if let jarCookie = cookies.header(for: URL(string: "https://www.youtube.com")!) {
            cookiePairs.append(jarCookie)
        }
        headers["Cookie"] = cookiePairs.joined(separator: "; ")

        let request = try HTTPRequest.post(url.url!, json: body, headers: headers)
        let response = try await http.fetch(request)
        guard response.isOK, let json = response.json else {
            throw ExtractionError.network(
                "InnerTube \(endpoint) HTTP \(response.status) (\(client.clientName))")
        }
        return json
    }

    /// 关键词搜索。params 为过滤条件（InnerTubeSearchFilter），continuation 用于翻页。
    func search(query: String, params: String? = nil, continuation: String? = nil) async throws -> JSON {
        var body: [String: Any] = [
            "context": Self.web.contextJSON(),
            "query": query,
        ]
        if let params, !params.isEmpty { body["params"] = params }
        if let continuation { body["continuation"] = continuation }
        return try await innertubeCall(endpoint: "search", body: body, client: Self.web)
    }

    /// 浏览频道/播放列表。browseId 为 UC…（频道）或 VL+playlistId（播放列表）；
    /// params 为页签过滤（InnerTubeBrowseTab）。
    func browse(browseId: String, params: String? = nil, continuation: String? = nil) async throws -> JSON {
        var body: [String: Any] = [
            "context": Self.web.contextJSON(),
            "browseId": browseId,
        ]
        if let params, !params.isEmpty { body["params"] = params }
        if let continuation { body["continuation"] = continuation }
        return try await innertubeCall(endpoint: "browse", body: body, client: Self.web)
    }

    /// 分页继续（search/browse 共用 next 端点）。
    func next(continuation: String) async throws -> JSON {
        let body: [String: Any] = [
            "context": Self.web.contextJSON(),
            "continuation": continuation,
        ]
        return try await innertubeCall(endpoint: "next", body: body, client: Self.web)
    }

    func next(videoID: String) async throws -> JSON {
        try await innertubeCall(endpoint: "next", body: ["context": Self.web.contextJSON(), "videoId": videoID], client: Self.web)
    }

    func liveChat(continuation: String, replay: Bool = false) async throws -> JSON {
        try await innertubeCall(endpoint: "live_chat/" + (replay ? "get_live_chat_replay" : "get_live_chat"),
                               body: ["context": Self.web.contextJSON(), "continuation": continuation], client: Self.web)
    }

    /// 抓取频道主页 HTML 并提取 UC 开头的 channel ID（@handle / /c/ / /user/ 解析用）。
    func resolveChannelID(handlePath: String) async throws -> String {
        var components = URLComponents(string: "https://www.youtube.com\(handlePath)")!
        components.queryItems = [URLQueryItem(name: "hl", value: "en")]
        var request = HTTPRequest.get(components.url!, headers: [
            "User-Agent": Self.web.userAgent,
            "Accept-Language": "en-US,en;q=0.9",
        ])
        request.headers["Cookie"] = ["CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI",
                                     cookies.header(for: components.url!)].compactMap { $0 }.joined(separator: "; ")
        let response = try await http.fetch(request)
        guard response.isOK else {
            throw ExtractionError.network("频道页 HTTP \(response.status)")
        }
        let html = response.text
        // 优先级：externalId > channelId > canonicalBaseUrl /channel/UC…
        for pattern in [
            #""externalId"\s*:\s*"(UC[A-Za-z0-9_-]{22})""#,
            #""channelId"\s*:\s*"(UC[A-Za-z0-9_-]{22})""#,
            #"/channel/(UC[A-Za-z0-9_-]{22})"#,
        ] {
            if let range = html.range(of: pattern, options: .regularExpression) {
                if let id = html[range].range(of: "UC[A-Za-z0-9_-]{22}", options: .regularExpression) {
                    return String(html[id])
                }
            }
        }
        throw ExtractionError.parse("频道页未能提取 channel ID（\(handlePath)）")
    }
}
