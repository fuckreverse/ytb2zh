import Foundation

// MARK: - 各步参数（全部 Codable，构成 Profile 的一部分；GUI 控件直接绑定）
// 注意：带自定义 init(from:) 的结构用 decodeIfPresent 保证旧模板 JSON 缺新字段时仍可加载。

public struct DownloadOptions: Codable, Hashable, Sendable {
    public var format: String     // yt-dlp -f 表达式
    public var proxy: String      // 空 = 不走代理
    public var keepSource: Bool
    /// 运行时注入（试转模式）：只下载/截取前 N 秒，不写入模板 JSON
    public var partialSeconds: Int?

    /// 原生直播与下载控制。
    public var liveFromStart: Bool = false
    public var startSeconds: Double = 0
    public var durationSeconds: Double? = nil
    public var rateLimitBytesPerSecond: Int? = nil

    /// 优先 avc1/m4a（AVPlayer 原生可播，原声即播模式必需）；找不到再回退任意格式
    public init(format: String = "bv*[vcodec^=avc1][height<=720]+ba[ext=m4a]/b[ext=mp4][height<=720]/bv*[height<=720]+ba/b[height<=720]",
                proxy: String = "http://127.0.0.1:7890", keepSource: Bool = true) {
        self.format = format; self.proxy = proxy; self.keepSource = keepSource
        self.partialSeconds = nil
    }

    private enum CodingKeys: String, CodingKey { case format, proxy, keepSource }
    /// partialSeconds 是运行时字段，永不落盘
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(format, forKey: .format)
        try c.encode(proxy, forKey: .proxy)
        try c.encode(keepSource, forKey: .keepSource)
    }
}

public struct TranscribeOptions: Codable, Hashable, Sendable {
    public var modelPath: String
    public var language: String
    /// SRT 导入模式：外部字幕文件路径（engines.transcribe == "srt" 时生效）
    public var srtPath: String

    public init(modelPath: String = "\(NSHomeDirectory())/vid2zh/models/ggml-medium.en-q5_0.bin",
                language: String = "en", srtPath: String = "") {
        self.modelPath = modelPath; self.language = language; self.srtPath = srtPath
    }

    private enum CodingKeys: String, CodingKey { case modelPath, language, srtPath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        modelPath = try c.decodeIfPresent(String.self, forKey: .modelPath) ?? TranscribeOptions().modelPath
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? "en"
        srtPath = try c.decodeIfPresent(String.self, forKey: .srtPath) ?? ""
    }
}

public struct SegmentationOptions: Codable, Hashable, Sendable {
    public var softWindow: Double   // 逗号处凑满多少秒可收
    public var hardWindow: Double   // 强制收句上限
    // LLM 断句（engines.segment == "llm-seg" 时生效）：在 punct 基础上重组
    public var endpoint: String
    public var model: String
    public init(softWindow: Double = 7.0, hardWindow: Double = 13.0,
                endpoint: String = "http://127.0.0.1:15000/v1/responses",
                model: String = "friday-personal/deepseek-v4-flash") {
        self.softWindow = softWindow; self.hardWindow = hardWindow
        self.endpoint = endpoint; self.model = model
    }

    private enum CodingKeys: String, CodingKey { case softWindow, hardWindow, endpoint, model }
    public init(from decoder: Decoder) throws {
        let d = SegmentationOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        softWindow = try c.decodeIfPresent(Double.self, forKey: .softWindow) ?? d.softWindow
        hardWindow = try c.decodeIfPresent(Double.self, forKey: .hardWindow) ?? d.hardWindow
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? d.endpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
    }
}

// MARK: 人声分离（可选步）

public struct SeparationOptions: Codable, Hashable, Sendable {
    public var model: String        // Demucs 模型名
    public init(model: String = "htdemucs") { self.model = model }
}

// MARK: 术语提取（可选步）

public struct TerminologyOptions: Codable, Hashable, Sendable {
    public var endpoint: String     // 走网关 Responses API（与翻译同源）
    public var model: String
    public var maxTerms: Int        // 术语表上限（防 prompt 膨胀）
    public init(endpoint: String = "http://127.0.0.1:15000/v1/responses",
                model: String = "friday-personal/deepseek-v4-flash", maxTerms: Int = 30) {
        self.endpoint = endpoint; self.model = model; self.maxTerms = maxTerms
    }
}

// MARK: 翻译

public enum TranslationQuality: String, Codable, Hashable, Sendable, CaseIterable {
    case singlePass   // 直出（快）
    case threePass    // 直译 → 反思 → 意译（VideoLingo 三步法）

