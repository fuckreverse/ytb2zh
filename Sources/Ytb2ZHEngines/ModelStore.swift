import Foundation
import Ytb2ZHCore

// MARK: - 模型按需下载（whisper ggml / sherpa-onnx vits → ~/.ytb2zh/models/）
// 设计：首次使用内嵌引擎时若模型缺失，自动下载到统一模型根目录；
// 已存在（含部分下载的 .part 残留判断）直接复用。支持代理。

public enum ModelStore {
    public static let root = NSHomeDirectory() + "/.ytb2zh/models"

    /// whisper ggml 模型（HuggingFace ggerganov/whisper.cpp）
    /// 已知模型名（不含 .bin 后缀也可）→ 远端文件名
    public static let whisperModels: [String: String] = [
        "ggml-tiny.bin": "ggml-tiny.bin",
        "ggml-tiny.en.bin": "ggml-tiny.en.bin",
        "ggml-base.bin": "ggml-base.bin",
        "ggml-base.en.bin": "ggml-base.en.bin",
        "ggml-small.bin": "ggml-small.bin",
        "ggml-small.en.bin": "ggml-small.en.bin",
        "ggml-small.en-tdrz.bin": "ggml-small.en-tdrz.bin",
        "ggml-medium.bin": "ggml-medium.bin",
        "ggml-medium.en.bin": "ggml-medium.en.bin",
        "ggml-large-v3-turbo.bin": "ggml-large-v3-turbo.bin",
    ]
    /// 默认模型（转录质量/速度/体积的平衡点）
    public static let whisperDefault = "ggml-base.en"

    /// sherpa-onnx 中文 vits 模型（官方 tts-models release）
    public static let sherpaZhModel = "vits-zh-hf-theresa"
    static let sherpaZhURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-hf-theresa.tar.bz2"

    /// demucs.cpp ggml 权重（HuggingFace Retrobear/demucs.cpp，float16）
    /// 模型名 → 远端文件名；htdemucs 为默认（80MB，4 源）
    public static let demucsModels: [String: String] = [
        "htdemucs": "ggml-model-htdemucs-4s-f16.bin",
        "htdemucs_6s": "ggml-model-htdemucs-6s-f16.bin",
        "hdemucs_mmi": "ggml-model-hdemucs_mmi-v3-f16.bin",
    ]
    public static let demucsDefault = "htdemucs"

    // MARK: - whisper

    /// 解析 whisper 模型路径：存在直接返回；是已知模型名则下载到模型根；
    /// 空或指向默认旧位置（vid2zh）则落到默认模型。
    /// 返回 (绝对路径, 是否发生了下载)
    @discardableResult
    public static func ensureWhisperModel(
        configured: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        // ① 显式路径存在 → 直接用
        if !trimmed.isEmpty {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded) { return expanded }
        }
        // ② 未配置/默认模板旧路径（vid2zh）→ 尝试默认模型（先看本地是否已有）
        guard let remoteName = whisperModels[trimmed.isEmpty ? (whisperDefault + ".bin") : (trimmed as NSString).lastPathComponent] else {
            throw EngineError.engineFailure(
                "whisper 模型不存在：\(trimmed)。请填写正确路径，或留空以自动下载 \(whisperDefault)（约 142MB）")
        }
        let dest = root + "/" + remoteName
        if fm.fileExists(atPath: dest) { return dest }

