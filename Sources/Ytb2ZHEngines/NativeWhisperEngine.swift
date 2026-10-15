import Foundation
import whisper
import Ytb2ZHCore

// MARK: - 内嵌 Whisper 转录引擎（whisper.cpp C API 进程内调用，Metal 加速）
// 与 WhisperCliEngine（sidecar）等价：词级时间戳 → [TimedWord]。
// 差异：零外部二进制依赖；模型缺失时自动下载（ModelStore）；进度用官方 progress_callback。

public struct NativeWhisperEngine: TranscribeEngine, @unchecked Sendable {
    public let descriptor = EngineDescriptor(
        "whisper-native", "Whisper（内嵌）",
        "whisper.cpp 进程内推理，Metal 加速；模型缺失自动下载（默认 base.en 约 142MB）")

    private let runner = ProcessRunner()

    public init() {}

    public func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                           progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord] {
        let fm = FileManager.default
        try fm.createDirectory(at: workDir, withIntermediateDirectories: true)
        let wav = workDir.appendingPathComponent("audio16k.wav")

        // 1) 抽 16k 单声道 wav（16-bit PCM，whisper 输入格式）
        progress(0.02, "抽取音轨")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-i", video.path, "-vn", "-ac", "1", "-ar", "16000",
             "-c:a", "pcm_s16le", wav.path])
        guard extract.code == 0 else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        // 2) 模型就绪（缺失自动下载）
        let model = try await ModelStore.ensureWhisperModel(configured: options.modelPath) { frac, msg in
            progress(0.02 + frac * 0.06, msg)
        }

        // 3) 读样本
        let samples = try readWavMono16(wav)

        // 4) whisper 全量转录（重 CPU，独立线程跑，避免占死协作线程池）
        progress(0.09, "开始转录（内嵌 Metal 加速）")
        let language = options.language
        let enableDTW = options.enableDTW
        let words = try await runWhisper(
            modelPath: model, samples: samples, language: language, enableDTW: enableDTW
        ) { frac in
            progress(0.09 + frac * 0.89, "转录中 \(Int(frac * 100))%")
        }
        progress(1.0, "\(words.count) 词")
        return words
    }

    /// 根据模型文件名推断对应的 DTW 交叉注意力头预设（whisper_alignment_heads_preset）
    public static func dtwPreset(for modelPath: String) -> whisper_alignment_heads_preset {
        let name = (modelPath as NSString).lastPathComponent.lowercased()
        if name.contains("large-v3-turbo") || name.contains("large-v3_turbo") {
            return WHISPER_AHEADS_LARGE_V3_TURBO
        }
        if name.contains("large-v3") { return WHISPER_AHEADS_LARGE_V3 }
        if name.contains("large-v2") { return WHISPER_AHEADS_LARGE_V2 }
        if name.contains("large-v1") || name.contains("large.") { return WHISPER_AHEADS_LARGE_V1 }
        if name.contains("medium.en") { return WHISPER_AHEADS_MEDIUM_EN }
        if name.contains("medium") { return WHISPER_AHEADS_MEDIUM }
        if name.contains("small.en") { return WHISPER_AHEADS_SMALL_EN }
        if name.contains("small") { return WHISPER_AHEADS_SMALL }
        if name.contains("base.en") { return WHISPER_AHEADS_BASE_EN }
        if name.contains("base") { return WHISPER_AHEADS_BASE }
        if name.contains("tiny.en") { return WHISPER_AHEADS_TINY_EN }
        if name.contains("tiny") { return WHISPER_AHEADS_TINY }
        return WHISPER_AHEADS_N_TOP_MOST
    }

    // MARK: - whisper.cpp 调用

    private func runWhisper(
        modelPath: String, samples: [Float], language: String, enableDTW: Bool = true,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> [TimedWord] {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<[TimedWord], Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var ctx: OpaquePointer?
                var state: OpaquePointer?
                // 拷贝进 C 生命周期安全的上下文对象
                final class ProgressBox: @unchecked Sendable {
                    let cb: @Sendable (Double) -> Void
                    init(_ cb: @escaping @Sendable (Double) -> Void) { self.cb = cb }
                }
                let box = ProgressBox(onProgress)
                do {
                    var cparams = whisper_context_default_params()
                    cparams.use_gpu = true
                    cparams.flash_attn = true
                    if enableDTW {
                        let preset = Self.dtwPreset(for: modelPath)
                        cparams.dtw_token_timestamps = true
                        cparams.dtw_aheads_preset = preset
                        if cparams.dtw_mem_size == 0 {
                            cparams.dtw_mem_size = 1024 * 1024 * 128
                        }
                    }
                    guard let c = whisper_init_from_file_with_params_no_state(modelPath, cparams) else {
                        throw EngineError.engineFailure("whisper 模型加载失败（路径或格式非法）：\(modelPath)")
                    }
                    ctx = c
                    guard let st = whisper_init_state(c) else {
                        throw EngineError.engineFailure("whisper state 初始化失败")
                    }
                    state = st

                    var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
                    params.n_threads = Int32(ProcessInfo.processInfo.activeProcessorCount)
                    params.translate = false
                    params.no_context = true
                    params.token_timestamps = true
                    params.print_progress = false
                    params.print_realtime = false
                    params.print_timestamps = false
                    params.suppress_nst = true
                    params.detect_language = false
                    let lang = language.isEmpty ? "en" : language
                    params.language = (lang as NSString).utf8String

                    // 进度回调（0-100）
                    let progressTrampoline: @convention(c) (
                        OpaquePointer?, OpaquePointer?, Int32, UnsafeMutableRawPointer?
                    ) -> Void = { _, _, pct, userData in
                        guard let userData else { return }
                        let box = Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue()
                        box.cb(Double(pct) / 100.0)
                    }
                    params.progress_callback = progressTrampoline
                    let userData = Unmanaged.passRetained(box).toOpaque()
                    defer { Unmanaged<ProgressBox>.fromOpaque(userData).release() }
                    params.progress_callback_user_data = userData

                    samples.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return }
                        _ = whisper_full_with_state(c, st, params, base, Int32(samples.count))
                    }

                    // 收词级时间戳（t0/t1/t_dtw 单位：1/100 秒）
                    var words: [TimedWord] = []
                    var prevEnd: Double = 0
                    let nSeg = whisper_full_n_segments_from_state(st)
                    for i in 0..<nSeg {
                        let nTok = whisper_full_n_tokens_from_state(st, i)
                        for j in 0..<nTok {
                            guard let textC = whisper_full_get_token_text_from_state(c, st, i, j) else { continue }
                            let text = String(cString: textC).trimmingCharacters(in: .whitespaces)
                            guard !text.isEmpty, !text.hasPrefix("[_"), text != "[_TT_]" && text != "[_TA_]" else { continue }
                            let tdata = whisper_full_get_token_data_from_state(st, i, j)
                            var t0 = Double(tdata.t0) / 100.0
                            var t1 = Double(tdata.t1) / 100.0
                            if enableDTW && tdata.t_dtw > 0 {
                                let dtwEnd = Double(tdata.t_dtw) / 100.0
                                let estDur = max(0.04, min(0.8, t1 - t0))
                                t0 = max(prevEnd, max(0, dtwEnd - estDur))
                                t1 = max(t0 + 0.02, dtwEnd)
                            } else {
                                t0 = max(prevEnd, t0)
                                t1 = max(t0 + 0.02, t1)
                            }
                            prevEnd = t1
                            words.append(TimedWord(start: t0, end: t1, text: text))
                        }
                    }
                    cont.resume(returning: words)
                } catch {
                    cont.resume(throwing: error)
                }
                if let state { whisper_free_state(state) }
                if let ctx { whisper_free(ctx) }
            }
        }
    }

    // MARK: - WAV 解析（16-bit PCM 单声道）

    func readWavMono16(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw EngineError.engineFailure("wav 文件过小") }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        // RIFF 头
        guard bytes[0...3].map({ Character(UnicodeScalar($0)) }) == ["R", "I", "F", "F"],
              bytes[8...11].map({ Character(UnicodeScalar($0)) }) == ["W", "A", "V", "E"] else {
            throw EngineError.engineFailure("非 RIFF/WAVE 文件")
        }
        // 遍历 chunk 找 "data "（跳过 LIST/fact 等杂项）
        var offset = 12
        var dataStart = -1
        var dataLen = 0
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4].map { Character(UnicodeScalar($0)) }
            let size = u32(offset + 4)
            if id == ["d", "a", "t", "a"] {
                dataStart = offset + 8
                dataLen = min(size, bytes.count - dataStart)
                break
            }
            offset += 8 + size + (size & 1)  // chunk 按 2 字节对齐
        }
        guard dataStart > 0 else { throw EngineError.engineFailure("wav 缺 data chunk") }

        var samples = [Float]()
        samples.reserveCapacity(dataLen / 2)
        var i = dataStart
        let end = dataStart + dataLen
        while i + 1 < end {
            let v = Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8)
            samples.append(Float(v) / 32768.0)
            i += 2
        }
        guard !samples.isEmpty else { throw EngineError.engineFailure("wav 无音频样本") }
        return samples
    }
}