    public var label: String {
        switch self {
        case .singlePass: "单次直出"
        case .threePass: "三步精修"
        }
    }
}

public struct TranslateOptions: Codable, Hashable, Sendable {
    public var endpoint: String
    public var model: String
    public var batchSize: Int
    public var concurrency: Int
    /// 翻译风格（决定 prompt 模板）
    public var style: TranslationStyle
    /// 自动扩译：填不满时间窗的单元定向扩写
    public var autoExpand: Bool
    /// 翻译时注入术语表（需 summarize 步骤产物 terminology.json）
    public var useTerminology: Bool
    /// 翻译质量模式
    public var quality: TranslationQuality
    /// 目标语言（ISO 639-1；zh 之外也可用于产出外挂字幕）
    public var targetLanguage: String
    /// OpenAI 兼容翻译引擎参数（engines.translate == "compat" 时生效）
    public var compatBaseURL: String
    public var compatAPIKey: String
    public var compatModel: String
    /// 运行时由 Pipeline 从 terminology.json 注入，不写入模板 JSON
    public var terminology: [TerminologyTerm]?
    /// 运行时由 Pipeline 从 terminology.json 注入的领域语境，不写入模板 JSON
    public var domain: DomainContext?

    public init(endpoint: String = "http://127.0.0.1:15000/v1/responses",
                model: String = "friday-personal/deepseek-v4-flash",
                batchSize: Int = 20, concurrency: Int = 4,
                style: TranslationStyle = .narrator, autoExpand: Bool = true,
                useTerminology: Bool = true, quality: TranslationQuality = .singlePass,
                targetLanguage: String = "zh",
                compatBaseURL: String = "https://api.openai.com/v1",
                compatAPIKey: String = "", compatModel: String = "gpt-4o-mini",
                terminology: [TerminologyTerm]? = nil, domain: DomainContext? = nil) {
        self.endpoint = endpoint; self.model = model; self.batchSize = batchSize
        self.concurrency = concurrency; self.style = style; self.autoExpand = autoExpand
        self.useTerminology = useTerminology; self.quality = quality
        self.targetLanguage = targetLanguage
        self.compatBaseURL = compatBaseURL; self.compatAPIKey = compatAPIKey; self.compatModel = compatModel
        self.terminology = terminology
        self.domain = domain
    }

    private enum CodingKeys: String, CodingKey {
        case endpoint, model, batchSize, concurrency, style, autoExpand
        case useTerminology, quality, targetLanguage
        case compatBaseURL, compatAPIKey, compatModel
    }

    public init(from decoder: Decoder) throws {
        let d = TranslateOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        endpoint = try c.decodeIfPresent(String.self, forKey: .endpoint) ?? d.endpoint
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        batchSize = try c.decodeIfPresent(Int.self, forKey: .batchSize) ?? d.batchSize
        concurrency = try c.decodeIfPresent(Int.self, forKey: .concurrency) ?? d.concurrency
        style = try c.decodeIfPresent(TranslationStyle.self, forKey: .style) ?? d.style
        autoExpand = try c.decodeIfPresent(Bool.self, forKey: .autoExpand) ?? d.autoExpand
        useTerminology = try c.decodeIfPresent(Bool.self, forKey: .useTerminology) ?? d.useTerminology
        quality = try c.decodeIfPresent(TranslationQuality.self, forKey: .quality) ?? d.quality
        targetLanguage = try c.decodeIfPresent(String.self, forKey: .targetLanguage) ?? d.targetLanguage
        compatBaseURL = try c.decodeIfPresent(String.self, forKey: .compatBaseURL) ?? d.compatBaseURL
        compatAPIKey = try c.decodeIfPresent(String.self, forKey: .compatAPIKey) ?? d.compatAPIKey
        compatModel = try c.decodeIfPresent(String.self, forKey: .compatModel) ?? d.compatModel
        terminology = nil
        domain = nil
    }

    /// terminology 是运行时字段，永不落盘
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(endpoint, forKey: .endpoint)
        try c.encode(model, forKey: .model)
        try c.encode(batchSize, forKey: .batchSize)
        try c.encode(concurrency, forKey: .concurrency)
        try c.encode(style, forKey: .style)
        try c.encode(autoExpand, forKey: .autoExpand)
        try c.encode(useTerminology, forKey: .useTerminology)
        try c.encode(quality, forKey: .quality)
        try c.encode(targetLanguage, forKey: .targetLanguage)
        try c.encode(compatBaseURL, forKey: .compatBaseURL)
        try c.encode(compatAPIKey, forKey: .compatAPIKey)
        try c.encode(compatModel, forKey: .compatModel)
    }
}

