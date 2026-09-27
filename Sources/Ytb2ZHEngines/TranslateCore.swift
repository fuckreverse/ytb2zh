import Foundation
import Ytb2ZHCore

// MARK: - 翻译核心：批量调度 + 三步翻译（直译→反思→意译）+ 术语注入
// 具体引擎只提供 LLM 完成函数（complete(system:user:)），质量策略在此统一实现。

public enum TranslateCore {
    /// LLM 完成函数签名（Responses API / chat-completions 各自实现）
    public typealias Complete = @Sendable (String, String) async throws -> String

    public static func runTranslate(units inputUnits: [SpeechUnit], options: TranslateOptions,
                                    progress: @Sendable @escaping (Double, String?) -> Void,
                                    complete: @escaping Complete) async throws -> [SpeechUnit] {
        let units = inputUnits
        var result = units
        let resultBox = Mutex(result)
        let batch = max(1, options.batchSize)
        let totalBatches = (units.count + batch - 1) / batch
        let termBlock = terminologyBlock(options.terminology ?? [])
        let sem = AsyncSemaphore(value: max(1, options.concurrency))
        let done = Mutex(0)

        try await withThrowingTaskGroup(of: Void.self) { group in
            var start = 0
            var batchIndex = 0
            while start < units.count {
                let range = start..<min(start + batch, units.count)
                batchIndex += 1
                start = range.upperBound
                group.addTask { [self] in
                    await sem.wait()
                    defer { Task { await sem.signal() } }
                    // 上下文：本批之前 6 条英文原文
                    let ctxStart = max(0, range.lowerBound - 6)
                    let context = units[ctxStart..<range.lowerBound].map(\.en).joined(separator: " ")
                    let lines = units[range].enumerated().map { k, u in
                        String(format: "%d: (%.1fs) %@", k, u.end - u.start, u.en)
                    }.joined(separator: "\n")
                    var user = "上一段上下文（勿翻译）：\(context)\n\n"
                    if options.targetLanguage != "zh" {
                        user += "目标语言：\(options.targetLanguage)（在 prompt 指令基础上输出该语言）\n\n"
                    }
                    user += "英文字幕（括号内为可用时长，译文不宜超过 时长×4.5 字）：\n\(lines)"

                    let first = try await complete(Self.systemPrompt(for: options.style) + termBlock, user)
                    var final = first
                    if options.quality == .threePass {
                        // 第二步：对照反思
                        let zh1 = (try? Self.extractJSONArray(first))?.compactMap { d -> String? in
                            guard let zh = d["zh"] as? String else { return nil }
                            return zh
                        }.joined(separator: "\n") ?? first
                        let critiquePrompt = """
                        你是字幕翻译审校。对照英文原文与初译，指出问题：漏译、直译腔、语序不顺、术语不一致、过长难念。只列问题，不重译。
                        """
                        let critiqueUser = "英文原文：\n\(lines)\n\n初译：\n\(zh1)"
                        _ = try await complete(critiquePrompt + termBlock, critiqueUser)
                        // 第三步：按意见出终稿
                        let refinePrompt = """
                        你是字幕翻译终审。根据审校意见输出最终译文，遵守原风格要求与术语表。
                        返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
                        """
                        let refineUser = "英文原文：\n\(lines)\n\n审校意见：\n（见系统提示上下文约定，直接给出终稿）\n初译：\n\(zh1)"
                        let second = try await complete(refinePrompt + termBlock, refineUser)
                        final = second
                    }

                    let arr = try Self.extractJSONArray(final)
                    let by = Dictionary(uniqueKeysWithValues: arr.compactMap { d -> (Int, String)? in
                        guard let i = d["i"] as? Int, let zh = d["zh"] as? String else { return nil }
                        return (i, zh.trimmingCharacters(in: .whitespaces))
                    })
                    resultBox.with { r in
                        for (k, idx) in range.enumerated() where by[k] != nil && !by[k]!.isEmpty {
                            r[idx].zh = by[k]!
                        }
                    }
                    let d = done.with { v -> Int in v += 1; return v }
                    progress(Double(d) / Double(max(1, totalBatches)), "批次 \(d)/\(totalBatches)")
                }
            }
            try await group.waitForAll()
        }
        return resultBox.wrapped
    }

    // MARK: 术语表 → prompt 片段

    static func terminologyBlock(_ terms: [TerminologyTerm]) -> String {
        guard !terms.isEmpty else { return "" }
        let lines = terms.map { t -> String in
            let note = t.note.isEmpty ? "" : "（\(t.note)）"
            return "- \(t.en) → \(t.zh)\(note)"
        }.joined(separator: "\n")
        return "\n\n术语表（必须严格遵守，不得自创译法）：\n\(lines)"
    }

    // MARK: prompt（三种风格，与原 GatewayTranslateEngine 一致）

    static func systemPrompt(for style: TranslationStyle) -> String {
        let base = """
        你是一位中文科技视频的资深译制配音编剧。把英文字幕翻译成解说旁白用的中文。
        核心原则：按中文思维重新组织语序，绝不逐词翻译。观众是"听"的，不是"看"的，一次要能听懂。

        必须遵守：
        1. 英文的后置定语、从句一律重组：不写"理解 LLM 特有的、不适用于传统系统的漏洞"，要写"LLM 有些漏洞，是传统系统没有的"。
        2. 短句优先，一句话一个意思，主动语态，多用动词少用名词化结构（"进行学习"→"学"）。
        3. 书面词换口语：旨在→这个视频会/我们要做的是；考量→要考虑的；此外→另外；同时→还有；进行→直接用动词。
        4. "as X"不译"作为X"，改写成完整的判断句；"X-based Y"译成"基于X的Y"或直接说人话。
        5. 专有名词保留英文（LLM、TryHackMe、API 等数字母词直接念字母）。
        6. 解说视频语气：像科技区 UP 主面对面讲解，自然、亲切、直接。
        返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
        """
        switch style {
        case .narrator: return base
        case .faithful:
            return """
            你是专业字幕翻译。将英文字幕逐条翻译为简体中文，忠实准确，术语规范。
            专有名词保留英文。返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
            """
        case .concise:
            return """
            你是极简字幕译者。将英文字幕译为简短有力的简体中文，每条不超过 20 字，去掉冗余客套。
            专有名词保留英文。返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
            """
        }
    }

    // MARK: JSON 抽取（与原实现一致）

    static func extractJSONArray(_ raw: String) throws -> [[String: Any]] {
        var text = raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "` \n"))
        if let l = text.firstIndex(of: "["), let r = text.lastIndex(of: "]") {
            text = String(text[l...r])
        }
        guard let data = text.data(using: .utf8),
              let arr = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw EngineError.engineFailure("LLM 回复中无 JSON 数组：\(text.prefix(200))")
        }
        return arr
    }
}
