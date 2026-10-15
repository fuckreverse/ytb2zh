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
                  let pr = providers.first(where: { $0.id == parts[0] && $0.enabled }),
                  let mo = pr.models.first(where: { $0.id == parts[1] }),
                  !mo.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
            return (pr, mo)
        }
        func baseURL(_ pr: ProviderConfig) -> String {
            let trimmed = pr.baseURL.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { return trimmed }
            return pr.preset?.defaultBaseURL.isEmpty == false ? pr.preset!.defaultBaseURL : pr.kind.defaultBaseURL
        }

        if let (pr, mo) = resolve(.translate) {
            let modelName = mo.name.trimmingCharacters(in: .whitespaces)
            switch pr.kind {
            case .gateway:
                p.engines[StepID.translate.rawValue] = "gateway"
                p.translate.endpoint = baseURL(pr)
                p.translate.apiKey = pr.apiKey
                p.translate.model = modelName
            case .openai, .anthropic, .gemini:
                if modelName.lowercased().contains("homura") {
                    p.engines[StepID.translate.rawValue] = "homura"
                } else {
                    p.engines[StepID.translate.rawValue] = "compat"
                }
                p.translate.compatBaseURL = baseURL(pr)
                p.translate.compatAPIKey = pr.apiKey
                p.translate.compatModel = modelName
                p.translate.compatProtocol = pr.kind.llmProtocolRaw
            default: break
            }
        }

        if let (pr, mo) = resolve(.segment), pr.kind.isLLMProtocol {
            p.engines[StepID.segment.rawValue] = "llm-seg"
            p.segmentation.endpoint = baseURL(pr)
            p.segmentation.apiKey = pr.apiKey
            p.segmentation.model = mo.name.trimmingCharacters(in: .whitespaces)
            p.segmentation.apiProtocol = pr.kind.llmProtocolRaw
        }

        if let (pr, mo) = resolve(.summarize), pr.kind.isLLMProtocol {
            p.engines[StepID.summarize.rawValue] = "gateway-terms"
            p.terminology.endpoint = baseURL(pr)
            p.terminology.apiKey = pr.apiKey
            p.terminology.model = mo.name.trimmingCharacters(in: .whitespaces)
            p.terminology.apiProtocol = pr.kind.llmProtocolRaw
        }

        if let (pr, mo) = resolve(.synthesize) {
            let modelName = mo.name.trimmingCharacters(in: .whitespaces)
            switch pr.kind {
            case .bailian:
                p.engines[StepID.synthesize.rawValue] = "bailian"
                p.synth.apiKey = pr.apiKey
                p.synth.model = modelName
            case .openai:
                p.engines[StepID.synthesize.rawValue] = "openai-tts"
                p.synth.compatBaseURL = baseURL(pr)
                p.synth.compatAPIKey = pr.apiKey
                p.synth.compatTTSModel = modelName
            case .edge:
                p.engines[StepID.synthesize.rawValue] = "edge-tts"
                p.synth.edgeVoice = modelName
            case .localTTS:
                let parts = modelName.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let subEngine = parts.first?.trimmingCharacters(in: .whitespaces) ?? "say"
                let param = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
                if subEngine == "sherpa-onnx" {
                    p.engines[StepID.synthesize.rawValue] = "sherpa-onnx"
                    p.synth.sherpaOnnxModelDir = param
                    if param.lowercased().contains("kokoro") || param.lowercased().contains("zipvoice") {
                        p.synth.podcastMode = true
                    }
                    if param.lowercased().contains("zipvoice") {
                        p.synth.cloneSourceVoice = true
                    }
                } else if subEngine == "mlx-tts" {
                    p.engines[StepID.synthesize.rawValue] = "mlx-tts"
                    if !param.isEmpty { p.synth.mlxModel = param }
                    p.synth.podcastMode = true
                } else {
                    // say 或未指定前缀 → macOS say 引擎
                    p.engines[StepID.synthesize.rawValue] = "local-say"
                    p.synth.localVoice = param.isEmpty ? "Tingting" : param
                }
            default: break
            }
        }

        if let (pr, mo) = resolve(.transcribe) {
            let modelName = mo.name.trimmingCharacters(in: .whitespaces)
            switch pr.kind {
            case .whisperLocal:
                if modelName.hasPrefix("sherpa-asr:") {
                    p.engines[StepID.transcribe.rawValue] = "sherpa-asr"
                    p.transcribe.sherpaModelDir = String(modelName.dropFirst("sherpa-asr:".count))
                } else if modelName.hasPrefix("mlx-asr:") {
                    p.engines[StepID.transcribe.rawValue] = "mlx-asr"
                    p.transcribe.mlxModel = String(modelName.dropFirst("mlx-asr:".count))
                } else {
                    // whisper.cpp 已内嵌（进程内 Metal 推理）；mo.name 为模型名或路径，缺失时自动下载
                    p.engines[StepID.transcribe.rawValue] = "whisper-native"
                    p.transcribe.modelPath = modelName
                }
            case .openai:
                p.engines[StepID.transcribe.rawValue] = "openai-asr"
                p.transcribe.compatBaseURL = baseURL(pr)
                p.transcribe.compatAPIKey = pr.apiKey
                p.transcribe.compatModel = modelName
            default: break
            }
        }

        return p
    }
}
