import Foundation
import Ytb2ZHCore
import Videx

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
        "ggml-medium.en-q5_0.bin": "ggml-medium.en-q5_0.bin",
        "ggml-large-v3.bin": "ggml-large-v3.bin",
        "ggml-large-v3-turbo.bin": "ggml-large-v3-turbo.bin",
        "ggml-large-v3-turbo-q5_0.bin": "ggml-large-v3-turbo-q5_0.bin",
        "ggml-large-v3-turbo-q8_0.bin": "ggml-large-v3-turbo-q8_0.bin",
    ]
    /// 默认模型（转录质量/速度/体积的平衡点）
    public static let whisperDefault = "ggml-base.en"

    /// sherpa-onnx 中文 vits 模型（官方 tts-models release）
    public static let sherpaZhModel = "vits-zh-hf-theresa"
    static let sherpaZhURL =
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-hf-theresa.tar.bz2"

    /// sherpa-onnx TTS 预设模型库（支持 VITS / Kokoro 中英播客多说话人 / ZipVoice 零样本音色克隆）
    public struct SherpaTTSPreset: Sendable {
        public let canonicalDirName: String
        public let archiveURL: String
        public let extraFileURL: (filename: String, url: String)?
    }

    public static let sherpaTTSPresets: [String: SherpaTTSPreset] = [
        "vits-zh-hf-theresa": .init(
            canonicalDirName: "vits-zh-hf-theresa",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-hf-theresa.tar.bz2",
            extraFileURL: nil),
        "theresa": .init(
            canonicalDirName: "vits-zh-hf-theresa",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/vits-zh-hf-theresa.tar.bz2",
            extraFileURL: nil),
        "kokoro": .init(
            canonicalDirName: "kokoro-multi-lang-v1_1",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2",
            extraFileURL: nil),
        "kokoro-multi-lang-v1_1": .init(
            canonicalDirName: "kokoro-multi-lang-v1_1",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_1.tar.bz2",
            extraFileURL: nil),
        "kokoro-multi-lang-v1_0": .init(
            canonicalDirName: "kokoro-multi-lang-v1_0",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/kokoro-multi-lang-v1_0.tar.bz2",
            extraFileURL: nil),
        "zipvoice": .init(
            canonicalDirName: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2",
            extraFileURL: ("vocos_24khz.onnx", "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx")),
        "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia": .init(
            canonicalDirName: "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia",
            archiveURL: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-zipvoice-distill-int8-zh-en-emilia.tar.bz2",
            extraFileURL: ("vocos_24khz.onnx", "https://github.com/k2-fsa/sherpa-onnx/releases/download/vocoder-models/vocos_24khz.onnx")),
    ]

    /// sherpa-onnx 离线 ASR 预设模型库（Parakeet TDT 0.6B / SenseVoice / Qwen3-ASR）
    public static let sherpaASRPresets: [String: (dirName: String, url: String)] = [
        "parakeet": (
            "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        ),
        "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8": (
            "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8.tar.bz2"
        ),
        "sensevoice": (
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
        ),
        "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17": (
            "sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-sense-voice-zh-en-ja-ko-yue-2024-07-17.tar.bz2"
        ),
        "qwen3-asr": (
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2"
        ),
        "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25": (
            "sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25",
            "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-qwen3-asr-0.6B-int8-2026-03-25.tar.bz2"
        ),
    ]
    public static let sherpaASRDefault = "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"

    /// demucs.cpp ggml 权重（HuggingFace Retrobear/demucs.cpp，float16）
    /// 模型名 → 远端文件名；htdemucs 为默认（80MB，4 源）
    public static let demucsModels: [String: String] = [
        "htdemucs": "ggml-model-htdemucs-4s-f16.bin",
        "htdemucs_6s": "ggml-model-htdemucs-6s-f16.bin",
        "hdemucs_mmi": "ggml-model-hdemucs_mmi-v3-f16.bin",
    ]
    public static let demucsDefault = "htdemucs"

    // MARK: - whisper

    /// 把配置值解析为远端模型名（纯函数，无 I/O）：
    /// 空 / 旧版默认路径（vid2zh 原型目录，模板历史默认值）→ 默认模型；
    /// 已知模型名（取 lastPathComponent，带不带 .bin 后缀均可）→ 自身；否则 nil。
    public static func whisperRemoteName(for configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed.contains("/vid2zh/") {
            return whisperModels[whisperDefault + ".bin"]
        }
        let name = (trimmed as NSString).lastPathComponent
        return whisperModels[name] ?? whisperModels[name + ".bin"]
    }

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
        // ② 未配置/旧版默认路径（vid2zh）→ 尝试默认模型（先看本地是否已有）
        guard let remoteName = whisperRemoteName(for: trimmed) else {
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

    /// 检查目录是否为完整的 Sherpa TTS 模型目录（支持 VITS / Kokoro / ZipVoice）
    public static func isValidSherpaTTSModelDir(_ dir: String) -> Bool {
        let fm = FileManager.default
        if fm.fileExists(atPath: dir + "/model.onnx") { return true }
        let files = (try? fm.contentsOfDirectory(atPath: dir)) ?? []
        let hasEncoder = files.contains { $0.hasPrefix("encoder") && $0.hasSuffix(".onnx") }
        let hasDecoder = files.contains { $0.hasPrefix("decoder") && $0.hasSuffix(".onnx") }
        let hasVocoder = files.contains { ($0.hasPrefix("vocos") || $0.hasPrefix("vocoder")) && $0.hasSuffix(".onnx") }
        return hasEncoder && hasDecoder && hasVocoder
    }

    /// 确保 sherpa TTS 模型目录就绪（支持 VITS / Kokoro / ZipVoice）。
    /// 目录存在且完整直接返回；configured 为已知预设名则按需自动下载；configured 为空走默认 vits-zh-hf-theresa。
    @discardableResult
    public static func ensureSherpaModel(
        configured: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        let trimmed = configured.trimmingCharacters(in: .whitespaces)

        // ① 显式目录存在 → 检查是否完整（VITS/Kokoro model.onnx 或 ZipVoice encoder+decoder+vocos）
        if !trimmed.isEmpty, sherpaTTSPresets[trimmed.lowercased()] == nil {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded) { normalizeModelOnnx(at: expanded) }
            if isValidSherpaTTSModelDir(expanded) { return expanded }
            if fm.fileExists(atPath: expanded) {
                throw EngineError.engineFailure("Sherpa 模型目录不完整（缺 model.onnx）：\(expanded)")
            }
        }

        // ② 解析预设（空 → 默认 vits-zh-hf-theresa；kokoro / zipvoice → 对应多语言/零样本克隆模型）
        let presetKey = trimmed.isEmpty ? sherpaZhModel : trimmed.lowercased()
        let preset = sherpaTTSPresets[presetKey] ?? sherpaTTSPresets[sherpaZhModel]!
        let dest = root + "/" + preset.canonicalDirName
        if fm.fileExists(atPath: dest) { normalizeModelOnnx(at: dest) }
        if isValidSherpaTTSModelDir(dest) { return dest }

        // ③ 下载 + 解压（tar.bz2，走系统 tar）
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let archive = root + "/" + preset.canonicalDirName + ".tar.bz2"
        try await download(url: preset.archiveURL, to: archive, proxy: proxy,
                           label: "下载 \(preset.canonicalDirName)", progress: progress)
        progress(0.92, "解压模型")
        let runner = ProcessRunner()
        let r = try runner.run("/usr/bin/tar", ["-xjf", archive, "-C", root])
        try? fm.removeItem(atPath: archive)
        guard r.code == 0, fm.fileExists(atPath: dest) else {
            throw EngineError.engineFailure("Sherpa 模型解压失败：\(String(r.stderr.suffix(300)))")
        }
        // ZipVoice 等模型需额外下载独立 vocoder（vocos_24khz.onnx）
        if let extra = preset.extraFileURL {
            let extraDest = dest + "/" + extra.filename
            if !fm.fileExists(atPath: extraDest) {
                try await download(url: extra.url, to: extraDest, proxy: proxy,
                                   label: "下载声码器 \(extra.filename)", progress: progress)
            }
        }
        normalizeModelOnnx(at: dest)
        guard isValidSherpaTTSModelDir(dest) else {
            throw EngineError.engineFailure("Sherpa 模型目录异常（未找到 .onnx 权重）：\(dest)")
        }
        progress(1.0, "模型就绪")
        return dest
    }

    /// 确保 Sherpa-Onnx 离线 ASR 模型目录就绪（支持 Parakeet TDT / SenseVoice / Qwen3-ASR）
    @discardableResult
    public static func ensureSherpaASRModel(
        configured: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        let trimmed = configured.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty, sherpaASRPresets[trimmed.lowercased()] == nil {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded) { return expanded }
        }
        let key = trimmed.isEmpty ? "parakeet" : trimmed.lowercased()
        guard let preset = sherpaASRPresets[key] else {
            throw EngineError.engineFailure(
                "未知的 Sherpa ASR 模型：\(trimmed)。可选预设：parakeet、sensevoice、qwen3-asr，或填本地模型目录路径")
        }
        let dest = root + "/" + preset.dirName
        if fm.fileExists(atPath: dest + "/tokens.txt") || fm.fileExists(atPath: dest + "/tokenizer") {
            return dest
        }
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let archive = root + "/" + preset.dirName + ".tar.bz2"
        try await download(url: preset.url, to: archive, proxy: proxy,
                           label: "下载 \(preset.dirName)", progress: progress)
        progress(0.95, "解压 ASR 模型")
        let runner = ProcessRunner()
        let r = try runner.run("/usr/bin/tar", ["-xjf", archive, "-C", root])
        try? fm.removeItem(atPath: archive)
        guard r.code == 0, fm.fileExists(atPath: dest) else {
            throw EngineError.engineFailure("Sherpa ASR 模型解压失败：\(String(r.stderr.suffix(300)))")
        }
        progress(1.0, "ASR 模型就绪")
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

    // MARK: - Index-Homura 音节受控翻译 GGUF 模型按需下载

    public static let homuraModels: [String: (filename: String, url: String)] = [
        "index-homura-2b": (
            "Index-Homura-2B.Q4_K_M.gguf",
            "https://huggingface.co/IndexTeam/Index-Homura-2B-GGUF/resolve/main/Index-Homura-2B.Q4_K_M.gguf"
        ),
        "index-homura-2b-q4_k_m": (
            "Index-Homura-2B.Q4_K_M.gguf",
            "https://huggingface.co/IndexTeam/Index-Homura-2B-GGUF/resolve/main/Index-Homura-2B.Q4_K_M.gguf"
        ),
        "index-homura-2b-q8_0": (
            "Index-Homura-2B.Q8_0.gguf",
            "https://huggingface.co/IndexTeam/Index-Homura-2B-GGUF/resolve/main/Index-Homura-2B.Q8_0.gguf"
        ),
    ]

    /// 确保本地 Index-Homura GGUF 模型就绪（默认下载 1.31GB 的 Index-Homura-2B.Q4_K_M.gguf）
    @discardableResult
    public static func ensureHomuraGGUF(
        configured: String = "index-homura-2b", proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws -> String {
        let fm = FileManager.default
        try? fm.createDirectory(atPath: root, withIntermediateDirectories: true)
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            let expanded = NSString(string: trimmed).expandingTildeInPath
            if fm.fileExists(atPath: expanded) && expanded.hasSuffix(".gguf") {
                return expanded
            }
        }
        let key = trimmed.lowercased().contains("q8") ? "index-homura-2b-q8_0" : "index-homura-2b"
        let info = homuraModels[key]!
        let dest = root + "/" + info.filename
        if fm.fileExists(atPath: dest) { return dest }
        try await download(url: info.url, to: dest, proxy: proxy,
                           label: "下载 \(info.filename)", progress: progress)
        return dest
    }

    // MARK: - 本地模型中心清单（供 GUI「本地模型一键管理」展示状态、占用空间与一键预下载）

    public struct LocalModelItem: Identifiable, Sendable {
        public let id: String
        public let title: String
        public let category: String
        public let subtitle: String
        public let estimatedSizeMB: Int
        public let localPath: String
        public let isInstalled: Bool
        public let installedSizeMB: Int
    }

    public static func inspectLocalModels() -> [LocalModelItem] {
        let specs: [(id: String, title: String, category: String, subtitle: String, estMB: Int, relPath: String)] = [
            ("whisper-turbo-q5", "Whisper Large-v3-Turbo (Q5_0)", "语音识别 (ASR)",
             "推荐主力：547MB 高准度英文/多语种识别，支持 Metal + DTW 毫秒级词时间戳", 547,
             "ggml-large-v3-turbo-q5_0.bin"),
            ("whisper-base-en", "Whisper Base.en", "语音识别 (ASR)",
             "轻量极速：142MB 基础英文识别，适合清晰口播快速试转", 142,
             "ggml-base.en.bin"),
            ("sherpa-parakeet", "Parakeet TDT 0.6B v3 (INT8)", "语音识别 (ASR)",
             "英文极速王：640MB 原生词时间戳 + 大小写标点恢复，CPU/ANE 40x 实时", 640,
             "sherpa-onnx-nemo-parakeet-tdt-0.6b-v3-int8"),
            ("kokoro-v1_1", "Kokoro v1.1 中英播客多音色", "语音合成 (TTS)",
             "播客首选：350MB 内置 103 音色（含云希/晓北等中文主播），原生中英无缝混读", 350,
             "kokoro-multi-lang-v1_1"),
            ("zipvoice", "ZipVoice 零样本音色克隆", "语音合成 (TTS)",
             "原声复刻：自动截取原视频博主 5~8s 声音说流利中文，无需额外 Python 环境", 180,
             "sherpa-onnx-zipvoice-distill-int8-zh-en-emilia"),
            ("theresa-vits", "Theresa 中文女声 (VITS)", "语音合成 (TTS)",
             "基础离线中文女声，170MB 极小体积", 170,
             "vits-zh-hf-theresa"),
            ("homura-2b-gguf", "Index-Homura-2B (Q4_K_M GGUF)", "音节受控翻译",
             "B站配音专用翻译模型：严格按视频时间窗控制中文音节数与术语表，消除赶拍", 1310,
             "Index-Homura-2B.Q4_K_M.gguf"),
            ("demucs-htdemucs", "HTDemucs 4源人声分离", "人声分离 (BGM保留)",
             "分离纯净人声轨（提质识别+音色克隆）与伴奏轨（保留原片背景音乐）", 80,
             "ggml-model-htdemucs-4s-f16.bin"),
        ]
        let fm = FileManager.default
        return specs.map { s in
            let full = root + "/" + s.relPath
            var installed = false
            var sizeBytes: Int64 = 0
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: full, isDirectory: &isDir) {
                if isDir.boolValue {
                    installed = isValidSherpaTTSModelDir(full)
                        || fm.fileExists(atPath: full + "/tokens.txt")
                        || fm.fileExists(atPath: full + "/tokenizer")
                    sizeBytes = directorySize(at: full)
                } else {
                    sizeBytes = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.int64Value ?? 0
                    installed = sizeBytes > 1_000_000
                }
            }
            return LocalModelItem(
                id: s.id, title: s.title, category: s.category, subtitle: s.subtitle,
                estimatedSizeMB: s.estMB, localPath: full, isInstalled: installed,
                installedSizeMB: max(1, Int(sizeBytes / 1_048_576)))
        }
    }

    /// 按模型卡片 ID 一键预下载到本地模型库
    public static func downloadLocalModel(
        id: String, proxy: String = "",
        progress: @Sendable (Double, String) -> Void = { _, _ in }
    ) async throws {
        switch id {
        case "whisper-turbo-q5":
            _ = try await ensureWhisperModel(configured: "ggml-large-v3-turbo-q5_0.bin", proxy: proxy, progress: progress)
        case "whisper-base-en":
            _ = try await ensureWhisperModel(configured: "ggml-base.en.bin", proxy: proxy, progress: progress)
        case "sherpa-parakeet":
            _ = try await ensureSherpaASRModel(configured: "parakeet", proxy: proxy, progress: progress)
        case "kokoro-v1_1":
            _ = try await ensureSherpaModel(configured: "kokoro-multi-lang-v1_1", proxy: proxy, progress: progress)
        case "zipvoice":
            _ = try await ensureSherpaModel(configured: "zipvoice", proxy: proxy, progress: progress)
        case "theresa-vits":
            _ = try await ensureSherpaModel(configured: "vits-zh-hf-theresa", proxy: proxy, progress: progress)
        case "homura-2b-gguf":
            _ = try await ensureHomuraGGUF(configured: "index-homura-2b", proxy: proxy, progress: progress)
        case "demucs-htdemucs":
            _ = try await ensureDemucsModel(configured: "htdemucs", proxy: proxy, progress: progress)
        default:
            throw EngineError.engineFailure("未知本地模型 ID：\(id)")
        }
    }

    private static func directorySize(at path: String) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while let rel = enumerator.nextObject() as? String {
            let full = path + "/" + rel
            if let sz = (try? fm.attributesOfItem(atPath: full)[.size] as? NSNumber)?.int64Value {
                total += sz
            }
        }
        return total
    }

    // MARK: - 通用下载（统一走 NativeMediaDownloader 多并发 + 断点续传底层）

    static func download(
        url: String, to dest: String, proxy: String, label: String,
        http: HTTPFetching? = nil,
        progress: @Sendable (Double, String) -> Void
    ) async throws {
        guard let req = URL(string: url) else {
            throw EngineError.engineFailure("下载地址非法：\(url)")
        }
        let client = http ?? URLSessionHTTPClient(proxy: proxy.isEmpty ? nil : proxy, timeout: 120)
        let targetURL = URL(fileURLWithPath: dest)
        progress(0.0, label + "…")
        do {
            _ = try await NativeMediaDownloader.downloadFile(
                url: req,
                to: targetURL,
                http: client,
                concurrency: 4,
                chunkSize: 1024 * 1024
            ) { frac, detail in
                let pct = Int((min(1, max(0, frac)) * 100).rounded())
                if let detail, !detail.isEmpty {
                    progress(frac, "\(label) \(pct)%（\(detail)）")
                } else {
                    progress(frac, "\(label) \(pct)%")
                }
            }
        } catch {
            throw EngineError.engineFailure("\(label)失败：\(error.localizedDescription)")
        }
        let sizeMB = max(1, Int((fileSize(dest) ?? 0) / 1_048_576))
        progress(1.0, "\(label)完成（\(sizeMB)MB）")
    }
}
