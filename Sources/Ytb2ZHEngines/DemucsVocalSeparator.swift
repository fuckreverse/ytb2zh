import CDemucsCpp
import Foundation
import Ytb2ZHCore

// MARK: - Demucs 人声分离（demucs.cpp 进程内推理，sevagh 的 C++17/Eigen 实现）
// 产物：workDir/vocals.wav（16k 单声道，供转录）+ workDir/instrumental.wav（48k 立体声，供 BGM 混入）
// 权重：ggml f16（htdemucs 80MB），ModelStore 按需下载；4 源模型顺序 drums/bass/other/vocals

public struct NativeDemucsSeparator: VocalSeparationEngine {
    public let descriptor = EngineDescriptor(
        "demucs", "Demucs 人声分离（内嵌）",
        "demucs.cpp 进程内推理，零外部依赖；权重缺失自动下载（htdemucs 约 80MB）")

    private let runner = ProcessRunner()

    public init() {}

    public func separate(video: URL, workDir: URL, options: SeparationOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> (vocals: URL, instrumental: URL) {
        let fm = FileManager.default
        let tmpDir = workDir.appendingPathComponent("demucs_out", isDirectory: true)
        try fm.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // 1) 抽 44.1k 立体声 float32 wav（demucs 输入格式）
        progress(0.02, "抽取音轨")
        let raw = tmpDir.appendingPathComponent("input.wav")
        let extract = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-v", "error", "-i", video.path, "-vn", "-ar", "44100", "-ac", "2",
             "-c:a", "pcm_f32le", raw.path])
        guard extract.code == 0 else {
            throw EngineError.engineFailure("ffmpeg 抽音轨失败：\(String(extract.stderr.suffix(400)))")
        }

        // 2) 权重就绪（缺失自动下载）
        let model = try await ModelStore.ensureDemucsModel(configured: options.model) { frac, msg in
            progress(0.02 + frac * 0.08, msg)
        }

        // 3) 读样本（interleaved 立体声）
        let samples = try readWavStereoF32(raw)
        let frames = samples.count / 2
        guard frames > 0 else { throw EngineError.engineFailure("音轨无样本") }

        // 4) 进程内推理（重 CPU，独立线程 + 进度回调）
        progress(0.1, "Demucs 分离中（CPU 推理，速度约 0.4x 实时）")
        let stems = try await runDemucs(modelPath: model, interleaved: samples, frames: frames) { p in
            progress(0.1 + p * 0.8, "分离中 \(Int(p * 100))%")
        }

        // 5) vocals（源 3）与 instrumental（其余源求和）写 44.1k f32 wav
        progress(0.92, "写分轨文件")
        let rawVocals = tmpDir.appendingPathComponent("vocals_f32.wav")
        let rawInst = tmpDir.appendingPathComponent("instrumental_f32.wav")
        try writeWavStereoF32(rawVocals, samples: stems.vocals, sampleRate: 44100)
        try writeWavStereoF32(rawInst, samples: stems.instrumental, sampleRate: 44100)

