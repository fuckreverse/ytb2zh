import Foundation
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - verify 子命令：逐引擎小成本真机自检
// 用法: ytb2zh verify [--media <path>]（默认复用 ~/vid2zh/HYynNBgyGoo/source.mp4 的前 30 秒）

enum VerifyCommand {
    static func run(_ args: [String]) async throws {
        let media = args.count >= 2 && args[0] == "--media"
            ? URL(fileURLWithPath: (args[1] as NSString).expandingTildeInPath)
            : URL(fileURLWithPath: NSHomeDirectory() + "/vid2zh/HYynNBgyGoo/source.mp4")
        guard FileManager.default.fileExists(atPath: media.path) else {
            throw EngineError.notConfigured("找不到验证素材：\(media.path)")
        }
        let work = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ytb2ZH/verify", isDirectory: true)
        try? FileManager.default.removeItem(at: work)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }

        let clip = work.appendingPathComponent("clip30.mp4")
        print("① 准备 30s 素材片段…")
        try runFFmpeg(["-y", "-v", "error", "-ss", "60", "-t", "30", "-i", media.path,
                       "-c", "copy", clip.path])

        // ② whisper 转录
        print("② WhisperCliEngine 转录 30s…")
        let transcriber = WhisperCliEngine()
        let words = try await transcriber.transcribe(video: clip, workDir: work,
                                                     options: TranscribeOptions()) { p, m in
            if let m { print("   [\(Int(p * 100))%] \(m)") }
        }
        print("   ✓ \(words.count) 词，样例：\(words.prefix(8).map(\.text).joined())")
        guard words.count > 20 else { throw EngineError.engineFailure("转录词数异常") }

        // ③ 切分
        print("③ PunctSegmentationEngine 切分…")
        let units = PunctSegmentationEngine().segment(words: words, options: .init())
        print("   ✓ \(units.count) 单元：\(units.map { String(format: "%.1fs", $0.end - $0.start) }.joined(separator: ", "))")

        // ④ 网关翻译前 3 单元
        print("④ GatewayTranslateEngine 翻译 3 单元…")
        var sample = Array(units.prefix(3))
        for i in sample.indices { sample[i].zh = "" }
        let translated = try await GatewayTranslateEngine().translate(
            units: sample, options: TranslateOptions()) { _, _ in }
        for u in translated { print("   ✓ \(u.en.prefix(40)) → \(u.zh)") }
        guard translated.allSatisfy({ !$0.zh.isEmpty }) else {
            throw EngineError.engineFailure("翻译存在空结果")
        }

        // ⑤ 百炼合成 2 子句
        print("⑤ BailianSynthEngine 合成 2 子句…")
        let synth = BailianSynthEngine()
        let cacheDir = work.appendingPathComponent("clauses", isDirectory: true)
        var durs: [Double] = []
        for (k, text) in ["大家好，", "今天我们来聊聊大模型安全。"].enumerated() {
            let (url, dur) = try await synth.synthesize(text: text, cacheKey: "u0_c\(k)",
                                                        cacheDir: cacheDir, options: SynthOptions())
            print("   ✓ \(text) → \(dur)s（\(url.lastPathComponent)）")
            durs.append(dur)
        }
        guard durs.allSatisfy({ $0 > 0.5 && $0 < 30 }) else {
            throw EngineError.engineFailure("合成时长异常：\(durs)")
        }

        // ⑥ 调度器
        print("⑥ DriftSchedulerEngine 调度…")
        let verifyUnits = [SpeechUnit(start: 1.0, end: 6.0, en: "intro", zh: "大家好，今天我们来聊聊大模型安全。")]
        let plan = DriftSchedulerEngine().schedule(units: verifyUnits,
                                                   clauseDurations: [durs], options: ScheduleOptions())
        print("   ✓ placements=\(plan.placements.count) maxLead=\(String(format: "%.2f", plan.maxLead))")

        // ⑦ ffmpeg 成片（30s，字幕+配音）
        print("⑦ FFmpegComposeEngine 成片…")
        let out = work.appendingPathComponent("verify_final.mp4")
        _ = try await FFmpegComposeEngine().compose(
            video: clip, placements: plan.placements, unitSchedules: plan.unitSchedules,
            units: verifyUnits, cacheDir: cacheDir, output: out, options: ComposeOptions()) { _, _ in }
        let outDur = ffprobeDuration(out) ?? 0
        print("   ✓ 输出 \(out.path)（\(String(format: "%.1f", outDur))s）")
        guard abs(outDur - 30) < 5 else { throw EngineError.engineFailure("成片时长异常 \(outDur)s") }

        print("""
        ✅ 全部引擎自检通过：
           yt-dlp: \(YtDlpInstaller.availablePath.map { "\($0)（已就绪）" } ?? "未安装（内置提取失败时按需下载）")
           whisper-cli: \(SidecarPaths.whisperCli)
           ffmpeg: \(SidecarPaths.ffmpeg)
        """)
    }
}
