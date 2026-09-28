import Foundation

/// YouTube URL 解析：支持 watch、youtu.be、shorts、embed、live 等形态。
public enum YouTubeURL {
    public static let hostSuffixes = [
        "youtube.com", "m.youtube.com", "music.youtube.com",
        "www.youtube.com", "youtu.be", "youtube-nocookie.com",
    ]

    /// 从 URL 提取 11 位视频 ID。
    public static func videoID(from url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        guard hostSuffixes.contains(where: { host == $0 || host.hasSuffix(".\($0)") }) else { return nil }

        let path = url.path
        // youtu.be/<id>
        if host == "youtu.be" || host.hasSuffix(".youtu.be") {
            let id = path.split(separator: "/").first.map(String.init)
            return validID(id)
        }
        // /watch?v=<id>
        if path == "/watch" || path.hasPrefix("/watch/") {
            if let v = QueryString.parse(url.query ?? "")["v"] {
                return validID(v)
            }
        }
        // /shorts/<id>、/embed/<id>、/live/<id>、/v/<id>
        for prefix in ["shorts", "embed", "live", "v"] {
            if path == "/\(prefix)" || path.hasPrefix("/\(prefix)/") {
                let id = path.split(separator: "/").dropFirst().first.map(String.init)
                return validID(id)
            }
        }
        return nil
    }

    /// 标准化的 watch URL。
    public static func watchURL(id: String) -> URL {
        URL(string: "https://www.youtube.com/watch?v=\(id)")!
    }

    private static func validID(_ candidate: String?) -> String? {
        guard let id = candidate, (11...12).contains(id.count) else { return nil }
        return id
    }
}
