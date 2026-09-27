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
        let units = [SpeechUnit(start: 10, end: 20, en: "hello", zh: "第一句，第二句")]
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
        let units = [SpeechUnit(start: 0, end: 5, en: "hello", zh: "第一句，第二句")]
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
        let captured = Mutex("")
        _ = try await TranslateCore.runTranslate(units: units, options: opts, progress: { _, _ in }) { system, _ in
            captured.with { $0 = system }
            return "[{\"i\":0,\"zh\":\"好\"}]"
        }
        XCTAssertTrue(captured.wrapped.contains("hello → 哈喽"))
    }
}
