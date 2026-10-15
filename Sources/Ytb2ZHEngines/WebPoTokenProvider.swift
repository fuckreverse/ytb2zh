import Foundation
import CryptoKit
import Videx
#if canImport(WebKit)
import WebKit
import Network
#endif

// MARK: - Web PO Token 收割（WKWebView as POT provider）
//
// 设计动机：GVS/player PO Token 是 web 系客户端拿到可用直链的前提，而
// token 必须由 BotGuard 在"像真浏览器"的环境里跑出来。本机 App 内嵌
// WKWebView，本身就是一个带真实指纹、真实 youtube.com origin、能自动
// 执行站点 BotGuard 的浏览器——于是把"生成 POT"这件事外包给它：
//
//   1. 加载 https://www.youtube.com/（真实页面，ytcfg/attestation 自动就绪）
//   2. 页面内收 visitorData + 首页 ytAtN 内嵌的 BotGuard 挑战
//   3. 宿主下载 interpreter JS（页面里 fetch 会被 CORS / Trusted Types 挡）
//   4. 页面内 eval interpreter → BotGuard 快照 → GenerateIT → 铸 POT
//
// 与 Videx 的 `ExtractionContext.youtubePoTokens` / `youtubeVisitorData`
// 注入点对接；token 与 visitorData 绑定，必须成对使用。
//
// 归因：BotGuard 互操作逻辑来自 LuanRT/BgUtils（bgutils-js，MIT）。

/// WebPO result: separate session/content bindings plus the matching browser session.
public struct HarvestedPoToken: Codable, Sendable, Equatable {
    public var visitorData: String
    public var poToken: String
    public var harvestedAt: Date
    public var expiresAt: Date
    /// Separate content-bound tokens. Legacy visitor-only cache entries have neither field.
    public var videoID: String?
    public var videoPoToken: String?
    public var sessionPoToken: String?
    public var gvsBoundToVideo: Bool?
    public var scopeKey: String?
    public var cookies: CookieJar?
    public var userAgent: String?

    public func tokens(for videoID: String) -> [String: String] {
        guard self.videoID == videoID, let videoPoToken, !videoPoToken.isEmpty else { return [:] }
        let gvs = gvsBoundToVideo == true ? videoPoToken : (sessionPoToken ?? poToken)
        var result: [String: String] = [:]
        for client in VidexBridge.webFamilyClientKeys {
            result[client + ".gvs"] = gvs
            result[client + ".gvs_session"] = sessionPoToken ?? poToken
            result[client + ".gvs_video"] = videoPoToken
            result[client + ".player"] = videoPoToken
            result[client + ".subs"] = videoPoToken
        }
        return result
    }


    public init(visitorData: String, poToken: String, harvestedAt: Date, expiresAt: Date) {
        self.visitorData = visitorData
        self.poToken = poToken
        self.harvestedAt = harvestedAt
        self.expiresAt = expiresAt
    }

    public func isFresh(now: Date = Date()) -> Bool { expiresAt > now }
}

public enum WebPoTokenError: LocalizedError {
    case unsupportedPlatform
    case pageUnavailable(String)
    case challengeMissing(String)
    case interpreterUnavailable(String)
    case botguardFailed(String)
    case tokenMintFailed(String)
    case timedOut
    case throttled(remaining: Int)

    public var errorDescription: String? {
        switch self {
        case .unsupportedPlatform:
            return "当前平台不支持 WebView POT 收割（需 macOS + WebKit）"
        case .pageUnavailable(let detail):
            return "YouTube 页面加载失败：\(detail)"
        case .challengeMissing(let detail):
            return "BotGuard 挑战获取失败：\(detail)"
        case .interpreterUnavailable(let detail):
            return "interpreter 脚本下载失败：\(detail)"
        case .botguardFailed(let detail):
            return "BotGuard 执行失败：\(detail)"
        case .tokenMintFailed(let detail):
            return "PO Token 铸造失败：\(detail)"
        case .timedOut:
            return "POT 收割超时"
        case .throttled(let remaining):
            return "POT 收割过于频繁（\(remaining)s 内已尝试），暂缓"
        }
    }
}

/// POT 收割开关（UserDefaults 键，App 侧用 @AppStorage 绑定；默认开启）。
public enum WebPotHarvestSetting {
    public static let key = "youtubeWebPOTEnabled"

    public static var enabled: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
}

/// POT 收割器 + 磁盘缓存。
public enum WebPoTokenProvider {

