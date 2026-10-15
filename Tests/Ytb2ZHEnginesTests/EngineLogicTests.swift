import XCTest
@testable import Ytb2ZHEngines
import Ytb2ZHCore

final class DriftSchedulerTests: XCTestCase {
    private let opts = ScheduleOptions()

    /// 单子句、时长富余：只扩不了停顿（n=1），慢放但不超 slowMax
    func testSlackSlowsDown() {
        let units = [SpeechUnit(start: 10, end: 20, en: "hello", zh: "你好世界")]
        let plan = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[3.0]], options: opts)
        let p = plan.placements[0]
        // ns = max(0.25, 10-1.2)=8.8, avail=20+1.2-8.8=12.4, slack=9.4 → stretch=min(1.15, 1+9.4/3)
        XCTAssertEqual(p.at, 8.8, accuracy: 0.01)
        XCTAssertEqual(p.duration, 3.0 * 1.15, accuracy: 0.01)
        XCTAssertEqual(p.atempo, 1.0 / 1.15, accuracy: 0.001)
        XCTAssertEqual(plan.unitSchedules[0].lead, 1.2, accuracy: 0.01)
    }

    /// 多子句富余：先扩停顿到 pauseMax，剩余再慢放
    func testSlackFillsPausesFirst() {
        // 长句才会被 ClauseTextSplitter 拆成 2 条子句（各≥8 字且总字数>16）
        let units = [SpeechUnit(start: 10, end: 20, en: "hello", zh: "第一条子句要凑够八个字以上，第二条子句也要凑够八个字。")]
        // 每子句 1s，可用 12.4：停顿 2 个 gap → 扩到 pauseMax=1.3，剩 12.4-2-2.6=7.8 → 慢放封顶
        let plan = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[1.0, 1.0]], options: opts)
        let ps = plan.placements
        XCTAssertEqual(ps.count, 2)
        // 第一子句慢放封顶 1.15 → 1.15s；停顿 = min(0.25+9.4/1, 1.3)=1.3
        XCTAssertEqual(ps[0].duration, 1.15, accuracy: 0.01)
        XCTAssertEqual(ps[1].at - ps[0].at - ps[0].duration, 1.3, accuracy: 0.01)
    }

    /// 时长不足：加速但不超过 fastMax，停顿压缩
    func testOverflowSpeedsUp() {
        var o = opts
        o.fastMax = 1.3
        let units = [SpeechUnit(start: 0, end: 5, en: "hello", zh: "第一条子句要凑够八个字以上，第二条子句也要凑够八个字。")]
        let plan = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[3.0, 3.0]], options: o)
        let ps = plan.placements
        // avail = 5.95，raw+pauses = 6.25 → need = 1.0593（未到 fastMax）→ 每子句 ≈ 2.83s
        XCTAssertEqual(ps[0].duration, 3.0 / (6.25 / 5.90), accuracy: 0.05)
        XCTAssertLessThanOrEqual(ps[0].duration, 3.0)
    }

    /// 连续单元：ns 受 prevEnd+unitGap 与 os-driftCap 双约束，且不落后 lagCap
    func testChainedUnits() {
        let units = [
            SpeechUnit(start: 0, end: 10, en: "a", zh: "甲"),
            SpeechUnit(start: 10.5, end: 20, en: "b", zh: "乙"),
        ]
        let plan = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[3.0], [3.0]], options: opts)
        let sch = plan.unitSchedules
        // 第二单元 ns = max(prevEnd+0.25, 10.5-1.2) = 9.3，且不落后 10.5+0.8
        XCTAssertGreaterThanOrEqual(sch[1].newStart, sch[0].newEnd + 0.25 - 0.001)
        XCTAssertEqual(sch[1].newStart, 9.3, accuracy: 0.01)
        for s in sch { XCTAssertLessThanOrEqual(s.lead, opts.driftCap + 0.001) }
    }

    /// 统计字段自洽
    func testStats() {
        let units = (0..<3).map { SpeechUnit(start: Double($0) * 10, end: Double($0) * 10 + 8, en: "u\($0)", zh: "第\($0)句") }
        let plan = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[2.0], [2.0], [2.0]], options: opts)
        XCTAssertEqual(plan.unitSchedules.count, 3)
        XCTAssertEqual(plan.maxLead, plan.unitSchedules.map(\.lead).max()!, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(plan.interUnitWait, 0)
    }

    // MARK: - 调度层叠加语速（schedule.rate：引擎不支持原生变速时的 atempo 兜底）

    /// r=1.0 恒等：与历史行为逐位一致（守护上面所有黄金断言）
    func testRateOneIsIdentity() {
        let units = [SpeechUnit(start: 10, end: 20, en: "hello", zh: "你好世界")]
        var o = opts
        o.rate = 1.0
        let p = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[3.0]], options: o).placements[0]
        XCTAssertEqual(p.duration, 3.0 * 1.15, accuracy: 1e-9)
        XCTAssertEqual(p.atempo, 1.0 / 1.15, accuracy: 1e-9)
    }

    /// 溢出场景：atempo = rate × 基线 atempo，落位时长 = 基线 / rate
    func testComposeSideRateFallbackOverflow() {
        let units = [SpeechUnit(start: 0, end: 2, en: "a", zh: "测试")]
        func plan(rate: Double) -> SchedulePlan {
            var o = opts
            o.rate = rate
            return DriftSchedulerEngine().schedule(units: units, clauseDurations: [[6.0]], options: o)
        }
        let base = plan(rate: 1.0)
        let fast = plan(rate: 1.2)
        // avail=2.95，raw=6 → need≈2.07 超 fastMax，双双钳到 1.3 → atempo 比值恰为 rate
        XCTAssertEqual(base.placements[0].atempo, 1.3, accuracy: 0.001)
        XCTAssertEqual(fast.placements[0].atempo, 1.3 * 1.2, accuracy: 0.001)
        XCTAssertEqual(fast.placements[0].duration, base.placements[0].duration / 1.2, accuracy: 0.001)
    }

    /// 富余场景：慢放封顶下 atempo = rate / slowMax
    func testComposeSideRateFallbackSlack() {
        let units = [SpeechUnit(start: 0, end: 4, en: "a", zh: "测试")]
        var o = opts
        o.rate = 0.5
        let p = DriftSchedulerEngine().schedule(units: units, clauseDurations: [[1.0]], options: o).placements[0]
        // 有效时长 2.0，avail=4.95，slack=2.95 → stretch 封顶 1.15 → atempo = 0.5/1.15（<0.5，需链式 atempo）
        XCTAssertEqual(p.atempo, 0.5 / 1.15, accuracy: 0.001)
        XCTAssertEqual(p.duration, 2.0 * 1.15, accuracy: 0.001)
    }
}

