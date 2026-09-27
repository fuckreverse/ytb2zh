import Foundation
import Ytb2ZHCore

// MARK: - Demucs 人声分离（python -m demucs sidecar，--two-stems=vocals）
// 产物：workDir/vocals.wav + workDir/instrumental.wav（16k 单声道 wav，供转录/BGM 混入）

public struct DemucsVocalSeparator: VocalSeparationEngine {
    public let descriptor = EngineDescriptor(
        "demucs", "Demucs 人声分离", "python -m demucs，需 pip install demucs")

    public init() {}

    public func separate(video: URL, workDir: URL, options: SeparationOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> (vocals: URL, instrumental: URL) {
        guard let python = SidecarPaths.which("python3") else {
            throw EngineError.engineFailure("未找到 python3")
        }
        let outDir = workDir.appendingPathComponent("demucs_out", isDirectory: true)
        try? FileManager.default.removeItem(at: outDir)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        progress(0.1, "Demucs 分离中（CPU 较慢，耐心等待）…")
        let runner = ProcessRunner()
        let r = try runner.run(python, ["-m", "demucs",
                                        "-n", options.model,
                                        "--two-stems=vocals",
                                        "-o", outDir.path,
                                        video.path],
                               onStderr: { s in
                                   if s.contains("%") {
                                       progress(0.15, s.trimmingCharacters(in: .whitespacesAndNewlines))
                                   }
                               })
        guard r.code == 0 else {
            let err = r.stderr.suffix(400).description
            if err.contains("No module named") {
                throw EngineError.engineFailure("demucs 未安装：pip3 install demucs")
            }
            throw EngineError.engineFailure("Demucs 分离失败：\(err)")
        }

        // demucs 产物：outdir/<model>/<曲名无扩展名>/vocals.wav + no_vocals.wav
        let stemDir = outDir.appendingPathComponent(options.model)
            .appendingPathComponent(video.deletingPathExtension().lastPathComponent)
        let rawVocals = stemDir.appendingPathComponent("vocals.wav")
        let rawBG = stemDir.appendingPathComponent("no_vocals.wav")
        guard FileManager.default.fileExists(atPath: rawVocals.path),
              FileManager.default.fileExists(atPath: rawBG.path) else {
            throw EngineError.engineFailure("Demucs 产物缺失：\(stemDir.path)")
        }

        progress(0.9, "转码 wav…")
        let vocals = workDir.appendingPathComponent("vocals.wav")
        let instrumental = workDir.appendingPathComponent("instrumental.wav")
        _ = try runFFmpeg(["-y", "-v", "error", "-i", rawVocals.path,
                           "-ar", "16000", "-ac", "1", vocals.path])
        _ = try runFFmpeg(["-y", "-v", "error", "-i", rawBG.path,
                           "-ar", "48000", "-ac", "2", instrumental.path])
        progress(1.0, "分离完成")
        return (vocals, instrumental)
    }
}

public struct NullVocalSeparator: VocalSeparationEngine {
    public let descriptor = EngineDescriptor("none", "不分离", "直接用原音轨")
    public init() {}
    public func separate(video: URL, workDir: URL, options: SeparationOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> (vocals: URL, instrumental: URL) {
        throw EngineError.engineFailure("当前 Profile 不做人声分离")
    }
}
