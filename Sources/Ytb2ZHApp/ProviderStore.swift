import Foundation
import SwiftUI
import Ytb2ZHEngines

// MARK: - 模型提供商数据模型（底层标准协议 + 主流国内外厂商预设库）
// 架构参考 Cherry Studio / Magpie：
//   1. ProviderKind 定义底层标准通信协议或本地引擎实现（OpenAI Chat / Responses / Anthropic / Gemini / 百炼 WS / Edge / 本地）；
//   2. ProviderPreset 提供主流服务商的一键预设（OpenRouter、OpenCode、阿里百炼、字节火山方舟、DeepSeek、硅基流动等），
//      自带默认 Base URL、官网 API Key 链接、推荐模型及默认能力勾选；
//   3. 各阶段在「模型分配」页按能力筛选后选择；运行时 AppSettings.applied(profile)
//      把 (提供商, 模型) 解析成具体引擎实现 + 参数（endpoint/key/model/protocol 等）。
// 持久化：UserDefaults providersJSON（向后兼容旧版 JSON）。

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

    var icon: String {
        switch self {
        case .transcribe: "waveform"
        case .tts: "speaker.wave.2.fill"
        case .translate: "character.bubble.fill"
        case .segment: "scissors"
        case .terminology: "text.book.closed.fill"
        }
    }
}

enum ProviderKind: String, Codable, CaseIterable, Identifiable, Hashable {
    case openai
    case gateway
    case anthropic
    case gemini
    case bailian
    case edge
    case whisperLocal
    case localTTS

    var id: String { rawValue }

    var label: String {
        switch self {
        case .openai: "OpenAI 兼容 (Chat / Audio)"
        case .gateway: "OpenAI Responses (/v1/responses)"
        case .anthropic: "Anthropic Messages (/v1/messages)"
        case .gemini: "Google Gemini (v1beta)"
        case .bailian: "百炼原生 TTS (DashScope WS)"
        case .edge: "Edge TTS (免费神经语音)"
        case .whisperLocal: "本地 whisper.cpp"
        case .localTTS: "本地 TTS (say / Sherpa-Onnx)"
        }
    }

    var shortBadge: String {
        switch self {
        case .openai: "OpenAI 协议"
        case .gateway: "Responses 协议"
        case .anthropic: "Anthropic 协议"
        case .gemini: "Gemini 协议"
        case .bailian: "DashScope WS"
        case .edge: "内置免费"
        case .whisperLocal: "本地 Metal"
        case .localTTS: "本地离线"
        }
    }

    var isLLMProtocol: Bool {
        switch self {
        case .openai, .gateway, .anthropic, .gemini: true
        case .bailian, .edge, .whisperLocal, .localTTS: false
        }
    }

    /// 传给引擎层的协议标识
    var llmProtocolRaw: String {
        switch self {
        case .openai: "openai"
        case .gateway: "responses"
        case .anthropic: "anthropic"
        case .gemini: "gemini"
        default: "openai"
        }
    }

    var needsBaseURL: Bool {
        switch self {
        case .openai, .gateway, .anthropic, .gemini: true
        case .bailian, .edge, .whisperLocal, .localTTS: false
        }
    }

    var needsAPIKey: Bool {
        switch self {
        case .openai, .gateway, .anthropic, .gemini, .bailian: true
        case .edge, .whisperLocal, .localTTS: false
        }
    }

    var supportsRemoteModels: Bool {
        switch self {
        case .openai, .gateway, .anthropic, .gemini: true
        default: false
        }
    }

    var supportsConnectionTest: Bool {
        switch self {
        case .openai, .gateway, .anthropic, .gemini: true
        default: false
        }
    }

    var baseURLLabel: String {
        switch self {
        case .gateway: "接口地址（到 /v1 或 /v1/responses）"
        case .anthropic: "Base URL（到 /v1）"
        case .gemini: "Base URL（到 /v1beta）"
        default: "Base URL（到 /v1 或 /v3）"
        }
    }

    var defaultBaseURL: String {
        switch self {
        case .gateway: "http://127.0.0.1:15000/v1/responses"
        case .openai: "https://api.openai.com/v1"
        case .anthropic: "https://api.anthropic.com/v1"
        case .gemini: "https://generativelanguage.googleapis.com/v1beta"
        default: ""
        }
    }

    /// 预览完整请求端点（仿 Cherry Studio 地址预览）
    func endpointPreview(baseURL: String, sampleModel: String = "model") -> String {
        let raw = baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? defaultBaseURL : baseURL
        switch self {
        case .openai:
            return OpenAICompatTranslateEngine.resolveChatCompletionsURL(raw)
        case .gateway:
            return GatewayTranslateEngine.resolveResponsesURL(raw)
        case .anthropic:
            return OpenAICompatTranslateEngine.resolveAnthropicMessagesURL(raw)
        case .gemini:
            if raw.lowercased().contains("/openai") {
                return OpenAICompatTranslateEngine.resolveChatCompletionsURL(raw)
            }
            return OpenAICompatTranslateEngine.resolveGeminiURL(raw, model: sampleModel.isEmpty ? "gemini-2.5-flash" : sampleModel, apiKey: "")
        case .bailian:
            return "wss://dashscope.aliyuncs.com/api-ws/v1/inference"
        case .edge, .whisperLocal, .localTTS:
            return ""
        }
    }

