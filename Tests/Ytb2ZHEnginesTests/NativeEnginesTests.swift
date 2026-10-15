import XCTest
import whisper
@testable import Ytb2ZHEngines
import Ytb2ZHCore

/// 内嵌 whisper / sherpa-onnx 引擎测试
final class NativeEnginesTests: XCTestCase {

    // MARK: - WAV 解析（纯逻辑）

    func testReadWavMono16() throws {
        // 构造最小 RIFF wav：44 字节头 + 4 样本
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        append("RIFF"); data.append(UInt32(36 + 8).littleEndian.data)
        append("WAVE")
        append("fmt "); data.append(UInt32(16).littleEndian.data)
        data.append(UInt16(1).littleEndian.data)      // PCM
        data.append(UInt16(1).littleEndian.data)      // mono
        data.append(UInt32(16000).littleEndian.data)  // rate
        data.append(UInt32(32000).littleEndian.data)  // byte rate
        data.append(UInt16(2).littleEndian.data)      // block align
        data.append(UInt16(16).littleEndian.data)     // bits
        append("data"); data.append(UInt32(8).littleEndian.data)
        for v: Int16 in [0, 16384, -16384, 32767] { data.append(v.littleEndian.data) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavtest_\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try NativeWhisperEngine().readWavMono16(url)
        XCTAssertEqual(samples.count, 4)
        XCTAssertEqual(samples[1], 0.5, accuracy: 0.001)
        XCTAssertEqual(samples[2], -0.5, accuracy: 0.001)
    }

    /// 带 LIST 杂项 chunk 的 wav 也能定位 data
    func testReadWavSkipsExtraChunks() throws {
        var data = Data()
        func append(_ s: String) { data.append(s.data(using: .ascii)!) }
        append("RIFF"); data.append(UInt32(0).littleEndian.data)
        append("WAVE")
        append("LIST"); data.append(UInt32(5).littleEndian.data); append("INFOx") // 5 字节 + 1 padding
        data.append(Data([0]))
        append("data"); data.append(UInt32(4).littleEndian.data)
        for v: Int16 in [1, -1] { data.append(v.littleEndian.data) }

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("wavtest2_\(UUID().uuidString).wav")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let samples = try NativeWhisperEngine().readWavMono16(url)
        XCTAssertEqual(samples.count, 2)
    }

    // MARK: - ModelStore 路径逻辑

    func testWhisperModelResolutionExistingPath() async throws {
        // 存在的显式路径直接返回（不触发下载）
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("wm_\(UUID().uuidString).bin")
        try Data([0x1]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let resolved = try await ModelStore.ensureWhisperModel(configured: tmp.path)
        XCTAssertEqual(resolved, tmp.path)
    }

    func testWhisperRemoteNameMapping() {
        // 空 / 旧版默认路径（vid2zh 原型目录）→ 回落默认模型，保证默认模板开箱即用
        XCTAssertEqual(ModelStore.whisperRemoteName(for: ""), "ggml-base.en.bin")
        XCTAssertEqual(ModelStore.whisperRemoteName(for: "~/vid2zh/models/ggml-medium.en-q5_0.bin"),
                       "ggml-base.en.bin")
        // 已知模型名（带不带 .bin 均可）→ 自身
        XCTAssertEqual(ModelStore.whisperRemoteName(for: "ggml-small.en"), "ggml-small.en.bin")
        XCTAssertEqual(ModelStore.whisperRemoteName(for: "ggml-base.en.bin"), "ggml-base.en.bin")
        XCTAssertEqual(ModelStore.whisperRemoteName(for: "ggml-large-v3-turbo-q5_0.bin"), "ggml-large-v3-turbo-q5_0.bin")
        XCTAssertEqual(ModelStore.whisperRemoteName(for: "ggml-large-v3-turbo"), "ggml-large-v3-turbo.bin")
        // 未知自定义路径 → nil（由调用方抛出带指引的错误）
        XCTAssertNil(ModelStore.whisperRemoteName(for: "/tmp/my-model.bin"))
    }

    func testWhisperDTWPresetMapping() {
        XCTAssertEqual(NativeWhisperEngine.dtwPreset(for: "/models/ggml-large-v3-turbo-q5_0.bin"),
                       WHISPER_AHEADS_LARGE_V3_TURBO)
        XCTAssertEqual(NativeWhisperEngine.dtwPreset(for: "ggml-large-v3.bin"),
                       WHISPER_AHEADS_LARGE_V3)
        XCTAssertEqual(NativeWhisperEngine.dtwPreset(for: "ggml-medium.en-q5_0.bin"),
                       WHISPER_AHEADS_MEDIUM_EN)
        XCTAssertEqual(NativeWhisperEngine.dtwPreset(for: "ggml-base.en.bin"),
                       WHISPER_AHEADS_BASE_EN)
    }

    func testSherpaModelFamilyAndKokoroLexiconDetection() throws {
        let fm = FileManager.default
        let baseDir = fm.temporaryDirectory.appendingPathComponent("sherpa_fam_\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: baseDir) }

        // 1) Kokoro 目录检测与中英双词典拼接
        let kokoroDir = baseDir.appendingPathComponent("kokoro", isDirectory: true)
        try fm.createDirectory(at: kokoroDir, withIntermediateDirectories: true)
        try Data([1]).write(to: kokoroDir.appendingPathComponent("model.onnx"))
        try Data([1]).write(to: kokoroDir.appendingPathComponent("voices.bin"))
        try Data([1]).write(to: kokoroDir.appendingPathComponent("lexicon-zh.txt"))
        try Data([1]).write(to: kokoroDir.appendingPathComponent("lexicon-us-en.txt"))
        XCTAssertEqual(SherpaOnnxTTSEngine.detectModelFamily(at: kokoroDir.path), .kokoro)
        let lex = SherpaOnnxTTSEngine.kokoroLexiconPaths(at: kokoroDir.path)
        XCTAssertTrue(lex.contains("lexicon-zh.txt"))
        XCTAssertTrue(lex.contains("lexicon-us-en.txt"))

        // 2) ZipVoice 目录检测
        let zipDir = baseDir.appendingPathComponent("zipvoice", isDirectory: true)
        try fm.createDirectory(at: zipDir, withIntermediateDirectories: true)
        try Data([1]).write(to: zipDir.appendingPathComponent("encoder.int8.onnx"))
        try Data([1]).write(to: zipDir.appendingPathComponent("decoder.int8.onnx"))
        try Data([1]).write(to: zipDir.appendingPathComponent("vocos_24khz.onnx"))
        XCTAssertEqual(SherpaOnnxTTSEngine.detectModelFamily(at: zipDir.path), .zipvoice)
        XCTAssertTrue(ModelStore.isValidSherpaTTSModelDir(zipDir.path))

        // 3) Speaker ID 解析
        XCTAssertEqual(SherpaOnnxTTSEngine.resolveSpeakerID("zm_010"), 50)
        XCTAssertEqual(SherpaOnnxTTSEngine.resolveSpeakerID("zf_001"), 45)
        XCTAssertEqual(SherpaOnnxTTSEngine.resolveSpeakerID("48"), 48)
    }

    func testSherpaASRSubwordMerging() {
        let tokens = ["▁Hello", ",", "▁this", "▁is", "▁Par", "akeet", "."]
        let timestamps = [0.10, 0.45, 0.60, 0.85, 1.00, 1.15, 1.35]
        let durations = [0.30, 0.05, 0.20, 0.15, 0.15, 0.20, 0.05]
        let words = SherpaOnnxASREngine.buildTimedWords(
            tokens: tokens, timestamps: timestamps, durations: durations, fallbackText: "")
        XCTAssertEqual(words.count, 4)
        XCTAssertEqual(words[0].text, " Hello,")
        XCTAssertEqual(words[1].text, " this")
        XCTAssertEqual(words[2].text, " is")
        XCTAssertEqual(words[3].text, " Parakeet.")
        XCTAssertEqual(words[3].start, 1.00, accuracy: 0.001)
        XCTAssertEqual(words[3].end, 1.40, accuracy: 0.001)
    }

    func testDefaultProfileAssembles() throws {
        // 默认模板与本地播客模板的引擎 id 必须全部可装配
        let engines = try EngineAssembly.engineSet(for: Profile.balanced)
        XCTAssertEqual(engines.transcriber.descriptor.id, "whisper-native")
        let podcastEngines = try EngineAssembly.engineSet(for: Profile.localPodcast)
        XCTAssertEqual(podcastEngines.translator.descriptor.id, "homura")
        XCTAssertEqual(podcastEngines.synthesizer.descriptor.id, "sherpa-onnx")
    }

    func testInspectLocalModelsInventory() {
        let items = ModelStore.inspectLocalModels()
        XCTAssertGreaterThanOrEqual(items.count, 8)
        XCTAssertTrue(items.contains { $0.id == "whisper-turbo-q5" })
        XCTAssertTrue(items.contains { $0.id == "kokoro-v1_1" })
        XCTAssertTrue(items.contains { $0.id == "zipvoice" })
        XCTAssertTrue(items.contains { $0.id == "homura-2b-gguf" })
    }

    // MARK: - 真机冒烟（默认跳过：YTB2ZH_NATIVE_SMOKE=1 启用）
    // sherpa：模型已在 ~/.ytb2zh/models/vits-zh-hf-theresa（首次用时自动下载）
    // whisper：显式填 vid2zh 旧路径（文件不在则自动下载默认 ggml-base.en）

    func testSherpaRealSynthSmoke() async throws {
        guard ProcessInfo.processInfo.environment["YTB2ZH_NATIVE_SMOKE"] == "1" else {
            throw XCTSkip("设 YTB2ZH_NATIVE_SMOKE=1 启用内嵌引擎真机冒烟")
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("sherpa_smoke_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let opts = SynthOptions()  // 未配置目录 → 默认模型
        let (url, dur) = try await SherpaOnnxTTSEngine().synthesize(
            text: "你好，这是内嵌语音合成测试。", cacheKey: "smoke", cacheDir: dir, options: opts)
        XCTAssertGreaterThan(dur, 1.0)
        // 二次调用命中缓存
        let (url2, dur2) = try await SherpaOnnxTTSEngine().synthesize(
            text: "你好，这是内嵌语音合成测试。", cacheKey: "smoke", cacheDir: dir, options: opts)
        XCTAssertEqual(url2, url)
        XCTAssertEqual(dur2, dur, accuracy: 0.01)
    }

    func testWhisperRealTranscribeSmoke() async throws {
        guard ProcessInfo.processInfo.environment["YTB2ZH_NATIVE_SMOKE"] == "1" else {
            throw XCTSkip("设 YTB2ZH_NATIVE_SMOKE=1 启用内嵌引擎真机冒烟")
        }
        // 用 ffmpeg 生成一段含清晰人声的合成语音（say 生成再转 16k wav 的视频）
        let work = FileManager.default.temporaryDirectory
            .appendingPathComponent("whisper_smoke_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let video = work.appendingPathComponent("in.mov")
        let runner = ProcessRunner()
        let r = try runner.run("/usr/bin/say", ["-v", "Samantha", "-o",
            work.appendingPathComponent("say.aiff").path,
            "Hello, this is a native whisper transcription test."])
        XCTAssertEqual(r.code, 0, "say 生成测试语音失败")
        let r2 = try runner.run(SidecarPaths.ffmpeg, ["-y", "-i",
            work.appendingPathComponent("say.aiff").path, "-pix_fmt", "yuv420p", video.path])
        XCTAssertEqual(r2.code, 0, "ffmpeg 生成测试视频失败")

        var opts = TranscribeOptions()
        opts.language = "en"
        opts.modelPath = NSHomeDirectory() + "/vid2zh/models/ggml-medium.en-q5_0.bin"
        let words = try await NativeWhisperEngine().transcribe(
            video: video, workDir: work, options: opts, progress: { _, _ in })
        XCTAssertFalse(words.isEmpty, "应转录出词")
        XCTAssertTrue(words.contains { $0.text.lowercased().contains("whisper") || $0.text.lowercased().contains("test") },
                      "词流应含关键词：\(words.prefix(12).map(\.text))")
        // 词级时间戳单调
        for (a, b) in zip(words, words.dropFirst()) {
            XCTAssertLessThanOrEqual(a.start, b.start + 0.01, "时间戳应单调：\(a) → \(b)")
        }
    }
}

private extension FixedWidthInteger {
    var data: Data {
        withUnsafeBytes(of: self) { Data($0) }
    }
}
