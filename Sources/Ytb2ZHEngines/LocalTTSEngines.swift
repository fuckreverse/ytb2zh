import Foundation
import CSherpaOnnx
import Ytb2ZHCore

// MARK: - 本地 TTS 引擎（零网络依赖，纯离线）
// local-say：macOS 内置 say 命令，系统自带中文音色
// sherpa-onnx：用户下载的 sherpa-onnx-offline-tts 二进制 + 模型目录

// MARK: macOS say 命令引擎

public struct LocalSayTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "local-say", "macOS 语音合成（say）", "系统内置，零依赖，离线可用")
    public var supportsRateControl: Bool { true }

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

        // 1) 写临时 AIFF（say 原生输出格式）；rate≠1.0 时按 180wpm 基线折算 -r
        // （实测 1.2×→1.18× 近似线性；残余漂移由调度层 atempo 吸收）
        let aiff = cacheDir.appendingPathComponent("\(cacheKey).aiff")
        try? fm.removeItem(at: aiff)
        let sayPath = "/usr/bin/say"
        var sayArgs = ["-v", voice]
        let rate = options.effectiveRate
        if abs(rate - 1.0) >= 0.001 {
            sayArgs += ["-r", String(Int((180 * rate).rounded()))]
        }
        sayArgs += ["-o", aiff.path, text]
        let runner = ProcessRunner()
        let r = try runner.run(sayPath, sayArgs)
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

// MARK: Sherpa-Onnx 离线 TTS 引擎（内嵌 v1.13.8 C API，支持 VITS / Kokoro 中英播客多音色 / ZipVoice 零样本克隆）
// 引擎 id 保持 "sherpa-onnx"：旧 profile 无需改动；二进制不再需要，模型目录缺失时自动下载默认中文模型。

