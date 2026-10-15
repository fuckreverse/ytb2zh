import Foundation
import SwiftUI

// MARK: - 模型提供商数据模型
// 提供商 → 模型 → 能力（语音识别/语音生成/翻译/语义切分/术语提取）。
// 各阶段在「模型分配」页按能力筛选后选择；运行时 AppSettings.applied(profile)
// 把 (提供商, 模型) 解析成具体引擎实现 + 参数（endpoint/key/model 等）。
// 持久化：UserDefaults providersJSON（数据量小；UserDefaults 线程安全，
// 管线侧可直接解码快照，无需 Actor 隔离）。

enum ModelCapability: String, Codable, CaseIterable, Identifiable, Hashable {
    case transcribe, tts, translate, segment, terminology

    var id: String { rawValue }

    var label: String {
        switch self {
        case .transcribe: "语音识别"
        case .tts: "语音生成"
        case .translate: "翻译"
        case .segment: "语义切分"
        case .terminology: "术语提取"
        }
    }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case gateway, openai, bailian, edge, whisperLocal, localTTS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .gateway: "LLM 网关"
        case .openai: "OpenAI 兼容"
        case .bailian: "百炼 (DashScope)"
        case .edge: "Edge TTS"
        case .whisperLocal: "本地 whisper.cpp"
        case .localTTS: "本地 TTS"
        }
    }

    var needsBaseURL: Bool { self == .gateway || self == .openai }
    var needsAPIKey: Bool { self == .openai || self == .bailian }
    var baseURLLabel: String { self == .gateway ? "接口地址（完整 Responses 端点）" : "Base URL（到 /v1）" }

    var defaultBaseURL: String {
        switch self {
        case .gateway: "http://127.0.0.1:15000/v1/responses"
        case .openai: "https://api.openai.com/v1"
        default: ""
        }
    }

    /// 新增模型时按提供商预勾选的能力
    var defaultCapabilities: [ModelCapability] {
        switch self {
        case .gateway: [.translate, .segment, .terminology]
        case .openai: [.translate, .tts]
        case .bailian, .edge, .localTTS: [.tts]
        case .whisperLocal: [.transcribe]
        }
    }

    var hint: String {
        switch self {
        case .gateway: "接口地址填完整 Responses 端点（http://host:port/v1/responses）；模型名称即模型 ID"
        case .openai: "Base URL 填到 /v1；同一提供商的模型可分别勾选翻译/语音生成等能力"
        case .bailian: "模型名称填 TTS 模型 ID（如 qwen-audio-3.1-tts-flash）"
        case .edge: "模型名称填音色名（如 zh-CN-YunxiNeural）"
        case .whisperLocal: "模型名称填 ggml 模型文件完整路径，或已知模型名（如 ggml-base.en，缺失自动下载）"
        case .localTTS: "模型名称填「say:音色名」或「sherpa-onnx:模型目录路径」。say 用系统语音（如 say:Tingting）；sherpa-onnx 需从 GitHub 下载模型二进制与模型目录"
        }
    }
}

struct ProviderModel: Codable, Equatable, Identifiable, Hashable {
    var id: String
    var name: String
    var capabilities: [ModelCapability]

    init(id: String = UUID().uuidString, name: String = "", capabilities: [ModelCapability]? = nil) {
        self.id = id
        self.name = name
        self.capabilities = capabilities ?? []
    }
}

struct ProviderConfig: Codable, Equatable, Identifiable {
    var id: String
    var name: String
    var kind: ProviderKind
    var baseURL: String
    var apiKey: String
    var models: [ProviderModel]

    init(id: String = UUID().uuidString, name: String = "", kind: ProviderKind = .gateway,
         baseURL: String = "", apiKey: String = "", models: [ProviderModel] = []) {
        self.id = id; self.name = name; self.kind = kind
        self.baseURL = baseURL; self.apiKey = apiKey; self.models = models
    }
}

// MARK: - 提供商存储（UI 侧 ObservableObject；管线侧用静态快照）

@MainActor
final class ProviderStore: ObservableObject {
    nonisolated static let key = "providersJSON"

    @Published var providers: [ProviderConfig]

    init() { providers = Self.load() }

    func save() { Self.persist(providers) }

    func add(_ kind: ProviderKind) {
        let used = Set(providers.map { $0.name })
        var n = 1
        var name = kind.label
        while used.contains(name) { n += 1; name = "\(kind.label) \(n)" }
        providers.append(ProviderConfig(name: name, kind: kind,
                                        baseURL: kind.defaultBaseURL,
                                        models: [ProviderModel(name: "", capabilities: kind.defaultCapabilities)]))
        save()
    }

    func remove(at offsets: IndexSet) {
        providers.remove(atOffsets: offsets)
        save()
    }

    func addModel(providerID: String) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[i].models.append(ProviderModel(name: "", capabilities: providers[i].kind.defaultCapabilities))
        save()
    }

    func removeModel(providerID: String, modelID: String) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }) else { return }
        providers[i].models.removeAll { $0.id == modelID }
        save()
    }

    func removeProvider(id: String) {
        providers.removeAll { $0.id == id }
        save()
    }

    // MARK: 非隔离读写（管线可直接调用）

    nonisolated static func load() -> [ProviderConfig] {
        let ud = UserDefaults.standard
        // 常规路径是 JSONEncoder 存的 Data；兼容手动 defaults write 塞进来的字符串
        let data = ud.data(forKey: key) ?? ud.string(forKey: key)?.data(using: .utf8)
        guard let data, let list = try? JSONDecoder().decode([ProviderConfig].self, from: data) else { return [] }
        return list
    }

    nonisolated static func persist(_ list: [ProviderConfig]) {
        guard let data = try? JSONEncoder().encode(list) else { return }
        UserDefaults.standard.set(data, forKey: key)
    }

    nonisolated static func snapshot() -> [ProviderConfig] { load() }
}
