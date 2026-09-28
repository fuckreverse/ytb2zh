import Foundation

/// 抖音提取器。
///
/// 路线（2026-09 实证有效）：
/// 1. ttwid 风控 cookie：向 `ttwid.bytedance.com/ttwid/union/register/` 注册
///    获取（无签名要求，一次注册长期有效，已缓存则复用）；
/// 2. web detail API：`https://www.douyin.com/aweme/v1/web/aweme/detail/?aweme_id=...`
///    （device_platform=webapp + 浏览器指纹参数），返回 app 风格 aweme_detail；
/// 3. AwemeParser 归一化解析。
///
/// 未登录默认拿到 1080p H.264 混合流（mp4 muxed）；登录 cookie（sessionid）
/// 可解锁更高码率档。WBI 签名在该端点非必需。
public struct DouyinExtractor: Extractor {
    public static let extractorID = "douyin"
    public var id: String { Self.extractorID }
    public var displayName: String { "Douyin" }

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return DouyinURL.hostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    public func extract(_ url: URL, context: ExtractionContext) async throws -> MediaInfo {
        let webUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

        // 1. 解析 aweme id（短链先重定向）
        var ref = DouyinURL.videoRef(from: url)
        if ref?.awemeID == nil {
            let resolved = try await resolve(url: url, context: context, userAgent: webUA)
            ref = DouyinURL.videoRef(from: resolved)
            guard ref?.awemeID != nil else {
                throw ExtractionError.notExtractable(site: Self.extractorID, reason: "短链重定向后未找到视频 ID：\(resolved.absoluteString)")
            }
        }
        guard let videoID = ref?.awemeID else { throw ExtractionError.unsupportedURL(url) }

        // 2. 确保 ttwid
        var jar = context.cookies
        if jar.value(named: "ttwid", forDomain: "douyin.com") == nil {
            let ttwid = try await registerTtwid(context: context)
            jar.set(SiteCookie(name: "ttwid", value: ttwid, domain: ".douyin.com"))
            context.log.log(.info, "已注册 ttwid（长度 \(ttwid.count)）")
        }

        // 3. detail API
        let apiURL = Self.detailURL(awemeID: videoID)
        let headers: [String: String] = [
            "User-Agent": webUA,
            "Referer": "https://www.douyin.com/",
            "Accept": "application/json",
            "Cookie": jar.header(for: apiURL) ?? "",
        ]
        let json = try await context.http.getJSON(apiURL, headers: headers)

        if let status = json["status_code"].int, status != 0 {
            throw ExtractionError.siteError(site: Self.extractorID, code: status, reason: "detail API 返回 status_code=\(status)（可能需要更新 cookie 或被风控）")
        }
        guard let detail = json["aweme_detail"].dict != nil ? json["aweme_detail"] : nil,
              detail.exists else {
            // filter_detail 携带人话原因（如“仅自己可见/已删除”）
            let reason = json["filter_detail"]["detail_msg"].string
                ?? json["filter_detail"]["notice"].string
            if let reason {
                throw ExtractionError.notExtractable(site: Self.extractorID, reason: reason)
            }
            throw ExtractionError.loginRequired(
                site: Self.extractorID,
                reason: "未获取到视频数据（风控要求新 cookie，请重试或提供登录 cookie）")
        }

        guard let info = AwemeParser.makeMediaInfo(
            appStyle: detail,
            webpageURL: URL(string: "https://www.douyin.com/video/\(videoID)") ?? url,
            extractorID: Self.extractorID)
        else {
            throw ExtractionError.parse("aweme_detail 结构解析失败")
        }
        return info
    }

    // MARK: - API URL

    static func detailURL(awemeID: String) -> URL {
        var components = URLComponents(string: "https://www.douyin.com/aweme/v1/web/aweme/detail/")!
        let ts = Int(Date().timeIntervalSince1970)
        components.queryItems = [
            URLQueryItem(name: "aweme_id", value: awemeID),
            URLQueryItem(name: "device_platform", value: "webapp"),
            URLQueryItem(name: "aid", value: "6383"),
            URLQueryItem(name: "channel", value: "channel_pc_web"),
            URLQueryItem(name: "version_code", value: "170400"),
            URLQueryItem(name: "version_name", value: "17.4.0"),
            URLQueryItem(name: "browser_language", value: "zh-CN"),
            URLQueryItem(name: "browser_platform", value: "MacIntel"),
            URLQueryItem(name: "browser_name", value: "Chrome"),
            URLQueryItem(name: "browser_version", value: "131.0.0.0"),
            URLQueryItem(name: "browser_online", value: "true"),
            URLQueryItem(name: "engine_name", value: "Blink"),
            URLQueryItem(name: "os_name", value: "mac"),
            URLQueryItem(name: "os_version", value: "10.15.7"),
            URLQueryItem(name: "platform", value: "PC"),
            URLQueryItem(name: "cookie_enabled", value: "true"),
            URLQueryItem(name: "screen_width", value: "1920"),
            URLQueryItem(name: "screen_height", value: "1080"),
            URLQueryItem(name: "ts", value: String(ts)),
        ]
        return components.url!
    }

    // MARK: - ttwid 注册

    /// 注册 ttwid（字节通用风控通行证）。返回 Set-Cookie 里的 ttwid 值。
    func registerTtwid(context: ExtractionContext) async throws -> String {
        let body: [String: Any] = [
            "region": "cn",
            "aid": 1768,
            "needFid": false,
            "service": "www.ixigua.com",
            "migrate_info": ["ticket": "", "source": "node"],
            "cbUrlProtocol": "https",
            "union": true,
        ]
        guard let url = URL(string: "https://ttwid.bytedance.com/ttwid/union/register/"),
              let request = try? HTTPRequest.post(url, json: body)
        else { throw ExtractionError.network("ttwid 注册 URL 无效") }

        let response = try await context.http.fetch(request)
        guard response.isOK else {
            throw ExtractionError.network("ttwid 注册失败：HTTP \(response.status)")
        }
        // Set-Cookie: ttwid=<value>; Path=/; Domain=bytedance.com ...
        // 键名大小写不敏感地查找（HTTP/2 下可能是 "set-cookie"）
        let setCookie = response.headers
            .first { $0.key.caseInsensitiveCompare("Set-Cookie") == .orderedSame }?
            .value ?? ""
        guard let match = RegexKit.firstMatch(pattern: "ttwid=([^;]+)", in: setCookie), match.count > 1 else {
            throw ExtractionError.network("ttwid 注册响应缺少 Set-Cookie")
        }
        return match[1]
    }

    // MARK: - 短链解析

    /// 跟随重定向取最终 URL（HTTPResponse.finalURL）。
    func resolve(url: URL, context: ExtractionContext, userAgent: String) async throws -> URL {
        let response = try await context.http.fetch(.get(url, headers: ["User-Agent": userAgent]))
        if let final = response.finalURL { return final }
        return url
    }
}
