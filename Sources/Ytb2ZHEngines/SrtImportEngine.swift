import Foundation
import Ytb2ZHCore

// MARK: - SRT 解析 + 导入引擎（外部字幕 → 词流，走既有 punct 切分/翻译管线）

public struct SRTLangCue: Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String
    public init(start: Double, end: Double, text: String) {
        self.start = start; self.end = end; self.text = text
    }
}

public enum SRTParser {
    /// 00:01:02,500 → 秒
    public static func parseTimestamp(_ s: String) -> Double? {
        let cleaned = s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")
        let parts = cleaned.split(separator: ":").map(String.init)
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var seconds = 0.0
        for p in parts { seconds = seconds * 60 + (Double(p) ?? 0) }
        return seconds
    }

    public static func parse(_ content: String) -> [SRTLangCue] {
        var cues: [SRTLangCue] = []
        var current: (Double, Double, [String])?
        for rawLine in content.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty {
                if let c = current, !c.2.isEmpty {
                    cues.append(SRTLangCue(start: c.0, end: c.1, text: c.2.joined(separator: "\n")))
                }
                current = nil
                continue
            }
            if current == nil, let dash = line.firstIndex(of: "-"), line.contains("-->") {
                let segs = line.components(separatedBy: "-->")
                if let t1 = parseTimestamp(segs[0]), let t2 = parseTimestamp(segs.count > 1 ? segs[1] : "") {
                    current = (t1, t2, [])
                    continue
                }
            }
            if line.allSatisfy(\.isNumber) && current == nil { continue }   // 序号行
            if current != nil { current!.2.append(line) }
        }
        if let c = current, !c.2.isEmpty {
            cues.append(SRTLangCue(start: c.0, end: c.1, text: c.2.joined(separator: "\n")))
        }
        return cues
    }
}

/// SRT 导入"转录"引擎：把每条 cue 的文本按比例铺到时间轴上，形成 TimedWord 流
public struct SrtTranscribeEngine: TranscribeEngine {
    public let descriptor = EngineDescriptor(
        "srt", "SRT 字幕导入", "不做语音识别，直接用外部 SRT 的文本与时间轴")

    public init() {}

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        guard !options.srtPath.isEmpty else {
            throw EngineError.engineFailure("transcribe.srtPath 未指定 SRT 文件")
        }
        let content = try String(contentsOfFile: options.srtPath, encoding: .utf8)
        let cues = SRTParser.parse(content)
        guard !cues.isEmpty else {
            throw EngineError.engineFailure("SRT 解析结果为空：\(options.srtPath)")
        }
        progress(0.5, "解析到 \(cues.count) 条字幕")

        // cue 文本 → 词 token，时长按 token 长度比例分配（让下游 punct 切分照常工作）
        var words: [TimedWord] = []
        for cue in cues {
            let tokens = Self.tokenize(cue.text)
            guard !tokens.isEmpty else { continue }
            let totalLen = tokens.reduce(0) { $0 + max(1, $1.text.count) }
            guard cue.end > cue.start else {
                words.append(contentsOf: tokens)
                continue
            }
            var cursor = cue.start
            for t in tokens {
                let span = (Double(max(1, t.text.count)) / Double(totalLen)) * (cue.end - cue.start)
                words.append(TimedWord(start: cursor, end: cursor + span, text: t.text))
                cursor += span
            }
        }
        progress(1.0, "词 \(words.count)")
        return words
    }

    /// 英文按空格/标点切，CJK 逐字
    public nonisolated static func tokenize(_ text: String) -> [TimedWord] {
        var tokens: [TimedWord] = []
        var current = ""
        func flush() {
            let t = current.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { tokens.append(TimedWord(start: 0, end: 0, text: t)) }
            current = ""
        }
        for ch in text {
            if ch.isASCII && (ch.isLetter || ch.isNumber || ch == "'" || ch == "-") {
                current.append(ch)
            } else if ch.isWhitespace {
                flush()
            } else if isCJK(ch) {
                flush()
                tokens.append(TimedWord(start: 0, end: 0, text: String(ch)))
            } else {
                // 标点：粘在前一个词上（保留句读信息）
                current.append(ch)
                flush()
            }
        }
        flush()
        return tokens
    }

    nonisolated static func isCJK(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x3040...0x30FF, 0xAC00...0xD7AF:
            return true
        default:
            return false
        }
    }
}