        // ③ 下载
        let url = "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/" + remoteName
        try await download(url: url, to: dest, proxy: proxy,
                           label: "下载 \(remoteName)", progress: progress)
        return dest
    }

    // MARK: - sherpa vits

    /// 确保 sherpa 中文 vits 模型目录就绪（含 model.onnx/tokens.txt/lexicon.txt/dict/）。
    /// 目录存在且完整直接返回；configured 非空且存在则用之（沿用旧行为）。
    @discardableResult
    public static func ensureSherpaModel(
        configured: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        let trimmed = configured.trimmingCharacters(in: .whitespaces)

        // ① 显式目录存在且含 model.onnx → 用之
        if !trimmed.isEmpty {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded + "/model.onnx") { return expanded }
            // 显式配置了但不存在/不完整 → 报错（不静默换模型，用户可能放着精心挑的模型）
            if fm.fileExists(atPath: expanded) {
                throw EngineError.engineFailure("Sherpa 模型目录不完整（缺 model.onnx）：\(expanded)")
            }
        }

        // ② 默认模型目录（权重名可能是 theresa.onnx，就绪检查前先归一化软链）
        let dest = root + "/" + sherpaZhModel
        if fm.fileExists(atPath: dest) { normalizeModelOnnx(at: dest) }
        if fm.fileExists(atPath: dest + "/model.onnx") { return dest }

        // ③ 下载 + 解压（tar.bz2，走系统 tar）
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let archive = root + "/" + sherpaZhModel + ".tar.bz2"
        try await download(url: sherpaZhURL, to: archive, proxy: proxy,
                           label: "下载 \(sherpaZhModel)", progress: progress)
        progress(0.95, "解压模型")
        let runner = ProcessRunner()
        let r = try runner.run("/usr/bin/tar", ["-xjf", archive, "-C", root])
        try? fm.removeItem(atPath: archive)
        guard r.code == 0, fm.fileExists(atPath: dest) else {
            throw EngineError.engineFailure("Sherpa 模型解压失败：\(String(r.stderr.suffix(300)))")
        }
        try normalizeModelOnnx(at: dest)
        guard fm.fileExists(atPath: dest + "/model.onnx") else {
            throw EngineError.engineFailure("Sherpa 模型目录异常（未找到 .onnx 权重）：\(dest)")
        }
        progress(1.0, "模型就绪")
        return dest
    }

    /// tar 包内权重文件名可能与目录名不同（如 theresa.onnx）：统一软链为 model.onnx
    static func normalizeModelOnnx(at dir: String) {
        let fm = FileManager.default
        let canonical = dir + "/model.onnx"
        guard !fm.fileExists(atPath: canonical) else { return }
        let onnxFiles = (try? fm.contentsOfDirectory(atPath: dir))?.filter { $0.hasSuffix(".onnx") } ?? []
        guard onnxFiles.count == 1 else { return }
        try? fm.createSymbolicLink(atPath: canonical,
                                   withDestinationPath: dir + "/" + onnxFiles[0])
    }

    /// 模型目录内可选的文本正则化 fst 规则（存在才拼，提升数字/日期读音准确度）
    static func sherpaRuleFsts(at dir: String) -> String {
        let fm = FileManager.default
        let names = ["number.fst", "date.fst", "phone.fst", "new_heteronym.fst"]
        let found = names.filter { fm.fileExists(atPath: dir + "/" + $0) }
        return found.map { dir + "/" + $0 }.joined(separator: ",")
    }

    // MARK: - demucs

    /// 确保 demucs ggml 权重就绪：显式 .bin 路径存在直接用；
    /// 模型名（htdemucs/htdemucs_6s/hdemucs_mmi）→ 下载到模型根；空 → 默认 htdemucs。
    @discardableResult
    public static func ensureDemucsModel(
        configured: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)

        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        // ① 显式 .bin 路径存在 → 直接用
        if !trimmed.isEmpty {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded) { return expanded }
        }
        // ② 模型名归一化（未知名称报错并给出可选项）
        let name = trimmed.isEmpty ? demucsDefault : trimmed
        guard let remoteName = demucsModels[name] else {
            throw EngineError.engineFailure(
                "未知 demucs 模型：\(name)。可选：\(demucsModels.keys.joined(separator: "、"))，或填 .bin 文件路径")
        }
        let dest = root + "/" + remoteName
        if fm.fileExists(atPath: dest) { return dest }

        // ③ 下载
        let url = "https://huggingface.co/datasets/Retrobear/demucs.cpp/resolve/main/" + remoteName
        try await download(url: url, to: dest, proxy: proxy,
                           label: "下载 demucs 权重（\(name)）", progress: progress)
        return dest
    }

    // MARK: - 通用下载

    private static func download(
        url: String, to dest: String, proxy: String, label: String,
        progress: @Sendable (Double, String) -> Void
    ) async throws {
        guard let req = URL(string: url) else {
            throw EngineError.engineFailure("下载地址非法：\(url)")
        }
        let config = URLSessionConfiguration.ephemeral
        let dict = EdgeTTSProxy.dictionary(from: proxy)
        if !dict.isEmpty { config.connectionProxyDictionary = dict }
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }

        progress(0.0, label + "…")
        let (bytes, response) = try await session.data(for: URLRequest(url: req))
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? -1
            throw EngineError.engineFailure("\(label)失败：HTTP \(code)")
        }
        let part = dest + ".part"
        try bytes.write(to: URL(fileURLWithPath: part))
        try FileManager.default.moveItem(at: URL(fileURLWithPath: part), to: URL(fileURLWithPath: dest))
        progress(1.0, label + "完成（\(bytes.count / 1_048_576)MB）")
    }
}
