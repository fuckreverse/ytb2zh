import Foundation

enum RegexKit {
    /// 返回第一个匹配的所有捕获组（组 0 为整体）。
    static func firstMatch(pattern: String, in text: String) -> [String]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return nil
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (0..<match.numberOfRanges).map { idx -> String? in
            guard let r = Range(match.range(at: idx), in: text) else { return nil }
            return String(text[r])
        }.compactMap { $0 }
    }

    /// 返回所有匹配的第一个捕获组。
    static func allMatches(pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators]) else {
            return []
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        let matches = regex.matches(in: text, options: [], range: range)
        return matches.compactMap { match -> String? in
            guard group < match.numberOfRanges, let r = Range(match.range(at: group), in: text) else { return nil }
            return String(text[r])
        }
    }
}

/// 从混淆 JS 源码中按花括号配对截取完整函数/对象声明。
///
/// 扫描时会跳过字符串字面量、模板字符串与注释，防止其中的
/// 花括号干扰配对；正则字面量里的花括号极少出现在挑战代码中，
/// 遇到解析异常时返回 nil 由调用方降级。
enum BraceMatcher {
    /// 从 `startIndex`（指向 '{' 或 '['）开始做括号配对，返回完整片段。
    /// 花括号与方括号各自独立计数（混合嵌套按出现顺序配对即可）。
    static func balancedBraces(in source: String, startAt braceIndex: String.Index) -> Substring? {
        guard braceIndex < source.endIndex else { return nil }
        let opener = source[braceIndex]
        guard opener == "{" || opener == "[" else { return nil }
        let closer: Character = opener == "{" ? "}" : "]"
        let otherOpen: Character = opener == "{" ? "[" : "{"
        let otherClose: Character = opener == "{" ? "]" : "}"

        var depth = 0
        var index = braceIndex
        while index < source.endIndex {
            let char = source[index]
            switch char {
            case opener, otherOpen:
                if char == opener { depth += 1 }
            case closer, otherClose:
                if char == closer {
                    depth -= 1
                    if depth == 0 {
                        return source[braceIndex...index]
                    }
                }
            case "\"":
                index = skipString(source, from: index, terminator: "\"")
                continue
            case "'":
                index = skipString(source, from: index, terminator: "'")
                continue
            case "`":
                index = skipTemplate(source, from: index)
                continue
            case "/":
                if let next = source.index(index, offsetBy: 1, limitedBy: source.endIndex) {
                    if source[next] == "/" {
                        index = skipLineComment(source, from: index)
                        continue
                    }
                    if source[next] == "*" {
                        index = skipBlockComment(source, from: index)
                        continue
                    }
                }
            default:
                break
            }
            index = source.index(after: index)
        }
        return nil
    }

    /// 提取名为 `name` 的函数声明（`function name(...)`、`name=function(...)`、
    /// `var name=function(...)`、`const/let name = function`），返回完整片段。
    static func function(named name: String, in source: String) -> Substring? {
        let esc = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "function[ \\t\\n]+\(esc)[ \\t\\n]*\\(",
            "\(esc)[ \\t\\n]*=[ \\t\\n]*function[ \\t\\n]*\\(",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, options: [], range: range) {
                guard let matchRange = Range(match.range, in: source),
                      let open = source[matchRange.lowerBound...].firstIndex(of: "{"),
                      let snippet = balancedBraces(in: source, startAt: open)
                else { continue }
                // 从匹配起点（含 `Name = ` 前缀）到闭括号，保证片段是完整可执行语句
                return source[matchRange.lowerBound..<snippet.endIndex]
            }
        }
        return nil
    }

    /// 提取 `var name = {...}` / `name = {...}` 形式的全局对象/数组声明。
    static func globalValue(named name: String, in source: String) -> Substring? {
        let esc = NSRegularExpression.escapedPattern(for: name)
        let patterns = [
            "var[ \\t\\n]+\(esc)[ \\t\\n]*=[ \\t\\n]*[\\[{]",
            "const[ \\t\\n]+\(esc)[ \\t\\n]*=[ \\t\\n]*[\\[{]",
            "let[ \\t\\n]+\(esc)[ \\t\\n]*=[ \\t\\n]*[\\[{]",
            "[,;\\n]\\s*\(esc)[ \\t\\n]*=[ \\t\\n]*[\\[{]",
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(source.startIndex..<source.endIndex, in: source)
            for match in regex.matches(in: source, options: [], range: range) {
                guard let matchRange = Range(match.range, in: source) else { continue }
                // '{' 或 '[' 是匹配的最后一个字符
                let open = source.index(before: matchRange.upperBound)
                let braceChar = source[open]
                guard braceChar == "{" || braceChar == "[",
                      let snippet = balancedBraces(in: source, startAt: open)
                else { continue }
                // 从匹配起点（含 `var Name =` 前缀）到闭括号，保证是完整赋值语句
                return source[matchRange.lowerBound..<snippet.endIndex]
            }
        }
        return nil
    }

    // MARK: Skippers

    private static func skipString(_ source: String, from index: String.Index, terminator: Character) -> String.Index {
        var i = source.index(after: index) // 跳过开头引号
        while i < source.endIndex {
            let c = source[i]
            if c == "\\" {
                i = source.index(i, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if c == terminator { return source.index(after: i) }
            if terminator == "\"" && c == "\n" { return i } // 字符串未闭合，退回避免死扫
            i = source.index(after: i)
        }
        return source.endIndex
    }

    private static func skipTemplate(_ source: String, from index: String.Index) -> String.Index {
        var i = source.index(after: index)
        var depth = 0 // ${ } 嵌套
        while i < source.endIndex {
            let c = source[i]
            if c == "\\" {
                i = source.index(i, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if c == "$" {
                let next = source.index(after: i)
                if next < source.endIndex, source[next] == "{" {
                    depth += 1
                    i = source.index(after: next)
                    continue
                }
            }
            if c == "}" && depth > 0 { depth -= 1 }
            if c == "`" && depth == 0 { return source.index(after: i) }
            i = source.index(after: i)
        }
        return source.endIndex
    }

    private static func skipLineComment(_ source: String, from index: String.Index) -> String.Index {
        var i = index
        while i < source.endIndex {
            if source[i] == "\n" { return i }
            i = source.index(after: i)
        }
        return source.endIndex
    }

    private static func skipBlockComment(_ source: String, from index: String.Index) -> String.Index {
        var i = source.index(index, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
        while i < source.endIndex {
            let next = source.index(after: i)
            if source[i] == "*" && next < source.endIndex && source[next] == "/" {
                return source.index(after: next)
            }
            i = next
        }
        return source.endIndex
    }
}
