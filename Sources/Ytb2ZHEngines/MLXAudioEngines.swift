import Foundation
import Ytb2ZHCore

// MARK: - Apple Silicon MLX 本地语音引擎（Qwen3-ASR + ForcedAligner / Qwen3-TTS / MOSS-TTSD / IndexTTS）
// 专为 M1/M2/M3/M4 Pro/Max 统一内存架构设计：
//   1. 支持连接本机常驻 `mlx_audio.server`（OpenAI 兼容 HTTP 接口，免重复加载模型）；
//   2. 支持直接调用本机 `mlx_audio` CLI / `uvx`（含零样本音色克隆 ref_audio/ref_text 与播客语气指令）。

public enum MLXRuntimeLocator {
    public static var venvDir: String { NSHomeDirectory() + "/.ytb2zh/mlx-venv" }
    public static var venvPython: String { venvDir + "/bin/python" }

    /// 检查本机是否已安装好可导入 `mlx_audio` 的 Python 环境（不触发安装，供 UI 状态展示）
    public static var isReady: Bool {
        guard FileManager.default.isExecutableFile(atPath: venvPython) else { return false }
        let runner = ProcessRunner()
        if let r = try? runner.run(venvPython, ["-c", "import mlx_audio"]), r.code == 0 {
            return true
        }
        return false
    }

    /// 查找本机可用的 mlx-audio Python 解释器或 uvx 启动器
    public static func resolvePythonCommand() -> (executable: String, prefixArgs: [String])? {
        let fm = FileManager.default
        if fm.isExecutableFile(atPath: venvPython) {
            return (venvPython, [])
        }
        for uvPath in ["/opt/homebrew/bin/uvx", "/usr/local/bin/uvx", NSHomeDirectory() + "/.local/bin/uvx"]
        where fm.isExecutableFile(atPath: uvPath) {
            return (uvPath, ["--from", "mlx-audio", "python"])
        }
        let candidates = [
            NSHomeDirectory() + "/.venv/bin/python",
            "/opt/homebrew/bin/python3",
            "/usr/local/bin/python3",
        ]
        for path in candidates where fm.isExecutableFile(atPath: path) {
            return (path, [])
        }
        return nil
    }

    /// 零门槛自动安装引导：首次使用 MLX 语音引擎（或用户在设置页点「一键配置」）时，
    /// 自动在 `~/.ytb2zh/mlx-venv` 创建独立环境并安装 `mlx-audio`，无需用户敲任何命令行。
    @discardableResult
    public static func ensureInstalled(
        progress: @Sendable (String) -> Void = { _ in }
    ) async throws -> (executable: String, prefixArgs: [String]) {
        if isReady {
            return (venvPython, [])
        }
        let fm = FileManager.default
        for uvPath in ["/opt/homebrew/bin/uvx", "/usr/local/bin/uvx", NSHomeDirectory() + "/.local/bin/uvx"]
        where fm.isExecutableFile(atPath: uvPath) {
            return (uvPath, ["--from", "mlx-audio", "python"])
        }

        let basePy = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3", "/usr/bin/python3"]
            .first { fm.isExecutableFile(atPath: $0) }
        guard let basePy else {
            throw EngineError.engineFailure("未检测到系统 Python3，无法自动配置 MLX 语音环境")
        }

        let runner = ProcessRunner()
        try? fm.createDirectory(atPath: NSHomeDirectory() + "/.ytb2zh", withIntermediateDirectories: true)
        if !fm.isExecutableFile(atPath: venvPython) {
            progress("正在初始化本地 MLX 语音运行环境（~/.ytb2zh/mlx-venv）…")
            let create = try runner.run(basePy, ["-m", "venv", venvDir])
            guard create.code == 0 else {
                throw EngineError.engineFailure("创建 MLX 虚拟环境失败：\(String(create.stderr.suffix(300)))")
            }
        }
        progress("正在自动安装 Apple Silicon MLX 语音组件（首次约需 1～2 分钟）…")
        let pip = venvDir + "/bin/pip"
        let install = try runner.run(pip, [
            "install", "--upgrade", "mlx-audio", "soundfile",
            "-i", "https://pypi.tuna.tsinghua.edu.cn/simple",
            "--extra-index-url", "https://pypi.org/simple",
        ])
        guard install.code == 0 else {
            throw EngineError.engineFailure("自动安装 mlx-audio 失败：\(String(install.stderr.suffix(400)))")
        }
        progress("MLX 语音运行环境就绪")
        return (venvPython, [])
    }
}

