import Foundation
import Ytb2ZHCore

// MARK: - ffmpeg 合成引擎（compose.sh 移植）
// 流程：按 plan 拼装配音轨（atempo 变速 + 精确落位）→ 生成 SRT → 烧字幕 + 音频替换/闪避混音。

public struct FFmpegComposeEngine: CompositionEngine {
    public let descriptor = EngineDescriptor(
        "ffmpeg", "ffmpeg 装配", "配音轨拼接 + SRT 烧字幕 + 音频替换")

    public init() {}

    public func compose(video: URL, placements: [Placement], unitSchedules: [UnitSchedule],
                        units: [SpeechUnit], cacheDir: URL, output: URL, options: ComposeOptions,
                        progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let workDir = output.deletingLastPathComponent()
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1) 生成 SRT（新时间轴，单元级，长单元拆分；Netflix 单行上限 + 可选中英双语）
        let srt = workDir.appendingPathComponent("zh.srt")
        try SRTBuilder.build(units: units, unitSchedules: unitSchedules,
                             maxLength: options.subtitleMaxLength,
                             perLineBias: options.subtitleTargetMultiplier,
                             bilingual: options.bilingualSubtitles)
            .write(to: srt, atomically: true, encoding: .utf8)
        progress(0.05, "字幕已生成")

        // 无配音（纯字幕模式）
        guard !placements.isEmpty else {
            try burnSubtitles(video: video, srt: srt, output: output, options: options, keepAudio: true, progress: progress)
            return output
        }

        // 2) 逐子句变速 → 24k 单声道 wav → 拼接文件列表
        let listFile = workDir.appendingPathComponent("concat.txt")
        var concatLines: [String] = []
        var prevEnd = 0.0
        for (i, pl) in placements.enumerated() {
            let src = cacheDir.appendingPathComponent("u\(pl.unitIndex)_c\(pl.clauseIndex).mp3")
            guard fm.fileExists(atPath: src.path) else { continue }
            let segWav = workDir.appendingPathComponent(String(format: "seg_%04d.wav", i))
            let lead = pl.at - prevEnd
            if lead > 0.02 {
                let silWav = workDir.appendingPathComponent(String(format: "sil_%04d.wav", i))
                try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                               "-i", "anullsrc=r=24000:cl=mono", "-t", String(format: "%.3f", lead),
                               silWav.path])
                concatLines.append("file '\(silWav.path)'")
            }
            let atempo = pl.atempo
            if abs(atempo - 1.0) < 0.015 {
                try runFFmpeg(["-y", "-v", "error", "-i", src.path,
                               "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", segWav.path])
            } else {
                try runFFmpeg(["-y", "-v", "error", "-i", src.path,
                               "-filter:a", String(format: "atempo=%.4f", atempo),
                               "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", segWav.path])
            }
            concatLines.append("file '\(segWav.path)'")
            prevEnd = pl.at + pl.duration
            progress(0.05 + 0.35 * Double(i + 1) / Double(placements.count), "配音轨 \(i + 1)/\(placements.count)")
        }
        try concatLines.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)

        let dubWav = workDir.appendingPathComponent("dub.wav")
        try runFFmpeg(["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path,
                       "-c:a", "pcm_s16le", dubWav.path])
        progress(0.45, "配音轨就绪")

        // 3) 成片：视频 copy，音频替换（可选原声闪避/BGM 混入）+ 烧字幕
        let instrumental = workDir.appendingPathComponent("instrumental.wav")
        let bgm: URL? = (options.keepBGM && fm.fileExists(atPath: instrumental.path)) ? instrumental : nil
        try burnSubtitles(video: video, srt: srt, output: output, options: options,
                          keepAudio: options.keepOriginalAudio && bgm == nil,
                          dubWav: dubWav, bgmWav: bgm, progress: progress)
        return output
    }

    private func burnSubtitles(video: URL, srt: URL, output: URL, options: ComposeOptions,
                               keepAudio: Bool, dubWav: URL? = nil, bgmWav: URL? = nil,
                               progress: @Sendable @escaping (Double, String?) -> Void) throws {
        let escapedSrt = srt.path
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: ":", with: "\\:")
            .replacingOccurrences(of: "'", with: "\\'")
        let vf = "subtitles='\(escapedSrt)':force_style='FontName=PingFang SC,FontSize=\(Int(options.subtitleFontSize)),MarginV=\(Int(options.subtitleMarginV)),Outline=1'"

        var args = ["-y", "-v", "error", "-i", video.path]
        if let dubWav { args += ["-i", dubWav.path] }
        if let bgmWav { args += ["-i", bgmWav.path] }
        var filters: [String] = ["[0:v]\(vf)[vout]"]
        var mapA: String
        if keepAudio && dubWav != nil {
            // 原声降 dB 与配音混入（未分离人声但有 BGM 的场景）
            filters.append("[1:a]volume=\(String(format: "%.1f", options.dubGainDB))dB[dub]")
            filters.append("[0:a]volume=-\(Int(options.originalDuckRatio))dB[orig]")
            filters.append("[dub][orig]amix=inputs=2:duration=first:dropout_transition=2[aout]")
            mapA = "[aout]"
        } else if dubWav != nil && bgmWav != nil {
            // 配音 + 伴奏混入（人声分离模式：BGM 保留，人声已换）
            filters.append("[1:a]volume=\(String(format: "%.1f", options.dubGainDB))dB,alimiter=limit=0.95[dub]")
            filters.append("[2:a]volume=\(String(format: "%.1f", options.bgmGainDB))dB[bgm]")
            filters.append("[dub][bgm]amix=inputs=2:duration=first:dropout_transition=2[aout]")
            mapA = "[aout]"
        } else if let dubWav {
            filters.append("[1:a]volume=\(String(format: "%.1f", options.dubGainDB))dB,alimiter=limit=0.95[aout]")
            mapA = "[aout]"
        } else {
            mapA = "0:a"
        }
        args += ["-filter_complex", filters.joined(separator: ";"),
                 "-map", "[vout]", "-map", mapA,
                 "-c:v", "libx264", "-preset", options.preset, "-crf", String(options.crf),
                 "-c:a", "aac", "-b:a", "192k",
                 "-movflags", "+faststart", output.path]
        progress(0.5, "编码中（视频转码约需数分钟）")
        try runFFmpeg(args)
        progress(1.0, "完成")
    }
}

