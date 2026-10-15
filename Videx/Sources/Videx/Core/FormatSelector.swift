import Foundation

public struct MediaSelection: Sendable, Equatable {
    public var formats: [MediaFormat]
    public init(formats: [MediaFormat]) { self.formats = formats }
}

/// Native format expression parser. Unsupported syntax is an error, never silently ignored.
public enum FormatSelector {
    public static func select(_ info: MediaInfo, expression: String) throws -> [MediaSelection] {
        let groups = try split(expression, separator: ",")
        return try groups.map { group in
            for alternative in try split(group, separator: "/") {
                let terms = try split(stripParentheses(alternative), separator: "+")
                var formats: [MediaFormat] = []
                var missing = false
                for term in terms {
                    let chosen = try evaluate(term, formats: info.formats)
                    if chosen.isEmpty { missing = true; break }
                    formats.append(contentsOf: chosen)
                }
                if !missing && !formats.isEmpty { return MediaSelection(formats: formats) }
            }
            throw ExtractionError.notExtractable(site: info.extractorID, reason: "没有满足格式表达式的流：\(group)")
        }
    }

    static func split(_ input: String, separator: Character) throws -> [String] {
        var result: [String] = [], current = "", brackets = 0, parentheses = 0
        var quote: Character?, escaped = false
        for character in input {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\", quote != nil { current.append(character); escaped = true; continue }
            if let delimiter = quote {
                current.append(character); if character == delimiter { quote = nil }; continue
            }
            if character == "\"" || character == "'" { quote = character }
            if character == "[" { brackets += 1 }
            if character == "]" { brackets -= 1 }
            if brackets == 0 {
                if character == "(" { parentheses += 1 }
                if character == ")" { parentheses -= 1 }
            }
            guard brackets >= 0 && parentheses >= 0 else { throw ExtractionError.parse("格式表达式括号不匹配") }
            if character == separator && brackets == 0 && parentheses == 0 {
                guard !current.trimmingCharacters(in: .whitespaces).isEmpty else { throw ExtractionError.parse("格式表达式有空选择项") }
                result.append(current.trimmingCharacters(in: .whitespaces)); current = ""
            } else { current.append(character) }
        }
        guard brackets == 0 && parentheses == 0 && quote == nil else { throw ExtractionError.parse("格式表达式没有闭合") }
        guard !current.trimmingCharacters(in: .whitespaces).isEmpty else { throw ExtractionError.parse("格式表达式有空选择项") }
        result.append(current.trimmingCharacters(in: .whitespaces))
        return result
    }
    private static func stripParentheses(_ input: String) -> String {
        let value = input.trimmingCharacters(in: .whitespaces)
        return value.hasPrefix("(") && value.hasSuffix(")") ? String(value.dropFirst().dropLast()) : value
    }
    private static func evaluate(_ input: String, formats: [MediaFormat]) throws -> [MediaFormat] {
        let input = stripParentheses(input)
        if try split(input, separator: "/").count > 1 {
            for branch in try split(input, separator: "/") {
                let result = try evaluate(branch, formats: formats); if !result.isEmpty { return result }
            }
            return []
        }
        let token = String(input.prefix { $0 != "[" }).trimmingCharacters(in: .whitespaces)
        var candidates = formats
        let filters = RegexKit.allMatches(pattern: #"\[([^\]]+)\]"#, in: input)
        for filter in filters { candidates = try candidates.filter { try matches($0, filter: filter) } }
        var tokenParts = token.components(separatedBy: ".")
        let ordinal = tokenParts.count == 2 && tokenParts[1].allSatisfy(\.isNumber) ? Int(tokenParts.removeLast()) : nil
        let name = tokenParts.joined(separator: ".")
        let ascending = name.hasPrefix("worst") || ["w","wv","wa","wv*","wa*"].contains(name)
        switch name {
        case "best", "b", "worst", "w": candidates = candidates.filter { $0.kind == .muxed }
        case "best*", "b*", "worst*", "w*": break
        case "bestvideo", "bv", "worstvideo", "wv": candidates = candidates.filter { $0.kind == .videoOnly }
        case "bestvideo*", "bv*", "worstvideo*", "wv*": candidates = candidates.filter { $0.kind != .audioOnly }
        case "bestaudio", "ba", "worstaudio", "wa": candidates = candidates.filter { $0.kind == .audioOnly }
        case "bestaudio*", "ba*", "worstaudio*", "wa*": candidates = candidates.filter { $0.kind != .videoOnly }
        case "all", "mergeall": break
        case "mp4","webm","m4a","mp3","ogg": candidates = candidates.filter { $0.container == name }
        default: candidates = candidates.filter { $0.formatID == name }
        }
        candidates.sort { better($0, $1) }
        if ascending { candidates.reverse() }
        if name == "all" || name == "mergeall" { return candidates }
        let index = (ordinal ?? 1) - 1
        guard index >= 0 && index < candidates.count else { return [] }
        return [candidates[index]]
    }
    private static func better(_ a: MediaFormat, _ b: MediaFormat) -> Bool {
        let aHeight = a.height ?? 0, bHeight = b.height ?? 0
        if aHeight != bHeight { return aHeight > bHeight }
        if (a.fps ?? 0) != (b.fps ?? 0) { return (a.fps ?? 0) > (b.fps ?? 0) }
        if a.isDefaultAudio != b.isDefaultAudio { return a.isDefaultAudio == true }
        if (a.averageBitrate ?? 0) != (b.averageBitrate ?? 0) { return (a.averageBitrate ?? 0) > (b.averageBitrate ?? 0) }
        let rank: [MediaProtocol: Int] = [.https:4,.hls:3,.dash:2,.sabr:1]
        if rank[a.protocolType] != rank[b.protocolType] { return rank[a.protocolType,default:0] > rank[b.protocolType,default:0] }
        return a.formatID < b.formatID
    }
    private static func value(_ format: MediaFormat, field: String) -> String? {
        switch field {
        case "height": return format.height.map(String.init)
        case "width": return format.width.map(String.init)
        case "fps": return format.fps.map(String.init)
        case "tbr","abr","vbr": return format.averageBitrate.map { String(Double($0) / 1000) }
        case "filesize","filesize_approx": return format.approximateSize.map(String.init)
        case "ext": return format.kind == .audioOnly && format.container == "mp4" ? "m4a" : format.container
        case "vcodec": return format.videoCodec ?? (format.kind == .audioOnly ? "none" : nil)
        case "acodec": return format.audioCodec ?? (format.kind == .videoOnly ? "none" : nil)
        case "protocol": return format.protocolType == .hls ? "m3u8_native" : format.protocolType == .dash ? "http_dash_segments" : format.protocolType.rawValue
        case "language": return format.language
        case "format_id": return format.formatID
        case "audio_track_id": return format.audioTrackID
        case "is_drc": return format.isDRC.map { $0 ? "true" : "false" }
        default: return nil
        }
    }
    private static func numeric(_ text: String) -> Double? {
        if let value = Double(text) { return value }
        guard let last = text.last, let power = "KMGTPE".firstIndex(of: Character(String(last).uppercased())),
              let base = Double(text.dropLast()) else { return nil }
        return base * pow(1024, Double("KMGTPE".distance(from: "KMGTPE".startIndex, to: power) + 1))
    }
    private static func matches(_ format: MediaFormat, filter: String) throws -> Bool {
        guard let match = RegexKit.firstMatch(pattern: #"^\s*([A-Za-z0-9_]+)\s*(!\^=|!\$=|!\*=|!~=|!=|<=|>=|\^=|\$=|\*=|~=|=|<|>)(\?)?\s*(.*?)\s*$"#, in: filter) else {
            throw ExtractionError.parse("不支持的格式筛选：\(filter)")
        }
        // Capture positions must stay stable even when the optional '?' is absent.
        guard let regex = try? NSRegularExpression(pattern: #"^\s*([A-Za-z0-9_]+)\s*(!\^=|!\$=|!\*=|!~=|!=|<=|>=|\^=|\$=|\*=|~=|=|<|>)(\?)?\s*(.*?)\s*$"#),
              let captures = regex.firstMatch(in: filter, range: NSRange(filter.startIndex..., in: filter)) else { return false }
        func capture(_ i: Int) -> String { Range(captures.range(at: i), in: filter).map { String(filter[$0]) } ?? "" }
        let field = capture(1), op = capture(2), allowMissing = capture(3) == "?"
        let expected = capture(4).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        guard let actual = value(format, field: field) else { return allowMissing }
        if ["<","<=",">",">="].contains(op) {
            guard let left = Double(actual), let right = numeric(expected) else { return false }
            switch op { case "<": return left < right; case "<=": return left <= right; case ">": return left > right; default: return left >= right }
        }
        let negative = op.hasPrefix("!"), base = negative ? String(op.dropFirst()) : op
        let result: Bool
        switch base {
        case "=": result = actual == expected
        case "^=": result = actual.hasPrefix(expected)
        case "$=": result = actual.hasSuffix(expected)
        case "*=": result = actual.contains(expected)
        case "~=":
            guard let pattern = try? NSRegularExpression(pattern: expected) else { throw ExtractionError.parse("格式筛选正则无效") }
            result = pattern.firstMatch(in: actual, range: NSRange(actual.startIndex..., in: actual)) != nil
        default: throw ExtractionError.parse("格式比较运算符无效：\(match)")
        }
        return negative ? !result : result
    }
}