    /// 缓存文件（与 ModelStore 等同根：~/.ytb2zh/）。
    public static var cachePath: String { NSHomeDirectory() + "/.ytb2zh/pot.json" }

    /// 保守复用上限：即使服务端给更长的 integrity token TTL，最多复用 6 小时
    ///（对齐 bgutil 默认 TOKEN_TTL；token 与出口 IP 绑定，换网需重新收割）。
    public static let maxReuseInterval: TimeInterval = 6 * 3600

    /// 两次收割之间的最小间隔，避免频繁拉起 WebView。
    public static let minHarvestInterval: TimeInterval = 60

    private static let lock = NSLock()
    private nonisolated(unsafe) static var lastAttemptAt: [String: Date] = [:]
    private static let coordinator = PoTokenHarvestCoordinator()

    // MARK: - 缓存读写

    /// 读取仍有效的缓存 token（过期 / 不存在返回 nil）。
    public static func cached(now: Date = Date(), scope: String? = nil) -> HarvestedPoToken? {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: scope.map(cacheFile) ?? cachePath)),
              let token = try? JSONDecoder().decode(HarvestedPoToken.self, from: data),
              token.isFresh(now: now), scope == nil || token.scopeKey == scope else { return nil }
        return token
    }

    public static func scope(videoID: String?, proxy: String?, cookies: CookieJar) -> String {
        let cookieRows = cookies.cookies.map { [$0.domain, $0.path ?? "/", $0.name, $0.value].joined(separator: "\u{0}") }.sorted()
        let data = (["webpo-event-id-v2", videoID ?? "", proxy ?? ""] + cookieRows).joined(separator: "\u{1}")
        return SHA256.hash(data: Data(data.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private static func cacheFile(_ scope: String) -> String {
        NSHomeDirectory() + "/.ytb2zh/pot/" + scope + ".json"
    }

    /// 丢弃缓存（提取失败时调用，下次强制重新收割）。
    public static func invalidate(scope: String? = nil) {
        lock.lock(); defer { lock.unlock() }
        if let scope { try? FileManager.default.removeItem(atPath: cacheFile(scope)) }
        else {
            try? FileManager.default.removeItem(atPath: cachePath)
            try? FileManager.default.removeItem(atPath: NSHomeDirectory() + "/.ytb2zh/pot")
        }
    }

    private static func store(_ token: HarvestedPoToken) {
        lock.lock(); defer { lock.unlock() }
        let url = URL(fileURLWithPath: token.scopeKey.map(cacheFile) ?? cachePath)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(token) {
            try? data.write(to: url, options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // Latest entry is a UI status snapshot; extraction always uses an exact scope.
            try? data.write(to: URL(fileURLWithPath: cachePath), options: .atomic)
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: cachePath)
        }
    }

    private static func markAttempt(scope: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let now = Date()
        if let last = lastAttemptAt[scope], now.timeIntervalSince(last) < minHarvestInterval { return false }
        lastAttemptAt = lastAttemptAt.filter { now.timeIntervalSince($0.value) < minHarvestInterval }
        lastAttemptAt[scope] = now
        return true
    }

    // MARK: - 收割

    /// Generate session/video WebPO tokens and cache them for this exact request scope.
    /// - Parameters:
    ///   - proxy: Used consistently by WKWebView and native interpreter downloads (HTTP/HTTPS/SOCKS5).
    ///   - timeout: 全流程超时。
    ///   - bypassThrottle: 跳过 `minHarvestInterval` 节流（用户手动「立即收割」/ 测试用）。
    ///   - log: 诊断日志（失败原因会原样带上，便于网络环境干净时定位）。
    public static func harvest(videoID: String? = nil, cookies: CookieJar = CookieJar(), proxy: String? = nil,
                               timeout: TimeInterval = 60, bypassThrottle: Bool = false,
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> HarvestedPoToken {
        guard timeout.isFinite, timeout > 0, timeout <= 600 else { throw WebPoTokenError.timedOut }
        if let videoID, videoID.utf8.count != 11 || !videoID.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 45 || $0 == 95 }) {
            throw WebPoTokenError.challengeMissing("Invalid video ID")
        }
        let key = scope(videoID: videoID, proxy: proxy, cookies: cookies)
        if !bypassThrottle, let token = cached(scope: key) { return token }
        return try await coordinator.run(key: key) {
            try await performHarvest(videoID: videoID, cookies: cookies, scope: key, proxy: proxy,
                                     timeout: timeout, bypassThrottle: bypassThrottle, log: log)
        }
    }

    private static func performHarvest(videoID: String?, cookies: CookieJar, scope: String, proxy: String? = nil,
                               timeout: TimeInterval = 60,
                               bypassThrottle: Bool = false,
                               log: @escaping @Sendable (String) -> Void = { _ in }) async throws -> HarvestedPoToken {
        #if canImport(WebKit) && os(macOS)
        guard bypassThrottle || markAttempt(scope: scope) else {
            throw WebPoTokenError.throttled(remaining: Int(minHarvestInterval))
        }
        var token = try await withThrowingTaskGroup(of: HarvestedPoToken.self) { group in
            group.addTask {
                try await WebKitPotHarvester(videoID: videoID, cookies: cookies, proxy: proxy, log: log).run()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                throw WebPoTokenError.timedOut
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw WebPoTokenError.timedOut }
            return result
        }
        token.scopeKey = scope
        store(token)
        log("[pot] 收割成功：独立 GVS/player/subs 绑定，有效至 \(token.expiresAt)")
        return token
        #else
        throw WebPoTokenError.unsupportedPlatform
        #endif
    }
}

actor PoTokenHarvestCoordinator {
    private var tasks: [String: Task<HarvestedPoToken, Error>] = [:]
    func run(key: String, operation: @escaping @Sendable () async throws -> HarvestedPoToken) async throws -> HarvestedPoToken {
        if let task = tasks[key] { return try await task.value }
        let task = Task { try await operation() }
        tasks[key] = task
        defer { tasks[key] = nil }
        return try await task.value
    }
}

#if canImport(WebKit) && os(macOS)

// MARK: - WKWebView 收割实现（主线程）

@MainActor
final class WebKitPotHarvester: NSObject {
    private let videoID: String?
    private let useNativeClient: Bool
    private let cookies: CookieJar
    private let proxy: String?
    private let log: @Sendable (String) -> Void
    /// 常驻变量：WKWebView 必须被强引用直到收割结束
    private var webView: WKWebView?

    init(videoID: String?, cookies: CookieJar, proxy: String?, useNativeClient: Bool = false, log: @escaping @Sendable (String) -> Void) {
        self.videoID = videoID
        self.useNativeClient = useNativeClient
        self.cookies = cookies
        self.proxy = proxy
        self.log = log
    }

    func run() async throws -> HarvestedPoToken {
        // CLI 场景需要 AppKit 以非 UI 形态初始化；GUI 场景保持原 activationPolicy。
        let app = NSApplication.shared
        if app.activationPolicy() != .regular { app.setActivationPolicy(.prohibited) }

        let controller = WKUserContentController()
        controller.addUserScript(WKUserScript(source: WebPoTokenScripts.bgutilsBundle,
                                             injectionTime: .atDocumentEnd,
                                             forMainFrameOnly: true))
        let config = WKWebViewConfiguration()
        config.userContentController = controller
        config.websiteDataStore = .nonPersistent()
        if let proxy, !proxy.isEmpty {
            guard let url = URL(string: proxy), let host = url.host, let rawPort = url.port,
                  let port = NWEndpoint.Port(rawValue: UInt16(exactly: rawPort) ?? 0), rawPort > 0 else {
                throw WebPoTokenError.pageUnavailable("Invalid proxy")
            }
            let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
            var configuration: ProxyConfiguration
            switch url.scheme?.lowercased() {
            case "http": configuration = ProxyConfiguration(httpCONNECTProxy: endpoint)
            case "https": configuration = ProxyConfiguration(httpCONNECTProxy: endpoint, tlsOptions: NWProtocolTLS.Options())
            case "socks5", "socks5h": configuration = ProxyConfiguration(socksv5Proxy: endpoint)
            default: throw WebPoTokenError.pageUnavailable("Unsupported WebKit proxy scheme")
            }
            if let user = url.user { configuration.applyCredential(username: user, password: url.password ?? "") }
            config.websiteDataStore.proxyConfigurations = [configuration]
        }
        for cookie in cookies.cookies {
            guard cookie.domain == "youtube.com" || cookie.domain.hasSuffix(".youtube.com") else { continue }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: cookie.name, .value: cookie.value,
                .domain: cookie.domain, .path: cookie.path ?? "/"]
            if let expires = cookie.expires, expires > 0 { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if cookie.secure == true { properties[.secure] = "TRUE" }
            if let value = HTTPCookie(properties: properties) { await config.websiteDataStore.httpCookieStore.setCookie(value) }
        }
        config.applicationNameForUserAgent = "Version/17.0 Safari/16617"

        let webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 800), configuration: config)
        self.webView = webView
        defer { webView.stopLoading(); self.webView = nil }

        // 1. 加载首页并等待 ytcfg 就绪
        log("[pot] 加载 YouTube 会话页面…")
        let pageURL = useNativeClient ? "https://www.youtube.com/?themeRefresh=1"
            : (videoID.map { "https://www.youtube.com/watch?v=" + $0 } ?? "https://www.youtube.com/")
        webView.load(URLRequest(url: URL(string: pageURL)!))
        try await waitForReady(webView)

        if useNativeClient {
            let result = try await callJSON(webView, WebPoTokenScripts.nativeWebPoClient,
                arguments: ["videoID": videoID ?? "", "authenticated": cookies.hasYouTubeAuthentication], stage: "native-wpc")
            guard result["ok"] as? Bool == true,
                  let visitor = result["visitorData"] as? String, !visitor.isEmpty,
                  let sessionToken = result["sessionPoToken"] as? String, !sessionToken.isEmpty else {
                throw WebPoTokenError.tokenMintFailed(result["error"] as? String ?? "Native WebPoClient failed")
            }
            // Native WPC exposes no TTL. Use once immediately; never persist/reuse it.
            let now = Date()
            var token = HarvestedPoToken(visitorData: visitor, poToken: sessionToken, harvestedAt: now, expiresAt: now)
            token.videoID = videoID
            token.sessionPoToken = sessionToken
            token.videoPoToken = result["videoPoToken"] as? String
            token.gvsBoundToVideo = result["gvsBoundToVideo"] as? Bool ?? false
            token.userAgent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
            token.cookies = CookieJar(cookies: await config.websiteDataStore.httpCookieStore.allCookies().filter {
                $0.domain == "youtube.com" || $0.domain.hasSuffix(".youtube.com")
            }.map {
                SiteCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path,
                    expires: $0.expiresDate?.timeIntervalSince1970, secure: $0.isSecure)
            })
            return token
        }

        // 2. 页面内取 visitorData + 挑战
        let stage1 = try await callJSON(webView, WebPoTokenScripts.stage1, arguments: [:], stage: "stage1")
        guard stage1["ok"] as? Bool == true else {
            throw WebPoTokenError.challengeMissing(stage1["error"] as? String ?? "未知")
        }
        let visitorData = stage1["visitorData"] as? String ?? ""
        guard !visitorData.isEmpty else { throw WebPoTokenError.challengeMissing("visitorData 为空") }

        // 3. interpreter：优先页面内嵌，其次宿主下载（绕开 CORS / Trusted Types）
        var interpreterJS = stage1["interpreterJS"] as? String
        if interpreterJS?.isEmpty != false {
            interpreterJS = nil
            guard let rawURL = stage1["interpreterUrl"] as? String else {
                throw WebPoTokenError.interpreterUnavailable("挑战未提供 interpreter")
            }
            let url = URL(string: rawURL.hasPrefix("http") ? rawURL : "https:" + rawURL)
            guard let url else { throw WebPoTokenError.interpreterUnavailable("非法 URL: \(rawURL)") }
            log("[pot] 下载 interpreter：\(url.host ?? "?")…")
            interpreterJS = try await download(url)
        }
        guard let interpreterJS, !interpreterJS.isEmpty,
              let program = stage1["program"] as? String,
              let globalName = stage1["globalName"] as? String else {
            throw WebPoTokenError.interpreterUnavailable("interpreter / program 缺失")
        }

        // 4. 页面内跑 BotGuard + GenerateIT + 铸 token
        log("[pot] 执行 BotGuard 挑战…")
        let stage2 = try await callJSON(webView, WebPoTokenScripts.stage2, arguments: [
            "interpreterJS": interpreterJS,
            "attestationConfig": stage1["attestationConfig"] as? [String: Any] ?? [:],
            "program": program,
            "globalName": globalName,
            "visitorData": visitorData,
            "videoID": videoID ?? "",
            "dataSyncID": stage1["dataSyncID"] as? String ?? "",
            "authenticated": cookies.hasYouTubeAuthentication,
        ], stage: "stage2")
        guard stage2["ok"] as? Bool == true else {
            let detail = stage2["error"] as? String ?? "未知"
            throw WebPoTokenError.botguardFailed(detail)
        }
        guard let poToken = stage2["poToken"] as? String, !poToken.isEmpty else {
            throw WebPoTokenError.tokenMintFailed("返回空 token")
        }

        let now = Date()
        let serverTTL = (stage2["itTtlSecs"] as? NSNumber)?.doubleValue ?? 0
        guard serverTTL.isFinite, serverTTL > 0 else { throw WebPoTokenError.tokenMintFailed("Missing or invalid integrity TTL") }
        let expiry = max(0, min(serverTTL, WebPoTokenProvider.maxReuseInterval) - min(300, serverTTL * 0.1))
        var token = HarvestedPoToken(visitorData: visitorData,
                                poToken: poToken,
                                harvestedAt: now,
                                expiresAt: now.addingTimeInterval(expiry))
        token.videoID = videoID
        token.videoPoToken = stage2["videoPoToken"] as? String
        token.sessionPoToken = stage2["sessionPoToken"] as? String
        token.gvsBoundToVideo = stage1["gvsBoundToVideo"] as? Bool ?? false
        token.userAgent = try await webView.evaluateJavaScript("navigator.userAgent") as? String
        let browserCookies = await config.websiteDataStore.httpCookieStore.allCookies()
        token.cookies = CookieJar(cookies: browserCookies.filter { $0.domain == "youtube.com" || $0.domain.hasSuffix(".youtube.com") }.map {
            SiteCookie(name: $0.name, value: $0.value, domain: $0.domain, path: $0.path, expires: $0.expiresDate?.timeIntervalSince1970, secure: $0.isSecure)
        })
        return token
    }

    // MARK: 辅助

    /// 轮询等待页面就绪：ytcfg 拿到 VISITOR_DATA **且** 注入的 bgutils bundle 已就位。
    ///（ytcfg 在 <head> 就已存在，若不校验 bundle 会与 documentEnd 注入形成竞态。）
    private func waitForReady(_ webView: WKWebView) async throws {
        let probe = "!!(window.__BgUtils && window.ytcfg && window.ytcfg.get"
            + " && window.ytcfg.get('VISITOR_DATA'))"
        for _ in 0..<40 {
            try Task.checkCancellation()
            if let ready = try? await webView.evaluateJavaScript(probe) as? Bool, ready { return }
            try await Task.sleep(nanoseconds: 400_000_000)
        }
        throw WebPoTokenError.pageUnavailable("ytcfg / bgutils 未就绪（20s 内未拿到 VISITOR_DATA）")
    }

    /// 执行页面脚本并解析 JSON 结果。
    private func callJSON(_ webView: WKWebView, _ script: String,
                          arguments: [String: Any], stage: String) async throws -> [String: Any] {
        let raw: Any?
        do {
            raw = try await webView.callAsyncJavaScript(script, arguments: arguments, in: nil, contentWorld: .page)
        } catch {
            throw WebPoTokenError.pageUnavailable("\(stage) 执行异常：\(error.localizedDescription)")
        }
        guard let text = raw as? String, let data = text.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WebPoTokenError.pageUnavailable("\(stage) 返回无法解析：\(String(describing: raw).prefix(200))")
        }
        return json
    }

    /// 宿主侧下载（无浏览器同源限制），可选走代理。
    private func download(_ url: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        if let proxy, !proxy.isEmpty {
            config.connectionProxyDictionary = URLSessionHTTPClient.proxyDictionary(from: proxy)
        }
        do {
            let (data, response) = try await URLSession(configuration: config).data(from: url)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard status == 200, let text = String(data: data, encoding: .utf8), !text.isEmpty else {
                throw WebPoTokenError.interpreterUnavailable("HTTP \(status)，\(data.count) 字节")
            }
            return text
        } catch let error as WebPoTokenError {
            throw error
        } catch {
            throw WebPoTokenError.interpreterUnavailable(error.localizedDescription)
        }
    }
}

#endif

/// Match the browser identity on WebPO API and CDN requests, preserving native/TV clients.
struct PoTokenSessionHTTPClient: HTTPFetching {
    let base: HTTPFetching
    let userAgent: String
    func fetch(_ original: HTTPRequest) async throws -> HTTPResponse {
        var request = original
        let client = request.headers["X-YouTube-Client-Name"]
        if client == nil || ["1", "2", "56"].contains(client!) {
            request.headers["User-Agent"] = userAgent
            if let body = request.body, var json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               var context = json["context"] as? [String: Any], var fields = context["client"] as? [String: Any] {
                fields["userAgent"] = userAgent; context["client"] = fields; json["context"] = context
                request.body = try JSONSerialization.data(withJSONObject: json)
            }
        }
        return try await base.fetch(request)
    }
}