// MARK: - SRT 生成（reschedule_v2.py split_events 移植）

public enum SRTBuilder {
    public static func build(units: [SpeechUnit], unitSchedules: [UnitSchedule],
                             maxLength: Int = 75, perLineBias: Double = 1.2,
                             bilingual: Bool = false) -> String {
        var lines: [String] = []
        var idx = 1
        let preferred = max(8, Int(Double(maxLength) / max(1.0, perLineBias)))
        for sch in unitSchedules {
            let i = sch.unitIndex
            guard i < units.count else { continue }
            let text = units[i].zh
            guard !text.isEmpty else { continue }
            for (a, b, txt) in splitEvents(text: text, start: sch.newStart, end: sch.newEnd,
                                           preferred: preferred, maxLength: maxLength) {
                lines += ["\(idx)", "\(timestamp(a)) --> \(timestamp(b))"]
                if bilingual {
                    lines += [units[i].en, txt]   // 英文在上，中文在下
                } else {
                    lines += [txt]
                }
                lines.append("")
                idx += 1
            }
        }
        return lines.joined(separator: "\n")
    }

    static func splitEvents(text: String, start: Double, end: Double,
                            preferred: Int = 24, maxLength: Int = 75) -> [(Double, Double, String)] {
        let dur = end - start
        let cnt = Int(max(1, max(dur / 7.5, Double(text.count) / Double(max(8, preferred)))))
        if cnt == 1 && text.count <= maxLength { return [(start, end, text)] }

        // 优先按标点切
        var cuts: [Int] = []
        var searchStart = text.startIndex
        while let r = text.range(of: #"[^，。！？；、]*[，。！？；、]"#, options: .regularExpression, range: searchStart..<text.endIndex) {
            cuts.append(text.distance(from: text.startIndex, to: r.upperBound))
            searchStart = r.upperBound
        }
        if cuts.count < cnt - 1 {
            let step = Double(text.count) / Double(cnt)
            cuts = (1..<cnt).map { Int(step * Double($0)) }
        }
        cuts = Array(Set(cuts)).sorted().prefix(cnt - 1).map { $0 }

        var parts: [String] = []
        var prev = 0
        for c in cuts {
            let a = text.index(text.startIndex, offsetBy: min(c, text.count))
            parts.append(String(text[text.index(text.startIndex, offsetBy: prev)..<a]))
            prev = min(c, text.count)
        }
        parts.append(String(text[text.index(text.startIndex, offsetBy: prev)...]))
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [(start, end, text)] }

        // Netflix 单行上限：仍超长的部分按字符数二分续切
        var events: [(Double, Double, String)] = []
        var t = start
        for (k, p) in parts.enumerated() {
            let e = (k == parts.count - 1) ? end : t + (end - start) * Double(p.count) / Double(total)
            if p.count > maxLength, e > t + 0.4 {
                events.append(contentsOf: hardSplit(p, from: t, to: e, maxLength: maxLength))
            } else {
                events.append((t, e, p))
            }
            t = e
        }
        return events
    }

    /// 超长行硬切：按接近等分的标点/字数边界拆为多条
    static func hardSplit(_ text: String, from start: Double, to end: Double,
                          maxLength: Int) -> [(Double, Double, String)] {
        let pieces = max(2, Int(ceil(Double(text.count) / Double(maxLength))))
        let step = Double(text.count) / Double(pieces)
        var cuts: [Int] = (1..<pieces).map { Int(step * Double($0)) }
        // 尽量落在标点上
        cuts = cuts.map { c -> Int in
            let window = max(0, c - 6)..<min(text.count, c + 6)
            if let r = text.range(of: #"[，。！？；、]"#, options: .regularExpression, range: text.index(text.startIndex, offsetBy: window.lowerBound)..<text.index(text.startIndex, offsetBy: window.upperBound)) {
                return text.distance(from: text.startIndex, to: r.upperBound)
            }
            return c
        }
        var parts: [String] = []
        var prev = 0
        for c in cuts {
            let a = text.index(text.startIndex, offsetBy: min(max(prev + 1, c), text.count))
            parts.append(String(text[text.index(text.startIndex, offsetBy: prev)..<a]))
            prev = min(max(prev + 1, c), text.count)
        }
        parts.append(String(text[text.index(text.startIndex, offsetBy: prev)...]))
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let total = parts.reduce(0) { $0 + $1.count }
        guard total > 0 else { return [(start, end, text)] }
        var events: [(Double, Double, String)] = []
        var t = start
        for (k, p) in parts.enumerated() {
            let e = (k == parts.count - 1) ? end : t + (end - start) * Double(p.count) / Double(total)
            events.append((t, e, p))
            t = e
        }
        return events
    }

    static func timestamp(_ t: Double) -> String {
        let clamped = max(0, t)
        let h = Int(clamped) / 3600
        let m = Int(clamped) % 3600 / 60
        let s = Int(clamped) % 60
        let ms = Int((clamped - Double(Int(clamped))) * 1000)
        return String(format: "%02d:%02d:%02d,%03d", h, m, s, ms)
    }
}