// MARK: - TTS 原生语速能力位与 atempo 链式拆分

final class TTSRateControlTests: XCTestCase {
    /// 能力位矩阵：有原生变速机制的引擎必须报告 true；none 无音频恒 false
    func testSupportsRateControlMatrix() {
        let engines: [(String, any SpeechSynthesisEngine)] = [
            ("bailian", BailianSynthEngine()),
            ("openai-tts", OpenAITTSEngine()),
            ("edge-tts", EdgeTTSEngine()),
            ("local-say", LocalSayTTSEngine()),
            ("sherpa-onnx", SherpaOnnxTTSEngine()),
        ]
        for (id, e) in engines {
            XCTAssertTrue(e.supportsRateControl, "\(id) 应支持原生语速")
        }
        XCTAssertFalse(NullSynthEngine().supportsRateControl)
    }

    /// atempo 链式拆分：单实例越界（>2.0 或 <0.5）时各段乘积保持目标倍率
    func testAtempoChain() {
        XCTAssertEqual(atempoChain(.infinity), "atempo=1.0000")
        XCTAssertEqual(atempoChain(-.infinity), "atempo=1.0000")
        XCTAssertEqual(atempoChain(.nan), "atempo=1.0000")
        XCTAssertEqual(atempoChain(1.0), "atempo=1.0000")
        XCTAssertEqual(atempoChain(1.3), "atempo=1.3000")
        XCTAssertEqual(atempoChain(2.0), "atempo=2.0000")
        XCTAssertEqual(atempoChain(0.5), "atempo=0.5000")
        // 语速 2.0 × fastMax 1.3 = 2.6 → 两段乘积 2.6
        XCTAssertEqual(atempoChain(2.6), "atempo=2.0000,atempo=1.3000")
        // 语速 0.5 × slowMax 1.15 ≈ 0.435 → 两段乘积 ≈0.435
        XCTAssertEqual(atempoChain(0.5 / 1.15), "atempo=0.5000,atempo=0.8696")
    }
}

