import XCTest
@testable import Ytb2ZHCore

final class CoreTests: XCTestCase {
    func testProfileDerivation() {
        let base = Profile.tightSync
        let derived = base.derived(named: "我的变体")
        XCTAssertEqual(derived.name, "我的变体")
        XCTAssertEqual(derived.schedule.driftCap, base.schedule.driftCap)
        XCTAssertNotEqual(derived, Profile.relaxed)
    }

    func testBuiltinProfilesValidDefaults() {
        for p in Profile.builtins {
            XCTAssertEqual(p.engines.count, StepID.allCases.count)
        }
    }

    func testDefaultTranscribeEngineIsNative() {
        // 默认模板必须走零依赖的内嵌 whisper（sidecar 版依赖外部 whisper-cli 二进制，
        // 未安装的机器上默认模板会直接失败）
        XCTAssertEqual(Profile.defaultEngines[StepID.transcribe.rawValue], "whisper-native")
        for p in Profile.builtins {
            XCTAssertEqual(p.engines[StepID.transcribe.rawValue], "whisper-native")
        }
    }

    func testTemplateStoreRoundTrip() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-test-\(UUID().uuidString)", isDirectory: true)
        let store = TemplateStore(userDir: dir)
        let p = Profile.relaxed.derived(named: "测试模板")
        try store.save(p)
        let loaded = store.loadUserTemplates()
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded[0].profile.schedule.driftCap, Profile.relaxed.schedule.driftCap)
        try store.delete(p)
        XCTAssertEqual(store.loadUserTemplates().count, 0)
        try? FileManager.default.removeItem(at: dir)
    }

    func testJobStoreStatusAndPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-test-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: dir)
        let id = try store.newJob(url: "https://example.com/v", profile: .balanced)
        XCTAssertEqual(store.stepState(id, .download), .pending)
        store.setStep(id, .download, .done)
        XCTAssertEqual(store.stepState(id, .download), .done)
        XCTAssertEqual(store.loadStatus(id).steps.count, StepID.allCases.count)
        XCTAssertEqual(StepID.allCases.count, 9)

        let units = [SpeechUnit(start: 0, end: 1, en: "a", zh: "甲")]
        try store.writeJSON(units, to: store.unitsJSON(id))
        XCTAssertEqual(store.readJSON(store.unitsJSON(id), as: [SpeechUnit].self), units)

        try? FileManager.default.removeItem(at: dir)
    }

    func testClauseSplitter() {
        XCTAssertEqual(ClauseTextSplitter().split("无标点一句话"), ["无标点一句话"])
        XCTAssertEqual(ClauseTextSplitter().split(""), [])
        // 短句（去标点 15 字 ≤ 16）→ 整句单条 TTS，不再拆成两截
        XCTAssertEqual(ClauseTextSplitter().split("第一部分很长，第二部分也很长，结尾。"),
                       ["第一部分很长，第二部分也很长，结尾。"])
        XCTAssertEqual(ClauseTextSplitter().split("所以这个方法很有效，对吧。"),
                       ["所以这个方法很有效，对吧。"])
    }

    func testClauseSplitterGreedyAndOrphan() {
        // 长句：贪心合并开头碎句 + 孤儿尾句并入前句
        let parts = ClauseTextSplitter().split(
            "你看，这个方法，其实非常非常简单而且很实用，你们回去都能用。")
        // "你看，"+"这个方法，" 均不足 8 字 → 依次并入后句
        XCTAssertTrue(parts[0].hasPrefix("你看，"))
        // 孤儿尾句"你们回去都能用。"… 实际 ≥8 字不并；此处验证整句被拆成了 2 条自然长句
        XCTAssertEqual(parts.count, 2)
        XCTAssertTrue(parts[0].contains("其实非常"))

        // 孤儿尾句：结尾 2 字并入前句
        let parts2 = ClauseTextSplitter().split(
            "比如说我们今天要聊的这个话题有多重要，其实就是大模型的安全问题，对吧。")
        XCTAssertEqual(parts2.count, 2)
        XCTAssertTrue(parts2[1].hasSuffix("对吧。"))
    }

    func testLegacyProfileDecode() throws {
        // 旧版（七步、无新参数）模板 JSON 必须能加载
        let legacy = """
        {"name":"旧模板","engines":{"download":"yt-dlp","transcribe":"whisper-cpp","segment":"punct","translate":"gateway","synthesize":"bailian","schedule":"drift","compose":"ffmpeg"},"download":{"format":"f","proxy":"","keepSource":true},"transcribe":{"modelPath":"/m.bin","language":"en"},"segmentation":{"softWindow":7,"hardWindow":13},"translate":{"endpoint":"http://x/v1/responses","model":"m","batchSize":10,"concurrency":2,"style":"narrator","autoExpand":true},"synth":{"apiKey":"k","wsURL":"wss://x","model":"m","voice":"v","rps":3},"schedule":{"driftCap":1.0,"lagCap":0.5,"unitGap":0.2,"pauseMin":0.2,"pauseMax":1.0,"slowMax":1.1,"fastMax":1.2,"slidePreviewRange":0},"compose":{"subtitleFontSize":16,"subtitleMarginV":26,"dubGainDB":4.5,"keepOriginalAudio":false,"originalDuckRatio":6,"crf":20,"preset":"veryfast"}}
        """
        let p = try JSONDecoder().decode(Profile.self, from: Data(legacy.utf8))
        XCTAssertEqual(p.name, "旧模板")
        XCTAssertEqual(p.engines[StepID.transcribe.rawValue], "whisper-cpp")   // 旧模板显式选择不被新默认覆盖
        XCTAssertEqual(p.engines[StepID.separate.rawValue], "none")   // 缺省步自动补齐
        XCTAssertEqual(p.engines[StepID.summarize.rawValue], "none")
        XCTAssertEqual(p.engines.count, StepID.allCases.count)
        XCTAssertEqual(p.compose.subtitleMaxLength, 75)
        XCTAssertEqual(p.synth.edgeVoice, "zh-CN-YunxiNeural")
        XCTAssertNil(p.translate.terminology)
        XCTAssertEqual(p.blurb, "", "旧模板无 blurb 字段应默认为空串")
        XCTAssertEqual(p.synth.rate, 1.0, "旧模板 synth 无 rate 键应默认 1.0")
        XCTAssertEqual(p.schedule.rate, 1.0, "旧模板 schedule 无 rate 键应默认 1.0")
    }

    // MARK: - 合成语速（synth.rate 用户设置 / schedule.rate 调度层兜底）

    func testSynthOptionsRateDefaultsAndClamp() {
        XCTAssertEqual(SynthOptions().rate, 1.0)
        XCTAssertEqual(SynthOptions(rate: 1.35).effectiveRate, 1.35)
        XCTAssertEqual(SynthOptions(rate: 5).effectiveRate, SynthOptions.rateMax)
        XCTAssertEqual(SynthOptions(rate: 0.1).effectiveRate, SynthOptions.rateMin)
    }

    func testSynthOptionsRateRoundTrip() throws {
        var o = SynthOptions()
        o.rate = 1.4
        let back = try JSONDecoder().decode(SynthOptions.self, from: try JSONEncoder().encode(o))
        XCTAssertEqual(back.rate, 1.4)
    }

    func testSynthOptionsLegacyJSONWithoutRate() throws {
        // 旧模板 synth 对象无 rate 键 → 默认 1.0（向后兼容）
        let json = #"{"apiKey":"k","wsURL":"wss://x","model":"m","voice":"v","rps":3}"#
        let o = try JSONDecoder().decode(SynthOptions.self, from: Data(json.utf8))
        XCTAssertEqual(o.rate, 1.0)
        XCTAssertEqual(o.voice, "v")
    }

    func testScheduleOptionsLegacyJSONWithoutRate() throws {
        // 旧模板 schedule 对象无 rate 键 → 默认 1.0（ synthesized decode 会因缺键抛错，故有自定义解码器）
        let json = """
        {"driftCap":1.0,"lagCap":0.5,"unitGap":0.2,"pauseMin":0.2,"pauseMax":1.0,"slowMax":1.1,"fastMax":1.2,"slidePreviewRange":0}
        """
        let o = try JSONDecoder().decode(ScheduleOptions.self, from: Data(json.utf8))
        XCTAssertEqual(o.rate, 1.0)
        XCTAssertEqual(o.driftCap, 1.0)
    }

    func testBlurbRoundTrip() throws {
        let data = try JSONEncoder().encode(Profile.keepBGM)
        let p = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(p.blurb, Profile.keepBGM.blurb)
    }

    func testIsEqualIgnoringName() {
        // 同模板改个名字：内容相等
        XCTAssertTrue(Profile.tightSync.isEqualIgnoringName(to: Profile.tightSync.derived(named: "改名")))
        // 基于模板改了参数：内容不等
        var tweaked = Profile.balanced
        tweaked.schedule.driftCap = 2.4
        XCTAssertFalse(tweaked.isEqualIgnoringName(to: Profile.balanced))
        // 改了 blurb 不算内容变化
        var reblurb = Profile.balanced
        reblurb.blurb = "新描述"
        XCTAssertTrue(reblurb.isEqualIgnoringName(to: Profile.balanced))
    }

    func testTerminologyRoundTripNotPersisted() throws {
        var p = Profile.balanced
        p.translate.terminology = [TerminologyTerm(en: "LLM", zh: "大语言模型")]
        p.translate.domain = DomainContext(domain: "人工智能", tone: "轻松教学", audience: "入门者")
        let data = try JSONEncoder().encode(p)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let translate = obj?["translate"] as? [String: Any]
        XCTAssertNil(translate?["terminology"], "运行时术语不得写入模板 JSON")
        XCTAssertNil(translate?["domain"], "运行时领域语境不得写入模板 JSON")
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertNil(back.translate.terminology)
        XCTAssertNil(back.translate.domain)
    }

    /// terminology.json 新格式（对象）与旧格式（纯数组）兼容读写
    func testTerminologyExtractionLegacyAndNewFormat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧格式：纯术语数组（老任务产物）
        let legacy = dir.appendingPathComponent("legacy.json")
        let legacyData = try JSONEncoder().encode([
            TerminologyTerm(en: "LLM", zh: "大语言模型"),
        ])
        try legacyData.write(to: legacy)
        let fromLegacy = try XCTUnwrap(TerminologyExtraction.load(from: legacy))
        XCTAssertEqual(fromLegacy.terms.count, 1)
        XCTAssertNil(fromLegacy.domain)

        // 新格式：{domain, terms}，往返一致
        let doc = TerminologyExtraction(
            domain: DomainContext(domain: "网络安全", tone: "严肃专业", audience: "从业者"),
            terms: [TerminologyTerm(en: "RAT", zh: "远程访问木马")])
        let newFile = dir.appendingPathComponent("new.json")
        try JSONEncoder().encode(doc).write(to: newFile)
        let back = try XCTUnwrap(TerminologyExtraction.load(from: newFile))
        XCTAssertEqual(back.domain?.domain, "网络安全")
        XCTAssertEqual(back.domain?.tone, "严肃专业")
        XCTAssertEqual(back.domain?.audience, "从业者")
        XCTAssertEqual(back.terms.first?.en, "RAT")

        // 新格式字段缺失也可解（domain/term 全空）
        let empty = try JSONSerialization.data(withJSONObject: ["terms": []] as [String: Any])
        let emptyFile = dir.appendingPathComponent("empty.json")
        try empty.write(to: emptyFile)
        let fromEmpty = try XCTUnwrap(TerminologyExtraction.load(from: emptyFile))
        XCTAssertTrue(fromEmpty.terms.isEmpty)
        XCTAssertFalse(fromEmpty.hasContent)
        XCTAssertTrue(doc.hasContent)
        // 仅领域无术语：同样算有内容（缓存有效，不会重复提取）
        XCTAssertTrue(TerminologyExtraction(
            domain: DomainContext(domain: "中医养生"), terms: []).hasContent)
    }

    func testEngineRegistryValidation() {
        var p = Profile.balanced
        p.engines[StepID.transcribe.rawValue] = "不存在的引擎"
        var registryOffers: [EngineRegistry.Offer] = []
        for step in StepID.allCases {
            registryOffers.append(.init(step: step, descriptors: [.init("x-\(step.rawValue)", "x")]))
        }
        let reg = EngineRegistry(registryOffers)
        XCTAssertFalse(reg.validate(profile: p).isEmpty)
        p.engines[StepID.transcribe.rawValue] = "x-transcribe"
        // 其它步骤 id 不在注册表 → 仍有错误
        XCTAssertFalse(reg.validate(profile: p).isEmpty)
    }

    // MARK: 试转模式（前 N 分钟验证配置）

    func testDownloadOptionsPartialSecondsNotPersisted() throws {
        var p = Profile.balanced
        p.download.partialSeconds = 180
        // 运行时字段不落盘
        let enc = try JSONEncoder().encode(p)
        let json = String(decoding: enc, as: UTF8.self)
        XCTAssertFalse(json.contains("partialSeconds"))
        // 旧模板 JSON（无 partialSeconds）仍可解码，默认 nil
        let legacy = try JSONSerialization.data(withJSONObject: [
            "format": "f", "proxy": "", "keepSource": true,
        ] as [String: Any])
        let dlOpts = try JSONDecoder().decode(DownloadOptions.self, from: legacy)
        XCTAssertNil(dlOpts.partialSeconds)
        XCTAssertEqual(dlOpts.format, "f")
        // 不带 download 字段的旧 Profile 兼容不变
        var pp = Profile.balanced
        pp.download.partialSeconds = nil
        XCTAssertEqual(pp.download.partialSeconds, nil)
    }

    func testTrialStatusMarkerAndLegacyCompat() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-test-\(UUID().uuidString)", isDirectory: true)
        let store = JobStore(root: dir)
        defer { try? FileManager.default.removeItem(at: dir) }

        // 旧 status.json（无 trial 键）解码不失败、isTrial = false
        let legacyID = try store.newJob(url: "https://example.com/old", profile: .balanced)
        let st = store.loadStatus(legacyID)
        XCTAssertEqual(st.trial, nil)
        XCTAssertFalse(st.isTrial)

        // 试转任务标记得持久化
        let trialID = try store.newJob(url: "https://example.com/v", profile: .balanced, trial: true)
        XCTAssertTrue(store.loadStatus(trialID).isTrial)
        // 普通任务不受影响
        let normalID = try store.newJob(url: "https://example.com/v", profile: .balanced)
        XCTAssertFalse(store.loadStatus(normalID).isTrial)

        // trial_source.mp4 路径约定在任务目录内
        XCTAssertTrue(store.trialSource(trialID).lastPathComponent == "trial_source.mp4")
        XCTAssertTrue(store.trialSource(trialID).path.hasPrefix(store.jobDir(id: trialID).path))
    }

    func testTrialTrimTrimsToSeconds() throws {
        // 合成 10s 视频，截取前 3s；ffmpeg 不可用则跳过（CI 环境保护）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in.mp4")
        let gen = Process()
        gen.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        gen.arguments = ["ffmpeg", "-y", "-v", "error", "-f", "lavfi",
                         "-i", "testsrc2=size=320x240:rate=15:duration=10",
                         "-f", "lavfi", "-i", "sine=frequency=440:duration=10",
                         "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", src.path]
        gen.standardError = FileHandle.nullDevice
        try gen.run(); gen.waitUntilExit()
        try XCTSkipUnless(gen.terminationStatus == 0, "ffmpeg 不可用，跳过试转截取测试")

        let dest = dir.appendingPathComponent("trial_source.mp4")
        try TrialTrim.trim(source: src, to: dest, seconds: 3)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.path))
        let d = try XCTUnwrap(ffprobeDuration(dest))
        XCTAssertEqual(d, 3, accuracy: 1.5)

        // 幂等重跑：目标已存在也重新生成成功
        try TrialTrim.trim(source: src, to: dest, seconds: 5)
        let d2 = try XCTUnwrap(ffprobeDuration(dest))
        XCTAssertEqual(d2, 5, accuracy: 1.5)
    }
}
