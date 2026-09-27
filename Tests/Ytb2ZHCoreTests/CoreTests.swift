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
        XCTAssertEqual(p.engines[StepID.separate.rawValue], "none")   // 缺省步自动补齐
        XCTAssertEqual(p.engines[StepID.summarize.rawValue], "none")
        XCTAssertEqual(p.engines.count, StepID.allCases.count)
        XCTAssertEqual(p.compose.subtitleMaxLength, 75)
        XCTAssertEqual(p.synth.edgeVoice, "zh-CN-YunxiNeural")
        XCTAssertNil(p.translate.terminology)
    }

    func testTerminologyRoundTripNotPersisted() throws {
        var p = Profile.balanced
        p.translate.terminology = [TerminologyTerm(en: "LLM", zh: "大语言模型")]
        let data = try JSONEncoder().encode(p)
        let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let translate = obj?["translate"] as? [String: Any]
        XCTAssertNil(translate?["terminology"], "运行时术语不得写入模板 JSON")
        let back = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertNil(back.translate.terminology)
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
}
