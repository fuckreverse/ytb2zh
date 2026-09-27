import Foundation

// MARK: - Pipeline：把七步串起来。引擎通过 inject 传入（依赖倒置），
// 执行器只认识协议；任何一步失败保留现场，下次从产物齐全的步继续。

// 出生在 Core 但依赖具体引擎的装配放在 Engines 层的 EngineAssembly。
public struct EngineSet: Sendable {
    public let downloader: any DownloadEngine
    public let transcriber: any TranscribeEngine
    public let segmenter: any SegmentationEngine
    public let translator: any TranslateEngine
    public let synthesizer: any SpeechSynthesisEngine
    public let scheduler: any SchedulerEngine
    public let composer: any CompositionEngine
    /// 可选步：nil = 未启用（separate / summarize 选 none 时不传）
    public let separator: (any VocalSeparationEngine)?
    public let terminologist: (any TerminologyEngine)?

    public init(downloader: any DownloadEngine, transcriber: any TranscribeEngine,
                segmenter: any SegmentationEngine, translator: any TranslateEngine,
                synthesizer: any SpeechSynthesisEngine, scheduler: any SchedulerEngine,
                composer: any CompositionEngine,
                separator: (any VocalSeparationEngine)? = nil,
                terminologist: (any TerminologyEngine)? = nil) {
        self.downloader = downloader; self.transcriber = transcriber; self.segmenter = segmenter
        self.translator = translator; self.synthesizer = synthesizer
        self.scheduler = scheduler; self.composer = composer
        self.separator = separator; self.terminologist = terminologist
    }
}

public final class Pipeline: Sendable {
    private let engines: EngineSet
    private let store: JobStore
    private let events: AsyncStream<PipelineEvent>.Continuation

    public init(engines: EngineSet, store: JobStore = JobStore(),
                events: AsyncStream<PipelineEvent>.Continuation) {
        self.engines = engines
        self.store = store
        self.events = events
    }

    private func emit(_ e: PipelineEvent) { events.yield(e) }

