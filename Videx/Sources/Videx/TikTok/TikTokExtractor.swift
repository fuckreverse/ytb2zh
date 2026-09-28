// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// TikTok 提取器。
///
/// 路线（2026-09 实证有效，与最新 yt-dlp master 对齐）：
/// 1. 请求视频页，遇到 WAF 挑战页（Slardar WAF）时用 sha256 PoW 原生求解，
///    写入挑战 cookie 后二次请求；
/// 2. 从 `__UNIVERSAL_DATA_FOR_REHYDRATION__` 提取 webapp.video-detail.itemStruct；
/// 3. AwemeParser 归一化解析（web 端 CamelCase 字段）。
///
/// 旧移动 API（api16/api22 …/aweme/v1/feed、multi/aweme/detail）对未签名
/// 客户端已返回空响应/限流，不再作为 v1 路线。
/// 流地址优先 `www.tiktok.com/aweme/v1/play/`（302 到签名 CDN，实测可下载）。
public struct TikTokExtractor: Extractor {
    public static let extractorID = "tiktok"
    public var id: String { Self.extractorID }
    public var displayName: String { "TikTok" }

    private static let browserUA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36"

    public init() {}

    public func canHandle(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return TikTokURL.hostSuffixes.contains { host == $0 || host.hasSuffix(".\($0)") }
    }

    public func extract(_ url: URL, context: ExtractionContext) async throws -> MediaInfo {
        // 1. 解析视频 ID（短链先重定向）
        var ref = TikTokURL.videoRef(from: url)
        if ref?.videoID == nil {
            let resolved = try await resolve(url: url, context: context)
            ref = TikTokURL.videoRef(from: resolved)
            // 重定向仍拿不到（如直接落到 @user 主页）时，报不支持
            guard ref?.videoID != nil else { throw ExtractionError.unsupportedURL(url) }
        }
        guard let videoID = ref?.videoID else { throw ExtractionError.unsupportedURL(url) }

        let pageURL = TikTokURL.canonicalURL(videoID: videoID, userHandle: ref?.userHandle)

        // 2. 抓页面（挑战页自动求解重试）+ 状态码判定
        let item = try await fetchVideoItem(pageURL: pageURL, videoID: videoID, context: context)

        // 3. 归一化解析
        guard let info = AwemeParser.makeMediaInfo(
            webItem: item,
            webpageURL: pageURL,
            extractorID: Self.extractorID)
        else {
            throw ExtractionError.parse("itemStruct 解析失败（缺少视频 ID）")
        }
        return info
    }

    // MARK: - 页面抓取 + 挑战

    private func fetchVideoItem(pageURL: URL, videoID: String, context: ExtractionContext) async throws -> JSON {
        var jar = context.cookies

        var html = try await fetchPage(pageURL, context: context, jar: jar)
        if let solution = try WAFChallenge.solve(fromHTML: html) {
            context.log.log(.info, "TikTok WAF 挑战已求解（\(solution.cookies.keys.sorted().joined(separator: ","))）")
            for (name, value) in solution.cookies {
                jar.set(SiteCookie(name: name, value: value, domain: ".tiktok.com"))
            }
            html = try await fetchPage(pageURL, context: context, jar: jar)
        }

        // universal data → webapp.video-detail
        guard let scope = universalData(from: html) else {
            if html.contains("/login") {
                throw ExtractionError.loginRequired(site: Self.extractorID, reason: "TikTok 要求登录后访问该内容")
            }
            throw ExtractionError.parse("未找到 __UNIVERSAL_DATA_FOR_REHYDRATION__ 数据（页面可能被风控或结构变化）")
        }

        let detail = scope["webapp.video-detail"]
        let status = detail["statusCode"].int ?? 0
        let item = detail["itemInfo"]["itemStruct"]

        switch status {
        case 0:
            guard item["video"].exists else {
                throw ExtractionError.notExtractable(site: Self.extractorID, reason: "视频数据不含 video 字段（幻灯片或敏感内容需登录）")
            }
        case 10216, 10222:
            throw ExtractionError.loginRequired(site: Self.extractorID, reason: "无权限查看该帖子（私密内容）")
        case 10204:
            throw ExtractionError.siteError(site: Self.extractorID, code: 10204, reason: "当前 IP 被屏蔽（尝试更换代理）")
        default:
            throw ExtractionError.notExtractable(site: Self.extractorID, reason: "视频不可用（status \(status)）")
        }
        return item
    }

    /// 提取 __UNIVERSAL_DATA_FOR_REHYDRATION__ 的 __DEFAULT_SCOPE__。
    private func universalData(from html: String) -> JSON? {
        guard let groups = RegexKit.firstMatch(
            pattern: #"<script[^>]+id="__UNIVERSAL_DATA_FOR_REHYDRATION__"[^>]*>(.*?)</script>"#,
            in: html),
            groups.count > 1,
            let json = try? JSON(data: Data(groups[1].utf8))
        else { return nil }
        let scope = json["__DEFAULT_SCOPE__"]
        return scope.exists ? scope : json
    }

    private func fetchPage(_ url: URL, context: ExtractionContext, jar: CookieJar) async throws -> String {
        var headers = [
            "User-Agent": Self.browserUA,
            "Accept": "text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8",
            "Accept-Language": "en-US,en;q=0.9",
        ]
        if let cookie = jar.header(for: url) {
            headers["Cookie"] = cookie
        }
        let response = try await context.http.fetch(.get(url, headers: headers))
        guard response.isOK else {
            throw ExtractionError.network("TikTok 页面请求失败：HTTP \(response.status)")
        }
        return response.text
    }

    // MARK: - 短链解析

    private func resolve(url: URL, context: ExtractionContext) async throws -> URL {
        let response = try await context.http.fetch(
            .get(url, headers: ["User-Agent": Self.browserUA]))
        return response.finalURL ?? url
    }
}
