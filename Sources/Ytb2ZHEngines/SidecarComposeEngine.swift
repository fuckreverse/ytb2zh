import Foundation
import Ytb2ZHCore

// MARK: - 旁挂字幕合成引擎（compose 第二步实现）
// 面向「成片要进外部剪辑流程」的用户：旁挂 SRT + 无烧录成片。
// 与 ffmpeg 引擎的差别：字幕不烧进画面、视频流直接 copy（不重编码，快）、
// 配音轨为干净替换（不混原声/BGM——混音交给外部剪辑软件）。

public struct SidecarComposeEngine: CompositionEngine {
    public let descriptor = EngineDescriptor(
        "sidecar", "旁挂字幕", "旁挂 SRT + 无烧录成片，视频不重编码，供外部剪辑使用")

    public init() {}

    public func compose(video: URL, placements: [Placement], unitSchedules: [UnitSchedule],
                        units: [SpeechUnit], cacheDir: URL, output: URL, options: ComposeOptions,
                        progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let fm = FileManager.default
        let workDir = output.deletingLastPathComponent()
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)

        // 1) SRT（与 ffmpeg 引擎同一生成器：Netflix 行宽 + 可选中英双语）
        let srt = workDir.appendingPathComponent("zh.srt")
        try SRTBuilder.build(units: units, unitSchedules: unitSchedules,
                             maxLength: options.subtitleMaxLength,
                             perLineBias: options.subtitleTargetMultiplier,
                             bilingual: options.bilingualSubtitles)
            .write(to: srt, atomically: true, encoding: .utf8)
        progress(0.05, "字幕已生成")

        // 2) 旁挂 SRT 到输出旁边（<成片>.srt）
        let sidecar = output.deletingPathExtension().appendingPathExtension("srt")
        try? fm.removeItem(at: sidecar)
        try fm.copyItem(at: srt, to: sidecar)

        // 3) 无配音（纯字幕模式）：视频原样 copy
        guard !placements.isEmpty else {
            progress(0.5, "合成中（纯字幕，视频不重编码）")
            try runFFmpeg(["-y", "-v", "error", "-i", video.path, "-c", "copy", output.path])
            progress(1.0, "完成")
            return output
        }

        // 4) 配音轨 + 成片：视频 copy，音频换配音
        let dubWav = try ComposeAudioTrack.assemble(placements: placements, cacheDir: cacheDir,
                                                    workDir: workDir, progress: progress)
        progress(0.5, "合成中（视频不重编码）")
        try runFFmpeg(["-y", "-v", "error", "-i", video.path, "-i", dubWav.path,
                       "-map", "0:v", "-map", "1:a",
                       "-c:v", "copy", "-c:a", "aac", "-b:a", "192k",
                       "-movflags", "+faststart", output.path])
        progress(1.0, "完成")
        return output
    }
}