public struct SherpaOnnxTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "sherpa-onnx", "Sherpa-Onnx 离线 TTS（内嵌 VITS / Kokoro / ZipVoice）",
        "进程内推理：支持 Kokoro v1.1 中英混读播客多音色、ZipVoice 零样本音色克隆及 VITS 中文模型")
    public var supportsRateControl: Bool { true }

    public enum ModelFamily: String, Sendable, Equatable {
        case vits
        case kokoro
        case zipvoice
    }

    public init() {}

    /// 已加载模型缓存（按目录缓存进程级句柄；提供 unloadAll() 主动释放统一内存）
    private static let loaded = Mutex<[String: OpaquePointer]>([:])

    /// 主动释放已缓存的 Sherpa-Onnx TTS 实例，回收 Apple Silicon 统一内存
    public static func unloadAll() {
        let handles = loaded.with { dict -> [OpaquePointer] in
            let all = Array(dict.values)
            dict.removeAll()
            return all
        }
        for h in handles {
            SherpaOnnxDestroyOfflineTts(h)
        }
    }

    /// 探测模型目录所属架构（Kokoro 含 voices.bin；ZipVoice 含 encoder+decoder+vocos；其余为 VITS）
    public static func detectModelFamily(at modelDir: String) -> ModelFamily {
        let fm = FileManager.default
        if fm.fileExists(atPath: modelDir + "/voices.bin") {
            return .kokoro
        }
        let files = (try? fm.contentsOfDirectory(atPath: modelDir)) ?? []
        let hasEncoder = files.contains { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") }
        let hasDecoder = files.contains { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") }
        let hasVocoder = files.contains { ($0.hasPrefix("vocos") || $0.hasPrefix("vocoder")) && $0.hasSuffix(".onnx") }
        if hasEncoder && hasDecoder && hasVocoder {
            return .zipvoice
        }
        return .vits
    }

    /// 解析 Kokoro v1.1 / 多说话人模型的 Speaker ID（支持数字 ID、zf_xxx / zm_xxx 音色名及播客别名）
    public static func resolveSpeakerID(_ voice: String) -> Int32 {
        let trimmed = voice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if trimmed.isEmpty { return 0 }
        if let id = Int32(trimmed), id >= 0 { return id }
        let aliases: [String: Int32] = [
            "af_alloy": 0, "af_aoede": 1, "af_bella": 2, "af_heart": 3,
            "am_adam": 11, "am_michael": 16,
            "zf_xiaobei": 45, "zf_xiaoni": 46, "zf_xiaoxiao": 47, "zf_xiaoyi": 48,
            "zm_yunjian": 49, "zm_yunxi": 50, "zm_yunxia": 51, "zm_yunyang": 52,
            "zf_001": 45, "zf_002": 46, "zf_003": 47, "zf_004": 48,
            "zm_009": 49, "zm_010": 50, "zm_011": 51, "zm_012": 52,
            "kokoro-zh-female": 45, "kokoro-zh-male": 50,
        ]
        if let mapped = aliases[trimmed] { return mapped }
        return 0
    }

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

        // 1) 模型目录：显式配置优先（缺失报错），支持 kokoro / zipvoice 预设名自动下载
        let modelDir = try await ModelStore.ensureSherpaModel(
            configured: options.sherpaOnnxModelDir, proxy: options.edgeProxy)
        let family = Self.detectModelFamily(at: modelDir)

        // 2) 取/建模型实例（重推理走专用线程）
        let tts = try await Self.ttsInstance(modelDir: modelDir, family: family)

        // 3) 合成 → wav（C 调用收进同步 helper，调度闭包只捕获 Sendable 值）
        let wav = cacheDir.appendingPathComponent("\(cacheKey).wav")
        try? fm.removeItem(at: wav)
        nonisolated(unsafe) let ttsHandle = tts
        let speed = Float(options.effectiveRate)
        let speakerID = Self.resolveSpeakerID(
            options.localVoice.isEmpty ? options.voice : options.localVoice)
        let refAudioPath = options.referenceAudioPath.trimmingCharacters(in: .whitespaces)
        let refText = options.referenceText.trimmingCharacters(in: .whitespaces)

        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.generateSync(
                        tts: ttsHandle, family: family, text: text, wav: wav,
                        sid: speakerID, speed: speed,
                        refAudioPath: refAudioPath, refText: refText)
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
        guard fm.fileExists(atPath: wav.path) else {
            throw EngineError.engineFailure("Sherpa-Onnx 未产出音频")
        }

        // 4) ffmpeg 转 mp3（与下游配音轨格式一致）
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

    /// 同步合成（支持标准说话人合成与 ZipVoice 零样本参考音频克隆）
    nonisolated private static func generateSync(
        tts: OpaquePointer, family: ModelFamily, text: String, wav: URL,
        sid: Int32, speed: Float, refAudioPath: String, refText: String
    ) throws {
        var genCfg = SherpaOnnxGenerationConfig()
        genCfg.sid = sid
        genCfg.speed = speed
        genCfg.num_steps = 4

        let generated: UnsafePointer<SherpaOnnxGeneratedAudio>?
        if family == .zipvoice || (!refAudioPath.isEmpty && FileManager.default.fileExists(atPath: refAudioPath)) {
            guard !refAudioPath.isEmpty, FileManager.default.fileExists(atPath: refAudioPath),
                  let wave = SherpaOnnxReadWave(UnsafePointer(strdup(refAudioPath))) else {
                throw EngineError.engineFailure(
                    "ZipVoice 零样本克隆需要参考音频（请开启 cloneSourceVoice 或指定 referenceAudioPath）")
            }
            defer { SherpaOnnxFreeWave(wave) }
            genCfg.reference_audio = wave.pointee.samples
            genCfg.reference_audio_len = wave.pointee.num_samples
            genCfg.reference_sample_rate = wave.pointee.sample_rate
            if !refText.isEmpty {
                genCfg.reference_text = UnsafePointer(strdup(refText))
            }
            generated = SherpaOnnxOfflineTtsGenerateWithConfig(
                tts, UnsafePointer(strdup(text)), &genCfg, nil, nil)
        } else {
            generated = SherpaOnnxOfflineTtsGenerateWithConfig(
                tts, UnsafePointer(strdup(text)), &genCfg, nil, nil)
        }

        guard let audio = generated else {
            throw EngineError.engineFailure(
                "Sherpa-Onnx 合成失败。请检查模型目录是否完整（\(family.rawValue)）")
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let a = audio.pointee
        let ok = SherpaOnnxWriteWave(a.samples, a.n, a.sample_rate,
                                     UnsafePointer(strdup(wav.path)))
        guard ok == 1 else {
            throw EngineError.engineFailure("Sherpa-Onnx 写 wav 失败：\(wav.path)")
        }
    }

    /// 组装 Kokoro 多语言词典路径（合并中文 + 英文词典以支持科技播客中英混读）
    static func kokoroLexiconPaths(at modelDir: String) -> String {
        let fm = FileManager.default
        let candidates = ["lexicon-zh.txt", "lexicon-us-en.txt", "lexicon-gb-en.txt", "lexicon.txt"]
        var found: [String] = []
        for name in candidates where fm.fileExists(atPath: modelDir + "/" + name) {
            found.append(modelDir + "/" + name)
        }
        // 若存在中英双词典，只取 zh + us-en 避免美英/英英重复
        if found.contains(modelDir + "/lexicon-zh.txt") && found.contains(modelDir + "/lexicon-us-en.txt") {
            return "\(modelDir)/lexicon-zh.txt,\(modelDir)/lexicon-us-en.txt"
        }
        return found.first ?? ""
    }

    /// 取缓存的 SherpaOnnxOfflineTts 实例（无则按 VITS / Kokoro / ZipVoice 家族加载）
    private static func ttsInstance(modelDir: String, family: ModelFamily) async throws -> OpaquePointer {
        if let cached = loaded.wrapped[modelDir] { return cached }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OpaquePointer, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var config = SherpaOnnxOfflineTtsConfig()
                let fm = FileManager.default

                switch family {
                case .kokoro:
                    config.model.kokoro.model = UnsafePointer(strdup(modelDir + "/model.onnx"))
                    config.model.kokoro.voices = UnsafePointer(strdup(modelDir + "/voices.bin"))
                    if fm.fileExists(atPath: modelDir + "/tokens.txt") {
                        config.model.kokoro.tokens = UnsafePointer(strdup(modelDir + "/tokens.txt"))
                    }
                    if fm.fileExists(atPath: modelDir + "/espeak-ng-data") {
                        config.model.kokoro.data_dir = UnsafePointer(strdup(modelDir + "/espeak-ng-data"))
                    }
                    let lex = Self.kokoroLexiconPaths(at: modelDir)
                    if !lex.isEmpty {
                        config.model.kokoro.lexicon = UnsafePointer(strdup(lex))
                    }
                    config.model.kokoro.lang = UnsafePointer(strdup("z"))
                    config.model.kokoro.length_scale = 1.0

                case .zipvoice:
                    let files = (try? fm.contentsOfDirectory(atPath: modelDir)) ?? []
                    let enc = files.first { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") } ?? "encoder.int8.onnx"
                    let dec = files.first { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") } ?? "decoder.int8.onnx"
                    let voc = files.first { ($0.hasPrefix("vocos") || $0.hasPrefix("vocoder")) && $0.hasSuffix(".onnx") } ?? "vocos_24khz.onnx"
                    config.model.zipvoice.encoder = UnsafePointer(strdup(modelDir + "/" + enc))
                    config.model.zipvoice.decoder = UnsafePointer(strdup(modelDir + "/" + dec))
                    config.model.zipvoice.vocoder = UnsafePointer(strdup(modelDir + "/" + voc))
                    if fm.fileExists(atPath: modelDir + "/tokens.txt") {
                        config.model.zipvoice.tokens = UnsafePointer(strdup(modelDir + "/tokens.txt"))
                    }
                    if fm.fileExists(atPath: modelDir + "/espeak-ng-data") {
                        config.model.zipvoice.data_dir = UnsafePointer(strdup(modelDir + "/espeak-ng-data"))
                    }
                    if fm.fileExists(atPath: modelDir + "/lexicon.txt") {
                        config.model.zipvoice.lexicon = UnsafePointer(strdup(modelDir + "/lexicon.txt"))
                    }
                    config.model.zipvoice.feat_scale = 0.1
                    config.model.zipvoice.t_shift = 0.5
                    config.model.zipvoice.target_rms = 0.1
                    config.model.zipvoice.guidance_scale = 1.0

                case .vits:
                    if fm.fileExists(atPath: modelDir + "/model.onnx") {
                        config.model.vits.model = UnsafePointer(strdup(modelDir + "/model.onnx"))
                    }
                    if fm.fileExists(atPath: modelDir + "/tokens.txt") {
                        config.model.vits.tokens = UnsafePointer(strdup(modelDir + "/tokens.txt"))
                    }
                    if fm.fileExists(atPath: modelDir + "/lexicon.txt") {
                        config.model.vits.lexicon = UnsafePointer(strdup(modelDir + "/lexicon.txt"))
                    }
                    config.model.vits.noise_scale = 0.667
                    config.model.vits.noise_scale_w = 0.8
                    config.model.vits.length_scale = 1.0
                }

                config.model.num_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
                config.model.provider = UnsafePointer(strdup("cpu"))
                config.model.debug = 0
                let fsts = ModelStore.sherpaRuleFsts(at: modelDir)
                if !fsts.isEmpty { config.rule_fsts = UnsafePointer(strdup(fsts)) }

                guard let tts = SherpaOnnxCreateOfflineTts(&config) else {
                    cont.resume(throwing: EngineError.engineFailure(
                        "Sherpa-Onnx 模型加载失败：\(modelDir)（缺 model.onnx 或文件损坏）"))
                    return
                }
                loaded.with { $0[modelDir] = tts }
                cont.resume(returning: tts)
            }
        }
    }
}

// MARK: - Sherpa-Onnx 离线 ASR 引擎（内嵌 v1.13.8 C API，支持 Parakeet TDT 0.6B / SenseVoice / Qwen3-ASR）

public struct SherpaOnnxASREngine: TranscribeEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "sherpa-asr", "Sherpa-Onnx 离线识别（Parakeet / SenseVoice / Qwen3-ASR）",
        "进程内 ONNX 推理，默认自动下载 Parakeet TDT 0.6B v3（极速英文词级时间戳+标点）")

    public enum ASRModelFamily: String, Sendable, Equatable {
        case parakeetTransducer
        case senseVoice
        case qwen3ASR
    }

    private let runner = ProcessRunner()

    public init() {}

    /// 识别模型目录所属的离线 ASR 家族
    public static func detectASRFamily(at modelDir: String) -> ASRModelFamily {
        let fm = FileManager.default
        let files = (try? fm.contentsOfDirectory(atPath: modelDir)) ?? []
        if files.contains(where: { $0.hasPrefix("conv_frontend") && $0.hasSuffix(".onnx") }) ||
           fm.fileExists(atPath: modelDir + "/tokenizer") {
            return .qwen3ASR
        }
        if files.contains(where: { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") }) &&
           files.contains(where: { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") }) &&
           files.contains(where: { $0.hasPrefix("joiner") && $0.hasSuffix(".onnx") }) {
            return .parakeetTransducer
        }
        return .senseVoice
    }

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let wav = workDir.appendingPathComponent("audio16k_sherpa.wav")

        progress(0.02, "抽取 16kHz 音轨")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000",
             "-c:a", "pcm_s16le", wav.path])
        guard extract.code == 0 else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        let configured = options.sherpaModelDir.trimmingCharacters(in: .whitespaces).isEmpty
            ? "" : options.sherpaModelDir
        let modelDir = try await ModelStore.ensureSherpaASRModel(configured: configured) { frac, msg in
            progress(0.02 + frac * 0.08, msg)
        }
        let family = Self.detectASRFamily(at: modelDir)
        let samples = try NativeWhisperEngine().readWavMono16(wav)
        let totalDur = Double(samples.count) / 16000.0

        progress(0.12, "Sherpa-Onnx 离线识别中（\(family.rawValue)）")
        let lang = options.language.isEmpty ? "en" : options.language
        let words = try await Self.recognize(
            modelDir: modelDir, family: family, samples: samples,
            language: lang, totalDuration: totalDur
        ) { frac in
            progress(0.12 + frac * 0.86, "转录中 \(Int(frac * 100))%")
        }
        progress(1.0, "\(words.count) 词")
        return words
    }

    private static func recognize(
        modelDir: String, family: ASRModelFamily, samples: [Float],
        language: String, totalDuration: Double,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TimedWord], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fm = FileManager.default
                let files = (try? fm.contentsOfDirectory(atPath: modelDir)) ?? []
                var config = SherpaOnnxOfflineRecognizerConfig()
                config.feat_config.sample_rate = 16000
                config.feat_config.feature_dim = 80
                config.model_config.num_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
                config.model_config.provider = UnsafePointer(strdup("cpu"))
                config.decoding_method = UnsafePointer(strdup("greedy_search"))

                if fm.fileExists(atPath: modelDir + "/tokens.txt") {
                    config.model_config.tokens = UnsafePointer(strdup(modelDir + "/tokens.txt"))
                }

                switch family {
                case .parakeetTransducer:
                    let enc = files.first { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") } ?? "encoder.int8.onnx"
                    let dec = files.first { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") } ?? "decoder.int8.onnx"
                    let joi = files.first { $0.hasPrefix("joiner") && $0.hasSuffix(".onnx") } ?? "joiner.int8.onnx"
                    config.model_config.transducer.encoder = UnsafePointer(strdup(modelDir + "/" + enc))
                    config.model_config.transducer.decoder = UnsafePointer(strdup(modelDir + "/" + dec))
                    config.model_config.transducer.joiner = UnsafePointer(strdup(modelDir + "/" + joi))
                    config.model_config.model_type = UnsafePointer(strdup("nemo_transducer"))

                case .qwen3ASR:
                    let conv = files.first { $0.hasPrefix("conv_frontend") && $0.hasSuffix(".onnx") } ?? "conv_frontend.onnx"
                    let enc = files.first { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") } ?? "encoder.int8.onnx"
                    let dec = files.first { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") } ?? "decoder.int8.onnx"
                    config.model_config.qwen3_asr.conv_frontend = UnsafePointer(strdup(modelDir + "/" + conv))
                    config.model_config.qwen3_asr.encoder = UnsafePointer(strdup(modelDir + "/" + enc))
                    config.model_config.qwen3_asr.decoder = UnsafePointer(strdup(modelDir + "/" + dec))
                    config.model_config.qwen3_asr.tokenizer = UnsafePointer(strdup(modelDir + "/tokenizer"))
                    config.model_config.qwen3_asr.max_total_len = 512
                    config.model_config.qwen3_asr.max_new_tokens = 256
                    config.model_config.qwen3_asr.temperature = 1e-6
                    config.model_config.qwen3_asr.top_p = 0.8

                case .senseVoice:
                    let mdl = files.first { $0.hasPrefix("model") && $0.hasSuffix(".onnx") } ?? "model.int8.onnx"
                    config.model_config.sense_voice.model = UnsafePointer(strdup(modelDir + "/" + mdl))
                    config.model_config.sense_voice.language = UnsafePointer(strdup(language.isEmpty ? "auto" : language))
                    config.model_config.sense_voice.use_itn = 1
                }

                guard let recognizer = SherpaOnnxCreateOfflineRecognizer(&config) else {
                    cont.resume(throwing: EngineError.engineFailure(
                        "Sherpa-Onnx ASR 模型初始化失败：\(modelDir)"))
                    return
                }
                defer { SherpaOnnxDestroyOfflineRecognizer(recognizer) }

                // 按 25 秒窗口切片推理，既能实时汇报进度又防止长音频爆内存
                let chunkSamples = 25 * 16000
                var allWords: [TimedWord] = []
                var offset = 0
                while offset < samples.count {
                    let end = min(samples.count, offset + chunkSamples)
                    let chunk = Array(samples[offset..<end])
                    let timeOffset = Double(offset) / 16000.0
                    let chunkDur = Double(end - offset) / 16000.0

                    if let stream = SherpaOnnxCreateOfflineStream(recognizer) {
                        chunk.withUnsafeBufferPointer { buf in
                            if let base = buf.baseAddress {
                                SherpaOnnxAcceptWaveformOffline(stream, 16000, base, Int32(chunk.count))
                            }
                        }
                        SherpaOnnxDecodeOfflineStream(recognizer, stream)
                        if let resPtr = SherpaOnnxGetOfflineStreamResult(stream) {
                            let res = resPtr.pointee
                            let count = Int(res.count)
                            var toks: [String] = []
                            var ts: [Double] = []
                            var durs: [Double] = []
                            if count > 0, let tokArr = res.tokens_arr {
                                for k in 0..<count {
                                    if let cStr = tokArr[k] {
                                        toks.append(String(cString: cStr))
                                    }
                                    if let tPtr = res.timestamps {
                                        ts.append(Double(tPtr[k]))
                                    }
                                    if let dPtr = res.durations {
                                        durs.append(Double(dPtr[k]))
                                    }
                                }
                            }
                            let text = res.text != nil ? String(cString: res.text) : ""
                            let chunkWords = Self.buildTimedWords(
                                tokens: toks, timestamps: ts, durations: durs,
                                fallbackText: text, timeOffset: timeOffset, chunkDuration: chunkDur)
                            allWords.append(contentsOf: chunkWords)
                            SherpaOnnxDestroyOfflineRecognizerResult(resPtr)
                        }
                        SherpaOnnxDestroyOfflineStream(stream)
                    }
                    offset = end
                    onProgress(Double(offset) / Double(max(1, samples.count)))
                }
                cont.resume(returning: allWords)
            }
        }
    }

    /// 将 Sherpa-Onnx BPE 子词流 + 时间戳重组为带标点的完整词流 `[TimedWord]`（纯函数，可单测）
    public static func buildTimedWords(
        tokens: [String], timestamps: [Double], durations: [Double],
        fallbackText: String, timeOffset: Double = 0, chunkDuration: Double = 10.0
    ) -> [TimedWord] {
        guard !tokens.isEmpty, timestamps.count == tokens.count else {
            let trimmed = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return [] }
            let rawTokens = SrtTranscribeEngine.tokenize(trimmed)
            guard !rawTokens.isEmpty else { return [] }
            let step = max(0.05, chunkDuration / Double(rawTokens.count))
            return rawTokens.enumerated().map { idx, tok in
                let s = timeOffset + Double(idx) * step
                return TimedWord(start: s, end: s + step, text: " " + tok.text)
            }
        }

        var merged: [TimedWord] = []
        for i in 0..<tokens.count {
            let raw = tokens[i]
            let clean = raw.replacingOccurrences(of: "▁", with: " ")
            if clean.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            let start = timeOffset + max(0, timestamps[i])
            let dur: Double = {
                if i < durations.count && durations[i] > 0.01 { return durations[i] }
                if i + 1 < timestamps.count { return max(0.04, timestamps[i + 1] - timestamps[i]) }
                return 0.18
            }()
            let end = start + dur
            let startsNewWord = raw.hasPrefix("▁") || raw.hasPrefix(" ") || merged.isEmpty
            let isPunctOnly = clean.trimmingCharacters(in: CharacterSet.punctuationCharacters).isEmpty

            if !startsNewWord || isPunctOnly, !merged.isEmpty {
                merged[merged.count - 1].text += clean
                merged[merged.count - 1].end = max(merged[merged.count - 1].end, end)
            } else {
                merged.append(TimedWord(start: start, end: end, text: clean))
            }
        }
        return merged
    }
}
