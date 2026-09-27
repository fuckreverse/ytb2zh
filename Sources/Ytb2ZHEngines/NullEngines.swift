import Foundation
import Ytb2ZHCore

// MARK: - 空实现（仅字幕模式：synth / schedule 选 none）

public struct NullSynthEngine: SpeechSynthesisEngine {
    public let descriptor = EngineDescriptor("none", "不合成", "纯字幕模式")
    public var supportsRateControl: Bool { false }
    public init() {}
    public func synthesize(text: String, cacheKey: String, cacheDir: URL,
                           options: SynthOptions) async throws -> (url: URL, duration: Double) {
        throw EngineError.engineFailure("当前 Profile 不合成语音")
    }
}

public struct NullSchedulerEngine: SchedulerEngine {
    public let descriptor = EngineDescriptor("none", "不调度", "纯字幕模式")
    public init() {}
    public func schedule(units: [SpeechUnit], clauseDurations: [[Double]], options: ScheduleOptions) -> SchedulePlan {
        .empty
    }
}