    /// 执行任务；已 done 且产物齐全的步骤自动跳过（断点续跑）。
    /// stepFilter 非空时只执行指定步骤（增量重跑，如只重排调度）。
    public func run(videoURL providedVideo: URL?,
                    url: String, profile: Profile, jobID: String,
                    stepFilter: Set<StepID> = []) async throws -> URL {
        let ctx = PipelineContext(jobDir: store.jobDir(id: jobID), profile: profile)
        var video = providedVideo ?? store.source(jobID)

        func shouldRun(_ s: StepID) -> Bool {
            stepFilter.isEmpty || stepFilter.contains(s)
        }

        // 1. 下载
        if shouldRun(.download) {
            if let providedVideo {
                try? FileManager.default.copyItem(at: providedVideo, to: store.source(jobID))
            } else {
                emit(.stepStarted(.download))
                store.setStep(jobID, .download, .running)
                do {
                    video = try await engines.downloader.download(
                        url: url, to: store.source(jobID), options: profile.download) { [weak self] p, msg in
                            self?.emit(.progress(.download, p, msg)) }
                    store.setStep(jobID, .download, .done)
                    emit(.stepFinished(.download, ["video": video.path]))
                } catch {
                    store.setStep(jobID, .download, .failed)
                    emit(.failed(.download, error.localizedDescription)); throw error
                }
            }
        }

        // 2. 人声分离（可选：供转录提质 + BGM 混入；失败降级用原音轨）
        var audioForTranscribe = video
        if shouldRun(.separate), let separator = engines.separator,
           profile.engines[StepID.separate.rawValue] != "none" {
            let vocals = store.vocalsWav(jobID)
            let instrumental = store.instrumentalWav(jobID)
            let fm = FileManager.default
            let cached = fm.fileExists(atPath: vocals.path) && fm.fileExists(atPath: instrumental.path)
            if !cached || stepFilter.contains(.separate) {
                emit(.stepStarted(.separate)); store.setStep(jobID, .separate, .running)
                do {
                    let res = try await separator.separate(
                        video: video, workDir: ctx.jobDir, options: profile.separate) { [weak self] p, msg in
                            self?.emit(.progress(.separate, p, msg)) }
                    store.setStep(jobID, .separate, .done)
                    emit(.stepFinished(.separate, ["vocals": res.vocals.path]))
                } catch {
                    // 降级：不阻断流水线
                    store.setStep(jobID, .separate, .failed)
                    emit(.log("人声分离失败，改用原音轨：\(error.localizedDescription)"))
                }
            }
            if FileManager.default.fileExists(atPath: vocals.path) { audioForTranscribe = vocals }
        }

        // 3. 转录
        var words: [TimedWord] = []
        if shouldRun(.transcribe) {
            if let cached = store.readJSON(store.wordsJSON(jobID), as: [TimedWord].self),
               !stepFilter.contains(.transcribe) {
                words = cached
            } else {
                emit(.stepStarted(.transcribe)); store.setStep(jobID, .transcribe, .running)
                do {
                    words = try await engines.transcriber.transcribe(
                        video: audioForTranscribe, workDir: ctx.jobDir, options: profile.transcribe) { [weak self] p, msg in
                            self?.emit(.progress(.transcribe, p, msg)) }
                    try store.writeJSON(words, to: store.wordsJSON(jobID))
                    store.setStep(jobID, .transcribe, .done)
                    emit(.stepFinished(.transcribe, ["words": String(words.count)]))
                } catch {
                    store.setStep(jobID, .transcribe, .failed)
                    emit(.failed(.transcribe, error.localizedDescription)); throw error
                }
            }
        } else {
            words = store.readJSON(store.wordsJSON(jobID), as: [TimedWord].self) ?? []
        }

        // 3. 语义切分
        var units: [SpeechUnit] = []
        if shouldRun(.segment) {
            if let cached = store.readJSON(store.unitsJSON(jobID), as: [SpeechUnit].self),
               !stepFilter.contains(.segment) {
                units = cached
            } else {
                emit(.stepStarted(.segment)); store.setStep(jobID, .segment, .running)
                units = engines.segmenter.segment(words: words, options: profile.segmentation)
                try store.writeJSON(units, to: store.unitsJSON(jobID))
                store.setStep(jobID, .segment, .done)
                emit(.stepFinished(.segment, ["units": String(units.count)]))
            }
        } else {
            units = store.readJSON(store.unitsJSON(jobID), as: [SpeechUnit].self) ?? []
        }

        // 4. 术语提取（可选；产物 terminology.json 含领域语境+术语，可人工修订后重跑翻译）
        var translateOptions = profile.translate
        if profile.translate.useTerminology {
            let termPath = store.terminologyJSON(jobID)
            var doc: TerminologyExtraction?
            if let cached = TerminologyExtraction.load(from: termPath), cached.hasContent,
               !stepFilter.contains(.summarize) {
                doc = cached
            } else if shouldRun(.summarize), let terminologist = engines.terminologist,
                      profile.engines[StepID.summarize.rawValue] != "none", !units.isEmpty {
                emit(.stepStarted(.summarize)); store.setStep(jobID, .summarize, .running)
                do {
                    let extracted = try await terminologist.extractTerms(
                        units: units, options: profile.terminology) { [weak self] p, msg in
                            self?.emit(.progress(.summarize, p, msg)) }
                    try store.writeJSON(extracted, to: termPath)
                    store.setStep(jobID, .summarize, .done)
                    emit(.stepFinished(.summarize, ["terms": String(extracted.terms.count)]))
                    doc = extracted
                } catch {
                    store.setStep(jobID, .summarize, .failed)
                    emit(.log("术语提取失败，继续无术语翻译：\(error.localizedDescription)"))
                }
            }
            let terms = doc?.terms ?? []
            translateOptions.terminology = terms.isEmpty ? nil : terms
            translateOptions.domain = doc?.domain
        }

        // 5. 翻译
        if shouldRun(.translate), !units.isEmpty {
            if needTranslate(jobID: jobID, units: units, force: stepFilter.contains(.translate)) {
                emit(.stepStarted(.translate)); store.setStep(jobID, .translate, .running)
                do {
                    let source = units
                    units = try await engines.translator.translate(
                        units: source, options: translateOptions) { [weak self] p, msg in
                            self?.emit(.progress(.translate, p, msg)) }
                    try store.writeJSON(units, to: store.translatedJSON(jobID))
                    store.setStep(jobID, .translate, .done)
                    emit(.stepFinished(.translate, ["units": String(units.count)]))
                } catch {
                    store.setStep(jobID, .translate, .failed)
                    emit(.failed(.translate, error.localizedDescription)); throw error
                }
            } else if let cached = store.readJSON(store.translatedJSON(jobID), as: [SpeechUnit].self) {
                units = cached
            }
        } else if let cached = store.readJSON(store.translatedJSON(jobID), as: [SpeechUnit].self) {
            units = cached
        }

        // 6. 语音合成（子句级，带缓存；支持单元级音色覆盖）
        let clauseTexts = units.map { splitClauses($0.zh) }
        let cacheDir = store.clauseCache(jobID)
        try? FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if shouldRun(.synthesize) {
            emit(.stepStarted(.synthesize)); store.setStep(jobID, .synthesize, .running)
            do {
                var total = 0
                for (ui, unit) in units.enumerated() where !clauseTexts[ui].isEmpty {
                    let group = clauseTexts[ui]
                    let unitSynthOpts: SynthOptions = {
                        var o = profile.synth
                        if let v = unit.voice, !v.isEmpty { o.voice = v }
                        return o
                    }()
                    try await withThrowingTaskGroup(of: Void.self) { group2 in
                        var active = 0
                        for (ci, clause) in group.enumerated() {
                            let key = "u\(ui)_c\(ci)"
                            if synthCacheHit(cacheDir, key) { continue }
                            if active >= max(1, profile.synth.rps) {
                                _ = try await group2.next(); active -= 1
                            }
                            active += 1
                            group2.addTask { [synthesizer = engines.synthesizer] in
                                _ = try await synthesizer.synthesize(
                                    text: clause, cacheKey: key, cacheDir: cacheDir, options: unitSynthOpts)
                            }
                            total += 1
                            if total % 10 == 0 {
                                emit(.progress(.synthesize, Double(total) / Double(clauseTexts.reduce(0) { $0 + $1.count }), "已合成 \(total) 子句"))
                            }
                        }
                        try await group2.waitForAll()
                    }
                }
                store.setStep(jobID, .synthesize, .done)
                emit(.stepFinished(.synthesize, ["clauses": String(total)]))
            } catch {
                store.setStep(jobID, .synthesize, .failed)
                emit(.failed(.synthesize, error.localizedDescription)); throw error
            }
        }

        // 7. 调度（需要子句实际时长，先探测）
        var clauseDurations: [[Double]] = []
        for (ui, group) in clauseTexts.enumerated() {
            var ds: [Double] = []
            for ci in group.indices {
                let key = "u\(ui)_c\(ci)"
                if let hit = cachedSynth(cacheDir, key) { ds.append(hit.duration) }
            }
            clauseDurations.append(ds)
        }
        var plan = SchedulePlan.empty
        if shouldRun(.schedule) {
            emit(.stepStarted(.schedule)); store.setStep(jobID, .schedule, .running)
            plan = engines.scheduler.schedule(units: units, clauseDurations: clauseDurations,
                                              options: profile.schedule)
            try store.writeJSON(plan, to: store.planJSON(jobID))
            store.setStep(jobID, .schedule, .done)
            emit(.stepFinished(.schedule, [
                "maxLead": String(format: "%.2f", plan.maxLead),
                "wait": String(format: "%.1f", plan.interUnitWait),
            ]))
        } else {
            plan = store.readJSON(store.planJSON(jobID), as: SchedulePlan.self) ?? .empty
        }

        // 8. 合成
        if shouldRun(.compose) {
            emit(.stepStarted(.compose)); store.setStep(jobID, .compose, .running)
            do {
                let source = units
                let planCopy = plan
                let out = try await engines.composer.compose(
                    video: store.source(jobID),
                    placements: planCopy.placements,
                    unitSchedules: planCopy.unitSchedules,
                    units: source, cacheDir: cacheDir,
                    output: store.finalVideo(jobID), options: profile.compose) { [weak self] p, msg in
                        self?.emit(.progress(.compose, p, msg)) }
                store.setStep(jobID, .compose, .done)
                emit(.stepFinished(.compose, ["output": out.path]))
                return out
            } catch {
                store.setStep(jobID, .compose, .failed)
                emit(.failed(.compose, error.localizedDescription)); throw error
            }
        }
        return store.finalVideo(jobID)
    }

