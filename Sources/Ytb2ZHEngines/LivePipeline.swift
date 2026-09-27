import Foundation
import Ytb2ZHCore

// MARK: - 实时直播管线（追赶式渐进播放）
//
// 与批量 Pipeline 的关系：下载/转录/切分仍全篇执行（保证语义切分质量，产物互通）；
// 翻译 → 合成 → 调度 → 配音轨 → 分片按 ~60s 语音窗口滚动推进，每窗口产出一个
// MPEG-TS 分片并追加进 EVENT 型 HLS 播放列表，AVPlayer 以"伪直播"形式消费。
// 处理速度约 4x 实时，播放始终落后于处理边缘，seek 只能进入已配音区间。
//
// 播放侧不经过网络：GUI 用 AVAssetResourceLoaderDelegate 直接读本目录文件，
// 本目录同时保留 CLI 可直接访问的 live.m3u8 / segNNN.ts。

public enum LiveEvent: Sendable {
    case phase(String, Double, String?)              // (阶段标题, 0-1 进度, 明细)
    case log(String)
    case srtUpdated(URL)                             // 字幕文件已更新（每窗口重写全量）
    case readyToPlay(token: String)                  // 首个分片就绪，可开播
    case sourceReady(URL)                            // 原片就绪（原声模式下载完成，可直接播放）
    case streamed(dubbedSeconds: Double, totalSeconds: Double)
    case finished(finalVideo: URL, srt: URL)
    case failed(String)
}

public struct LiveSegment: Sendable {
    public let name: String
    public let duration: Double
    public init(name: String, duration: Double) {
        self.name = name; self.duration = duration
    }
}

public struct LivePipeline: Sendable {
    public init() {}