    /// 新增模型时按提供商预勾选的能力
    var defaultCapabilities: [ModelCapability] {
        switch self {
        case .gateway, .anthropic, .gemini: [.translate, .segment, .terminology]
        case .openai: [.translate, .segment, .terminology]
        case .bailian, .edge, .localTTS: [.tts]
        case .whisperLocal: [.transcribe]
        }
    }

    /// 根据模型名称智能推断能力（用于从远端 /models 拉取模型时自动打勾）
    func inferCapabilities(for modelName: String) -> [ModelCapability] {
        let lower = modelName.lowercased()
        switch self {
        case .bailian, .edge, .localTTS:
            return [.tts]
        case .whisperLocal:
            return [.transcribe]
        case .openai, .gateway, .anthropic, .gemini:
            if lower.contains("tts") || lower.contains("cosyvoice") || lower.contains("speech") || lower.contains("voice") {
                return [.tts]
            }
            if lower.contains("whisper") || lower.contains("sensevoice") || lower.contains("asr") || lower.contains("transcribe") || lower.contains("paraformer") {
                return [.transcribe]
            }
            return [.translate, .segment, .terminology]
        }
    }

    var hint: String {
        switch self {
        case .gateway: "支持 OpenAI Responses 协议（/v1/responses）；本地无鉴权网关可留空 API Key，云端网关填 Bearer Key"
        case .openai: "兼容标准 OpenAI 协议：对话走 /chat/completions（翻译/切分/术语），语音合成走 /audio/speech，语音识别走 /audio/transcriptions"
        case .anthropic: "兼容 Anthropic Messages 协议（/v1/messages，自动发送 x-api-key 与 anthropic-version 头），支持 Claude 官方及中转服务"
        case .gemini: "支持 Google Gemini 原生协议（v1beta/models/{model}:generateContent）或其 OpenAI 兼容端点"
        case .bailian: "阿里云百炼 DashScope 原生 WebSocket 流式语音合成；模型名称填 TTS 模型 ID（如 qwen-audio-3.1-tts-flash）"
        case .edge: "免费微软 Edge 神经语音，零外部依赖；模型名称填音色名（如 zh-CN-YunxiNeural、zh-CN-XiaoxiaoNeural）"
        case .whisperLocal: "内嵌 whisper.cpp 本地 Metal 推理；模型名称填 ggml 模型路径或已知模型名（如 ggml-base.en，缺失自动下载）"
        case .localTTS: "模型名称填「say:音色名」或「sherpa-onnx:模型目录路径」。say 用 macOS 系统语音（如 say:Tingting）"
        }
    }
}

// MARK: - 主流提供商预设分类与目录（参考 Cherry Studio / Magpie）

enum ProviderCategory: String, CaseIterable, Identifiable {
    case china = "中国主流大模型"
    case aggregator = "聚合网关与 AI 编程"
    case global = "国际主流厂商"
    case protocolAndLocal = "标准协议与本地引擎"

    var id: String { rawValue }
}

struct ProviderPreset: Identifiable, Equatable {
    let id: String
    let name: String
    let subtitle: String
    let badgeText: String
    let badgeColor: Color
    let category: ProviderCategory
    let kind: ProviderKind
    let defaultBaseURL: String
    let apiKeyURL: String
    let recommendedModels: [ProviderModel]

    /// 转换为一个可持久化的 ProviderConfig 实例
    func makeConfig(existingNames: Set<String> = []) -> ProviderConfig {
        var finalName = name
        var idx = 1
        while existingNames.contains(finalName) {
            idx += 1
            finalName = "\(name) \(idx)"
        }
        let clonedModels = recommendedModels.isEmpty
            ? [ProviderModel(name: "", capabilities: kind.defaultCapabilities)]
            : recommendedModels.map { ProviderModel(name: $0.name, capabilities: $0.capabilities) }
        return ProviderConfig(
            name: finalName,
            kind: kind,
            baseURL: defaultBaseURL,
            apiKey: "",
            models: clonedModels,
            presetID: id,
            enabled: true
        )
    }