    private func needTranslate(jobID: String, units: [SpeechUnit], force: Bool) -> Bool {
        if force { return true }
        guard let cached = store.readJSON(store.translatedJSON(jobID), as: [SpeechUnit].self) else { return true }
        return cached.count != units.count || cached.contains { $0.zh.isEmpty } || units.contains { $0.zh.isEmpty }
    }

    // MARK: 子句切分（与调度器共用同一实现）

    private nonisolated static let sharedClauseSplitter = ClauseTextSplitter()
    nonisolated func splitClauses(_ text: String) -> [String] {
        Self.sharedClauseSplitter.split(text)
    }

    func synthCacheHit(_ dir: URL, _ key: String) -> Bool { cachedSynth(dir, key) != nil }
}

/// 子句拆分：供 Pipeline 与调度器共用
/// 目标：每条子句是一个自然的连读单元。逗号拆分本身没错，错在"拆太碎"——
/// 短句被拆成两条 TTS 片段、调度器再塞 pauseMin 停顿，听感上"一句话念成两截"。
/// 三条新规则：
///   ① 短句不拆：整条译文去标点 ≤ wholeSentenceMaxChars 时视为一句，单条 TTS 连读；
///   ② 贪心凑整：相邻子句累计 < minClauseChars 字时继续并入，避免碎句连读；
///   ③ 孤儿尾句：最后一条 < orphanTailChars 字并入前句。
public final class ClauseTextSplitter: @unchecked Sendable {
    private let separators = CharacterSet(charactersIn: "，；、")
    private let punct = CharacterSet(charactersIn: "，；、。！？…")

