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

// MARK: Sherpa-Onnx 离线 TTS 引擎（内嵌 v1.13.8 C API，进程内推理）
// 引擎 id 保持 "sherpa-onnx"：旧 profile 无需改动；二进制不再需要，模型目录缺失时自动下载默认中文模型。

public struct SherpaOnnxTTSEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor(
        "sherpa-onnx", "Sherpa-Onnx 离线 TTS（内嵌）",
        "进程内 vits 推理，零外部依赖；模型缺失自动下载（默认 theresa 中文女声约 170MB）")
    public var supportsRateControl: Bool { false }

    public init() {}

    /// 已加载模型缓存（模型加载重，按目录缓存进程级单例；进程生命周期内不释放）
    private static let loaded = Mutex<[String: OpaquePointer]>([:])

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

        // 1) 模型目录：显式配置优先（缺失报错），未配置自动下载默认模型
        let modelDir = try await ModelStore.ensureSherpaModel(configured: options.sherpaOnnxModelDir)

        // 2) 取/建模型实例（重推理走专用线程）
        let tts = try await Self.ttsInstance(modelDir: modelDir)

        // 3) 合成 → wav（C 调用收进同步 helper，调度闭包只捕获 Sendable 值）
        let wav = cacheDir.appendingPathComponent("\(cacheKey).wav")
        try? fm.removeItem(at: wav)
        nonisolated(unsafe) let ttsHandle = tts
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try Self.generateSync(tts: ttsHandle, text: text, wav: wav)
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

    /// 同步合成（vits C API 调用；运行在专用调度线程）
    nonisolated private static func generateSync(tts: OpaquePointer, text: String, wav: URL) throws {
        // strdup 固定 C 字符串（utf8String 缓冲随临时对象释放，同调内使用虽安全但统一走 strdup）
        guard let audio = SherpaOnnxOfflineTtsGenerate(tts, UnsafePointer(strdup(text)), 0, 1.0) else {
            throw EngineError.engineFailure(
                "Sherpa-Onnx 合成失败。请检查模型目录是否完整（model.onnx/tokens.txt/lexicon.txt/dict/）")
        }
        defer { SherpaOnnxDestroyOfflineTtsGeneratedAudio(audio) }
        let a = audio.pointee
        let ok = SherpaOnnxWriteWave(a.samples, a.n, a.sample_rate,
                                     UnsafePointer(strdup(wav.path)))
        guard ok == 1 else {  // C API 约定：1 成功 / 0 失败
            throw EngineError.engineFailure("Sherpa-Onnx 写 wav 失败：\(wav.path)")
        }
    }

    /// 取缓存的 SherpaOnnxOfflineTts 实例（无则加载）
    private static func ttsInstance(modelDir: String) async throws -> OpaquePointer {
        if let cached = loaded.wrapped[modelDir] { return cached }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<OpaquePointer, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                // 关键：C 字符串生命周期——(s as NSString).utf8String 的缓冲随临时 NSString 释放而悬垂，
                // 而 SherpaOnnxCreateOfflineTts 在同一次调用内读取后不再持有，安全做法是 strdup 固定住。
                var config = SherpaOnnxOfflineTtsConfig()
                // 注意：data_dir 仅用于 espeak-ng-data（非中文模型）；中文 lexicon 型模型不要设，
                // 塞 jieba dict 目录会初始化失败（旧 sidecar 的 --vits-data-dir 用法已废弃）
                let fm = FileManager.default
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
                config.model.num_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
                config.model.provider = UnsafePointer(strdup("cpu"))
                config.model.debug = 0
                // 文本正则化规则（数字/日期/电话号码读音），目录内存在才拼
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