public enum TranslationStyle: String, Codable, Hashable, Sendable, CaseIterable {
    case narrator      // 科技 UP 主口语解说（默认）
    case faithful      // 忠实书面
    case concise       // 极简字幕体

    public var label: String {
        switch self {
        case .narrator: "口语解说"
        case .faithful: "忠实书面"
        case .concise: "极简字幕"
        }
    }
}

public struct SynthOptions: Codable, Hashable, Sendable {
    public var apiKey: String
    public var wsURL: String
    public var model: String
    public var voice: String
    public var rps: Int   // 并发上限（百炼限流 3）
    // OpenAI 兼容 TTS（engines.synthesize == "openai-tts" 时生效）
    public var compatBaseURL: String
    public var compatAPIKey: String
    public var compatTTSModel: String
    // Edge TTS（engines.synthesize == "edge-tts" 时生效）
    public var edgeVoice: String
    /// Edge TTS 请求代理（空 = 直连；edge-tts 不读环境变量，由引擎透传）
    public var edgeProxy: String
    // 本地 TTS（engines.synthesize == "local-say" / "sherpa-onnx" 时生效）
    /// macOS say 音色（如 Tingting、Mei-Jia）；空 = 默认 Tingting
    public var localVoice: String
    /// Sherpa-Onnx 模型目录（含 model.onnx、tokens.txt、dict/ 等）；空 = 未配置
    public var sherpaOnnxModelDir: String

    public init(apiKey: String = "",
                wsURL: String = "wss://llm-tj31icsrw8blnhj0.cn-beijing.maas.aliyuncs.com/api-ws/v1/inference",
                model: String = "qwen-audio-3.1-tts-flash",
                voice: String = "anmingyuan_v3.1", rps: Int = 3,
                compatBaseURL: String = "https://api.openai.com/v1",
                compatAPIKey: String = "", compatTTSModel: String = "gpt-4o-mini-tts",
                edgeVoice: String = "zh-CN-YunxiNeural",
                edgeProxy: String = "http://127.0.0.1:7890",
                localVoice: String = "Tingting",
                sherpaOnnxModelDir: String = "") {
        self.apiKey = apiKey; self.wsURL = wsURL; self.model = model
        self.voice = voice; self.rps = rps
        self.compatBaseURL = compatBaseURL; self.compatAPIKey = compatAPIKey
        self.compatTTSModel = compatTTSModel; self.edgeVoice = edgeVoice
        self.edgeProxy = edgeProxy
        self.localVoice = localVoice; self.sherpaOnnxModelDir = sherpaOnnxModelDir
    }

    private enum CodingKeys: String, CodingKey {
        case apiKey, wsURL, model, voice, rps
        case compatBaseURL, compatAPIKey, compatTTSModel, edgeVoice, edgeProxy
        case localVoice, sherpaOnnxModelDir
    }

    public init(from decoder: Decoder) throws {
        let d = SynthOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        apiKey = try c.decodeIfPresent(String.self, forKey: .apiKey) ?? d.apiKey
        wsURL = try c.decodeIfPresent(String.self, forKey: .wsURL) ?? d.wsURL
        model = try c.decodeIfPresent(String.self, forKey: .model) ?? d.model
        voice = try c.decodeIfPresent(String.self, forKey: .voice) ?? d.voice
        rps = try c.decodeIfPresent(Int.self, forKey: .rps) ?? d.rps
        compatBaseURL = try c.decodeIfPresent(String.self, forKey: .compatBaseURL) ?? d.compatBaseURL
        compatAPIKey = try c.decodeIfPresent(String.self, forKey: .compatAPIKey) ?? d.compatAPIKey
        compatTTSModel = try c.decodeIfPresent(String.self, forKey: .compatTTSModel) ?? d.compatTTSModel
        edgeVoice = try c.decodeIfPresent(String.self, forKey: .edgeVoice) ?? d.edgeVoice
        edgeProxy = try c.decodeIfPresent(String.self, forKey: .edgeProxy) ?? d.edgeProxy
        localVoice = try c.decodeIfPresent(String.self, forKey: .localVoice) ?? d.localVoice
        sherpaOnnxModelDir = try c.decodeIfPresent(String.self, forKey: .sherpaOnnxModelDir) ?? d.sherpaOnnxModelDir
    }
}

