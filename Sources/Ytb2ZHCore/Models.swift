import Foundation

// MARK: - 术语表（翻译前提取/人工维护，注入翻译 prompt）
public struct TerminologyTerm: Codable, Hashable, Sendable {
    public var en: String
    public var zh: String
    public var note: String

    public init(en: String, zh: String, note: String = "") {
        self.en = en; self.zh = zh; self.note = note
    }
}

// MARK: - 语音单元模型（贯穿全流水线）

/// 词级时间戳（ASR 输出）
public struct TimedWord: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var text: String

    public init(start: Double, end: Double, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}

/// 语义完整单元：英文原文，中文译文，原始时间窗
public struct SpeechUnit: Codable, Hashable, Sendable {
    public var start: Double
    public var end: Double
    public var en: String
    public var zh: String
    /// 多角色配音：本单元使用的音色（nil = 用 SynthOptions.voice）
    public var voice: String?

    public init(start: Double, end: Double, en: String, zh: String = "", voice: String? = nil) {
        self.start = start
        self.end = end
        self.en = en
        self.zh = zh
        self.voice = voice
    }
}

/// 单元内子句（停顿可调的最小合成单位）
public struct Clause: Codable, Hashable, Sendable {
    public var text: String
    public init(text: String) { self.text = text }
}

/// 调度结果：一条子句在配音轨上的落位
public struct Placement: Codable, Hashable, Sendable {
    public var unitIndex: Int
    public var clauseIndex: Int
    public var text: String
    public var at: Double        // 新时间轴起点
    public var duration: Double  // 变速后时长
    public var atempo: Double    // 1.0 = 原速

    public init(unitIndex: Int, clauseIndex: Int, text: String,
                at: Double, duration: Double, atempo: Double) {
        self.unitIndex = unitIndex; self.clauseIndex = clauseIndex; self.text = text
        self.at = at; self.duration = duration; self.atempo = atempo
    }
}

/// 单元级调度布局（用于 SRT 与统计）
public struct UnitSchedule: Codable, Hashable, Sendable {
    public var unitIndex: Int
    public var originalStart: Double
    public var originalEnd: Double
    public var newStart: Double
    public var newEnd: Double
    public var lead: Double  // 原起点 - 新起点（配音提前量）

    public init(unitIndex: Int, originalStart: Double, originalEnd: Double,
                newStart: Double, newEnd: Double, lead: Double) {
        self.unitIndex = unitIndex; self.originalStart = originalStart; self.originalEnd = originalEnd
        self.newStart = newStart; self.newEnd = newEnd; self.lead = lead
    }
}

// MARK: - 管线产物与事件

public struct VideoMeta: Codable, Hashable, Sendable {
    public var title: String
    public var duration: Double
    public var id: String
}

public enum PipelineEvent: Sendable {
    case stepStarted(StepID)
    case stepFinished(StepID, [String: String])
    case progress(StepID, Double, String?)
    case log(String)
    case failed(StepID, String)
}

public enum StepID: String, Codable, Sendable, CaseIterable {
    case download, separate, transcribe, segment, summarize, translate
    case synthesize, schedule, compose

    public var label: String {
        switch self {
        case .download: "下载"
        case .separate: "人声分离"
        case .transcribe: "转录"
        case .segment: "语义切分"
        case .summarize: "术语提取"
        case .translate: "翻译"
        case .synthesize: "语音合成"
        case .schedule: "对齐调度"
        case .compose: "视频合成"
        }
    }
}

/// 管线执行上下文：引擎只与自己签名的数据打交道，通过 JobStore 落盘解耦
public struct PipelineContext: Sendable {
    public let jobDir: URL
    public let profile: Profile

    public init(jobDir: URL, profile: Profile) {
        self.jobDir = jobDir
        self.profile = profile
    }
}