    /// 整条译文去标点不超过此字数 → 不拆（约 4 字/秒 ≈ 4 秒语音之内）
    static let wholeSentenceMaxChars = 16
    /// 子句合并目标长度（相邻子句累计不足此字数即并入）
    static let minClauseChars = 8
    /// 孤儿尾句判定阈值
    static let orphanTailChars = 5

    public init() {}

    public func split(_ text: String) -> [String] {
        var parts: [String] = []
        var current = ""
        for ch in text {
            current.append(ch)
            if separators.contains(ch.unicodeScalars.first!) {
                parts.append(current); current = ""
            }
        }
        if !current.isEmpty { parts.append(current) }
        parts = parts.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            return parts.isEmpty && !text.isEmpty ? [text] : parts
        }

        let punctSet = punct
        let bare = { (s: String) -> Int in s.trimmingCharacters(in: punctSet).count }

        // 规则①：短句不拆
        if parts.reduce(0, { $0 + bare($1) }) <= Self.wholeSentenceMaxChars {
            return [text]
        }

        // 规则②：贪心合并，目标每条 ≥ minClauseChars（尾条例外，交给规则③）
        var merged: [String] = []
        var acc = ""
        for p in parts {
            if acc.isEmpty { acc = p; continue }
            if bare(acc) < Self.minClauseChars {
                acc += p
            } else {
                merged.append(acc); acc = p
            }
        }
        if !acc.isEmpty { merged.append(acc) }

        // 规则③：孤儿尾句并入前句（连读更自然）
        if merged.count > 1, let tail = merged.last, bare(tail) < Self.orphanTailChars {
            merged[merged.count - 2] += tail
            merged.removeLast()
        }
        return merged.isEmpty && !text.isEmpty ? [text] : merged
    }
}


public func cachedSynth(_ dir: URL, _ key: String) -> (url: URL, duration: Double)? {
    let fm = FileManager.default
    let mp3 = dir.appendingPathComponent("\(key).mp3")
    guard fm.fileExists(atPath: mp3.path) else { return nil }
    let durPath = dir.appendingPathComponent("\(key).duration")
    var duration: Double = 0
    if let data = try? String(contentsOf: durPath, encoding: .utf8), let d = Double(data.trimmingCharacters(in: .whitespaces)) {
        duration = d
    } else {
        guard let d = ffprobeDuration(mp3) else { return nil }
        duration = d
        try? String(format: "%.3f", d).write(to: durPath, atomically: true, encoding: .utf8)
    }
    if duration < 0.35 { return nil }  // 静音占位视为未合成
    return (mp3, duration)
}

public func ffprobeDuration(_ url: URL) -> Double? {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    p.arguments = ["ffprobe", "-v", "error", "-show_entries", "format=duration",
                   "-of", "csv=p=0", url.path]
    let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { return nil }
    guard p.terminationStatus == 0,
          let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8),
          let d = Double(s.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
    return d
}