public struct ScheduleOptions: Codable, Hashable, Sendable {
    public var driftCap: Double         // 配音最多领先画面
    public var lagCap: Double           // 配音最多落后画面
    public var unitGap: Double          // 单元间最小停顿
    public var pauseMin: Double         // 子句停顿下限
    public var pauseMax: Double         // 子句停顿上限（句内扩停顿）
    public var slowMax: Double          // 语音最多拉长（1.15 = 慢放 15%）
    public var fastMax: Double          // 溢出时最多加速
    public var slidePreviewRange: Int   // GUI 预览只处理前 N 秒（0 = 全片）
    public init(driftCap: Double = 1.2, lagCap: Double = 0.8, unitGap: Double = 0.25,
                pauseMin: Double = 0.25, pauseMax: Double = 1.3,
                slowMax: Double = 1.15, fastMax: Double = 1.3, slidePreviewRange: Int = 0) {
        self.driftCap = driftCap; self.lagCap = lagCap; self.unitGap = unitGap
        self.pauseMin = pauseMin; self.pauseMax = pauseMax
        self.slowMax = slowMax; self.fastMax = fastMax
        self.slidePreviewRange = slidePreviewRange
    }
}

public struct ComposeOptions: Codable, Hashable, Sendable {
    public var subtitleFontSize: Double
    public var subtitleMarginV: Double
    public var dubGainDB: Double
    public var keepOriginalAudio: Bool   // true = 原声侧链闪避混入（未做人声分离时用）
    public var originalDuckRatio: Double
    public var crf: Int
    public var preset: String
    // Netflix 单行字幕标准：单行上限 = min(base * targetMultiplier, maxLength)
    public var subtitleMaxLength: Int        // 单行最大字符数（中文字符计）
    public var subtitleTargetMultiplier: Double
    public var bilingualSubtitles: Bool      // 中英双语字幕
    // BGM 保留（require 人声分离产物 instrumental.wav）
    public var keepBGM: Bool
    public var bgmGainDB: Double
    public init(subtitleFontSize: Double = 16, subtitleMarginV: Double = 26,
                dubGainDB: Double = 4.5, keepOriginalAudio: Bool = false,
                originalDuckRatio: Double = 6, crf: Int = 20, preset: String = "veryfast",
                subtitleMaxLength: Int = 75, subtitleTargetMultiplier: Double = 1.2,
                bilingualSubtitles: Bool = false,
                keepBGM: Bool = false, bgmGainDB: Double = -3) {
        self.subtitleFontSize = subtitleFontSize; self.subtitleMarginV = subtitleMarginV
        self.dubGainDB = dubGainDB; self.keepOriginalAudio = keepOriginalAudio
        self.originalDuckRatio = originalDuckRatio; self.crf = crf; self.preset = preset
        self.subtitleMaxLength = subtitleMaxLength
        self.subtitleTargetMultiplier = subtitleTargetMultiplier
        self.bilingualSubtitles = bilingualSubtitles
        self.keepBGM = keepBGM; self.bgmGainDB = bgmGainDB
    }

    private enum CodingKeys: String, CodingKey {
        case subtitleFontSize, subtitleMarginV, dubGainDB, keepOriginalAudio, originalDuckRatio
        case crf, preset, subtitleMaxLength, subtitleTargetMultiplier, bilingualSubtitles
        case keepBGM, bgmGainDB
    }

    public init(from decoder: Decoder) throws {
        let d = ComposeOptions()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        subtitleFontSize = try c.decodeIfPresent(Double.self, forKey: .subtitleFontSize) ?? d.subtitleFontSize
        subtitleMarginV = try c.decodeIfPresent(Double.self, forKey: .subtitleMarginV) ?? d.subtitleMarginV
        dubGainDB = try c.decodeIfPresent(Double.self, forKey: .dubGainDB) ?? d.dubGainDB
        keepOriginalAudio = try c.decodeIfPresent(Bool.self, forKey: .keepOriginalAudio) ?? d.keepOriginalAudio
        originalDuckRatio = try c.decodeIfPresent(Double.self, forKey: .originalDuckRatio) ?? d.originalDuckRatio
        crf = try c.decodeIfPresent(Int.self, forKey: .crf) ?? d.crf
        preset = try c.decodeIfPresent(String.self, forKey: .preset) ?? d.preset
        subtitleMaxLength = try c.decodeIfPresent(Int.self, forKey: .subtitleMaxLength) ?? d.subtitleMaxLength
        subtitleTargetMultiplier = try c.decodeIfPresent(Double.self, forKey: .subtitleTargetMultiplier) ?? d.subtitleTargetMultiplier
        bilingualSubtitles = try c.decodeIfPresent(Bool.self, forKey: .bilingualSubtitles) ?? d.bilingualSubtitles
        keepBGM = try c.decodeIfPresent(Bool.self, forKey: .keepBGM) ?? d.keepBGM
        bgmGainDB = try c.decodeIfPresent(Double.self, forKey: .bgmGainDB) ?? d.bgmGainDB
    }
}