        // 6) 转码为下游格式（与旧 sidecar 输出契约一致）
        let vocals = workDir.appendingPathComponent("vocals.wav")
        let instrumental = workDir.appendingPathComponent("instrumental.wav")
        _ = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-v", "error", "-i", rawVocals.path, "-ar", "16000", "-ac", "1",
             "-c:a", "pcm_s16le", vocals.path])
        _ = try runner.run(SidecarPaths.ffmpeg,
            ["-y", "-v", "error", "-i", rawInst.path, "-ar", "48000", "-ac", "2",
             "-c:a", "pcm_s16le", instrumental.path])
        guard fm.fileExists(atPath: vocals.path), fm.fileExists(atPath: instrumental.path) else {
            throw EngineError.engineFailure("分轨转码失败（ffmpeg）")
        }
        try? fm.removeItem(at: tmpDir)
        progress(1.0, "分离完成")
        return (vocals, instrumental)
    }

    // MARK: - demucs.cpp 调用

    private func runDemucs(
        modelPath: String, interleaved: [Float], frames: Int,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> (vocals: [Float], instrumental: [Float]) {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<(vocals: [Float], instrumental: [Float]), Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                final class ProgressBox: @unchecked Sendable {
                    let cb: @Sendable (Double) -> Void
                    var last = 0.0
                    init(_ cb: @escaping @Sendable (Double) -> Void) { self.cb = cb }
                }
                let box = ProgressBox(onProgress)
                do {
                    guard let handle = modelPath.withCString({ demucscpp_create($0) }) else {
                        throw EngineError.engineFailure("demucs 权重加载失败：\(modelPath)")
                    }
                    defer { demucscpp_destroy(handle) }

                    let trampoline: @convention(c) (
                        Float, UnsafePointer<CChar>?, UnsafeMutableRawPointer?
                    ) -> Void = { p, _, ud in
                        guard let ud else { return }
                        let box = Unmanaged<ProgressBox>.fromOpaque(ud).takeUnretainedValue()
                        // demucs 进度按 chunk 反复从 0 计，取历史最大值保持单调
                        box.last = max(box.last, Double(p))
                        box.cb(box.last)
                    }
                    let boxOpaque = Unmanaged.passRetained(box).toOpaque()
                    defer { Unmanaged<ProgressBox>.fromOpaque(boxOpaque).release() }

                    let out: UnsafeMutablePointer<Float>? = interleaved.withUnsafeBufferPointer { buf in
                        guard let base = buf.baseAddress else { return nil }
                        return demucscpp_apply(handle, base, frames, trampoline, boxOpaque)
                    }
                    guard let out else {
                        throw EngineError.engineFailure("demucs 推理失败（内存不足或输入异常）")
                    }
                    defer { demucscpp_free_result(out) }

                    let nb = Int(demucscpp_num_sources(handle))
                    let total = frames * 2
                    var vocals = [Float](repeating: 0, count: total)
                    var instrumental = [Float](repeating: 0, count: total)
                    for src in 0..<nb {
                        let base = out + src * total
                        if src == 3 {  // vocals（4s/6s/v3 均为索引 3）
                            for i in 0..<total { vocals[i] = base[i] }
                        } else {
                            for i in 0..<total { instrumental[i] += base[i] }
                        }
                    }
                    cont.resume(returning: (vocals, instrumental))
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - WAV I/O（float32 立体声）

    /// 读 float32 立体声 wav（RIFF 遍历 chunk，容错 LIST 等杂项）
    func readWavStereoF32(_ url: URL) throws -> [Float] {
        let data = try Data(contentsOf: url)
        guard data.count >= 12 else { throw EngineError.engineFailure("wav 文件过小") }
        let bytes = [UInt8](data)
        func u16(_ o: Int) -> Int { Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard String(bytes: bytes[0..<4], encoding: .ascii) == "RIFF",
              String(bytes: bytes[8..<12], encoding: .ascii) == "WAVE" else {
            throw EngineError.engineFailure("非 RIFF/WAVE 文件")
        }
        var offset = 12
        var format = -1, channels = -1
        var dataStart = -1, dataLen = 0
        while offset + 8 <= bytes.count {
            let id = String(bytes: bytes[offset..<offset + 4], encoding: .ascii) ?? ""
            let size = u32(offset + 4)
            if id == "fmt " {
                format = u16(offset + 8)
                channels = u16(offset + 10)
            } else if id == "data" {
                dataStart = offset + 8
                dataLen = min(size, bytes.count - dataStart)
                break
            }
            offset += 8 + size + (size & 1)
        }
        guard dataStart > 0 else { throw EngineError.engineFailure("wav 缺 data chunk") }
        guard format == 3, channels == 2 else {
            throw EngineError.engineFailure("demucs 输入须为 float32 立体声 wav（fmt=\(format), ch=\(channels)）")
        }
        let nFloats = dataLen / 4
        var samples = [Float](repeating: 0, count: nFloats)
        for i in 0..<nFloats {
            let o = dataStart + i * 4
            var v: Float = 0
            withUnsafeMutableBytes(of: &v) { vbuf in
                for b in 0..<4 { vbuf[b] = bytes[o + b] }
            }
            samples[i] = v
        }
        guard !samples.isEmpty else { throw EngineError.engineFailure("wav 无音频样本") }
        return samples
    }

    /// 写 float32 立体声 wav（44 字节标准头 + IEEE float data）
    func writeWavStereoF32(_ url: URL, samples: [Float], sampleRate: Int) throws {
        var data = Data()
        func appendU32(_ v: Int) {
            withUnsafeBytes(of: UInt32(v).littleEndian) { data.append(contentsOf: $0) }
        }
        func appendU16(_ v: Int) {
            withUnsafeBytes(of: UInt16(v).littleEndian) { data.append(contentsOf: $0) }
        }
        let byteCount = samples.count * 4
        data.append(contentsOf: Array("RIFF".utf8))
        appendU32(36 + byteCount)
        data.append(contentsOf: Array("WAVE".utf8))
        data.append(contentsOf: Array("fmt ".utf8))
        appendU32(16)
        appendU16(3)                       // IEEE float
        appendU16(2)                       // stereo
        appendU32(sampleRate)
        appendU32(sampleRate * 8)           // byte rate
        appendU16(8)                       // block align
        appendU16(32)                      // bits per sample
        data.append(contentsOf: Array("data".utf8))
        appendU32(byteCount)
        samples.withUnsafeBufferPointer { buf in
            guard let base = buf.baseAddress else { return }
            data.append(Data(bytes: base, count: byteCount))
        }
        try data.write(to: url)
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
