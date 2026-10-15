import Foundation
import CryptoKit

/// Per-extraction webpage state. Never shared across videos, accounts or proxies.
struct YouTubeSession: Sendable {
    var config = JSON([String: Any]())
    var initialPlayer: JSON?
    var initialData: JSON?
    var playerPath: String?
    var playerSource: String?
    var signatureTimestamp: Int?
    var visitorData: String?
    var encryptedHostFlags: String?

    static func parse(_ html: String, videoID: String) -> YouTubeSession {
        var state = YouTubeSession()
        var config: [String: Any] = [:]
        for object in objects(after: #"ytcfg\.set\s*\(\s*"#, in: html) {
            if let values = object.raw as? [String: Any] { config.merge(values) { _, new in new } }
        }
        state.config = JSON(config)
        state.initialPlayer = objects(after: #"(?:var\s+)?ytInitialPlayerResponse\s*=\s*"#, in: html)
            .first { $0["videoDetails"]["videoId"].string == videoID }
        state.initialData = objects(after: #"(?:var\s+)?ytInitialData\s*=\s*"#, in: html).first
        state.visitorData = state.config["VISITOR_DATA"].string
            ?? state.config["INNERTUBE_CONTEXT"]["client"]["visitorData"].string
            ?? state.initialPlayer?["responseContext"]["visitorData"].string
        state.playerPath = state.config["PLAYER_JS_URL"].string
            ?? RegexKit.allMatches(pattern: #""(?:jsUrl|js|PLAYER_JS_URL)"\s*:\s*"([^"]+)""#, in: html)
                .map { $0.replacingOccurrences(of: "\\/", with: "/") }
                .first { $0.contains("/s/player/") && $0.contains(".js") }
        state.signatureTimestamp = state.config["STS"].int
        state.encryptedHostFlags = state.config["WEB_PLAYER_CONTEXT_CONFIGS"]["WEB_PLAYER_CONTEXT_CONFIG_ID_EMBEDDED_PLAYER"]["encryptedHostFlags"].string
        return state
    }

    private static func objects(after pattern: String, in html: String) -> [JSON] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { match in
            guard let range = Range(match.range, in: html), range.upperBound < html.endIndex,
                  let text = BraceMatcher.balancedBraces(in: html, startAt: range.upperBound) else { return nil }
            return try? JSON(data: Data(text.utf8))
        }
    }

    var userSessionID: String? {
        guard let value = config["DATASYNC_ID"].string else { return nil }
        let parts = value.components(separatedBy: "||")
        return parts.count > 1 && !parts[1].isEmpty ? parts[1] : parts.first
    }

    func headers(cookies: CookieJar, timestamp: Int = Int(Date().timeIntervalSince1970.rounded())) -> [String: String] {
        let origin = "https://www.youtube.com"
        var headers: [String: String] = [:]
        if let visitorData { headers["X-Goog-Visitor-Id"] = visitorData }
        if let index = config["SESSION_INDEX"].int { headers["X-Goog-AuthUser"] = String(index) }
        if let value = config["DATASYNC_ID"].string {
            let parts = value.components(separatedBy: "||")
            if parts.count > 1, !parts[1].isEmpty {
                headers["X-Goog-PageId"] = parts[0]
                if headers["X-Goog-AuthUser"] == nil { headers["X-Goog-AuthUser"] = "0" }
            }
        }
        let third = cookies.value(named: "__Secure-3PAPISID", for: URL(string: origin)!)
        let pairs = [
            ("SAPISIDHASH", cookies.value(named: "SAPISID", for: URL(string: origin)!) ?? third),
            ("SAPISID1PHASH", cookies.value(named: "__Secure-1PAPISID", for: URL(string: origin)!)),
            ("SAPISID3PHASH", third),
        ]
        let auth = pairs.compactMap { scheme, sid -> String? in
            guard let sid, !sid.isEmpty else { return nil }
            var parts = [String(timestamp), sid, origin]
            if let userSessionID, !userSessionID.isEmpty { parts.insert(userSessionID, at: 0) }
            let hash = Insecure.SHA1.hash(data: Data(parts.joined(separator: " ").utf8))
                .map { String(format: "%02x", $0) }.joined()
            return "\(scheme) \(timestamp)_\(hash)" + ((userSessionID?.isEmpty == false) ? "_u" : "")
        }
        if !auth.isEmpty {
            headers["Authorization"] = auth.joined(separator: " ")
            headers["X-Origin"] = origin
        }
        if config["LOGGED_IN"].bool == true { headers["X-Youtube-Bootstrap-Logged-In"] = "true" }
        return headers
    }
}
