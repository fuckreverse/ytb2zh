import Foundation
import Ytb2ZHCore

// MARK: - 标点语义切分引擎（build_sentences.py 移植 + 句界消歧）
// 规则：句末标点(.?!)必收；逗号/分号/冒号处累计 >= softWindow 收；累计 >= hardWindow 强制收。
// 句界消歧（防止一句话被切成两条）：
//   ① 缩写句点不收：Mr. / Dr. / e.g. / U.S. / etc. / 单字母首字母 / 纯数字编号；
//   ② 句点后下个词首字母小写 → 大概率不是句末，不收（问号叹号不受此限）；
//   ③ 无标点硬切（13s 强制收 / whisper 漏句末标点）的单元，后处理与下一单元确定性合并（总时长 ≤ hardWindow×1.5）。

public struct PunctSegmentationEngine: SegmentationEngine {
    public let descriptor = EngineDescriptor(
        "punct", "英文标点切分", "词级时间戳上按 .?! 必收（含句界消歧）、逗号 7s 软收、13s 强制收")

    public init() {}

    /// 常见缩写（句点前的小写/大写词干，不含末尾句点）
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "mt", "ft",
        "gen", "sen", "rep", "gov", "col", "capt", "sgt", "lt", "rev", "hon",
        "vs", "etc", "inc", "ltd", "co", "corp", "dept", "univ", "bros",
        "eg", "ie", "cf", "al", "approx", "est", "fig", "figs", "eq",
        "no", "nos", "vol", "vols", "pp", "ed", "eds",
        "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct", "nov", "dec",
        "mon", "tue", "tues", "wed", "thu", "thur", "thurs", "fri", "sat", "sun",
        "min", "max", "sec", "hr", "hrs", "yrs", "ca",
    ]

    public func segment(words: [TimedWord], options: SegmentationOptions) -> [SpeechUnit] {
        // 预收集有效词（句界消歧需要 lookahead 下一个词）
        var toks: [(w: TimedWord, trimmed: String)] = []
        for w in words {
            let tok = w.text
            // 过滤 whisper 特殊 token
            if tok.hasPrefix("[_") || tok.hasPrefix("<|") || tok == "[_END_]" || tok == "[_BEG_]" {
                continue
            }
            let trimmed = tok.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            toks.append((w, trimmed))
        }

        var units: [SpeechUnit] = []
        var curStart: Double?
        var curEnd: Double = 0
        var pieces: [String] = []

        func flush() {
            let text = pieces.joined().replacingOccurrences(of: #"\s+"#, with: " ",
                                                            options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
            if let s = curStart, text.count > 2 {
                units.append(SpeechUnit(start: (s * 100).rounded() / 100,
                                  end: (curEnd * 100).rounded() / 100, en: text))
            }
            curStart = nil; curEnd = 0; pieces = []
        }

        for (idx, t) in toks.enumerated() {
            let tok = t.w.text
            let trimmed = t.trimmed
            if curStart == nil { curStart = t.w.start }
            curEnd = max(curEnd, t.w.end)
            // whisper token 自带前导空格；若没有则补（标点前不加）
            if !pieces.isEmpty, !tok.hasPrefix(" "),
               let last = pieces.last, !last.hasSuffix(" "),
               !".,!?;:)\"'”.".contains(trimmed.first!) {
                pieces.append(" ")
            }
            pieces.append(tok)

            let dur = curEnd - curStart!
            let hard = trimmed.range(of: #"[.?!]["')\]]*\s*$"#, options: .regularExpression) != nil
            let soft = trimmed.range(of: #"[,;:]["')\]]*\s*$"#, options: .regularExpression) != nil
            if hard, Self.isSentenceBoundary(trimmed, next: idx + 1 < toks.count ? toks[idx + 1].trimmed : nil) {
                flush()
            } else if soft && dur >= options.softWindow {
                flush()
            } else if dur >= options.hardWindow {
                flush()   // 无标点硬切：flush 后由 mergeOpenEnded 与下一单元合并
            }
        }
        flush()
        return Self.mergeOpenEnded(units, cap: max(options.hardWindow * 1.5, 16))
    }

    // MARK: 句界消歧

    /// 判断以 .?! 收尾的 token 是否真的是句末
    static func isSentenceBoundary(_ trimmed: String, next: String?) -> Bool {
        // 问号/叹号永远按句末处理
        if trimmed.range(of: #"[?!]["')\]]*\s*$"#, options: .regularExpression) != nil { return true }
        // 以下均为句点结尾
        // 句点后无词 → 句末
        guard let next = next, !next.isEmpty else { return true }
        // 下一个词首字母小写 → 大概率是缩写/编号后接续，不收
        if let ch = next.first(where: { $0.isLetter }), ch.isLowercase { return false }
        // 词干：剥掉末尾的句点/闭引号/闭括号（省略号连号一并去净）
        var stem = trimmed
        while let last = stem.last, ".\"')]".contains(last) {
            stem.removeLast()
        }
        if let first = stem.first, "\"([".contains(first) { stem.removeFirst() }
        if stem.isEmpty { return true }   // 纯 "..." → 句末
        let lower = stem.lowercased()
        // 纯数字编号（"3."）不收
        if lower.allSatisfy({ $0.isNumber }) { return false }
        // 单字母首字母缩写（"J."）不收
        if lower.count == 1 { return false }
        // 词干内部还有句点（"U.S" / "e.g" / "Ph.D"）→ 缩写链，不收
        if lower.contains(".") { return false }
        // 缩写白名单
        if Self.abbreviations.contains(lower) { return false }
        return true
    }

    // MARK: 无标点硬切单元的确定性合并

    /// 单元文本是否以任意标点结尾（.?! 逗号冒号等，可带闭引号/括号）
    /// 注：逗号软收是设计内的子句切分，不应合并；只有完全无标点（13s 硬切 / whisper 漏句末标点）才合并
    static func endsTerminal(_ text: String) -> Bool {
        text.range(of: #"[.,!?;:…．]["')\]】」”’]*\s*$"#, options: .regularExpression) != nil
    }

    /// 前一单元无终止标点（13s 硬切或 whisper 漏句末标点）→ 与下一单元合并，直到出现终止标点或超时长上限
    static func mergeOpenEnded(_ units: [SpeechUnit], cap: Double) -> [SpeechUnit] {
        guard !units.isEmpty else { return units }
        var out: [SpeechUnit] = [units[0]]
        for u in units.dropFirst() {
            let last = out[out.count - 1]
            if !endsTerminal(last.en), (u.end - last.start) <= cap {
                out[out.count - 1] = SpeechUnit(start: last.start, end: u.end,
                                                en: last.en + " " + u.en)
            } else {
                out.append(u)
            }
        }
        return out
    }
}
