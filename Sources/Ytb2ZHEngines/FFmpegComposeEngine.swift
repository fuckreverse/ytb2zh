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

        // 2) 配音轨（静音填充 + atempo 变速 + concat，与旁挂字幕引擎共用）
        let dubWav = try ComposeAudioTrack.assemble(placements: placements, cacheDir: cacheDir,
                                                    workDir: workDir, progress: progress)

        // 3) 成片：字幕烧录 + 音频替换（可选原声闪避/BGM 混入）
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
        let renderer = SubtitleRenderer.preferred(
            hasSubtitlesFilter: FFmpegCapabilities.hasFilter("subtitles"))

        // —— 音频链（烧录/软字幕两态共用）：配音 / 原声闪避 / BGM 混音 ——
        var filters: [String] = []
        let mapA: String
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

        var args = ["-y", "-v", "error", "-i", video.path]
        if let dubWav { args += ["-i", dubWav.path] }
        if let bgmWav { args += ["-i", bgmWav.path] }

        switch renderer {
        case .burn:
            let escapedSrt = srt.path
                .replacingOccurrences(of: "\\", with: "\\\\")
                .replacingOccurrences(of: ":", with: "\\:")
                .replacingOccurrences(of: "'", with: "\\'")
            // 字体单一书写：PingFang SC 为 macOS 内置，缺失字形由 libass 逐字形回退兜底；
            // 不写逗号回退链——旧版 libass 会把整串当作单一字体名，反而丢掉当前可用的匹配。
            let vf = "subtitles='\(escapedSrt)':force_style='FontName=PingFang SC,FontSize=\(Int(options.subtitleFontSize)),MarginV=\(Int(options.subtitleMarginV)),Outline=1'"
            filters.insert("[0:v]\(vf)[vout]", at: 0)
            args += ["-filter_complex", filters.joined(separator: ";"),
                     "-map", "[vout]", "-map", mapA,
                     "-c:v", "libx264", "-preset", options.preset, "-crf", String(options.crf),
                     "-c:a", "aac", "-b:a", "192k",
                     "-movflags", "+faststart", output.path]
            progress(0.5, "编码中（视频转码约需数分钟）")
        case .soft:
            // 缺 libass：不烧录。视频流直接 copy + mov_text 软字幕轨 + 旁挂 SRT——
            // 字幕仍然可用（播放器/外部工具可读），好过整步以 "No such filter" 失败。
            let subInput = (dubWav != nil ? 1 : 0) + (bgmWav != nil ? 1 : 0) + 1
            args += ["-i", srt.path]
            if !filters.isEmpty {
                args += ["-filter_complex", filters.joined(separator: ";")]
            }
            args += ["-map", "0:v", "-map", mapA, "-map", "\(subInput):s",
                     "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                     "-c:s", "mov_text", "-movflags", "+faststart", output.path]
            let sidecar = output.deletingPathExtension().appendingPathExtension("srt")
            try? FileManager.default.removeItem(at: sidecar)
            try? FileManager.default.copyItem(at: srt, to: sidecar)
            progress(0.5, "当前 ffmpeg 无 libass：视频不重编码，已输出软字幕轨并旁挂 SRT")
        }
        try runFFmpeg(args)
        progress(1.0, "完成")
    }
}

// MARK: - ffmpeg 滤镜能力探测（进程内缓存一次）

enum FFmpegCapabilities {
    private static let cache = Mutex<Set<String>?>(nil)

    /// ffmpeg 是否内置某滤镜（合成步据此决定字幕渲染策略）
    static func hasFilter(_ name: String) -> Bool {
        if let cached = cache.wrapped { return cached.contains(name) }
        let probed = Self.probe()
        cache.with { $0 = probed }
        return probed.contains(name)
    }

    /// 解析 `ffmpeg -filters` 输出为滤镜名集合（纯函数，便于测试）
    static func parseFilterNames(_ text: String) -> Set<String> {
        var names: Set<String> = []
        for line in text.split(separator: "\n") {
            let tokens = line.split(separator: " ")
            guard tokens.count >= 3 else { continue }
            names.insert(String(tokens[1]))
        }
        return names
    }

    private static func probe() -> Set<String> {
        guard FileManager.default.fileExists(atPath: SidecarPaths.ffmpeg) else { return [] }
        guard let r = try? ProcessRunner().run(SidecarPaths.ffmpeg, ["-hide_banner", "-filters"]),
              r.code == 0 else { return [] }
        return parseFilterNames(r.stdout)
    }
}

// MARK: - 字幕渲染策略

/// 优先 libass 烧录；ffmpeg 缺 libass 时降级为软字幕轨（mov_text）+ 旁挂 SRT。
/// 不设 drawtext 中间级：drawtext 无自动换行/ASS 样式，CJK 长行会溢出画面，
/// 且需自带 SRT 解析与转义；而「缺 libass 但有 drawtext」的环境极窄。
enum SubtitleRenderer: String, CaseIterable {
    case burn   // subtitles 滤镜硬烧（默认路径）
    case soft   // mov_text 软字幕轨 + 旁挂 SRT（降级路径）

    static func preferred(hasSubtitlesFilter: Bool) -> SubtitleRenderer {
        hasSubtitlesFilter ? .burn : .soft
    }
}

// MARK: - 配音轨装配（ffmpeg 引擎与旁挂字幕引擎共用）

enum ComposeAudioTrack {
    /// 按 plan 拼装配音轨：静音填充 + atempo 变速 + concat，返回 dub.wav 路径。
    /// progress 语义：0.05–0.35 逐段、0.45 就绪（与 ffmpeg 引擎原进度区间一致）。
    static func assemble(placements: [Placement], cacheDir: URL, workDir: URL,
                         progress: @Sendable @escaping (Double, String?) -> Void) throws -> URL {
        let fm = FileManager.default
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
                               "-filter:a", atempoChain(atempo),
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
        return dubWav
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