    static let all: [ProviderPreset] = [
        // ── 1. 聚合网关与 AI 编程 ──
        ProviderPreset(
            id: "openrouter",
            name: "OpenRouter",
            subtitle: "全球最流行的多模型聚合路由，统一 OpenAI 协议接入 Claude / Gemini / DeepSeek / GPT",
            badgeText: "OR",
            badgeColor: Color(red: 0.38, green: 0.32, blue: 0.88),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://openrouter.ai/api/v1",
            apiKeyURL: "https://openrouter.ai/keys",
            recommendedModels: [
                ProviderModel(name: "google/gemini-2.5-flash", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek/deepseek-chat-v3-0324", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "anthropic/claude-sonnet-4", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "openai/gpt-4.1-mini", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "opencode",
            name: "OpenCode (Zen / Go)",
            subtitle: "OpenCode 官方模型网关，支持 OpenAI / Anthropic / Responses 标准协议切换",
            badgeText: "OC",
            badgeColor: Color(red: 0.14, green: 0.62, blue: 0.56),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://opencode.ai/zen/v1",
            apiKeyURL: "https://opencode.ai",
            recommendedModels: [
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "claude-sonnet-4", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gemini-2.5-flash", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4.1-mini", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "siliconflow",
            name: "硅基流动 (SiliconFlow)",
            subtitle: "国内高性价比聚合平台，全栈支持 DeepSeek / Qwen 文本、CosyVoice 语音合成与 SenseVoice 识别",
            badgeText: "硅基",
            badgeColor: Color(red: 0.44, green: 0.28, blue: 0.92),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://api.siliconflow.cn/v1",
            apiKeyURL: "https://cloud.siliconflow.cn/account/ak",
            recommendedModels: [
                ProviderModel(name: "deepseek-ai/DeepSeek-V3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "Qwen/Qwen3-32B", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "FunAudioLLM/CosyVoice2-0.5B", capabilities: [.tts]),
                ProviderModel(name: "FunAudioLLM/SenseVoiceSmall", capabilities: [.transcribe]),
            ]
        ),
        ProviderPreset(
            id: "302ai",
            name: "302.AI",
            subtitle: "按需付费的企业级 AI 应用与全球大模型聚合网关",
            badgeText: "302",
            badgeColor: Color(red: 0.90, green: 0.45, blue: 0.12),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://api.302.ai/v1",
            apiKeyURL: "https://302.ai",
            recommendedModels: [
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4o-mini", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "claude-3-7-sonnet-latest", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "aihubmix",
            name: "AiHubMix",
            subtitle: "一站式海外与国内大模型 API 聚合中转服务",
            badgeText: "Hub",
            badgeColor: Color(red: 0.20, green: 0.52, blue: 0.90),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://aihubmix.com/v1",
            apiKeyURL: "https://aihubmix.com",
            recommendedModels: [
                ProviderModel(name: "gpt-4o-mini", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-chat", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "claude-3-7-sonnet-latest", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "ppio",
            name: "PPIO 派欧云",
            subtitle: "分布式算力与开源大模型推理网关",
            badgeText: "PPIO",
            badgeColor: Color(red: 0.16, green: 0.48, blue: 0.82),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "https://api.ppinfra.com/v3/openai",
            apiKeyURL: "https://ppinfra.com",
            recommendedModels: [
                ProviderModel(name: "deepseek/deepseek-v3-0324", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen/qwen3-235b-a22b", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "newapi",
            name: "NewAPI / OneAPI 中转",
            subtitle: "自建或第三方 NewAPI / OneAPI 标准接口，可自由切换 OpenAI / Claude / Gemini 协议",
            badgeText: "One",
            badgeColor: Color(red: 0.30, green: 0.56, blue: 0.72),
            category: .aggregator,
            kind: .openai,
            defaultBaseURL: "http://127.0.0.1:3000/v1",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4o-mini", capabilities: [.translate, .segment, .terminology]),
            ]
        ),

        // ── 2. 中国主流大模型 ──
        ProviderPreset(
            id: "alibaba-bailian",
            name: "阿里云百炼 · 通义千问 (DashScope)",
            subtitle: "阿里云大模型服务平台 OpenAI 兼容接口（通义千问 Qwen3 / Qwen-Plus / Qwen-Max / DeepSeek）",
            badgeText: "阿里",
            badgeColor: Color(red: 0.98, green: 0.42, blue: 0.08),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1",
            apiKeyURL: "https://bailian.console.aliyun.com/?apiKey=1",
            recommendedModels: [
                ProviderModel(name: "qwen-plus", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen-max", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen-turbo-latest", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen3-235b-a22b", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "alibaba-bailian-tts",
            name: "阿里云百炼 · 语音合成 (DashScope TTS)",
            subtitle: "百炼原生 WebSocket 流式语音合成（qwen-audio-3.1-tts-flash，支持原生语速调节与多音色）",
            badgeText: "百炼音",
            badgeColor: Color(red: 0.92, green: 0.35, blue: 0.14),
            category: .china,
            kind: .bailian,
            defaultBaseURL: "",
            apiKeyURL: "https://bailian.console.aliyun.com/?apiKey=1",
            recommendedModels: [
                ProviderModel(name: "qwen-audio-3.1-tts-flash", capabilities: [.tts]),
            ]
        ),
        ProviderPreset(
            id: "bytedance-ark",
            name: "字节跳动 · 火山方舟 (豆包 Volcengine)",
            subtitle: "字节跳动火山引擎大模型平台（豆包 Doubao 1.5 Pro / Seed / DeepSeek，支持模型 ID 或推理接入点 ep-...）",
            badgeText: "字节",
            badgeColor: Color(red: 0.12, green: 0.48, blue: 0.96),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://ark.cn-beijing.volces.com/api/v3",
            apiKeyURL: "https://console.volcengine.com/ark/region:ark+cn-beijing/apiKey",
            recommendedModels: [
                ProviderModel(name: "doubao-1-5-pro-32k-250115", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "doubao-1-5-lite-32k-250115", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-v3-250324", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-r1-250120", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "deepseek",
            name: "DeepSeek (深度求索)",
            subtitle: "深度求索官方 API（deepseek-chat V3 / deepseek-reasoner R1，中文语序重组极佳）",
            badgeText: "DS",
            badgeColor: Color(red: 0.22, green: 0.42, blue: 0.94),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.deepseek.com/v1",
            apiKeyURL: "https://platform.deepseek.com/api_keys",
            recommendedModels: [
                ProviderModel(name: "deepseek-chat", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-reasoner", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "zhipu",
            name: "智谱 AI (Zhipu GLM / BigModel)",
            subtitle: "智谱清言开放平台（GLM-4-Plus / GLM-4-Air / GLM-4-Flash 免费高速模型）",
            badgeText: "智谱",
            badgeColor: Color(red: 0.18, green: 0.38, blue: 0.86),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://open.bigmodel.cn/api/paas/v4",
            apiKeyURL: "https://open.bigmodel.cn/usercenter/apikeys",
            recommendedModels: [
                ProviderModel(name: "glm-4-plus", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "glm-4-air-250414", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "glm-4-flash-250414", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "moonshot",
            name: "月之暗面 (Moonshot / Kimi)",
            subtitle: "Kimi 开放平台（kimi-k2 / moonshot-v1，擅长长文本理解与地道中文表达）",
            badgeText: "Kimi",
            badgeColor: Color(red: 0.15, green: 0.18, blue: 0.26),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.moonshot.cn/v1",
            apiKeyURL: "https://platform.moonshot.cn/console/api-keys",
            recommendedModels: [
                ProviderModel(name: "kimi-k2-0711-preview", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "moonshot-v1-auto", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "minimax",
            name: "MiniMax (海螺 AI)",
            subtitle: "MiniMax 开放平台（MiniMax-Text-01 / abab6.5s，口语化旁白表现自然）",
            badgeText: "MM",
            badgeColor: Color(red: 0.88, green: 0.26, blue: 0.42),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.minimax.chat/v1",
            apiKeyURL: "https://platform.minimaxi.com/user-center/basic-information/interface-key",
            recommendedModels: [
                ProviderModel(name: "MiniMax-Text-01", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "abab6.5s-chat", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "hunyuan",
            name: "腾讯混元 (Tencent Hunyuan)",
            subtitle: "腾讯云混元大模型 OpenAI 兼容接口（hunyuan-turbos / hunyuan-pro）",
            badgeText: "混元",
            badgeColor: Color(red: 0.05, green: 0.44, blue: 0.90),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.hunyuan.cloud.tencent.com/v1",
            apiKeyURL: "https://console.cloud.tencent.com/hunyuan/api-key",
            recommendedModels: [
                ProviderModel(name: "hunyuan-turbos-latest", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "hunyuan-pro", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "hunyuan-standard", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "qianfan",
            name: "百度千帆 (Baidu Qianfan)",
            subtitle: "百度智能云千帆大模型平台 V2 接口（文心一言 ERNIE 4.5 / DeepSeek）",
            badgeText: "千帆",
            badgeColor: Color(red: 0.16, green: 0.36, blue: 0.92),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://qianfan.baidubce.com/v2",
            apiKeyURL: "https://console.bce.baidu.com/iam/#/iam/apikey/list",
            recommendedModels: [
                ProviderModel(name: "ernie-4.5-turbo-128k", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "ernie-4.0-turbo-8k", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "stepfun",
            name: "阶跃星辰 (StepFun)",
            subtitle: "阶跃星辰开放平台（Step-2 / Step-1 对话模型与 step-tts-mini 语音合成）",
            badgeText: "阶跃",
            badgeColor: Color(red: 0.26, green: 0.60, blue: 0.94),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.stepfun.com/v1",
            apiKeyURL: "https://platform.stepfun.com/interface-key",
            recommendedModels: [
                ProviderModel(name: "step-2-16k", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "step-1-8k", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "step-tts-mini", capabilities: [.tts]),
            ]
        ),
        ProviderPreset(
            id: "yi",
            name: "零一万物 (Yi / Lingyiwanwu)",
            subtitle: "零一万物大模型开放平台（yi-lightning / yi-large）",
            badgeText: "零一",
            badgeColor: Color(red: 0.12, green: 0.56, blue: 0.42),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.lingyiwanwu.com/v1",
            apiKeyURL: "https://platform.lingyiwanwu.com/apikeys",
            recommendedModels: [
                ProviderModel(name: "yi-lightning", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "yi-large", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "spark",
            name: "讯飞星火 (iFlytek Spark)",
            subtitle: "科大讯飞星火认知大模型 OpenAI 兼容接口（4.0Ultra / generalv3.5）",
            badgeText: "讯飞",
            badgeColor: Color(red: 0.08, green: 0.46, blue: 0.88),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://spark-api-open.xf-yun.com/v1",
            apiKeyURL: "https://console.xfyun.cn/services/bm35",
            recommendedModels: [
                ProviderModel(name: "4.0Ultra", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "generalv3.5", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "baichuan",
            name: "百川智能 (Baichuan)",
            subtitle: "百川大模型开放平台（Baichuan4-Turbo / Baichuan4-Air）",
            badgeText: "百川",
            badgeColor: Color(red: 0.92, green: 0.46, blue: 0.16),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api.baichuan-ai.com/v1",
            apiKeyURL: "https://platform.baichuan-ai.com/console/apikey",
            recommendedModels: [
                ProviderModel(name: "Baichuan4-Turbo", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "Baichuan4-Air", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "infiniai",
            name: "无问芯穹 (Infini-AI GenStudio)",
            subtitle: "无问芯穹大模型云服务（DeepSeek-V3 / Qwen2.5 高速推理）",
            badgeText: "无问",
            badgeColor: Color(red: 0.34, green: 0.36, blue: 0.84),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://cloud.infini-ai.com/maas/v1",
            apiKeyURL: "https://cloud.infini-ai.com",
            recommendedModels: [
                ProviderModel(name: "deepseek-v3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen2.5-72b-instruct", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "modelscope",
            name: "魔搭社区 (ModelScope API-Inference)",
            subtitle: "阿里魔搭社区免费/普惠开源模型推理接口（Qwen3 / DeepSeek-V3）",
            badgeText: "魔搭",
            badgeColor: Color(red: 0.42, green: 0.30, blue: 0.88),
            category: .china,
            kind: .openai,
            defaultBaseURL: "https://api-inference.modelscope.cn/v1",
            apiKeyURL: "https://modelscope.cn/my/myaccesstoken",
            recommendedModels: [
                ProviderModel(name: "Qwen/Qwen3-235B-A22B", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "deepseek-ai/DeepSeek-V3", capabilities: [.translate, .segment, .terminology]),
            ]
        ),

        // ── 3. 国际主流厂商 ──
        ProviderPreset(
            id: "openai",
            name: "OpenAI",
            subtitle: "OpenAI 官方接口（GPT-4.1 / GPT-4o 翻译、gpt-4o-mini-tts 配音、whisper-1 语音识别）",
            badgeText: "OA",
            badgeColor: Color(red: 0.06, green: 0.64, blue: 0.50),
            category: .global,
            kind: .openai,
            defaultBaseURL: "https://api.openai.com/v1",
            apiKeyURL: "https://platform.openai.com/api-keys",
            recommendedModels: [
                ProviderModel(name: "gpt-4.1-mini", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4.1", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4o-mini", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gpt-4o-mini-tts", capabilities: [.tts]),
                ProviderModel(name: "whisper-1", capabilities: [.transcribe]),
            ]
        ),
        ProviderPreset(
            id: "anthropic",
            name: "Anthropic (Claude)",
            subtitle: "Anthropic 官方 Messages 协议（Claude Sonnet 4 / 3.7 Sonnet / 3.5 Haiku）",
            badgeText: "CL",
            badgeColor: Color(red: 0.82, green: 0.46, blue: 0.30),
            category: .global,
            kind: .anthropic,
            defaultBaseURL: "https://api.anthropic.com/v1",
            apiKeyURL: "https://console.anthropic.com/settings/keys",
            recommendedModels: [
                ProviderModel(name: "claude-sonnet-4-20250514", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "claude-3-7-sonnet-latest", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "claude-3-5-haiku-latest", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "gemini",
            name: "Google Gemini",
            subtitle: "Google AI Studio 原生 v1beta 协议（Gemini 2.5 Flash / 2.5 Pro，超大上下文窗口）",
            badgeText: "GM",
            badgeColor: Color(red: 0.24, green: 0.52, blue: 0.96),
            category: .global,
            kind: .gemini,
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeyURL: "https://aistudio.google.com/apikey",
            recommendedModels: [
                ProviderModel(name: "gemini-2.5-flash", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gemini-2.5-pro", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "gemini-2.0-flash", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "xai",
            name: "xAI (Grok)",
            subtitle: "xAI 官方 OpenAI 兼容接口（Grok-3 / Grok-3-Mini）",
            badgeText: "xAI",
            badgeColor: Color(red: 0.20, green: 0.20, blue: 0.24),
            category: .global,
            kind: .openai,
            defaultBaseURL: "https://api.x.ai/v1",
            apiKeyURL: "https://console.x.ai",
            recommendedModels: [
                ProviderModel(name: "grok-3-mini", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "grok-3", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "groq",
            name: "Groq",
            subtitle: "LPU 极速推理云（Llama 3.3 70B 极速翻译 + whisper-large-v3-turbo 秒级语音识别）",
            badgeText: "GQ",
            badgeColor: Color(red: 0.94, green: 0.34, blue: 0.20),
            category: .global,
            kind: .openai,
            defaultBaseURL: "https://api.groq.com/openai/v1",
            apiKeyURL: "https://console.groq.com/keys",
            recommendedModels: [
                ProviderModel(name: "llama-3.3-70b-versatile", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "whisper-large-v3-turbo", capabilities: [.transcribe]),
            ]
        ),
        ProviderPreset(
            id: "mistral",
            name: "Mistral AI",
            subtitle: "欧洲旗舰大模型平台（Mistral Large / Small）",
            badgeText: "MS",
            badgeColor: Color(red: 0.94, green: 0.50, blue: 0.14),
            category: .global,
            kind: .openai,
            defaultBaseURL: "https://api.mistral.ai/v1",
            apiKeyURL: "https://console.mistral.ai/api-keys",
            recommendedModels: [
                ProviderModel(name: "mistral-large-latest", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "mistral-small-latest", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "together",
            name: "Together AI",
            subtitle: "海外主流开源模型推理云（DeepSeek-V3 / Llama 3.3）",
            badgeText: "TG",
            badgeColor: Color(red: 0.18, green: 0.44, blue: 0.90),
            category: .global,
            kind: .openai,
            defaultBaseURL: "https://api.together.xyz/v1",
            apiKeyURL: "https://api.together.ai/settings/api-keys",
            recommendedModels: [
                ProviderModel(name: "deepseek-ai/DeepSeek-V3", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "meta-llama/Llama-3.3-70B-Instruct-Turbo", capabilities: [.translate, .segment, .terminology]),
            ]
        ),

        // ── 4. 标准协议与本地引擎 ──
        ProviderPreset(
            id: "custom-openai",
            name: "自定义 OpenAI 兼容服务",
            subtitle: "任意兼容 /v1/chat/completions、/v1/audio/speech、/v1/audio/transcriptions 的标准端点",
            badgeText: "OAI",
            badgeColor: Color(red: 0.16, green: 0.58, blue: 0.48),
            category: .protocolAndLocal,
            kind: .openai,
            defaultBaseURL: "https://api.openai.com/v1",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "gpt-4o-mini", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "custom-responses",
            name: "OpenAI Responses / 本地网关",
            subtitle: "兼容 /v1/responses 标准协议的云端或本地网关（如 127.0.0.1:15000）",
            badgeText: "RSP",
            badgeColor: Color(red: 0.36, green: 0.48, blue: 0.86),
            category: .protocolAndLocal,
            kind: .gateway,
            defaultBaseURL: "http://127.0.0.1:15000/v1/responses",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "friday-personal/deepseek-v4-flash", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "custom-anthropic",
            name: "自定义 Anthropic Messages 服务",
            subtitle: "任意兼容 /v1/messages (Claude 标准协议) 的官方或第三方中转端点",
            badgeText: "ANT",
            badgeColor: Color(red: 0.80, green: 0.44, blue: 0.28),
            category: .protocolAndLocal,
            kind: .anthropic,
            defaultBaseURL: "https://api.anthropic.com/v1",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "claude-sonnet-4-20250514", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "custom-gemini",
            name: "自定义 Google Gemini 服务",
            subtitle: "任意兼容 Gemini v1beta generateContent 协议的官方或反代端点",
            badgeText: "GEM",
            badgeColor: Color(red: 0.22, green: 0.50, blue: 0.92),
            category: .protocolAndLocal,
            kind: .gemini,
            defaultBaseURL: "https://generativelanguage.googleapis.com/v1beta",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "gemini-2.5-flash", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "ollama",
            name: "Ollama (本地大模型)",
            subtitle: "本机离线推理（http://127.0.0.1:11434/v1，支持 Qwen3 与 Index-Homura 音节受控配音翻译）",
            badgeText: "OL",
            badgeColor: Color(red: 0.28, green: 0.32, blue: 0.38),
            category: .protocolAndLocal,
            kind: .openai,
            defaultBaseURL: "http://127.0.0.1:11434/v1",
            apiKeyURL: "https://ollama.com",
            recommendedModels: [
                ProviderModel(name: "IndexTeam/Index-Homura-9B", capabilities: [.translate]),
                ProviderModel(name: "IndexTeam/Index-Homura-2B", capabilities: [.translate]),
                ProviderModel(name: "qwen3:8b", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen3:14b", capabilities: [.translate, .segment, .terminology]),
                ProviderModel(name: "qwen2.5:14b", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "lmstudio",
            name: "LM Studio / llama.cpp (本地大模型)",
            subtitle: "LM Studio 或 llama-server 本地服务（http://127.0.0.1:1234/v1，支持 GGUF 模型免 Key 调用）",
            badgeText: "LMS",
            badgeColor: Color(red: 0.42, green: 0.26, blue: 0.78),
            category: .protocolAndLocal,
            kind: .openai,
            defaultBaseURL: "http://127.0.0.1:1234/v1",
            apiKeyURL: "https://lmstudio.ai",
            recommendedModels: [
                ProviderModel(name: "Index-Homura-9B-Q4_K_M", capabilities: [.translate]),
                ProviderModel(name: "Index-Homura-2B-Q8_0", capabilities: [.translate]),
                ProviderModel(name: "local-model", capabilities: [.translate, .segment, .terminology]),
            ]
        ),
        ProviderPreset(
            id: "edge-tts",
            name: "Edge TTS (免费神经语音)",
            subtitle: "纯 Swift 直连微软 Edge 语音合成，零费用、零外部依赖",
            badgeText: "Edge",
            badgeColor: Color(red: 0.08, green: 0.58, blue: 0.84),
            category: .protocolAndLocal,
            kind: .edge,
            defaultBaseURL: "",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "zh-CN-YunxiNeural", capabilities: [.tts]),
                ProviderModel(name: "zh-CN-XiaoxiaoNeural", capabilities: [.tts]),
                ProviderModel(name: "zh-CN-YunyeNeural", capabilities: [.tts]),
                ProviderModel(name: "zh-CN-XiaoyiNeural", capabilities: [.tts]),
            ]
        ),
        ProviderPreset(
            id: "whisper-local",
            name: "本地语音识别 (Whisper DTW / Parakeet / Qwen3-ASR)",
            subtitle: "Apple Silicon 本地离线识别：支持 Whisper Turbo (DTW)、Sherpa Parakeet TDT 0.6B 与 MLX Qwen3-ASR",
            badgeText: "ASR",
            badgeColor: Color(red: 0.20, green: 0.64, blue: 0.38),
            category: .protocolAndLocal,
            kind: .whisperLocal,
            defaultBaseURL: "",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "ggml-large-v3-turbo-q5_0.bin", capabilities: [.transcribe]),
                ProviderModel(name: "ggml-large-v3-turbo.bin", capabilities: [.transcribe]),
                ProviderModel(name: "ggml-base.en", capabilities: [.transcribe]),
                ProviderModel(name: "ggml-medium.en-q5_0.bin", capabilities: [.transcribe]),
                ProviderModel(name: "sherpa-asr:parakeet", capabilities: [.transcribe]),
                ProviderModel(name: "sherpa-asr:sensevoice", capabilities: [.transcribe]),
                ProviderModel(name: "mlx-asr:mlx-community/Qwen3-ASR-1.7B-4bit", capabilities: [.transcribe]),
            ]
        ),
        ProviderPreset(
            id: "local-tts",
            name: "本地播客 TTS (Kokoro / ZipVoice / Qwen3-TTS / say)",
            subtitle: "Apple Silicon 离线语音合成：支持 Kokoro 中英混读播客、ZipVoice/Qwen3-TTS 零样本音色克隆及系统 say",
            badgeText: "TTS",
            badgeColor: Color(red: 0.52, green: 0.44, blue: 0.34),
            category: .protocolAndLocal,
            kind: .localTTS,
            defaultBaseURL: "",
            apiKeyURL: "",
            recommendedModels: [
                ProviderModel(name: "sherpa-onnx:kokoro-multi-lang-v1_1", capabilities: [.tts]),
                ProviderModel(name: "sherpa-onnx:zipvoice", capabilities: [.tts]),
                ProviderModel(name: "mlx-tts:mlx-community/Qwen3-TTS-12Hz-0.6B-Base-8bit", capabilities: [.tts]),
                ProviderModel(name: "mlx-tts:mlx-community/Qwen3-TTS-12Hz-1.7B-CustomVoice-bf16", capabilities: [.tts]),
                ProviderModel(name: "mlx-tts:OpenMOSS-Team/MOSS-TTSD-v1.0", capabilities: [.tts]),
                ProviderModel(name: "say:Tingting", capabilities: [.tts]),
            ]
        ),
    ]

    static func find(_ id: String?) -> ProviderPreset? {
        guard let id, !id.isEmpty else { return nil }
        return all.first { $0.id == id }
    }
}

// MARK: - 提供商与模型配置实体

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
    var presetID: String?
    var enabled: Bool

    init(id: String = UUID().uuidString, name: String = "", kind: ProviderKind = .gateway,
         baseURL: String = "", apiKey: String = "", models: [ProviderModel] = [],
         presetID: String? = nil, enabled: Bool = true) {
        self.id = id; self.name = name; self.kind = kind
        self.baseURL = baseURL; self.apiKey = apiKey; self.models = models
        self.presetID = presetID; self.enabled = enabled
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, kind, baseURL, apiKey, models, presetID, enabled
    }

    /// 兼容旧版 providersJSON（无 presetID / enabled 键时自动补齐默认值）
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? ""
        kind = try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .openai
        baseURL = try c.decodeIfPresent(String.self, forKey: .baseURL) ?? ""
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? ""
        models = try c.decodeIfPresent([ProviderModel].self, forKey: .models) ?? []
        presetID = try c.decodeIfPresent(String.self, forKey: .presetID)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
    }

    var preset: ProviderPreset? {
        if let hit = ProviderPreset.find(presetID) { return hit }
        // 按名称或 URL 启发式匹配旧配置对应的预设
        let lowerName = name.lowercased()
        let lowerURL = baseURL.lowercased()
        if lowerURL.contains("openrouter.ai") || lowerName.contains("openrouter") { return ProviderPreset.find("openrouter") }
        if lowerURL.contains("opencode.ai") || lowerName.contains("opencode") { return ProviderPreset.find("opencode") }
        if lowerURL.contains("siliconflow") || lowerName.contains("硅基") { return ProviderPreset.find("siliconflow") }
        if lowerURL.contains("dashscope.aliyuncs.com") { return ProviderPreset.find("alibaba-bailian") }
        if lowerURL.contains("volces.com") || lowerName.contains("火山") || lowerName.contains("豆包") || lowerName.contains("字节") {
            return ProviderPreset.find("bytedance-ark")
        }
        if lowerURL.contains("deepseek.com") || lowerName.contains("deepseek") { return ProviderPreset.find("deepseek") }
        if lowerURL.contains("bigmodel.cn") || lowerName.contains("智谱") { return ProviderPreset.find("zhipu") }
        if lowerURL.contains("moonshot.cn") || lowerName.contains("kimi") || lowerName.contains("月之暗面") { return ProviderPreset.find("moonshot") }
        if lowerURL.contains("minimax") || lowerName.contains("minimax") || lowerName.contains("海螺") { return ProviderPreset.find("minimax") }
        if lowerURL.contains("hunyuan") || lowerName.contains("混元") { return ProviderPreset.find("hunyuan") }
        if lowerURL.contains("baidubce.com") || lowerName.contains("千帆") { return ProviderPreset.find("qianfan") }
        if lowerURL.contains("stepfun.com") || lowerName.contains("阶跃") { return ProviderPreset.find("stepfun") }
        if lowerURL.contains("anthropic.com") || kind == .anthropic { return ProviderPreset.find("anthropic") }
        if lowerURL.contains("googleapis.com") || kind == .gemini { return ProviderPreset.find("gemini") }
        if kind == .bailian { return ProviderPreset.find("alibaba-bailian-tts") }
        if kind == .edge { return ProviderPreset.find("edge-tts") }
        if kind == .whisperLocal { return ProviderPreset.find("whisper-local") }
        if kind == .localTTS { return ProviderPreset.find("local-tts") }
        if kind == .gateway { return ProviderPreset.find("custom-responses") }
        return nil
    }

    var badgeText: String {
        if let p = preset { return p.badgeText }
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "AI" }
        return String(trimmed.prefix(2)).uppercased()
    }

    var badgeColor: Color {
        if let p = preset { return p.badgeColor }
        switch kind {
        case .openai: return Color(red: 0.16, green: 0.58, blue: 0.48)
        case .gateway: return Color(red: 0.36, green: 0.48, blue: 0.86)
        case .anthropic: return Color(red: 0.80, green: 0.44, blue: 0.28)
        case .gemini: return Color(red: 0.22, green: 0.50, blue: 0.92)
        case .bailian: return Color(red: 0.92, green: 0.35, blue: 0.14)
        case .edge: return Color(red: 0.08, green: 0.58, blue: 0.84)
        case .whisperLocal: return Color(red: 0.20, green: 0.64, blue: 0.38)
        case .localTTS: return Color(red: 0.52, green: 0.44, blue: 0.34)
        }
    }
}

// MARK: - 提供商存储（UI 侧 ObservableObject；管线侧用静态快照）

@MainActor
final class ProviderStore: ObservableObject {
    nonisolated static let key = "providersJSON"

    @Published var providers: [ProviderConfig]

    init() { providers = Self.load() }

    func save() { Self.persist(providers) }

    @discardableResult
    func add(_ kind: ProviderKind) -> String {
        let used = Set(providers.map { $0.name })
        var n = 1
        var name = kind.label
        while used.contains(name) { n += 1; name = "\(kind.label) \(n)" }
        let item = ProviderConfig(
            name: name,
            kind: kind,
            baseURL: kind.defaultBaseURL,
            models: [ProviderModel(name: "", capabilities: kind.defaultCapabilities)]
        )
        providers.append(item)
        save()
        return item.id
    }

    @discardableResult
    func addPreset(_ preset: ProviderPreset) -> String {
        let used = Set(providers.map { $0.name })
        let item = preset.makeConfig(existingNames: used)
        providers.append(item)
        save()
        return item.id
    }

    func remove(at offsets: IndexSet) {
        providers.remove(atOffsets: offsets)
        save()
    }

    func addModel(providerID: String, name: String = "", capabilities: [ModelCapability]? = nil) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }) else { return }
        let caps = capabilities ?? (name.isEmpty
            ? providers[i].kind.defaultCapabilities
            : providers[i].kind.inferCapabilities(for: name))
        providers[i].models.append(ProviderModel(name: name, capabilities: caps))
        save()
    }

    /// 一键补齐当前提供商对应预设中的推荐模型（不覆盖已有同名模型）
    func addRecommendedModels(providerID: String) {
        guard let i = providers.firstIndex(where: { $0.id == providerID }),
              let preset = providers[i].preset else { return }
        let existing = Set(providers[i].models.map { $0.name.trimmingCharacters(in: .whitespaces) })
        // 如果当前只有一个空模型行，先移除空占位行
        if providers[i].models.count == 1,
           providers[i].models[0].name.trimmingCharacters(in: .whitespaces).isEmpty {
            providers[i].models.removeAll()
        }
        for rec in preset.recommendedModels where !existing.contains(rec.name) {
            providers[i].models.append(ProviderModel(name: rec.name, capabilities: rec.capabilities))
        }
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
