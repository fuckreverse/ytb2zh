import Foundation
import Ytb2ZHCore

// MARK: - LLM 断句引擎：先 punct 粗切，再让 LLM 按完整语义重组（合并相邻单元）
// 视频级两段式（NLP 粗切 + LLM 重组），借鉴 VideoLingo；LLM 失败时回退 punct 结果。

public struct LLMSegmentationEngine: SegmentationEngine {
    public let descriptor = EngineDescriptor(
        "llm-seg", "punct + LLM 重组", "标点粗切后由 LLM 合并成语义完整单元")

    public init() {}

    public func segment(words: [TimedWord], options: SegmentationOptions) -> [SpeechUnit] {
        let rough = PunctSegmentationEngine().segment(words: words, options: options)
        guard rough.count > 1 else { return rough }

        // 分批送 LLM（每批 ≤60 条，防上下文过长）
        var merged: [SpeechUnit] = []
        let batch = 60
        var start = 0
        while start < rough.count {
            let range = start..<min(start + batch, rough.count)
            merged.append(contentsOf: regroup(Array(rough[range]), offset: range.lowerBound,
                                              total: rough.count, options: options))
            start = range.upperBound
        }
        return merged.isEmpty ? rough : merged
    }

    /// 让 LLM 输出索引分组，合并成新单元
    private func regroup(_ units: [SpeechUnit], offset: Int, total: Int,
                         options: SegmentationOptions) -> [SpeechUnit] {
        let numbered = units.enumerated().map { i, u in "\(i): \(u.en)" }.joined(separator: "\n")
        let system = """
        你是字幕断句师。下面是按时间顺序编号的字幕片段（已经过标点粗切）。把语义不完整的相邻片段合并成完整句子。
        规则：每组是连续索引；不拆散单个片段；输出覆盖 0..\(units.count - 1) 每个索引恰好一次。
        返回 JSON 数组的数组，如 [[0,1],[2],[3,4]]，不要其他内容。
        """
        guard let reply = try? blockingLLM(endpoint: options.endpoint, model: options.model,
                                           system: system, user: numbered),
              let groups = Self.parseGroups(reply) else {
            return units   // 回退粗切
        }
        var result: [SpeechUnit] = []
        for g in groups {
            let idxs = g.filter { $0 >= 0 && $0 < units.count }
            guard !idxs.isEmpty else { continue }
            let en = idxs.map { units[$0].en }.joined(separator: " ")
            let unit = SpeechUnit(start: units[idxs.first!].start,
                                  end: units[idxs.last!].end, en: en)
            result.append(unit)
        }
        // 校验覆盖：漏索引的回填原单元
        let covered = Set(groups.flatMap { $0 })
        for (i, u) in units.enumerated() where !covered.contains(i) {
            result.append(u)
        }
        return result.sorted { $0.start < $1.start }
    }

    /// Responses API 同步调用（segment 是同步协议方法，用信号量桥接）
    private func blockingLLM(endpoint: String, model: String, system: String, user: String) throws -> String {
        let box = Mutex<Result<String, Error>?>(nil)
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            do {
                let r = try await GatewayTranslateEngine.callLLM(endpoint: endpoint, model: model,
                                                                 system: system, user: user)
                box.with { $0 = .success(r) }
            } catch {
                box.with { $0 = .failure(error) }
            }
            sem.signal()
        }
        sem.wait()
        return try box.wrapped!.get()
    }

    /// 解析 [[0,1],[2]] 形式
    public nonisolated static func parseGroups(_ raw: String) -> [[Int]]? {
        var text = raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "` \n"))
        if let l = text.firstIndex(of: "["), let r = text.lastIndex(of: "]") {
            text = String(text[l...r])
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[Any]] else { return nil }
        var groups: [[Int]] = []
        for g in arr {
            let idxs = g.compactMap { $0 as? Int }
            guard !idxs.isEmpty else { return nil }
            groups.append(idxs)
        }
        return groups.isEmpty ? nil : groups
    }
}