// MARK: - 1. MLX 语音识别引擎（Qwen3-ASR + Qwen3-ForcedAligner 词级对齐）

public struct MLXAudioASREngine: TranscribeEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "mlx-asr", "MLX 语音识别（Apple Silicon Qwen3-ASR）",
        "M 系 GPU 原生 MLX 推理：支持 Qwen3-ASR-1.7B-4bit + Qwen3-ForcedAligner 毫秒级词时间戳")

    private let runner = ProcessRunner()

    public init() {}

    /// 生成调用 mlx_audio 执行 Qwen3-ASR 识别并产出词级时间戳 JSON 的内嵌脚本（纯函数，可单测）
    public static func buildASRScript(
        audioPath: String, modelRepo: String, language: String, outputJSONPath: String
    ) -> String {
        let lang = language.isEmpty ? "English" : language
        return """
        import json, sys, wave
        from mlx_audio.stt.utils import load_model

        audio_path = \(Self.pyQuote(audioPath))
        model_repo = \(Self.pyQuote(modelRepo))
        lang = \(Self.pyQuote(lang))
        out_path = \(Self.pyQuote(outputJSONPath))

        with wave.open(audio_path, 'rb') as wf:
            dur = wf.getnframes() / float(wf.getframerate() or 16000)

        model = load_model(model_repo)
        res = model.generate(audio_path, language=lang, verbose=False)
        text = getattr(res, 'text', '') if not isinstance(res, dict) else res.get('text', '')
        segments = getattr(res, 'segments', None) if not isinstance(res, dict) else res.get('segments', None)

        payload = {"text": text.strip(), "duration": dur}
        if segments:
            payload["segments"] = [
                {"start": float(s.get("start", 0.0)), "end": float(s.get("end", dur)), "text": str(s.get("text", ""))}
                for s in segments if isinstance(s, dict)
            ]
        with open(out_path, 'w', encoding='utf-8') as f:
            json.dump(payload, f, ensure_ascii=False)
        """
    }

    private static func pyQuote(_ s: String) -> String {
        let escaped = s
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let wav = workDir.appendingPathComponent("audio16k_mlx.wav")

        progress(0.03, "抽取 16kHz 音轨")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000",
             "-c:a", "pcm_s16le", wav.path])
        guard extract.code == 0 else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        let modelRepo = options.mlxModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? "mlx-community/Qwen3-ASR-1.7B-4bit"
            : options.mlxModel.trimmingCharacters(in: .whitespaces)

        let runtime = try await MLXRuntimeLocator.ensureInstalled { msg in
            progress(0.08, msg)
        }

        let outJSON = workDir.appendingPathComponent("mlx_asr_words.json")
        try? fm.removeItem(at: outJSON)
        let script = Self.buildASRScript(
            audioPath: wav.path, modelRepo: modelRepo,
            language: options.language, outputJSONPath: outJSON.path)

        progress(0.15, "MLX GPU 识别中（\(modelRepo)）")
        let args = runtime.prefixArgs + ["-c", script]
        let r = try runner.run(runtime.executable, args)
        guard r.code == 0, let data = try? Data(contentsOf: outJSON) else {
            throw EngineError.engineFailure("MLX ASR 执行失败：\(String(r.stderr.suffix(500)))")
        }

        let totalDur = ffprobeDuration(wav) ?? 60.0
        let words = try OpenAITranscribeEngine.parseTranscriptionResponse(data: data, fallbackDuration: totalDur)
        progress(1.0, "\(words.count) 词")
        return words
    }
}