    /// 执行一次直播会话。jobDir 与批量任务同构（断点续跑互通：words/units/clauses 缓存复用）。
    public func run(url: String, profile: Profile, jobID: String,
                    store: JobStore = JobStore(),
                    events: AsyncStream<LiveEvent>.Continuation) async throws {
        let engines = try EngineAssembly.engineSet(for: profile)
        let fm = FileManager.default
        let jobDir = store.jobDir(id: jobID)
        try fm.createDirectory(at: jobDir, withIntermediateDirectories: true)
        let liveDir = jobDir.appendingPathComponent("live", isDirectory: true)
        try fm.createDirectory(at: liveDir, withIntermediateDirectories: true)

        @Sendable func emit(_ e: LiveEvent) { events.yield(e) }

        do {
            // —— 阶段一：下载（复用 job 已有原片：source.mp4 优先，否则 webm/mkv/mov/m4v 等）
            var source = store.existingSource(jobID) ?? store.source(jobID)
            if !fm.fileExists(atPath: source.path) {
                emit(.phase("下载", 0, nil))
                source = try await engines.downloader.download(
                    url: url, to: store.source(jobID), options: profile.download) { p, msg in
                        emit(.phase("下载", p, msg))
                }
            }
            let totalDuration = ffprobeDuration(source) ?? 0

            // —— 转录（全篇；本地 whisper 约 10x 实时）
            var words: [TimedWord]
            if let cached = store.readJSON(store.wordsJSON(jobID), as: [TimedWord].self) {
                words = cached
            } else {
                emit(.phase("转录", 0, nil))
                words = try await engines.transcriber.transcribe(
                    video: source, workDir: jobDir, options: profile.transcribe) { p, msg in
                        emit(.phase("转录", p, msg))
                }
                try store.writeJSON(words, to: store.wordsJSON(jobID))
            }
            guard !words.isEmpty else { throw EngineError.engineFailure("转录结果为空") }

            // —— 语义切分（全篇：句边界需要全篇上下文，不做窗口化）
            var units: [SpeechUnit]
            if let cached = store.readJSON(store.unitsJSON(jobID), as: [SpeechUnit].self) {
                units = cached
            } else {
                emit(.phase("语义切分", 0.9, nil))
                units = engines.segmenter.segment(words: words, options: profile.segmentation)
                try store.writeJSON(units, to: store.unitsJSON(jobID))
            }
            guard !units.isEmpty else { throw EngineError.engineFailure("未切分出语音单元") }

            // —— 术语（可选；与批量管线同一份 terminology.json，含领域语境+术语）
            var translateOptions = profile.translate
            if profile.translate.useTerminology, let terminologist = engines.terminologist {
                let termPath = store.terminologyJSON(jobID)
                var doc = TerminologyExtraction.load(from: termPath)
                if doc?.hasContent != true {
                    emit(.phase("术语提取", 0, nil))
                    if let extracted = try? await terminologist.extractTerms(
                        units: units, options: profile.terminology) { _, _ in } {
                        doc = extracted
                        try? store.writeJSON(extracted, to: termPath)
                    }
                }
                let terms = doc?.terms ?? []
                translateOptions.terminology = terms.isEmpty ? nil : terms
                translateOptions.domain = doc?.domain
            }

            emit(.phase("实时配音", 0, "共 \(units.count) 个语音单元，约 \(Self.planWindows(units: units).count) 个窗口"))

            // —— 全量译文缓存（断点续播 / 与批量任务 translated.json 互通）
            // 无缓存时用空译文预分配（与 units 等长），窗口翻译按下标回填——
            // 直接从 [] 起步会让 translatedAll[idx] = 越界崩溃（全新任务必崩）
            var translatedAll: [SpeechUnit] = {
                if let cached = store.readJSON(store.translatedJSON(jobID), as: [SpeechUnit].self),
                   cached.count == units.count { return cached }
                return units.map { u in var c = u; c.zh = ""; return c }
            }()
            let translateAllCached = !translatedAll.contains { $0.zh.isEmpty }

            // —— 窗口循环
            let windows = Self.planWindows(units: units)
            let clauseCacheDir = store.clauseCache(jobID)
            try fm.createDirectory(at: clauseCacheDir, withIntermediateDirectories: true)
            let splitter = ClauseTextSplitter()

            var placements: [Placement] = []
            var unitSchedules: [UnitSchedule] = []
            var segDurations: [LiveSegment] = []
            var globalPrevEnd = 0.0
            var segStart = 0.0
            var segIndex = 0
            var targetDuration = 0

            for (w, range) in windows.enumerated() {
                try Task.checkCancellation()

                // 1) 翻译：携带上一窗口末尾 3 条做上下文前缀（前缀的翻译结果丢弃）
                if !translateAllCached {
                    let ctxCount = min(3, range.lowerBound)
                    var batch = Array(translatedAll[(range.lowerBound - ctxCount)..<range.lowerBound])
                        + Array(units[range])
                    let out = try await engines.translator.translate(
                        units: batch, options: translateOptions) { p, msg in
                            emit(.phase("实时配音", Double(w) / Double(windows.count) * 0.4,
                                        "翻译 窗口\(w + 1)/\(windows.count)"))
                        }
                    let win = Array(out.suffix(range.count))
                    for (k, idx) in range.enumerated() {
                        // LLM 偶发少条：缺位回退原英文单元，绝不下标越界
                        translatedAll[idx] = k < win.count ? win[k] : units[idx]
                    }
                    try store.writeJSON(translatedAll, to: store.translatedJSON(jobID))
                }
                let winUnits = Array(translatedAll[range])

                // 2) 合成子句（子句缓存与批量管线互通；rps 并发上限；synth=none 时跳过）
                var clauseDurations: [[Double]] = []
                let synthEnabled = (profile.engines[StepID.synthesize.rawValue] ?? "bailian") != "none"
                if synthEnabled {
                    try await withThrowingTaskGroup(of: Void.self) { group in
                        var active = 0
                        for (k, unit) in winUnits.enumerated() {
                            let ui = range.lowerBound + k
                            let texts = splitter.split(unit.zh)
                            let opts: SynthOptions = {
                                var o = profile.synth
                                if let v = unit.voice, !v.isEmpty { o.voice = v }
                                return o
                            }()
                            for (ci, text) in texts.enumerated() {
                                let key = "u\(ui)_c\(ci)"
                                if cachedSynth(clauseCacheDir, key) != nil { continue }
                                if active >= max(1, profile.synth.rps) {
                                    _ = try await group.next(); active -= 1
                                }
                                active += 1
                                group.addTask { [synthesizer = engines.synthesizer] in
                                    _ = try await synthesizer.synthesize(
                                        text: text, cacheKey: key, cacheDir: clauseCacheDir, options: opts)
                                }
                            }
                        }
                        try await group.waitForAll()
                    }
                }
                // 时长统一从子句缓存回读（synthesize 落盘 + duration 伴生文件；synth=none 时为空）
                for (k, unit) in winUnits.enumerated() {
                    let ui = range.lowerBound + k
                    let texts = splitter.split(unit.zh)
                    var durs: [Double] = []
                    for ci in texts.indices {
                        let key = "u\(ui)_c\(ci)"
                        if let hit = cachedSynth(clauseCacheDir, key) { durs.append(hit.duration) }
                    }
                    clauseDurations.append(durs)
                }

                // 3) 调度：窗口内独立漂移调度（绝对时间落位），再整体平移防止与上一窗口重叠
                var plan = engines.scheduler.schedule(
                    units: winUnits, clauseDurations: clauseDurations, options: profile.schedule)
                if let first = plan.placements.first,
                   first.at < globalPrevEnd + profile.schedule.unitGap {
                    let delta = globalPrevEnd + profile.schedule.unitGap - first.at
                    plan.placements = plan.placements.map { p in
                        var q = p; q.at += delta; return q
                    }
                    plan.unitSchedules = plan.unitSchedules.map { s in
                        var t = s; t.newStart += delta; t.newEnd += delta; return t
                    }
                }
                globalPrevEnd = plan.unitSchedules.last?.newEnd ?? globalPrevEnd

                // 4) 分片时间轴：起点 = 上一分片终点；终点 ≥ 最后落位终点 + 余量（配音不被截断）
                let winEndNatural: Double
                if range.upperBound < units.count {
                    winEndNatural = units[range.upperBound].start
                } else {
                    winEndNatural = totalDuration > 0 ? totalDuration : (units.last?.end ?? segStart + 1)
                }
                let segEnd = max(winEndNatural, globalPrevEnd + 0.3)
                let segDur = max(1.0, segEnd - segStart)

                // 5) 配音轨（相对 segStart 铺设；无落位则不产出）
                let dubWav = liveDir.appendingPathComponent(String(format: "dub_%03d.wav", segIndex))
                try Self.buildDubTrack(placements: plan.placements, cacheDir: clauseCacheDir,
                                       segStart: segStart, segIndex: segIndex, output: dubWav)

                // 6) 分片：视频转码保证精确切点；有配音则替换音轨
                let segTS = liveDir.appendingPathComponent(String(format: "seg%03d.ts", segIndex))
                var args = ["-y", "-v", "error",
                            "-ss", String(format: "%.3f", segStart),
                            "-t", String(format: "%.3f", segDur),
                            "-i", source.path]
                if fm.fileExists(atPath: dubWav.path) && !plan.placements.isEmpty {
                    args += ["-i", dubWav.path,
                             "-map", "0:v:0", "-map", "1:a:0",
                             "-filter:a", String(format: "volume=%.1fdB,alimiter=limit=0.95", profile.compose.dubGainDB)]
                } else {
                    args += ["-map", "0"]
                }
                args += ["-c:v", "libx264", "-preset", profile.compose.preset, "-crf", String(profile.compose.crf),
                         "-c:a", "aac", "-b:a", "192k", "-avoid_negative_ts", "make_zero", segTS.path]
                try runFFmpeg(args)
                let actual = ffprobeDuration(segTS) ?? segDur
                targetDuration = max(targetDuration, Int(actual.rounded(.up)))

                // 7) playlist 追加（每次全量重写，播放端重读即可见新分片）
                placements += plan.placements
                unitSchedules += plan.unitSchedules
                segDurations.append(LiveSegment(name: segTS.lastPathComponent, duration: actual))
                try Self.playlistText(segments: segDurations, target: targetDuration, endlist: false)
                    .write(to: liveDir.appendingPathComponent("live.m3u8"), atomically: true, encoding: .utf8)

                let dubbed = min(segEnd, totalDuration > 0 ? totalDuration : segEnd)
                emit(.streamed(dubbedSeconds: dubbed, totalSeconds: totalDuration))

                // 8) 增量字幕：每窗口重写全量 SRT（已处理区间立即呈现）
                let srtPath = store.subtitles(jobID)
                try SRTBuilder.build(units: translatedAll, unitSchedules: unitSchedules,
                                     maxLength: profile.compose.subtitleMaxLength,
                                     perLineBias: profile.compose.subtitleTargetMultiplier,
                                     bilingual: profile.compose.bilingualSubtitles)
                    .write(to: srtPath, atomically: true, encoding: .utf8)
                emit(.srtUpdated(srtPath))

                if segIndex == 0 {
                    let token = LiveMediaStore.shared.register(dir: liveDir)
                    emit(.readyToPlay(token: token))
                }
                emit(.log("窗口 \(w + 1)/\(windows.count) 已就绪（\(String(format: "%.0f", dubbed))s / \(String(format: "%.0f", totalDuration))s）"))

                segStart = segEnd
                segIndex += 1
            }

            // —— 终局：ENDLIST + SRT + concat 成片
            try Self.playlistText(segments: segDurations, target: targetDuration, endlist: true)
                .write(to: liveDir.appendingPathComponent("live.m3u8"), atomically: true, encoding: .utf8)

            let srt = store.subtitles(jobID)
            try SRTBuilder.build(units: translatedAll, unitSchedules: unitSchedules,
                                 maxLength: profile.compose.subtitleMaxLength,
                                 perLineBias: profile.compose.subtitleTargetMultiplier,
                                 bilingual: profile.compose.bilingualSubtitles)
                .write(to: srt, atomically: true, encoding: .utf8)

            let listFile = liveDir.appendingPathComponent("final_list.txt")
            let concatLines = segDurations.map { "file '\(liveDir.appendingPathComponent($0.name).path)'" }
            try concatLines.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)
            let final = store.finalVideo(jobID)
            try runFFmpeg(["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", listFile.path,
                           "-c", "copy", "-movflags", "+faststart", final.path])

            emit(.finished(finalVideo: final, srt: srt))
        } catch {
            emit(.failed(error.localizedDescription))
            throw error
        }
    }

    // MARK: 窗口划分（纯函数，供测试）

    /// 按目标窗长把语音单元切成连续窗口；单元不跨窗，超长单元独立成窗
    public static func planWindows(units: [SpeechUnit], target: Double = 60.0) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var i = 0
        while i < units.count {
            let ws = units[i].start
            var j = i
            while j < units.count, units[j].end - ws <= target { j += 1 }
            if j == i { j = i + 1 }   // 单个单元超长也必须收窗
            ranges.append(i..<j)
            i = j
        }
        return ranges
    }

    // MARK: HLS playlist 文本（纯函数，供测试）

    public static func playlistText(segments: [LiveSegment], target: Int, endlist: Bool) -> String {
        var lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-PLAYLIST-TYPE:EVENT",
                     "#EXT-X-TARGETDURATION:\(max(1, target))", "#EXT-X-MEDIA-SEQUENCE:0"]
        for s in segments {
            lines.append("#EXTINF:\(String(format: "%.3f", s.duration)),")
            lines.append(s.name)
        }
        if endlist { lines.append("#EXT-X-ENDLIST") }
        return lines.joined(separator: "\n")
    }

    // MARK: 配音轨装配（与 FFmpegComposeEngine 同构，但锚定 segStart）

    static func buildDubTrack(placements: [Placement], cacheDir: URL,
                              segStart: Double, segIndex: Int, output: URL) throws {
        let fm = FileManager.default
        let workDir = output.deletingLastPathComponent()
        var lines: [String] = []
        var cursor = segStart
        var index = 0
        for pl in placements.sorted(by: { $0.at < $1.at }) {
            let src = cacheDir.appendingPathComponent("u\(pl.unitIndex)_c\(pl.clauseIndex).mp3")
            guard fm.fileExists(atPath: src.path) else { continue }
            let lead = max(0, pl.at - cursor)
            if lead > 0.02 {
                let sil = workDir.appendingPathComponent(String(format: "sil_%03d_%04d.wav", segIndex, index))
                try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                               "-i", "anullsrc=r=24000:cl=mono", "-t", String(format: "%.3f", lead),
                               sil.path])
                lines.append("file '\(sil.path)'")
            }
            let seg = workDir.appendingPathComponent(String(format: "voice_%03d_%04d.wav", segIndex, index))
            if abs(pl.atempo - 1.0) < 0.015 {
                try runFFmpeg(["-y", "-v", "error", "-i", src.path,
                               "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", seg.path])
            } else {
                try runFFmpeg(["-y", "-v", "error", "-i", src.path,
                               "-filter:a", String(format: "atempo=%.4f", pl.atempo),
                               "-ar", "24000", "-ac", "1", "-c:a", "pcm_s16le", seg.path])
            }
            lines.append("file '\(seg.path)'")
            cursor = max(cursor, pl.at + pl.duration)
            index += 1
        }
        guard !lines.isEmpty else { return }
        let list = workDir.appendingPathComponent(String(format: "dub_%03d.txt", segIndex))
        try lines.joined(separator: "\n").write(to: list, atomically: true, encoding: .utf8)
        try runFFmpeg(["-y", "-v", "error", "-f", "concat", "-safe", "0", "-i", list.path,
                       "-c:a", "pcm_s16le", output.path])
    }
}

// MARK: - 播放媒体注册表：token → 分片目录（本地 LiveHTTPServer 供片给 AVPlayer）

public final class LiveMediaStore: @unchecked Sendable {
    public static let shared = LiveMediaStore()
    private var dirs: [String: URL] = [:]
    private let lock = NSLock()
    private init() {}

    public func register(dir: URL) -> String {
        lock.lock(); defer { lock.unlock() }
        let token = String(UUID().uuidString.prefix(8)).lowercased()
        dirs[token] = dir
        return token
    }

    public func dir(for token: String) -> URL? {
        lock.lock(); defer { lock.unlock() }
        return dirs[token]
    }
}