// MARK: - Profile：一整套选择 + 参数（即"模板"的实体）

public struct Profile: Codable, Hashable, Sendable {
    public var name: String
    /// 一句话描述（内置模板说明适用场景；用户另存时随参数一起保存）
    public var blurb: String
    /// 每步选用的引擎 id（在 EngineRegistry 中解析）
    public var engines: [String: String]   // StepID.rawValue -> engine id
    public var download: DownloadOptions
    public var separate: SeparationOptions
    public var transcribe: TranscribeOptions
    public var segmentation: SegmentationOptions
    public var terminology: TerminologyOptions
    public var translate: TranslateOptions
    public var synth: SynthOptions
    public var schedule: ScheduleOptions
    public var compose: ComposeOptions

    /// 默认引擎装配（九步；可选步默认关闭 = none）
    public static let defaultEngines: [String: String] = [
        StepID.download.rawValue: "auto",
        StepID.separate.rawValue: "none",
        StepID.transcribe.rawValue: "whisper-native",
        StepID.segment.rawValue: "punct",
        StepID.summarize.rawValue: "none",
        StepID.translate.rawValue: "gateway",
        StepID.synthesize.rawValue: "bailian",
        StepID.schedule.rawValue: "drift",
        StepID.compose.rawValue: "ffmpeg",
    ]

    public init(name: String = "自定义",
                blurb: String = "",
                engines: [String: String] = Profile.defaultEngines,
                download: DownloadOptions = .init(),
                separate: SeparationOptions = .init(),
                transcribe: TranscribeOptions = .init(),
                segmentation: SegmentationOptions = .init(),
                terminology: TerminologyOptions = .init(),
                translate: TranslateOptions = .init(),
                synth: SynthOptions = .init(),
                schedule: ScheduleOptions = .init(),
                compose: ComposeOptions = .init()) {
        self.name = name; self.blurb = blurb; self.engines = engines
        self.download = download; self.separate = separate
        self.transcribe = transcribe; self.segmentation = segmentation
        self.terminology = terminology; self.translate = translate
        self.synth = synth; self.schedule = schedule
        self.compose = compose
    }

    private enum CodingKeys: String, CodingKey {
        case name, blurb, engines
        case download, separate, transcribe, segmentation, terminology
        case translate, synth, schedule, compose
    }

    /// 旧版本模板 JSON（7 步、缺新参数）也能加载：缺省字段全部取默认值
    public init(from decoder: Decoder) throws {
        let d = Profile()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? d.name
        blurb = try c.decodeIfPresent(String.self, forKey: .blurb) ?? ""
        let storedEngines = try c.decodeIfPresent([String: String].self, forKey: .engines) ?? [:]
        engines = Profile.defaultEngines.merging(storedEngines) { _, new in new }
        download = try c.decodeIfPresent(DownloadOptions.self, forKey: .download) ?? d.download
        separate = try c.decodeIfPresent(SeparationOptions.self, forKey: .separate) ?? d.separate
        transcribe = try c.decodeIfPresent(TranscribeOptions.self, forKey: .transcribe) ?? d.transcribe
        segmentation = try c.decodeIfPresent(SegmentationOptions.self, forKey: .segmentation) ?? d.segmentation
        terminology = try c.decodeIfPresent(TerminologyOptions.self, forKey: .terminology) ?? d.terminology
        translate = try c.decodeIfPresent(TranslateOptions.self, forKey: .translate) ?? d.translate
        synth = try c.decodeIfPresent(SynthOptions.self, forKey: .synth) ?? d.synth
        schedule = try c.decodeIfPresent(ScheduleOptions.self, forKey: .schedule) ?? d.schedule
        compose = try c.decodeIfPresent(ComposeOptions.self, forKey: .compose) ?? d.compose
    }

    // MARK: 内置模板

