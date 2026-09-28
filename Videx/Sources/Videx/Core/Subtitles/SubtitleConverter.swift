import Foundation

/// 字幕拉取与格式转换工具。
///
/// 当前支持：YouTube json3、B 站 json 弹幕字幕，统一转 SRT。
/// 转换是纯函数，方便测试；下载走注入的 HTTPFetching。
public enum SubtitleConverter {
    // MARK: - Fetch

    /// 下载字幕轨并转换为 SRT 文本。
    public static func fetchSRT(
        _ track: SubtitleTrack,
        client: HTTPFetching
    ) async throws -> String {
        let resp = try await client.fetch(.get(track.url))
        guard resp.isOK else {
            throw ExtractionError.network("HTTP \(resp.status) 下载字幕失败 — \(track.url.absoluteString)")
        }
        let text = resp.text
        switch track.formatHint {
        case "youtube-json3":
            guard let json = resp.json else { throw ExtractionError.parse("字幕不是合法 JSON") }
            return srtFromYouTubeJSON3(json)
        case "bilibili-json":
            guard let json = resp.json else { throw ExtractionError.parse("字幕不是合法 JSON") }
            return srtFromBilibiliJSON(json)
        case "vtt":
            return vttToSRT(text)
        default:
            // 未知格式：按内容嗅探
            if let json = resp.json {
                return json["body"].array.isEmpty == false
                    ? srtFromBilibiliJSON(json)
                    : srtFromYouTubeJSON3(json)
            }
            return vttToSRT(text)
        }
    }

    // MARK: - YouTube json3 → SRT

    public static func srtFromYouTubeJSON3(_ json: JSON) -> String {
        var out: [String] = []
        var index = 1
        for event in json["events"].array {
            guard let startMs = event["tStartMs"].double,
                  let durationMs = event["dDurationMs"].double
            else { continue }
            let text = event["segs"].array.compactMap { $0["utf8"].string }.joined()
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            out.append("\(index)")
            out.append("\(srtTime(startMs / 1000)) --> \(srtTime((startMs + durationMs) / 1000))")
            out.append(trimmed)
            out.append("")
            index += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Bilibili json → SRT

    public static func srtFromBilibiliJSON(_ json: JSON) -> String {
        var out: [String] = []
        var index = 1
        for line in json["body"].array {
            guard let from = line["from"].double,
                  let to = line["to"].double,
                  let content = line["content"].string
            else { continue }
            out.append("\(index)")
            out.append("\(srtTime(from)) --> \(srtTime(to))")
            out.append(content)
            out.append("")
            index += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - WebVTT → SRT

    public static func vttToSRT(_ vtt: String) -> String {
        var out: [String] = []
        var index = 1
        for block in vtt.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n\n") {
            var lines = block.split(separator: "\n").map(String.init)
            if lines.first?.contains("-->") == nil { lines.removeFirst() }
            guard let timeLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let converted = timeLine
                .replacingOccurrences(of: ".", with: ",")
                .split(separator: " ", omittingEmptySubsequences: true)
                .filter { $0.contains("-->") || $0.allSatisfy { $0.isNumber || $0 == ":" || $0 == "," || $0 == "." } }
            guard converted.count >= 2 else { continue }
            out.append("\(index)")
            out.append("\(converted[0]) --> \(converted[1])")
            out.append(lines.drop { $0 != timeLine }.dropFirst().joined(separator: "\n"))
            out.append("")
            index += 1
        }
        return out.joined(separator: "\n")
    }

    // MARK: - Time

    public static func srtTime(_ seconds: Double) -> String {
        let clamped = max(0, seconds)
        let h = Int(clamped) / 3600
        let m = Int(clamped) % 3600 / 60
        let s = Int(clamped) % 60
        let ms = Int((clamped - Double(Int(clamped))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
