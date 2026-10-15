import Foundation

/// HLS master/media playlist parsing; returns playlist URLs, never segment URLs.
enum HLSParser {
    static func attributes(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        let pattern = #"([A-Z0-9-]+)=(?:"([^"]*)"|([^,]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let valueRange = match.range(at: 2).location != NSNotFound ? match.range(at: 2) : match.range(at: 3)
            if let range = Range(valueRange, in: text) { result[String(text[keyRange])] = String(text[range]) }
        }
        return result
    }

    static func formats(_ text: String, url: URL) -> [MediaFormat] {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U" else { return [] }
        // AES-128 with identity keys is supported by HLS consumers; DRM isn't.
        if lines.contains(where: { line in
            guard line.hasPrefix("#EXT-X-KEY:") || line.hasPrefix("#EXT-X-SESSION-KEY:") else { return false }
            let a = attributes(line)
            return (a["KEYFORMAT"] != nil && a["KEYFORMAT"] != "identity")
                || (a["METHOD"] != nil && !["NONE", "AES-128"].contains(a["METHOD"]!))
        }) { return [] }
        var formats: [MediaFormat] = []
        var audioGroups = Set<String>()
        func resolve(_ value: String) -> URL? {
            guard let resolved = URL(string: value, relativeTo: url)?.absoluteURL,
                  ["http", "https"].contains(resolved.scheme?.lowercased() ?? "") else { return nil }
            return resolved
        }
        func identifier(_ value: URL, fallback: String) -> String {
            let itag = RegexKit.firstMatch(pattern: #"/itag/(\d+)(?:/|$)"#, in: value.path)?[1]
                ?? URLComponents(url: value, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "itag" }?.value
            return (itag ?? fallback) + "-hls"
        }
        for line in lines where line.hasPrefix("#EXT-X-MEDIA:") {
            let a = attributes(line)
            guard a["TYPE"] == "AUDIO", let uri = a["URI"], let mediaURL = resolve(uri) else { continue }
            if let group = a["GROUP-ID"] { audioGroups.insert(group) }
            formats.append(MediaFormat(formatID: identifier(mediaURL, fallback: "audio-\(formats.count)"),
                kind: .audioOnly, url: mediaURL, container: "mp4", protocolType: .hls,
                language: a["LANGUAGE"], qualityLabel: a["NAME"]))
        }
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF:") {
            let a = attributes(line)
            guard let uri = lines.dropFirst(i + 1).first(where: { !$0.isEmpty }),
                  !uri.hasPrefix("#"), let mediaURL = resolve(uri) else { continue }
            let codecs = (a["CODECS"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            let audio = codecs.first { $0.hasPrefix("mp4a") || $0.hasPrefix("opus") || $0.hasPrefix("ac-3") || $0.hasPrefix("ec-3") }
            let video = codecs.first { $0.hasPrefix("avc") || $0.hasPrefix("hev") || $0.hasPrefix("hvc") || $0.hasPrefix("vp") || $0.hasPrefix("av01") }
            let size = (a["RESOLUTION"] ?? "").split(separator: "x").compactMap { Int($0) }
            let hasExternalAudio = a["AUDIO"].map { audioGroups.contains($0) } ?? false
            let kind: MediaKind = video == nil && size.isEmpty && audio != nil ? .audioOnly
                : (hasExternalAudio || (video != nil && audio == nil) ? .videoOnly : .muxed)
            let height = size.count == 2 ? size[1] : nil
            formats.append(MediaFormat(formatID: identifier(mediaURL, fallback: "variant-\(formats.count)"),
                kind: kind, url: mediaURL, container: "mp4", videoCodec: video,
                audioCodec: hasExternalAudio ? nil : audio, width: size.count == 2 ? size[0] : nil,
                height: height, fps: a["FRAME-RATE"].flatMap(Double.init).map { Int($0.rounded()) },
                averageBitrate: (a["AVERAGE-BANDWIDTH"] ?? a["BANDWIDTH"]).flatMap(Int.init),
                protocolType: .hls, qualityLabel: height.map { "\($0)p" }))
        }
        // A direct media playlist can be passed to a player/downloader unchanged.
        if formats.isEmpty, lines.contains(where: { $0.hasPrefix("#EXTINF:") }) {
            formats.append(MediaFormat(formatID: "hls", kind: .muxed, url: url,
                                       container: "mp4", protocolType: .hls))
        }
        var seen = Set<String>()
        return formats.filter { seen.insert($0.url.absoluteString).inserted }
    }
}