    public static let balanced = Profile(name: "均衡（默认）", blurb: "通用场景首选：口语解说风格 + 百炼配音 + 自动对齐，不确定就用它")

    public static let tightSync: Profile = {
        var p = Profile(name: "精准对齐", blurb: "收紧音画同步（配音最多领先 0.8s、停顿更短），适合口播、教程、访谈类视频")
        p.schedule.driftCap = 0.8
        p.schedule.pauseMax = 0.9
        p.schedule.slowMax = 1.08
        return p
    }()

    public static let relaxed: Profile = {
        var p = Profile(name: "从容解说", blurb: "放宽同步窗口 + 解说文风，配音更从容自然，适合风景、纪录片等长视频")
        p.schedule.driftCap = 2.0
        p.schedule.pauseMax = 1.6
        p.schedule.slowMax = 1.18
        p.translate.style = .narrator
        return p
    }()

    public static let subtitlesOnly: Profile = {
        var p = Profile(name: "仅字幕（不配音）", blurb: "跳过配音与对齐，只要中文字幕，速度最快、成本最低")
        p.engines[StepID.synthesize.rawValue] = "none"
        p.engines[StepID.schedule.rawValue] = "none"
        p.compose.keepOriginalAudio = true
        return p
    }()

    /// 研究级：术语表 + 三步翻译（直译→反思→意译），术语一致性最佳
    public static let studied: Profile = {
        var p = Profile(name: "研究级（术语+三步翻译）", blurb: "先提取术语表，再直译→反思→意译三步翻译，专业术语一致性最好，耗时更长")
        p.engines[StepID.summarize.rawValue] = "gateway-terms"
        p.translate.useTerminology = true
        p.translate.quality = .threePass
        return p
    }()

    /// 保留 BGM：人声分离后只换人声，伴奏重新混入
    public static let keepBGM: Profile = {
        var p = Profile(name: "保留 BGM（人声分离）", blurb: "demucs 分离人声后只替换人声，背景音乐原样保留，适合音乐/综艺类视频")
        p.engines[StepID.separate.rawValue] = "demucs"
        p.compose.keepBGM = true
        return p
    }()

    public static let builtins: [Profile] = [.balanced, .tightSync, .relaxed, .subtitlesOnly, .studied, .keepBGM]

    /// 以某模板为起点派生
    public func derived(named newName: String) -> Profile {
        var p = self
        p.name = newName
        return p
    }

    /// 忽略 name/blurb 的内容比较：判断用户是否在模板基础上改过参数
    /// （用于切模板前的“未保存修改”确认，避免静默丢弃用户调整）
    public func isEqualIgnoringName(to other: Profile) -> Bool {
        var a = self; a.name = ""; a.blurb = ""
        var b = other; b.name = ""; b.blurb = ""
        return a == b
    }
}

// MARK: - 模板仓库（内置 + 用户模板，Application Support 持久化）

public struct TemplateStore {
    public enum Location: String, Codable, Sendable {
        case builtin
        case user
    }

    public struct Entry: Codable, Identifiable, Hashable {
        public var id: String { (location == .builtin ? "builtin:" : "user:") + profile.name }
        public var location: Location
        public var profile: Profile
    }

    public let userDir: URL

    public init(userDir: URL? = nil) {
        self.userDir = userDir
            ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Ytb2ZH/Templates", isDirectory: true)
    }

    public func all() -> [Entry] {
        var entries = Profile.builtins.map { Entry(location: .builtin, profile: $0) }
        entries.append(contentsOf: loadUserTemplates())
        return entries
    }

    public func loadUserTemplates() -> [Entry] {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: userDir, includingPropertiesForKeys: nil) else { return [] }
        return files.filter { $0.pathExtension == "json" }
            .compactMap { try? JSONDecoder().decode(Profile.self, from: (try? Data(contentsOf: $0)) ?? Data()) }
            .map { Entry(location: .user, profile: $0) }
            .sorted { $0.profile.name < $1.profile.name }
    }

    public func save(_ profile: Profile) throws {
        let fm = FileManager.default
        try fm.createDirectory(at: userDir, withIntermediateDirectories: true)
        let safe = profile.name.replacingOccurrences(of: "/", with: "_")
        let url = userDir.appendingPathComponent("\(safe).json")
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try enc.encode(profile).write(to: url)
    }

    public func delete(_ profile: Profile) throws {
        let safe = profile.name.replacingOccurrences(of: "/", with: "_")
        let url = userDir.appendingPathComponent("\(safe).json")
        try? FileManager.default.removeItem(at: url)
    }
}
