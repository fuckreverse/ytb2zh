import Foundation
import Ytb2ZHCore

// MARK: - 全局运行偏好（UserDefaults 持久化）
// 应用设置页写入；优先级：全局覆盖 > 模板内置值（空 = 跟随模板）。
// 网络：代理可按用途（下载 / 搜索 / edge-tts）分别开关。
// 模型：阶段 → (提供商, 模型) 分配，由 applied() 解析成引擎实现 + 参数。

enum ProxyScope: String {
    case download   // yt-dlp 下载
    case search     // YouTube 搜索 / 频道浏览
    case edgeTTS    // edge-tts 语音合成
}

enum AppSettings {
    static let proxyKey = "globalProxy"
    static let jobRootKey = JobStore.customRootKey
    static let proxyForDownloadKey = "proxyForDownload"
    static let proxyForSearchKey = "proxyForSearch"
    static let proxyForEdgeTTSKey = "proxyForEdgeTTS"
    static let stageModelsKey = "stageModels"   // [StepID: "providerID|modelID"]

    static func str(_ key: String) -> String {
        (UserDefaults.standard.string(forKey: key) ?? "").trimmingCharacters(in: .whitespaces)
    }

    /// 全局代理（空 = 用模板内置的 download.proxy / synth.edgeProxy）
    static var proxy: String { str(proxyKey) }

    static func setProxy(_ value: String) {
        UserDefaults.standard.set(value.trimmingCharacters(in: .whitespaces), forKey: proxyKey)
    }

    /// 代理对各用途是否生效（缺省 = 全部启用）
    static func proxyApplies(_ scope: ProxyScope) -> Bool {
        let key: String
        switch scope {
        case .download: key = proxyForDownloadKey
        case .search: key = proxyForSearchKey
        case .edgeTTS: key = proxyForEdgeTTSKey
        }
        return UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    /// 搜索等临时取数的生效代理：全局优先（按用途开关），回退模板值
    static func effectiveProxy(fallback: String, scope: ProxyScope = .search) -> String {
        (!proxy.isEmpty && proxyApplies(scope)) ? proxy : fallback
    }

    /// 各阶段已分配的模型引用（step.rawValue → "providerID|modelID"）
    static var stageModels: [String: String] {
        (UserDefaults.standard.dictionary(forKey: stageModelsKey) as? [String: String] ?? [:])
            .filter { !$0.value.isEmpty }
    }

    static func setStageModels(_ value: [String: String]) {
        UserDefaults.standard.set(value, forKey: stageModelsKey)
    }

    // MARK: - 应用到 Profile
    // 所有非空的全局项覆盖模板对应字段（不改模板名，重播匹配不受影响）。

    static func applied(_ profile: Profile) -> Profile {
        var p = profile

        // —— 网络：代理按用途生效
        let g = proxy
        if !g.isEmpty {
            if proxyApplies(.download) { p.download.proxy = g }
            if proxyApplies(.edgeTTS) { p.synth.edgeProxy = g }
        }

        // —— 模型分配：阶段 → (提供商, 模型) → 引擎实现 + 参数
        let providers = ProviderStore.snapshot()
        func resolve(_ step: StepID) -> (ProviderConfig, ProviderModel)? {
            guard let ref = stageModels[step.rawValue] else { return nil }
            let parts = ref.split(separator: "|", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 2,
                  let pr = providers.first(where: { $0.id == parts[0] }),
                  let mo = pr.models.first(where: { $0.id == parts[1] }),
                  !mo.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (pr, mo)
        }
        func baseURL(_ pr: ProviderConfig) -> String {
            pr.baseURL.trimmingCharacters(in: .whitespaces).isEmpty ? pr.kind.defaultBaseURL : pr.baseURL
        }

        if let (pr, mo) = resolve(.translate) {
            switch pr.kind {
            case .gateway:
                p.engines[StepID.translate.rawValue] = "gateway"
                p.translate.endpoint = baseURL(pr)
                p.translate.model = mo.name
            case .openai:
                p.engines[StepID.translate.rawValue] = "compat"
                p.translate.compatBaseURL = baseURL(pr)
                p.translate.compatAPIKey = pr.apiKey
                p.translate.compatModel = mo.name
            default: break
            }
        }

        if let (pr, mo) = resolve(.segment), pr.kind == .gateway {
            p.engines[StepID.segment.rawValue] = "llm-seg"
            p.segmentation.endpoint = baseURL(pr)
            p.segmentation.model = mo.name
        }

        if let (pr, mo) = resolve(.summarize), pr.kind == .gateway {
            p.engines[StepID.summarize.rawValue] = "gateway-terms"
            p.terminology.endpoint = baseURL(pr)
            p.terminology.model = mo.name
        }

        if let (pr, mo) = resolve(.synthesize) {
            switch pr.kind {
            case .bailian:
                p.engines[StepID.synthesize.rawValue] = "bailian"
                p.synth.apiKey = pr.apiKey
                p.synth.model = mo.name
            case .openai:
                p.engines[StepID.synthesize.rawValue] = "openai-tts"
                p.synth.compatBaseURL = baseURL(pr)
                p.synth.compatAPIKey = pr.apiKey
                p.synth.compatTTSModel = mo.name
            case .edge:
                p.engines[StepID.synthesize.rawValue] = "edge-tts"
                p.synth.edgeVoice = mo.name
            case .localTTS:
                let parts = mo.name.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let subEngine = parts.first?.trimmingCharacters(in: .whitespaces) ?? "say"
                let param = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if subEngine == "sherpa-onnx" {
                    p.engines[StepID.synthesize.rawValue] = "sherpa-onnx"
                    p.synth.sherpaOnnxModelDir = param
                } else {
                    // say 或未指定前缀 → macOS say 引擎
                    p.engines[StepID.synthesize.rawValue] = "local-say"
                    p.synth.localVoice = param.isEmpty ? "Tingting" : param
                }
            default: break
            }
        }

        if let (pr, mo) = resolve(.transcribe), pr.kind == .whisperLocal {
            p.engines[StepID.transcribe.rawValue] = "whisper-cpp"
            p.transcribe.modelPath = mo.name
        }

        return p
    }
}
