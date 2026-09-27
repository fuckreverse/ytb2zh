import Foundation
import Ytb2ZHCore

// MARK: - 标点语义切分引擎（build_sentences.py 移植）
// 规则：句末标点(.?!)必收；逗号/分号/冒号处累计 >= softWindow 收；累计 >= hardWindow 强制收。

public struct PunctSegmentationEngine: SegmentationEngine {
    public let descriptor = EngineDescriptor(
        "punct", "英文标点切分", "词级时间戳上按 .?! 必收、逗号 7s 软收、13s 强制收")

    public init() {}

    public func segment(words: [TimedWord], options: SegmentationOptions) -> [SpeechUnit] {
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

        for w in words {
            let tok = w.text
            // 过滤 whisper 特殊 token
            if tok.hasPrefix("[_") || tok.hasPrefix("<|") || tok == "[_END_]" || tok == "[_BEG_]" {
                continue
            }
            let trimmed = tok.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if curStart == nil { curStart = w.start }
            curEnd = max(curEnd, w.end)
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
            if hard || (soft && dur >= options.softWindow) || dur >= options.hardWindow {
                flush()
            }
        }
        flush()
        return units
    }
}
