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

        public func contextJSON() -> [String: Any] {
            var client: [String: Any] = [
                "clientName": clientName,
                "clientVersion": clientVersion,
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

    // 客户端常量来自公开的 yt-dlp 实现（版本随上游风控变动，需定期同步）。
    public static let ios = ClientConfig(
        clientName: "IOS",
        clientVersion: "20.10.4",
        userAgent: "com.google.ios.youtube/20.10.4 (iPhone16,2; U; CPU iOS 18_3_2 like Mac OS X;)",
        clientIDHeader: "5",
        extraClientFields: [
            "deviceMake": JSON("Apple"),
            "deviceModel": JSON("iPhone16,2"),
            "osName": JSON("iPhone"),
            "osVersion": JSON("18.3.2.22D82"),
        ]
    )

    public static let android = ClientConfig(
        clientName: "ANDROID",
        clientVersion: "20.10.38",
        userAgent: "com.google.android.youtube/20.10.38 (Linux; U; Android 11) gzip",
        clientIDHeader: "3",
        extraClientFields: [
            "androidSdkVersion": JSON(30),
            "osName": JSON("Android"),
            "osVersion": JSON("11"),
        ]
    )

    /// VR 客户端：目前不要求 PO Token，是免签名的优质通道。
    public static let androidVr = ClientConfig(
        clientName: "ANDROID_VR",
        clientVersion: "1.62.27",
        userAgent: "com.google.android.apps.youtube.vr.oculus/1.62.27 (Linux; U; Android 12L; eureka-user Build/SQ3A.220605.009.A1) gzip",
        clientIDHeader: "28",
        extraClientFields: [
            "deviceMake": JSON("Oculus"),
            "deviceModel": JSON("Quest 3"),
            "androidSdkVersion": JSON(32),
            "osName": JSON("Android"),
            "osVersion": JSON("12L"),
        ]
    )

    public static let tvEmbedded = ClientConfig(
        clientName: "TVHTML5_SIMPLY_EMBEDDED_PLAYER",
        clientVersion: "2.0",
        userAgent: "Mozilla/5.0 (ChromiumStylePlatform) Cobalt/Version",
        clientIDHeader: "85",
        extraClientFields: [:],
        thirdParty: ["embedUrl": JSON("https://www.youtube.com/")]
    )

    public static let web = ClientConfig(
        clientName: "WEB",
        clientVersion: "2.20250312.04.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36",
        clientIDHeader: "1",
        extraClientFields: [:]
    )

    /// Safari 指纹的 WEB 客户端（部分风控场景比 Chrome 指纹宽松）。
    public static let webSafari = ClientConfig(
        clientName: "WEB",
        clientVersion: "2.20250312.04.00",
        userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/15.5 Safari/605.1.15,gzip(gfe)",
        clientIDHeader: "1",
        extraClientFields: [:]
    )

    /// 默认轮询顺序：ios/android_vr 通常免 decipher；tv 嵌入式对嵌入类视频友好；
    /// web 最通用但几乎必然要解 JS 挑战。
    public static let defaultClientOrder: [ClientConfig] = [ios, androidVr, android, tvEmbedded, web]

    public let http: HTTPFetching
    public let cookies: CookieJar

    public init(http: HTTPFetching, cookies: CookieJar) {
        self.http = http
        self.cookies = cookies
    }

    /// 请求 player 响应。返回的 JSON 原样透传，解析交给上层。
    func player(videoID: String, client: ClientConfig) async throws -> JSON {
        var url = URLComponents(string: "https://www.youtube.com/youtubei/v1/player")!
        url.queryItems = [URLQueryItem(name: "prettyPrint", value: "false")]

        let body: [String: Any] = [
            "context": client.contextJSON(),
            "videoId": videoID,
            "contentCheckOk": true,
            "racyCheckOk": true,
        ]

        var headers = [
            "User-Agent": client.userAgent,
            "X-YouTube-Client-Name": client.clientIDHeader,
            "X-YouTube-Client-Version": client.clientVersion,
            "Origin": "https://www.youtube.com",
            "Accept-Language": "en-US,en;q=0.9",
        ]
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
    func watchPage(videoID: String) async throws -> String {
        var components = URLComponents(string: "https://www.youtube.com/watch")!
        components.queryItems = [
            URLQueryItem(name: "v", value: videoID),
            URLQueryItem(name: "hl", value: "en"),
        ]
        var request = HTTPRequest.get(components.url!, headers: [
            "User-Agent": Self.web.userAgent,
            "Accept-Language": "en-US,en;q=0.9",
        ])
        request.headers["Cookie"] = "CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI"
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
    private func innertubeCall(endpoint: String, body: [String: Any],
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

    /// 抓取频道主页 HTML 并提取 UC 开头的 channel ID（@handle / /c/ / /user/ 解析用）。
    func resolveChannelID(handlePath: String) async throws -> String {
        var components = URLComponents(string: "https://www.youtube.com\(handlePath)")!
        components.queryItems = [URLQueryItem(name: "hl", value: "en")]
        var request = HTTPRequest.get(components.url!, headers: [
            "User-Agent": Self.web.userAgent,
            "Accept-Language": "en-US,en;q=0.9",
        ])
        request.headers["Cookie"] = "CONSENT=YES+cb.20210328-17-p0.en+FX+419; SOCS=CAI"
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
