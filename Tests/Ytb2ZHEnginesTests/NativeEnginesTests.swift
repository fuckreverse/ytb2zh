import XCTest
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

    // MARK: - 真机冒烟（默认跳过：YTB2ZH_NATIVE_SMOKE=1 启用）
    // sherpa：模型已在 ~/.ytb2zh/models/vits-zh-hf-theresa（首次用时自动下载）
    // whisper：默认走 ~/vid2zh/models/ggml-medium.en-q5_0.bin（存在即用）

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
