import Foundation
import Ytb2ZHCore

// MARK: - 本地 TTS 引擎（零网络依赖，纯离线）
// local-say：macOS 内置 say 命令，系统自带中文音色
// sherpa-onnx：用户下载的 sherpa-onnx-offline-tts 二进制 + 模型目录

// MARK: macOS say 命令引擎

public struct LocalSayTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "local-say", "macOS 语音合成（say）", "系统内置，零依赖，离线可用")
    public var supportsRateControl: Bool { false }

    public init() {}

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // 幂等缓存命中
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = probeDuration(mp3), cached >= 0.35 {
            return (mp3, cached)
        }

        let voice = options.localVoice.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Tingting" : options.localVoice.trimmingCharacters(in: .whitespaces)

        // 1) 写临时 AIFF（say 原生输出格式）
        let aiff = cacheDir.appendingPathComponent("\(cacheKey).aiff")
        try? fm.removeItem(at: aiff)
        let sayPath = "/usr/bin/say"
        let runner = ProcessRunner()
        let r = try runner.run(sayPath, ["-v", voice, "-o", aiff.path, text])
        guard r.code == 0, fm.fileExists(atPath: aiff.path) else {
            throw EngineError.engineFailure("say 合成失败：\(String(r.stderr.suffix(300)))")
        }

        // 2) ffmpeg 转 mp3
        do {
            try runFFmpeg(["-y", "-v", "error", "-i", aiff.path,
                           "-codec:a", "libmp3lame", "-q:a", "4", mp3.path])
        } catch {
            // 转格式失败但 AIFF 还在，尝试直接用 AIFF 探时长
            let dur = probeDuration(aiff) ?? 0
            if dur >= 0.35 {
                try? fm.moveItem(at: aiff, to: mp3)
                try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
                return (mp3, dur)
            }
            throw EngineError.engineFailure("音频转码失败：\(error.localizedDescription)")
        }
        try? fm.removeItem(at: aiff)

        let dur = probeDuration(mp3) ?? 0
        try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
        guard dur >= 0.35 else {
            throw EngineError.engineFailure("合成时长异常 \(dur)s")
        }
        return (mp3, dur)
    }
}

// MARK: Sherpa-Onnx 离线 TTS 引擎

public struct SherpaOnnxTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "sherpa-onnx", "Sherpa-Onnx 离线 TTS", "需下载二进制 + 模型，音质优于 say")
    public var supportsRateControl: Bool { false }

    public init() {}

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        // 幂等缓存命中
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = probeDuration(mp3), cached >= 0.35 {
            return (mp3, cached)
        }

        // 1) 配置校验先行（未配置模型目录时优先报配置错，而非二进制缺失）
        if options.sherpaOnnxModelDir.trimmingCharacters(in: .whitespaces).isEmpty {
            throw EngineError.engineFailure(
                "未配置 Sherpa-Onnx 模型目录。请在「应用设置 → 模型分配」选择模型，或手动指定含 model.onnx 的目录路径。")
        }
        // 2) 定位 sherpa-onnx 二进制
        let binPath = try resolveBinary()
        // 3) 定位模型目录（展开 ~ 并校验必要文件）
        let modelDir = try resolveModelDir(options.sherpaOnnxModelDir)

        // 4) 合成到临时 wav
        let wav = cacheDir.appendingPathComponent("\(cacheKey).wav")
        try? fm.removeItem(at: wav)

        let r = try runSherpaOnnx(binPath: binPath, modelDir: modelDir, text: text, output: wav)
        guard r == 0, fm.fileExists(atPath: wav.path) else {
            throw EngineError.engineFailure(
                "Sherpa-Onnx 合成失败（exit=\(r)）。请检查模型目录是否完整（需含 model.onnx、tokens.txt、dict/）")
        }

        // 5) ffmpeg 转 mp3
        try runFFmpeg(["-y", "-v", "error", "-i", wav.path,
                       "-codec:a", "libmp3lame", "-q:a", "4", mp3.path])
        try? fm.removeItem(at: wav)

        let dur = probeDuration(mp3) ?? 0
        try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
        guard dur >= 0.35 else {
            throw EngineError.engineFailure("合成时长异常 \(dur)s")
        }
        return (mp3, dur)
    }

    // MARK: - 私有

    /// 查找 sherpa-onnx-offline-tts 二进制：环境变量目录 → homebrew → 常见下载位置
    private func resolveBinary() throws -> String {
        let fm = FileManager.default
        // 常见位置
        let candidates = [
            NSHomeDirectory() + "/sherpa-onnx/bin/sherpa-onnx-offline-tts",
            NSHomeDirectory() + "/sherpa-onnx-offline-tts",
            "/opt/homebrew/bin/sherpa-onnx-offline-tts",
            "/usr/local/bin/sherpa-onnx-offline-tts",
        ]
        for c in candidates where fm.isExecutableFile(atPath: c) {
            return c
        }
        // which
        if let p = SidecarPaths.which("sherpa-onnx-offline-tts") {
            return p
        }
        throw EngineError.engineFailure(
            "未找到 sherpa-onnx-offline-tts 二进制。请从 https://github.com/k2-fsa/sherpa-onnx/releases 下载对应模型二进制，解压到 ~/sherpa-onnx/bin/ 或通过 homebrew 安装。")
    }

    /// 解析模型目录（支持 ~ 展开）；前置空值校验在 synthesize 里，这里只做文件级校验
    private func resolveModelDir(_ configured: String) throws -> String {
        let path = configured.trimmingCharacters(in: .whitespaces)
        let expanded = NSString(string: path).expandingTildeInPath
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            throw EngineError.engineFailure("Sherpa-Onnx 模型目录不存在：\(expanded)")
        }
        // 校验必要文件
        let modelFile = expanded + "/model.onnx"
        let tokensFile = expanded + "/tokens.txt"
        guard fm.fileExists(atPath: modelFile) else {
            throw EngineError.engineFailure("模型目录缺少 model.onnx：\(expanded)")
        }
        guard fm.fileExists(atPath: tokensFile) else {
            throw EngineError.engineFailure("模型目录缺少 tokens.txt：\(expanded)")
        }
        return expanded
    }

    /// 调用 sherpa-onnx-offline-tts 二进制
    /// 用法：sherpa-onnx-offline-tts --vits-model=<dir>/model.onnx --vits-tokens=<dir>/tokens.txt
    ///       --vits-data-dir=<dir>/dict --output-filename=<wav> "text"
    private func runSherpaOnnx(binPath: String, modelDir: String, text: String, output: URL) throws -> Int32 {
        let dictDir = modelDir + "/dict"
        let args = [
            "--vits-model", modelDir + "/model.onnx",
            "--vits-tokens", modelDir + "/tokens.txt",
            "--vits-data-dir", dictDir,
            "--vits-length-scale", "1.0",
            "--output-filename", output.path,
            text,
        ]
        let runner = ProcessRunner()
        let r = try runner.run(binPath, args)
        return r.code
    }
}