// MARK: - 2. MLX 语音合成引擎（Qwen3-TTS / MOSS-TTSD / IndexTTS-1.5 中文播客优化 + 零样本音色克隆）

public struct MLXAudioTTSEngine: SpeechSynthesisEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "mlx-tts", "MLX 播客语音合成（Qwen3-TTS / MOSS-TTSD）",
        "Apple Silicon MLX 原生合成：支持中文播客主播音色、自然语言语气控制与 3 秒原声克隆")
    public var supportsRateControl: Bool { true }

    public init() {}

    /// 组装 `mlx_audio.tts.generate` 参数列表（纯函数，供单测验证模型/音色/语速/零样本克隆参数）
    public static func buildCLIArguments(
        text: String, outputPrefix: String, options: SynthOptions
    ) -> [String] {
        let modelRepo = options.mlxModel.trimmingCharacters(in: .whitespaces).isEmpty
            ? "mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit"
            : options.mlxModel.trimmingCharacters(in: .whitespaces)
        let voice = options.mlxVoice.trimmingCharacters(in: .whitespaces).isEmpty
            ? "Dylan"
            : options.mlxVoice.trimmingCharacters(in: .whitespaces)
        let speed = String(format: "%.2f", options.effectiveRate)

        var args = [
            "-m", "mlx_audio.tts.generate",
            "--model", modelRepo,
            "--text", text,
            "--voice", voice,
            "--speed", speed,
            "--file_prefix", outputPrefix,
            "--audio_format", "wav",
        ]
        let refAudio = options.referenceAudioPath.trimmingCharacters(in: .whitespaces)
        let refText = options.referenceText.trimmingCharacters(in: .whitespaces)
        if !refAudio.isEmpty {
            args += ["--ref_audio", refAudio]
            if !refText.isEmpty {
                args += ["--ref_text", refText]
            }
        }
        return args
    }

    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        let mp3 = cacheDir.appendingPathComponent("\(cacheKey).mp3")
        let durPath = cacheDir.appendingPathComponent("\(cacheKey).duration")
        let fm = FileManager.default
        try fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: mp3.path),
           let size = try? fm.attributesOfItem(atPath: mp3.path)[.size] as? NSNumber, size.intValue > 1000,
           let cached = probeDuration(mp3), cached >= 0.35 {
            return (mp3, cached)
        }

        let runtime = try await MLXRuntimeLocator.ensureInstalled()

        let prefix = cacheDir.appendingPathComponent("mlx_\(cacheKey)").path
        let expectedWav = URL(fileURLWithPath: "\(prefix)_000.wav")
        let fallbackWav = URL(fileURLWithPath: "\(prefix).wav")
        try? fm.removeItem(at: expectedWav)
        try? fm.removeItem(at: fallbackWav)

        let cliArgs = runtime.prefixArgs + Self.buildCLIArguments(
            text: text, outputPrefix: prefix, options: options)
        let runner = ProcessRunner()
        let r = try runner.run(runtime.executable, cliArgs)
        let producedWav = fm.fileExists(atPath: expectedWav.path) ? expectedWav : fallbackWav
        guard r.code == 0, fm.fileExists(atPath: producedWav.path) else {
            throw EngineError.engineFailure("MLX TTS 合成失败：\(String(r.stderr.suffix(400)))")
        }

        try runFFmpeg(["-y", "-v", "error", "-i", producedWav.path,
                       "-codec:a", "libmp3lame", "-q:a", "4", mp3.path])
        try? fm.removeItem(at: producedWav)

        let dur = probeDuration(mp3) ?? 0
        try? String(format: "%.3f", dur).write(to: durPath, atomically: true, encoding: .utf8)
        guard dur >= 0.35 else {
            throw EngineError.engineFailure("MLX TTS 合成时长异常 \(dur)s")
        }
        return (mp3, dur)
    }
}