final class PunctSegmentationTests: XCTestCase {
    func testHardPunctuationAlwaysEnds() {
        let words = [
            TimedWord(start: 0, end: 0.5, text: "This"),
            TimedWord(start: 0.5, end: 1.0, text: "works."),
            TimedWord(start: 1.0, end: 1.5, text: "Next"),
            TimedWord(start: 1.5, end: 2.0, text: "one?"),
        ]
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0].en, "This works.")
    }

    func testSoftOnlyAfterWindow() {
        let words = [
            TimedWord(start: 0, end: 1, text: "part"),
            TimedWord(start: 1, end: 2, text: "one,"),   // 累计 2s < 7 → 不收
            TimedWord(start: 2, end: 6, text: "part"),
            TimedWord(start: 6, end: 7.5, text: "two,"), // 累计 7.5 ≥ 7 → 收
        ]
        let units = PunctSegmentationEngine().segment(words: words, options: .init(softWindow: 7.0, hardWindow: 13.0))
        XCTAssertEqual(units.count, 1)
        XCTAssertTrue(units[0].en.hasSuffix("two,"))
    }

    func testForceAtHardWindow() {
        var words: [TimedWord] = []
        for k in 0..<15 {
            words.append(TimedWord(start: Double(k), end: Double(k) + 1, text: "w\(k)"))
        }
        let units = PunctSegmentationEngine().segment(words: words, options: .init(softWindow: 7, hardWindow: 13))
        XCTAssertTrue(units[0].en.contains("w12"))
    }

    func testFiltersWhisperTokens() {
        let words = [TimedWord(start: 0, end: 1, text: "[_BEG_]"), TimedWord(start: 1, end: 2, text: "ok.")]
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].en, "ok.")
    }

    // MARK: 句界消歧（防止一句话被切成两条）

    /// 缩写句点不收：Dr./U.S. 等不在句子中间断开
    func testAbbreviationDoesNotCut() {
        let words = [
            TimedWord(start: 0, end: 0.5, text: " Meet"),
            TimedWord(start: 0.5, end: 1.0, text: " Dr."),
            TimedWord(start: 1.0, end: 1.5, text: " Smith"),
            TimedWord(start: 1.5, end: 2.0, text: " at"),
            TimedWord(start: 2.0, end: 2.5, text: " the"),
            TimedWord(start: 2.5, end: 3.0, text: " U.S."),
            TimedWord(start: 3.0, end: 3.5, text: " lab."),
        ]
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        XCTAssertEqual(units.count, 1)
        XCTAssertTrue(units[0].en.contains("Smith"))
        XCTAssertTrue(units[0].en.contains("U.S."))
    }

    /// 句点后下个词小写 → 不是句末（whisper 标点错位 / 编号列表）
    func testLowercaseAfterPeriodNotBoundary() {
        let words = [
            TimedWord(start: 0, end: 0.5, text: " It"),
            TimedWord(start: 0.5, end: 1.0, text: " never"),
            TimedWord(start: 1.0, end: 1.5, text: " stops."),
            TimedWord(start: 1.5, end: 2.0, text: " it"),
            TimedWord(start: 2.0, end: 2.5, text: " keeps"),
            TimedWord(start: 2.5, end: 3.0, text: " going."),
        ]
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        XCTAssertEqual(units.count, 1)   // "stops." 后接小写 "it" → 不收，整句一条
    }

    /// 硬切（无标点 13s 强制收）后与下一单元合并
    func testHardCutMergesWithNext() {
        var words: [TimedWord] = []
        for k in 0..<16 { words.append(TimedWord(start: Double(k), end: Double(k) + 1, text: " w\(k)")) }
        words.append(TimedWord(start: 16, end: 16.5, text: " done."))
        // w12 处累计 13s 无标点 → 硬切出第 1 条（0~13s，无终止标点），
        // 第 2 条 w13~done.（13~16.5s）；合并趟把两条合回一句（16.5 ≤ cap 19.5）
        let units = PunctSegmentationEngine().segment(words: words, options: .init(softWindow: 7, hardWindow: 13))
        XCTAssertEqual(units.count, 1)
        XCTAssertTrue(units[0].en.hasSuffix("done."))
    }

    /// 逗号软收是设计内切分，不被合并趟吃掉
    func testCommaSoftCutNotMerged() {
        var words: [TimedWord] = []
        for k in 0..<6 { words.append(TimedWord(start: Double(k), end: Double(k) + 1, text: " w\(k)")) }
        words.append(TimedWord(start: 6, end: 7, text: " part,"))
        words.append(TimedWord(start: 7, end: 8, text: " two"))
        words.append(TimedWord(start: 8, end: 9, text: " done."))
        let units = PunctSegmentationEngine().segment(words: words, options: .init(softWindow: 7, hardWindow: 13))
        XCTAssertEqual(units.count, 2)   // 逗号处收句 → 两条；合并趟不得把它们合回去
        XCTAssertTrue(units[0].en.hasSuffix("part,"))
    }

    /// isSentenceBoundary 单测：缩写白名单 / 内部句点 / 纯数字 / 问叹号
    func testIsSentenceBoundary() {
        // 问叹号永远句末
        XCTAssertTrue(PunctSegmentationEngine.isSentenceBoundary("stop?", next: "And"))
        XCTAssertTrue(PunctSegmentationEngine.isSentenceBoundary("great!", next: nil))
        // 缩写
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("Dr.", next: "Smith"))
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("e.g.", next: "GPUs"))
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("etc.", next: "Also"))
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("vs.", next: "Windows"))
        // 纯数字编号 / 单字母
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("3.", next: "Run"))
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("J.", next: "Smith"))
        // 正常句末
        XCTAssertTrue(PunctSegmentationEngine.isSentenceBoundary("works.", next: "Next"))
        XCTAssertTrue(PunctSegmentationEngine.isSentenceBoundary("works.", next: nil))
        // 句点后小写 → 不收
        XCTAssertFalse(PunctSegmentationEngine.isSentenceBoundary("stops.", next: "it"))
    }
}

final class SRTAndClauseTests: XCTestCase {
    func testSRTTimestamps() {
        XCTAssertEqual(SRTBuilder.timestamp(3661.5), "01:01:01,500")
        XCTAssertEqual(SRTBuilder.timestamp(0), "00:00:00,000")
    }

    func testSRTLongUnitSplit() {
        let units = [SpeechUnit(start: 0, end: 20, en: "x", zh: "这是一个很长的句子，有很多内容，需要拆分成多条，字幕显示，才不会太长。")]
        let sch = [UnitSchedule(unitIndex: 0, originalStart: 0, originalEnd: 20, newStart: 0, newEnd: 20, lead: 0)]
        let srt = SRTBuilder.build(units: units, unitSchedules: sch)
        XCTAssertGreaterThan(srt.split(separator: "\n\n").count, 1)
        XCTAssertTrue(srt.contains("-->"))
    }

    func testClauseSplitterMergesShort() {
        let parts = ClauseTextSplitter().split("好，那我们接着看，下面这个例子说的是，LLM 的漏洞")
        // "好，" 与 "那我们接着看，" 均过短 → 并入
        XCTAssertTrue(parts[0].hasPrefix("好，"))
        XCTAssertGreaterThanOrEqual(parts.count, 2)
    }
}

