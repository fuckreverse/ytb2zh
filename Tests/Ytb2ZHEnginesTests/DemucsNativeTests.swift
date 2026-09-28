import XCTest
@testable import Ytb2ZHEngines
import Ytb2ZHCore

/// 内嵌 demucs.cpp 引擎测试（纯逻辑 + 真机冒烟）
final class DemucsNativeTests: XCTestCase {

    // MARK: - WAV I/O（纯逻辑）

    /// float32 立体声 wav 读回往返：writeWavStereoF32 → readWavStereoF32
    func testWavStereoF32RoundTrip() throws {
        let samples: [Float] = [0, 0.25, -0.25, 0.5, -0.5, 1.0, -1.0, 0.75]
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demucs_rt_\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }

        try NativeDemucsSeparator().writeWavStereoF32(url, samples: samples, sampleRate: 44100)
        let back = try NativeDemucsSeparator().readWavStereoF32(url)
        XCTAssertEqual(back.count, samples.count)
        for (a, b) in zip(samples, back) { XCTAssertEqual(a, b, accuracy: 1e-6) }
    }

    /// 非 float32/非立体声输入被拒绝并给出格式提示
    func testWavRejectsPcmInput() throws {
        func le32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func le16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        var buf = Data()
        func append(_ s: String) { buf.append(s.data(using: .ascii)!) }
        append("RIFF"); buf.append(le32(36 + 8))
        append("WAVE")
        append("fmt "); buf.append(le32(16))
        buf.append(le16(1))      // PCM
        buf.append(le16(2))      // stereo
        buf.append(le32(44100))
        buf.append(le32(44100 * 4))
        buf.append(le16(4))
        buf.append(le16(16))
        append("data"); buf.append(le32(8))
        buf.append(Data(repeating: 0, count: 8))

        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("demucs_pcm_\(UUID().uuidString).wav")
        try buf.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        XCTAssertThrowsError(try NativeDemucsSeparator().readWavStereoF32(url)) { err in
            XCTAssertTrue("\(err)".contains("float32"), "错误应提示格式要求：\(err)")
        }
    }

    // MARK: - 模型解析（ModelStore，纯逻辑）

    func testDemucsModelResolution() async throws {
        // 显式 .bin 路径存在 → 直接返回
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("demucs_model_\(UUID().uuidString).bin")
        try Data([0x1]).write(to: tmp)
        defer { try? FileManager.default.removeItem(at: tmp) }
        let p = try await ModelStore.ensureDemucsModel(configured: tmp.path)
        XCTAssertEqual(p, tmp.path)
    }

    func testDemucsUnknownModelRejected() async {
        do {
            _ = try await ModelStore.ensureDemucsModel(configured: "mdx_extra")
            XCTFail("未知模型名应报错")
        } catch {
            let msg = "\(error)"
            XCTAssertTrue(msg.contains("htdemucs"), "提示应含可选模型名：\(msg)")
        }
    }

    // MARK: - 引擎注册

    func testDemucsEngineRegistered() {
        let reg = EngineAssembly.registry()
        let seps = reg.descriptors(for: .separate)
        XCTAssertTrue(seps.contains { $0.id == "demucs" && $0.name.contains("内嵌") },
                      "separate 应注册内嵌 demucs：\(seps.map(\.name))")
    }

    // MARK: - 真机冒烟（默认跳过：YTB2ZH_DEMUCS_SMOKE=1 启用）
    // 覆盖：权重下载（缺失时）→ ffmpeg 抽轨 → 进程内推理 → 分轨写盘 → 转码

    func testDemucsRealSeparationSmoke() async throws {
        guard ProcessInfo.processInfo.environment["YTB2ZH_DEMUCS_SMOKE"] == "1" else {
            throw XCTSkip("设 YTB2ZH_DEMUCS_SMOKE=1 启用 demucs 真机冒烟")
        }
        // 生成测试视频音轨：中文语音（人声）+ 低频正弦（伴奏）
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("demucs_smoke_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let runner = ProcessRunner()
        let speech = dir.appendingPathComponent("speech.aiff")
        _ = try runner.run("/usr/bin/say", ["-v", "Tingting", "-o", speech.path,
                                            "这是一段用于测试人声分离效果的中文语音，今天天气不错"])
        let video = dir.appendingPathComponent("mix.wav")
        _ = try runner.run(SidecarPaths.ffmpeg, [
            "-y", "-v", "error", "-i", speech.path,
            "-f", "lavfi", "-i", "sine=frequency=150:duration=8:sample_rate=44100",
            "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=first",
            "-ar", "44100", "-ac", "2", video.path])

        let lastProgress = Mutex(0.0)
        let res = try await NativeDemucsSeparator().separate(
            video: video, workDir: dir,
            options: SeparationOptions(model: "htdemucs")) { p, _ in
                lastProgress.with { $0 = max($0, p) }
            }
        defer {
            try? FileManager.default.removeItem(at: res.vocals)
            try? FileManager.default.removeItem(at: res.instrumental)
        }

        // 产物契约：vocals.wav（16k 单声道）+ instrumental.wav（48k 立体声）
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: res.vocals.path))
        XCTAssertTrue(fm.fileExists(atPath: res.instrumental.path))
        XCTAssertGreaterThan(try fm.attributesOfItem(atPath: res.vocals.path)[.size] as? Int ?? 0, 100_000)
        XCTAssertEqual(lastProgress.with { $0 }, 1.0, accuracy: 0.001)

        // 分离有效性：vocals 与 instrumental 时长均 ≈ 输入时长（帧数保持，不截断/不补长）
        let ffprobe0 = SidecarPaths.which("ffprobe") ?? "ffprobe"
        let r0 = try runner.run(ffprobe0, ["-v", "error", "-show_entries", "format=duration",
                                           "-of", "csv=p=0", video.path])
        let inputDur = Double(String(r0.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) ?? 0
        for u in [res.vocals, res.instrumental] {
            let ffprobe = SidecarPaths.which("ffprobe") ?? "ffprobe"
            let r = try runner.run(ffprobe, ["-v", "error", "-show_entries",
                                             "format=duration", "-of", "csv=p=0", u.path])
            let d = Double(String(r.stdout.trimmingCharacters(in: .whitespacesAndNewlines))) ?? 0
            XCTAssertEqual(d, inputDur, accuracy: 1.0, "分轨时长应接近输入时长：\(u.path) = \(d)s")
        }
    }
}
