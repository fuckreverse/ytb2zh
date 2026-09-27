import Foundation
import Ytb2ZHCore

// MARK: - 漂移调度引擎（reschedule_v2.py 移植，纯算法无 IO）
// 核心：ns = max(prev_end + unitGap, os - driftCap)，再钳到 os + lagCap；
// 单元内时间预算：富余 → 先扩子句停顿 → 再慢放；不足 → 加速。

public struct DriftSchedulerEngine: SchedulerEngine {
    public let descriptor = EngineDescriptor(
        "drift", "漂移上限调度", "硬上限提前/落后 + 停顿优先 + 语速兜底")

    public init() {}

    public func schedule(units: [SpeechUnit], clauseDurations: [[Double]],
                         options: ScheduleOptions) -> SchedulePlan {
        var placements: [Placement] = []
        var unitSchedules: [UnitSchedule] = []
        var prevEnd = 0.0

        for (i, unit) in units.enumerated() {
            let durs = i < clauseDurations.count ? clauseDurations[i] : []
            if durs.isEmpty { continue }

            let os = unit.start
            let oe = unit.end
            // 与验证过的 reschedule_v2 相同：max(上一尾+gap, os-CAP) 銳到 os+lagCap；
            // 但保证不与上一单元重叠（极端溢出时优先不重叠）
            let earliest = max(prevEnd + options.unitGap, os - options.driftCap)
            let latest = max(os + options.lagCap, prevEnd + options.unitGap)
            let ns = min(earliest, latest)

            // 可用时长：到下一单元可出现的最早位置为止
            let avail: Double
            if i + 1 < units.count {
                let nxtHint = max(ns + 0.5, units[i + 1].start - options.driftCap)
                avail = max(nxtHint - ns, 1.0)
            } else {
                avail = max(oe + options.driftCap - ns, 1.0)
            }

            let n = durs.count
            let raw = durs.reduce(0, +)
            var pauses = [Double](repeating: options.pauseMin, count: max(0, n - 1))
            var slack = avail - (raw + pauses.reduce(0, +))
            var stretch: Double = 1.0   // f：>1 慢放，<1 加速（作用在音频时长上）

            if slack > 0 {
                if n > 1 {
                    let extra = min(slack / Double(n - 1), options.pauseMax - options.pauseMin)
                    pauses = [Double](repeating: options.pauseMin + extra, count: n - 1)
                    slack -= extra * Double(n - 1)
                }
                if slack > 0 && raw > 0 {
                    stretch = min(options.slowMax, 1 + slack / raw)
                }
            } else if slack < 0 {
                let need = (raw + pauses.reduce(0, +)) / max(avail - 0.05, 0.1)
                let capped = min(need, options.fastMax)
                stretch = 1.0 / capped
                if n > 1 {
                    pauses = pauses.map { max(0.12, $0 / capped) }
                }
            }
            if abs(stretch - 1.0) <= 0.01 { stretch = 1.0 }

            // 逐子句落位
            var t = ns
            let clauseTexts = splitClauses(unit.zh)
            for k in 0..<n {
                let dur = durs[k] * stretch
                let atempo = 1.0 / stretch
                placements.append(Placement(
                    unitIndex: i, clauseIndex: k,
                    text: k < clauseTexts.count ? clauseTexts[k] : "",
                    at: (t * 1000).rounded() / 1000,
                    duration: dur, atempo: atempo))
                t += dur + (k < n - 1 ? pauses[k] : 0)
            }
            unitSchedules.append(UnitSchedule(
                unitIndex: i, originalStart: os, originalEnd: oe,
                newStart: ns, newEnd: t, lead: os - ns))
            prevEnd = t
        }

        let leads = unitSchedules.map(\.lead)
        var wait = 0.0
        for (a, b) in zip(unitSchedules, unitSchedules.dropFirst()) {
            wait += max(0, b.newStart - a.newEnd)
        }
        return SchedulePlan(
            placements: placements, unitSchedules: unitSchedules,
            maxLead: leads.max() ?? 0,
            meanLead: leads.isEmpty ? 0 : leads.reduce(0, +) / Double(leads.count),
            interUnitWait: wait,
            totalDuration: unitSchedules.last?.newEnd ?? 0)
    }

    private func splitClauses(_ text: String) -> [String] {
        ClauseTextSplitter().split(text)
    }
}