final class SRTImportTests: XCTestCase {
    func testSRTParser() {
        let srt = """
        1
        00:00:01,000 --> 00:00:03,500
        Hello world.

        2
        00:00:04,000 --> 00:00:06,000
        Second line
        second part
        """
        let cues = SRTParser.parse(srt)
        XCTAssertEqual(cues.count, 2)
        XCTAssertEqual(cues[0].start, 1.0, accuracy: 0.001)
        XCTAssertEqual(cues[0].end, 3.5, accuracy: 0.001)
        XCTAssertEqual(cues[0].text, "Hello world.")
        XCTAssertTrue(cues[1].text.contains("second part"))
    }

    func testSRTTokenize() {
        let tokens = SrtTranscribeEngine.tokenize("Hello, LLM world")
        XCTAssertEqual(tokens.map(\.text), ["Hello,", "LLM", "world"])
        let cjk = SrtTranscribeEngine.tokenize("你好世界")
        XCTAssertEqual(cjk.count, 4)
    }

    /// SRT 导入：词流时间铺满 cue 时长，下游 punct 可照常工作
    func testSrtTranscribeEngine() async throws {
        let srt = """
        1
        00:00:00,000 --> 00:00:04,000
        This is the first sentence, and it is long enough.

        2
        00:00:04,500 --> 00:00:08,000
        Second sentence comes right after, you see.
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-srt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let srtURL = dir.appendingPathComponent("test.srt")
        try srt.write(to: srtURL, atomically: true, encoding: .utf8)

        var opts = TranscribeOptions()
        opts.srtPath = srtURL.path
        let words = try await SrtTranscribeEngine().transcribe(
            video: URL(fileURLWithPath: "/dev/null"), workDir: dir, options: opts) { _, _ in }
        XCTAssertFalse(words.isEmpty)
        // 词流覆盖 cue 时段：首词起点 ≈ 0，末词终点 ≤ 8.0
        XCTAssertLessThanOrEqual(words.last!.end, 8.001)
        XCTAssertGreaterThanOrEqual(words.first!.start, 0)

        // 词流可走 punct 切分
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        XCTAssertFalse(units.isEmpty)
        try? FileManager.default.removeItem(at: dir)
    }

    func testSmartDownloadLocalFile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-dl-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let src = dir.appendingPathComponent("in.mp4")
        try Data([0x1]).write(to: src)
        let dest = dir.appendingPathComponent("source.mp4")
        let out = try await SmartDownloadEngine().download(
            url: src.path, to: dest, options: DownloadOptions()) { _, _ in }
        XCTAssertEqual(out, dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        try? FileManager.default.removeItem(at: dir)
    }
}

final class NetflixSubtitleTests: XCTestCase {
    let units = [SpeechUnit(start: 0, end: 20, en: "The original line",
                            zh: "这是一个特别特别长的句子它中间没有任何标点符号所以只能靠字数硬切保证每行都不超过上限值")]
    let sch = [UnitSchedule(unitIndex: 0, originalStart: 0, originalEnd: 20,
                            newStart: 0, newEnd: 20, lead: 0)]

    func testMaxLengthHardSplit() {
        let srt = SRTBuilder.build(units: units, unitSchedules: sch, maxLength: 20, perLineBias: 1.2)
        // 每条字幕行不超过 maxLength
        let body = srt.components(separatedBy: "\n\n").filter { !$0.isEmpty }
        XCTAssertGreaterThan(body.count, 1)
        for block in body {
            let lines = block.components(separatedBy: "\n")
            let text = lines.dropFirst(2).joined()
            XCTAssertLessThanOrEqual(text.count, 20, "行超长：\(text)")
        }
    }

    func testBilingualMode() {
        let srt = SRTBuilder.build(units: units, unitSchedules: sch, bilingual: true)
        XCTAssertTrue(srt.contains("The original line"))
        XCTAssertTrue(srt.contains("这是一个"))
    }

    func testPerLineBiasSplitsSooner() {
        let tight = SRTBuilder.build(units: units, unitSchedules: sch, maxLength: 75, perLineBias: 2.0)
        let loose = SRTBuilder.build(units: units, unitSchedules: sch, maxLength: 75, perLineBias: 1.0)
        let countTight = tight.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count
        let countLoose = loose.components(separatedBy: "\n\n").filter { !$0.isEmpty }.count
        XCTAssertGreaterThanOrEqual(countTight, countLoose)
    }
}

final class TranslateCoreTests: XCTestCase {
    func testTerminologyBlock() {
        let empty = TranslateCore.terminologyBlock([])
        XCTAssertTrue(empty.isEmpty)
        let block = TranslateCore.terminologyBlock([
            TerminologyTerm(en: "LLM", zh: "大语言模型", note: "不译成大型模型"),
        ])
        XCTAssertTrue(block.contains("LLM → 大语言模型"))
        XCTAssertTrue(block.contains("不译成大型模型"))
    }

    func testParseGroups() {
        XCTAssertEqual(LLMSegmentationEngine.parseGroups("[[0,1],[2],[3,4]]"), [[0, 1], [2], [3, 4]])
        XCTAssertNil(LLMSegmentationEngine.parseGroups("不是 JSON"))
        XCTAssertNil(LLMSegmentationEngine.parseGroups("[[]]"))
    }

    /// 单步直出：完整走一遍 runTranslate（假 LLM 闭包）
    func testRunTranslateSinglePass() async throws {
        let units = [SpeechUnit(start: 0, end: 2, en: "hello"), SpeechUnit(start: 2, end: 4, en: "world")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        opts.quality = .singlePass
        opts.autoExpand = false
        let calls = Mutex(0)
        let out = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, user in
            calls.with { $0 += 1 }
            XCTAssertTrue(system.contains("JSON 数组"))
            return "[{\"i\":0,\"zh\":\"你好\"},{\"i\":1,\"zh\":\"世界\"}]"
        }
        XCTAssertEqual(calls.wrapped, 1)
        XCTAssertEqual(out[0].zh, "你好")
        XCTAssertEqual(out[1].zh, "世界")
    }

    /// 三步模式：同批调用 3 次，终稿取第三步输出
    func testRunTranslateThreePass() async throws {
        let units = [SpeechUnit(start: 0, end: 2, en: "hello")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        opts.quality = .threePass
        opts.autoExpand = false
        let calls = Mutex(0)
        let out = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { _, _ in
            let c = calls.with { v -> Int in v += 1; return v }
            return c < 3 ? "初稿" : "[{\"i\":0,\"zh\":\"终稿\"}]"
        }
        XCTAssertEqual(calls.wrapped, 3)
        XCTAssertEqual(out[0].zh, "终稿")
    }

    /// 术语注入：complete 闭包的 system prompt 里含术语表
    func testTerminologyInjection() async throws {
        let units = [SpeechUnit(start: 0, end: 2, en: "hello")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        opts.terminology = [TerminologyTerm(en: "hello", zh: "哈喽")]
        opts.autoExpand = false
        let captured = Mutex("")
        _ = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, _ in
            captured.with { $0 = system }
            return "[{\"i\":0,\"zh\":\"好\"}]"
        }
        XCTAssertTrue(captured.wrapped.contains("hello → 哈喽"))
    }

    /// 领域语境注入：捕获的 system prompt 里含领域/语气/受众；空语境不注入
    func testDomainInjection() async throws {
        let units = [SpeechUnit(start: 0, end: 2, en: "hello")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        opts.domain = DomainContext(domain: "网络安全", tone: "轻松教学", audience: "入门者")
        opts.autoExpand = false
        let captured = Mutex("")
        _ = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, _ in
            captured.with { $0 = system }
            return "[{\"i\":0,\"zh\":\"好\"}]"
        }
        XCTAssertTrue(captured.wrapped.contains("专业领域：网络安全"))
        XCTAssertTrue(captured.wrapped.contains("语气基调：轻松教学"))
        XCTAssertTrue(captured.wrapped.contains("目标受众：入门者"))

        // 空语境不注入
        XCTAssertTrue(TranslateCore.domainBlock(nil, style: .narrator).isEmpty)
        XCTAssertTrue(TranslateCore.domainBlock(DomainContext(domain: "", tone: "", audience: ""), style: .narrator).isEmpty)
        // 仅领域也成立
        XCTAssertTrue(TranslateCore.domainBlock(DomainContext(domain: "法律科普"), style: .narrator).contains("法律科普"))
    }

    /// 风格过滤：faithful/concise 只注入领域行，不注入语气/受众（防扩写指令与风格定义打架）
    func testDomainBlockStyleFilter() throws {
        let d = DomainContext(domain: "法律科普", tone: "激动解说", audience: "入门者")
        for style in [TranslationStyle.faithful, .concise] {
            let block = TranslateCore.domainBlock(d, style: style)
            XCTAssertTrue(block.contains("专业领域：法律科普"), "\(style) 应保留领域行")
            XCTAssertFalse(block.contains("语气基调"), "\(style) 不应注入语气")
            XCTAssertFalse(block.contains("目标受众"), "\(style) 不应注入受众")
        }
        let narrator = TranslateCore.domainBlock(d, style: .narrator)
        XCTAssertTrue(narrator.contains("语气基调：激动解说"))
        XCTAssertTrue(narrator.contains("目标受众：入门者"))
    }

    /// 提取引擎：新回复格式（对象，领域+术语）解析与去重
    func testTerminologyEngineParsing() throws {
        let obj = try GatewayTerminologyEngine.extractJSONObject("""
        ```json
        {"domain":"人工智能","tone":"轻松教学","audience":"入门者","terms":[
            {"en":"LLM","zh":"大语言模型","note":""},
            {"en":"llm","zh":"重复项","note":""},
            {"en":"","zh":"空 en 跳过"}
        ]}
        ```
        """)
        XCTAssertEqual(obj["domain"] as? String, "人工智能")
        let terms = GatewayTerminologyEngine.parseTerms(obj["terms"] as? [[String: Any]] ?? [])
        XCTAssertEqual(terms.count, 1)
        XCTAssertEqual(terms[0].zh, "大语言模型")
        XCTAssertThrowsError(try GatewayTerminologyEngine.extractJSONObject("不是 JSON"))
    }

    // MARK: 时长节奏（双向字数预算 + 超短句扩写）

    /// 超短句判定阈值：< 时长×3 字且时长≥2s
    func testIsTooShortThreshold() {
        XCTAssertTrue(TranslateCore.isTooShort(zh: "哈喽", duration: 2.0))              // 2字 < 6字
        XCTAssertFalse(TranslateCore.isTooShort(zh: "哈喽大家好呀", duration: 2.0))     // 6字 ≥ 6字
        XCTAssertFalse(TranslateCore.isTooShort(zh: "哦", duration: 1.9))              // 时长过短不判
        XCTAssertFalse(TranslateCore.isTooShort(zh: "今天我们聊一个很有意思的话题", duration: 4.0))  // 16字 ≥ 12字
    }

    /// 双向字数预算：开启时 prompt 带建议字数（时长×4）与节奏规则；关闭时回退旧单向上限提示
    func testPacingPromptOnOff() async throws {
        let units = [SpeechUnit(start: 0, end: 4, en: "hello world foo bar")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        let captured = Mutex("")
        let longZh = "[{\"i\":0,\"zh\":\"大家好呀今天咱们聊一个挺有意思的话题看看吧\"}]"

        opts.autoExpand = true
        _ = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, user in
            captured.with { $0 = "S:\(system)\n====\nU:\(user)" }
            return longZh
        }
        XCTAssertTrue(captured.wrapped.contains("≈16字"))
        XCTAssertTrue(captured.wrapped.contains("90%～110%"))
        XCTAssertTrue(captured.wrapped.contains("时长节奏"))

        opts.autoExpand = false
        _ = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, user in
            captured.with { $0 = "S:\(system)\n====\nU:\(user)" }
            return longZh
        }
        XCTAssertTrue(captured.wrapped.contains("不宜超过"))
        XCTAssertFalse(captured.wrapped.contains("时长节奏"))
        XCTAssertFalse(captured.wrapped.contains("≈16字"))
    }

    /// 超短句定向扩写：译文远短于时间窗时发第二次请求，采纳更长结果
    func testShortSentenceExpansion() async throws {
        let units = [SpeechUnit(start: 0, end: 6, en: "hello everyone welcome back to the channel")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        let calls = Mutex(0)
        let expanded = "哈喽各位朋友，欢迎回到咱们的频道，今天咱们接着往下聊"
        let out = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, user in
            let c = calls.with { v -> Int in v += 1; return v }
            if c == 1 {
                return "[{\"i\":0,\"zh\":\"大家好\"}]"   // 3字 < 6s×3=18字 → 超短
            }
            XCTAssertTrue(system.contains("润色师"))
            XCTAssertTrue(user.contains("目标约24字"))
            return "[{\"i\":0,\"zh\":\"\(expanded)\"}]"
        }
        XCTAssertEqual(calls.wrapped, 2)
        XCTAssertEqual(out[0].zh, expanded)
    }

    /// 译文足够长时不应触发扩写额外调用
    func testNoExpansionWhenLongEnough() async throws {
        let units = [SpeechUnit(start: 0, end: 2, en: "hello")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        let calls = Mutex(0)
        let out = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { _, _ in
            calls.with { $0 += 1 }
            return "[{\"i\":0,\"zh\":\"哈喽大家好呀今天天气不错\"}]"  // 12字 ≥ 2s×3=6字
        }
        XCTAssertEqual(calls.wrapped, 1)
        XCTAssertEqual(out[0].zh, "哈喽大家好呀今天天气不错")
    }

    /// 超长句定向精简：译文远超时间窗容量（> 时长×5.5 字且时长 ≥ 2.5s）时自动发一次精简请求
    func testLongSentenceCompression() async throws {
        let units = [SpeechUnit(start: 0, end: 3.0, en: "This is a quick intro.")]
        var opts = TranslateOptions(batchSize: 10, concurrency: 1)
        opts.autoExpand = true
        opts.autoCompress = true
        let calls = Mutex(0)
        let overlyLong = "这是一段非常非常冗长啰嗦的中文翻译句子，字数远远超过了三秒钟能自然念完的上限"
        let concise = "这是一段简洁自然的开场介绍"
        let out = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, user in
            let c = calls.with { v -> Int in v += 1; return v }
            if c == 1 {
                return "[{\"i\":0,\"zh\":\"\(overlyLong)\"}]"
            }
            XCTAssertTrue(system.contains("精简师"))
            XCTAssertTrue(user.contains("目标约12字"))
            return "[{\"i\":0,\"zh\":\"\(concise)\"}]"
        }
        XCTAssertEqual(calls.wrapped, 2)
        XCTAssertEqual(out[0].zh, concise)
    }

    /// Index-Homura 音节计算与官方受控翻译 Prompt 组装
    func testIndexHomuraSyllableAndPrompt() {
        XCTAssertEqual(IndexHomuraTranslateEngine.targetSyllableCount(duration: 4.0, syllablesPerSec: 4.2), 17)
        // 纯中文：7 个汉字 = 7 音节
        XCTAssertEqual(IndexHomuraTranslateEngine.countSyllables("今天我们聊大模型"), 8)
        // 中英混读：LLM（3字母缩写=3音节）+ 的安全（3汉字=3音节）= 6 音节
        XCTAssertEqual(IndexHomuraTranslateEngine.countSyllables("LLM的安全"), 6)

        let terms = [
            TerminologyTerm(en: "Prompt Injection", zh: "提示词注入"),
            TerminologyTerm(en: "UnusedTerm", zh: "未命中术语"),
        ]
        let prompt = IndexHomuraTranslateEngine.buildHomuraPrompt(
            sourceText: "How does Prompt Injection work in practice?",
            targetLanguage: "zh",
            targetSyllables: 15,
            terminology: terms)
        XCTAssertTrue(prompt.contains("译文严格控制在 15 个音节"))
        XCTAssertTrue(prompt.contains("- Prompt Injection -> 提示词注入"))
        XCTAssertFalse(prompt.contains("UnusedTerm"), "未在当前句出现的术语不应注入，防止干扰小模型")
        XCTAssertTrue(prompt.contains("直接输出翻译结果，不要进行任何解释。"))
    }

    /// MLX TTS 与 ASR 参数构造验证
    func testMLXAudioCLIAndScriptBuilders() {
        var opts = SynthOptions()
        opts.mlxModel = "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
        opts.mlxVoice = "Dylan, 沉稳自然的中文科技播客男主播"
        opts.rate = 1.15
        opts.referenceAudioPath = "/tmp/ref.wav"
        opts.referenceText = "Hello world."
        let args = MLXAudioTTSEngine.buildCLIArguments(text: "你好，欢迎收听本期播客", outputPrefix: "/tmp/out", options: opts)
        XCTAssertTrue(args.contains("--model"))
        XCTAssertTrue(args.contains("mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"))
        XCTAssertTrue(args.contains("--ref_audio"))
        XCTAssertTrue(args.contains("/tmp/ref.wav"))
        XCTAssertTrue(args.contains("--ref_text"))
        XCTAssertTrue(args.contains("1.15"))

        let script = MLXAudioASREngine.buildASRScript(
            audioPath: "/tmp/in.wav",
            modelRepo: "mlx-community/Qwen3-ASR-1.7B-4bit",
            language: "en",
            outputJSONPath: "/tmp/out.json")
        XCTAssertTrue(script.contains("mlx-community/Qwen3-ASR-1.7B-4bit"))
        XCTAssertTrue(script.contains("from mlx_audio.stt.utils import load_model"))
    }
}

// MARK: - 本地 TTS 引擎

final class LocalTTSEngineTests: XCTestCase {
    private func tempCacheDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-tts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// say 引擎真合成：短句 → mp3 + 时长 > 0.35s + 缓存命中
    func testLocalSaySynthesize() async throws {
        let dir = try tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var opts = SynthOptions()
        opts.localVoice = "Tingting"
        let (url, dur) = try await LocalSayTTSEngine().synthesize(
            text: "你好世界，这是本地语音合成测试。", cacheKey: "cached-tts-001", cacheDir: dir, options: opts)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        XCTAssertGreaterThan(dur, 0.35)
        XCTAssertEqual(url.pathExtension, "mp3")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("cached-tts-001.duration").path))

        // 幂等缓存命中：同 key 再次合成直接返回
        let (url2, dur2) = try await LocalSayTTSEngine().synthesize(
            text: "你好世界，这是本地语音合成测试。", cacheKey: "cached-tts-001", cacheDir: dir, options: opts)
        XCTAssertEqual(url2, url)
        XCTAssertEqual(dur2, dur, accuracy: 0.01)
    }

    /// sherpa-onnx（内嵌）：配置的目录存在但缺权重时报可操作错误
    func testSherpaOnnxIncompleteModelDir() async throws {
        let dir = try tempCacheDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        var opts = SynthOptions()
        opts.sherpaOnnxModelDir = dir.path  // 空目录：存在但无 model.onnx
        do {
            _ = try await SherpaOnnxTTSEngine().synthesize(
                text: "你好", cacheKey: "so-incomplete-\(UUID().uuidString)", cacheDir: dir, options: opts)
            XCTFail("应抛模型不完整错误")
        } catch let e as EngineError {
            guard case .engineFailure(let msg) = e else { return XCTFail("错误类型不对：\(e)") }
            XCTAssertTrue(msg.contains("model.onnx"), "提示应含权重文件名：\(msg)")
        }
    }

    /// sherpa-onnx（内嵌）：未配置目录 → ModelStore 归一化/默认模型路径逻辑
    func testSherpaOnnxModelResolution() throws {
        // normalizeModelOnnx：目录内唯一 .onnx 软链为 model.onnx
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherpa_norm_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "fake".write(to: dir.appendingPathComponent("theresa.onnx"), atomically: true, encoding: .utf8)
        ModelStore.normalizeModelOnnx(at: dir.path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.path + "/model.onnx"))
        // 多个 onnx 不歧义处理
        try "fake".write(to: dir.appendingPathComponent("other.onnx"), atomically: true, encoding: .utf8)
        try? FileManager.default.removeItem(atPath: dir.appendingPathComponent("model.onnx").path)
        ModelStore.normalizeModelOnnx(at: dir.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.path + "/model.onnx"))
    }

    /// SynthOptions 新字段向后兼容：老 JSON（无 localVoice/sherpaOnnxModelDir）解码不掉默认值
    func testSynthOptionsBackwardCompat() throws {
        let legacyJSON = """
        {"apiKey": "", "wsURL": "wss://x", "model": "m", "voice": "v", "rps": 3,
         "compatBaseURL": "https://api.openai.com/v1", "compatAPIKey": "", "compatTTSModel": "t",
         "edgeVoice": "zh-CN-YunxiNeural", "edgeProxy": "http://127.0.0.1:7890"}
        """
        let opts = try JSONDecoder().decode(SynthOptions.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(opts.localVoice, "Tingting")
        XCTAssertEqual(opts.sherpaOnnxModelDir, "")
        // 编码往返不丢新字段
        let data = try JSONEncoder().encode(opts)
        let round = try JSONDecoder().decode(SynthOptions.self, from: data)
        XCTAssertEqual(round.localVoice, opts.localVoice)
        XCTAssertEqual(round.sherpaOnnxModelDir, opts.sherpaOnnxModelDir)
    }
}


// MARK: 原声即播：容器可播性

final class MediaCompatTests: XCTestCase {
    func testMediaCompatPlayability() {
        XCTAssertTrue(MediaCompat.isNativePlayable(URL(fileURLWithPath: "/x/y/source.mp4")))
        XCTAssertTrue(MediaCompat.isNativePlayable(URL(fileURLWithPath: "/x/y/a.MOV")))
        XCTAssertFalse(MediaCompat.isNativePlayable(URL(fileURLWithPath: "/x/y/source.webm")))
        XCTAssertFalse(MediaCompat.isNativePlayable(URL(fileURLWithPath: "/x/y/source.mkv")))
    }
}


// MARK: 下载复用：dest 缺失但同前缀产物已存在时秒回，不触发真实下载

final class DownloadReuseTests: XCTestCase {
    func testDownloadReusesSiblingSourceFile() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ytb2zh-dlreuse-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // 模拟上一次下载落到 source.webm（>1MB 完整产物）
        let webm = dir.appendingPathComponent("source.webm")
        try Data(count: 2_000_000).write(to: webm)

        let engine = YtDlpDownloadEngine()
        // 无效 URL + 无代理：若引擎真的发起下载必然失败；测试通过即证明提前复用返回
        let file = try await engine.download(
            url: "https://www.youtube.com/watch?v=nonexistent000",
            to: dir.appendingPathComponent("source.mp4"),
            options: DownloadOptions(proxy: "")) { _, _ in }
        XCTAssertEqual(file.standardizedFileURL.path, webm.standardizedFileURL.path)
    }

    func testDownloadDoesNotReuseTinyPartialFile() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("ytb2zh-dlreuse-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }
        // <1MB 视为不完整产物，不应复用（会走真实下载并因连接拒绝立即失败）
        let tiny = dir.appendingPathComponent("source.webm")
        try Data(count: 100).write(to: tiny)

        let engine = YtDlpDownloadEngine()
        do {
            _ = try await engine.download(
                url: "http://127.0.0.1:1/video",
                to: dir.appendingPathComponent("source.mp4"),
                options: DownloadOptions(proxy: "")) { _, _ in }
            XCTFail("不应复用不完整产物")
        } catch { }
    }
}

// MARK: - 多协议端点归一化、推理 <think> 标签剥离与云端 ASR 响应解析

final class MultiProtocolAndASRTests: XCTestCase {
    func testEndpointResolution() {
        XCTAssertEqual(
            OpenAICompatTranslateEngine.resolveChatCompletionsURL("https://openrouter.ai/api/v1"),
            "https://openrouter.ai/api/v1/chat/completions")
        XCTAssertEqual(
            OpenAICompatTranslateEngine.resolveChatCompletionsURL("https://ark.cn-beijing.volces.com/api/v3/"),
            "https://ark.cn-beijing.volces.com/api/v3/chat/completions")
        XCTAssertEqual(
            GatewayTranslateEngine.resolveResponsesURL("http://127.0.0.1:15000/v1"),
            "http://127.0.0.1:15000/v1/responses")
        XCTAssertEqual(
            GatewayTranslateEngine.resolveResponsesURL("http://127.0.0.1:15000/v1/responses"),
            "http://127.0.0.1:15000/v1/responses")
        XCTAssertEqual(
            OpenAICompatTranslateEngine.resolveAnthropicMessagesURL("https://api.anthropic.com/v1"),
            "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(
            OpenAICompatTranslateEngine.resolveGeminiURL(
                "https://generativelanguage.googleapis.com/v1beta",
                model: "gemini-2.5-flash",
                apiKey: "k123"),
            "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.5-flash:generateContent?key=k123")
    }

    func testStripThinkTagsAndLocalDetection() {
        let raw = "<think>\n首先分析语序...\n</think>\n[{\"i\":0,\"zh\":\"你好世界\"}]"
        XCTAssertEqual(OpenAICompatTranslateEngine.stripThinkTags(raw), "[{\"i\":0,\"zh\":\"你好世界\"}]")
        XCTAssertTrue(OpenAICompatTranslateEngine.isLocalEndpoint("http://127.0.0.1:11434/v1"))
        XCTAssertTrue(OpenAICompatTranslateEngine.isLocalEndpoint("http://localhost:1234/v1"))
        XCTAssertFalse(OpenAICompatTranslateEngine.isLocalEndpoint("https://api.deepseek.com/v1"))
    }

    func testOpenAITranscribeResponseParsing() throws {
        // 1) word-level
        let wordJSON = """
        {"words":[{"word":"Hello","start":0.0,"end":0.5},{"word":"world.","start":0.5,"end":1.2}]}
        """.data(using: .utf8)!
        let words1 = try OpenAITranscribeEngine.parseTranscriptionResponse(data: wordJSON, fallbackDuration: 5.0)
        XCTAssertEqual(words1.count, 2)
        XCTAssertEqual(words1[0].text, " Hello")

        // 2) segment-level fallback
        let segJSON = """
        {"segments":[{"text":"Hello world.","start":1.0,"end":3.0}]}
        """.data(using: .utf8)!
        let words2 = try OpenAITranscribeEngine.parseTranscriptionResponse(data: segJSON, fallbackDuration: 5.0)
        XCTAssertEqual(words2.count, 2)
        XCTAssertEqual(words2.first?.start ?? 0, 1.0, accuracy: 0.01)

        // 3) plain text fallback (e.g. SenseVoice)
        let txtJSON = """
        {"text":"Hello world."}
        """.data(using: .utf8)!
        let words3 = try OpenAITranscribeEngine.parseTranscriptionResponse(data: txtJSON, fallbackDuration: 4.0)
        XCTAssertEqual(words3.count, 2)
    }
}
