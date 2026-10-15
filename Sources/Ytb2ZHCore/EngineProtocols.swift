import Foundation

// MARK: - 插件协议（九步）
// 每一步都是一个协议 + 一个支持能力查询的描述器。
// 换引擎 = 换实现，Pipeline 与其他步骤完全不感知。

/// 1. 下载：URL → 本地视频文件
public protocol DownloadEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func download(url: String, to dest: URL, options: DownloadOptions,
                  progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL
}

/// 2. 人声分离（可选）：视频 → 人声轨 + 伴奏轨，供转录提质与 BGM 混入
public protocol VocalSeparationEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    /// 返回 (人声, 伴奏) 两个音频文件；失败由调用方降级为不分离
    func separate(video: URL, workDir: URL, options: SeparationOptions,
                  progress: @Sendable @escaping (Double, String?) -> Void) async throws -> (vocals: URL, instrumental: URL)
}

/// 3. 转录：音频 → 词级时间戳
public protocol TranscribeEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    /// 从视频/音频提取 16k wav 并转录，返回词级结果
    func transcribe(video: URL, workDir: URL, options: TranscribeOptions,
                    progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TimedWord]
}

/// 3. 语义切分：词流 → 语义单元（纯算法）
public protocol SegmentationEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func segment(words: [TimedWord], options: SegmentationOptions) -> [SpeechUnit]
}

/// 4. 术语提取（可选）：从英文单元抽取领域语境 + 术语表，供翻译注入
public protocol TerminologyEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func extractTerms(units: [SpeechUnit], options: TerminologyOptions,
                      progress: @Sendable @escaping (Double, String?) -> Void) async throws -> TerminologyExtraction
}

/// 5. 翻译：英文单元 → 中文单元
public protocol TranslateEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func translate(units: [SpeechUnit], options: TranslateOptions,
                   progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [SpeechUnit]
}

/// 6. 语音合成：文本 → 合成音频文件的时长（负责缓存与落盘）
public protocol SpeechSynthesisEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    /// 合成一条子句到 cacheDir，返回 (文件URL, 实际时长)
    func synthesize(text: String, cacheKey: String, cacheDir: URL,
                    options: SynthOptions) async throws -> (url: URL, duration: Double)
    /// 可选：能否按 options.rate 原生变速合成。
    /// true = 合成产物已含目标语速（调度层不再叠加变速；原生语速音质优于 atempo 后处理）；
    /// false = 忽略 rate，由调度层把语速折算进 atempo 兜底。
    var supportsRateControl: Bool { get }
}

/// 7. 对齐调度：合成时长 + 原时间窗 → 新时间轴布局（纯算法）
public protocol SchedulerEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    /// clauses: 每单元子句含已探测的合成时长
    func schedule(units: [SpeechUnit], clauseDurations: [[Double]], options: ScheduleOptions) -> SchedulePlan
}

/// 8. 视频合成：装配配音轨 + 烧字幕 + 输出成片
public protocol CompositionEngine: Sendable {
    var descriptor: EngineDescriptor { get }
    func compose(video: URL, placements: [Placement], unitSchedules: [UnitSchedule],
                 units: [SpeechUnit], cacheDir: URL, output: URL, options: ComposeOptions,
                 progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL
}

// MARK: - 引擎注册描述

public struct EngineDescriptor: Sendable, Hashable {
    public let id: String
    public let name: String
    public let detail: String
    public init(_ id: String, _ name: String, _ detail: String = "") {
        self.id = id; self.name = name; self.detail = detail
    }
}

/// 一步的所有可选引擎（协议不知道彼此存在，GUI 用它渲染选择器）
public struct EngineChoice: Sendable, Hashable {
    public let descriptors: [EngineDescriptor]
    public init(_ descriptors: [EngineDescriptor]) { self.descriptors = descriptors }
}

// MARK: - 调度产物

public struct SchedulePlan: Codable, Hashable, Sendable {
    public var placements: [Placement]
    public var unitSchedules: [UnitSchedule]
    /// 供人看的统计
    public var maxLead: Double
    public var meanLead: Double
    public var interUnitWait: Double
    public var totalDuration: Double

    public init(placements: [Placement], unitSchedules: [UnitSchedule],
                maxLead: Double, meanLead: Double, interUnitWait: Double, totalDuration: Double) {
        self.placements = placements; self.unitSchedules = unitSchedules
        self.maxLead = maxLead; self.meanLead = meanLead
        self.interUnitWait = interUnitWait; self.totalDuration = totalDuration
    }

    public static let empty = SchedulePlan(placements: [], unitSchedules: [],
                                           maxLead: 0, meanLead: 0, interUnitWait: 0, totalDuration: 0)
}
