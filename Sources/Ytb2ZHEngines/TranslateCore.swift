import Foundation
import Ytb2ZHCore

// MARK: - 翻译核心：批量调度 + 三步翻译（直译→反思→意译）+ 术语注入 + 时长节奏（双向字数预算/超短句扩写）
// 具体引擎只提供 LLM 完成函数（complete(system:user:)），质量策略在此统一实现。
// 时长节奏由 TranslateOptions.autoExpand 控制（此前为死开关，现已接通）：
//   ① prompt 给每条建议字数（时长×4 字/秒，允许 90%～110%），防太长也防太短；
//   ② 结果落地后检测超短句（< 时长×3 字且时长≥2s），单独发一次定向扩写请求。

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
        // 领域语境块：术语步产出的领域/语气/受众，随术语表一同注入所有 LLM 请求
        // 语气/受众仅 narrator 注入（faithful 忠实翻译、concise 限字数，扩张性指令与两者语义冲突）
        let contextualBlock = Self.domainBlock(options.domain, style: options.style) + termBlock
        let sem = AsyncSemaphore(value: max(1, options.concurrency))
        let done = Mutex(0)
        // 时长节奏：仅解说风格 + 中文目标语 + 开关打开时启用（concise 风格与扩写语义冲突）
        let pacing = options.autoExpand && options.targetLanguage == "zh" && options.style == .narrator

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
                    let lines = units[range].enumerated().map { k, u -> String in
                        let dur = u.end - u.start
                        if pacing {
                            let chars = Int((dur * Self.targetCharsPerSec).rounded())
                            return String(format: "%d: (%.1fs≈%d字) %@", k, dur, chars, u.en)
                        }
                        return String(format: "%d: (%.1fs) %@", k, dur, u.en)
                    }.joined(separator: "\n")
                    var user = "上一段上下文（勿翻译）：\(context)\n\n"
                    if options.targetLanguage != "zh" {
                        user += "目标语言：\(options.targetLanguage)（在 prompt 指令基础上输出该语言）\n\n"
                    }
                    if pacing {
                        user += "英文字幕（括号内为可用时长与建议字数，译文长度应控制在建议字数的 90%～110%）：\n\(lines)"
                    } else {
                        user += "英文字幕（括号内为可用时长，译文不宜超过 时长×4.5 字）：\n\(lines)"
                    }

                    let first = try await complete(Self.systemPrompt(for: options.style) + Self.pacingRuleBlock(enabled: pacing) + contextualBlock, user)
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
                        _ = try await complete(critiquePrompt + contextualBlock, critiqueUser)
                        // 第三步：按意见出终稿
                        let refinePrompt = """
                        你是字幕翻译终审。根据审校意见输出最终译文，遵守原风格要求与术语表。
                        返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
                        """
                        let refineUser = "英文原文：\n\(lines)\n\n审校意见：\n（见系统提示上下文约定，直接给出终稿）\n初译：\n\(zh1)"
                        let second = try await complete(refinePrompt + contextualBlock, refineUser)
                        final = second
                    }

                    let arr = try Self.extractJSONArray(final)
                    var by = Dictionary(uniqueKeysWithValues: arr.compactMap { d -> (Int, String)? in
                        guard let i = d["i"] as? Int, let zh = d["zh"] as? String else { return nil }
                        return (i, zh.trimmingCharacters(in: .whitespaces))
                    })
                    if pacing {
                        by = await Self.expandTooShort(in: by, range: range, units: units,
                                                       promptExtra: contextualBlock, complete: complete)
                        if options.autoCompress {
                            by = await Self.compressTooLong(in: by, range: range, units: units,
                                                            promptExtra: contextualBlock, complete: complete)
                        }
                    }
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

    // MARK: 时长节奏（双向字数预算 + 超短句定向扩写 + 超长句定向精简）

    /// 建议字数速率：中文 TTS 约 4～5 字/秒，取 4 留余量
    static let targetCharsPerSec = 4.0
    /// 超短句判定阈值：低于 时长×3 字视为填不满时间窗
    static let minCharsPerSec = 3.0
    /// 超长句判定阈值：高于 时长×5.5 字视为超出 1.3x 加速预算，需精简防机关枪语速
    static let maxCharsPerSec = 5.5
    /// 过短时长不作扩写判定（单元太短噪声大）
    static let minTooShortDuration = 2.0
    /// 过短时长不作缩写判定
    static let minTooLongDuration = 2.5

    static func charCount(_ s: String) -> Int {
        s.filter { !$0.isWhitespace }.count
    }

    static func isTooShort(zh: String, duration: Double) -> Bool {
        duration >= minTooShortDuration && Double(charCount(zh)) < duration * minCharsPerSec
    }

    static func isTooLong(zh: String, duration: Double) -> Bool {
        duration >= minTooLongDuration && Double(charCount(zh)) > duration * maxCharsPerSec
    }

    static func pacingRuleBlock(enabled: Bool) -> String {
        guard enabled else { return "" }
        return """
        \n\n时长节奏（重要）：这是配音不是字幕，中文必须填满对应的英文时间窗，否则念完会留明显停顿。每条译文长度控制在括号内建议字数的 90%～110%；原文信息量不足时，用自然的口语扩写补足（补充解释、过渡、举例），禁止注水和车轴辘话。
        """
    }

    /// 定向扩写：检测本批超短句，单独发一次扩写请求；结果只在更长时才采纳，失败静默回退
    static func expandTooShort(in by: [Int: String], range: Range<Int>, units: [SpeechUnit],
                               promptExtra: String, complete: Complete) async -> [Int: String] {
        let flagged: [(k: Int, zh: String, dur: Double)] = range.enumerated().compactMap { k, idx in
            guard let zh = by[k], !zh.isEmpty else { return nil }
            let u = units[idx]
            let dur = u.end - u.start
            return isTooShort(zh: zh, duration: dur) ? (k, zh, dur) : nil
        }
        guard !flagged.isEmpty else { return by }

        let lines = flagged.enumerated().map { j, f -> String in
            let target = Int((f.dur * targetCharsPerSec).rounded())
            return String(format: "%d: (%.1fs，目标约%d字) %@", j, f.dur, target, f.zh)
        }.joined(separator: "\n")
        let user = "以下中文配音译文明显短于可用时长（念完会留明显停顿），请扩写到目标字数附近：\n\(lines)"
        let system = """
        你是配音译文润色师。把偏短的中文译文自然扩写到目标字数附近：可补充解释、过渡语气、口语化衔接，不改变原意，禁止注水、禁止车轴辘话。
        专有名词保留英文。返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
        """
        guard let raw = try? await complete(system + promptExtra, user),
              let arr = try? extractJSONArray(raw) else { return by }

        var out = by
        for (j, f) in flagged.enumerated() {
            if let d = arr.first(where: { ($0["i"] as? Int) == j }),
               let zh = d["zh"] as? String,
               charCount(zh) > charCount(f.zh) {
                out[f.k] = zh.trimmingCharacters(in: .whitespaces)
            }
        }
        return out
    }

    /// 定向精简：检测本批超长句（> 时长×5.5 字），发一次精简请求；结果只在更短且非空时采纳
    static func compressTooLong(in by: [Int: String], range: Range<Int>, units: [SpeechUnit],
                                promptExtra: String, complete: Complete) async -> [Int: String] {
        let flagged: [(k: Int, zh: String, dur: Double)] = range.enumerated().compactMap { k, idx in
            guard let zh = by[k], !zh.isEmpty else { return nil }
            let u = units[idx]
            let dur = u.end - u.start
            return isTooLong(zh: zh, duration: dur) ? (k, zh, dur) : nil
        }
        guard !flagged.isEmpty else { return by }

        let lines = flagged.enumerated().map { j, f -> String in
            let target = Int((f.dur * targetCharsPerSec).rounded())
            return String(format: "%d: (%.1fs，目标约%d字) %@", j, f.dur, target, f.zh)
        }.joined(separator: "\n")
        let user = "以下中文配音译文相对可用时长过长（合成后会严重赶拍），请在不丢失核心信息的前提下精简到目标字数附近：\n\(lines)"
        let system = """
        你是配音台词精简师。把偏长的中文配音译文用利落自然的播客口语压缩到目标字数附近：删掉冗余修饰与书面套话，保留核心信息与英文专有名词。
        返回 JSON 数组 [{"i":0,"zh":"..."}]，条数与输入一致，不要其他内容。
        """
        guard let raw = try? await complete(system + promptExtra, user),
              let arr = try? extractJSONArray(raw) else { return by }

        var out = by
        for (j, f) in flagged.enumerated() {
            if let d = arr.first(where: { ($0["i"] as? Int) == j }),
               let zh = d["zh"] as? String {
                let trimmed = zh.trimmingCharacters(in: .whitespaces)
                if !trimmed.isEmpty && charCount(trimmed) < charCount(f.zh) {
                    out[f.k] = trimmed
                }
            }
        }
        return out
    }

    // MARK: 领域语境 → prompt 片段

    /// 领域语境块：锚定专业领域，翻译前先认同域再看文本；人设里的"科技视频"定位如与此冲突以本块为准。
    /// 语气/受众仅 narrator 风格注入——faithful 忠实逐条、concise 限字数，留这两条会诱导扩写与风格定义打架。领域行各风格均注入（术语译法准确不挑风格）。
    static func domainBlock(_ d: DomainContext?, style: TranslationStyle) -> String {
        guard let d, !d.isEmpty else { return "" }
        var lines: [String] = []
        if !d.domain.isEmpty {
            lines.append("专业领域：\(d.domain)。专业概念、行话、惯用说法按该领域通行译法与表达习惯处理；上文人设中的\"科技视频\"定位如与此不符，以本条为准。")
        }
        if style == .narrator {
            if !d.tone.isEmpty { lines.append("语气基调：\(d.tone)。") }
            if !d.audience.isEmpty { lines.append("目标受众：\(d.audience)，表达深度与背景铺垫按受众水平调整。") }
        }
        return "\n\n领域语境（翻译前先确认）：\n" + lines.joined(separator: "\n")
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

// MARK: - Index-Homura 音节可控配音翻译引擎（Bilibili IndexTeam/Index-Homura-2B/9B GGUF 本地推理）
// 遵循官方 instTrans 受控翻译模板：逐句精确指定目标音节数 + 术语强约束（--glossary），
// 并在 chat_template_kwargs 中显式关闭思考块（enable_thinking: false）及使用推荐温度 0.3。

public struct IndexHomuraTranslateEngine: TranslateEngine {
    public let descriptor = EngineDescriptor(
        "homura", "Index-Homura 音节可控翻译（本地 GGUF）",
        "B站配音专用受控翻译模型（2B/9B），显式控制目标音节数与术语表，从源头消除配音时长漂移")

    public init() {}

    /// 计算给定时间窗的目标音节预算（中文 1 汉字 = 1 音节，默认 4.2 音节/秒）
    public static func targetSyllableCount(duration: Double, syllablesPerSec: Double = 4.2) -> Int {
        let rate = syllablesPerSec > 0.5 ? syllablesPerSec : 4.2
        return max(2, Int((max(0.5, duration) * rate).rounded()))
    }

    /// 估算中英混合播客译文的实际音节数（CJK 字符每字 1 音节；英文单词按元音群估算音节；数字按位估算）
    public static func countSyllables(_ text: String) -> Int {
        var count = 0
        var asciiWord = ""
        func flushAsciiWord() {
            guard !asciiWord.isEmpty else { return }
            let w = asciiWord.lowercased()
            asciiWord = ""
            // 全大写缩写（如 LLM / API / GPU）按字母逐个念出
            if w.count <= 4 && w.allSatisfy({ $0.isLetter }) {
                count += w.count
                return
            }
            let vowels = Set("aeiouy")
            var groups = 0
            var prevVowel = false
            for ch in w {
                if ch.isNumber {
                    groups += 1
                    prevVowel = false
                } else if vowels.contains(ch) {
                    if !prevVowel { groups += 1 }
                    prevVowel = true
                } else {
                    prevVowel = false
                }
            }
            if w.hasSuffix("e") && groups > 1 { groups -= 1 }
            count += max(1, groups)
        }

        for scalar in text.unicodeScalars {
            if scalar.isASCII && (CharacterSet.alphanumerics.contains(scalar)) {
                asciiWord.append(Character(scalar))
            } else {
                flushAsciiWord()
                // CJK 统一表意文字
                if (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value) {
                    count += 1
                }
            }
        }
        flushAsciiWord()
        return count
    }

    /// 组装 Index-Homura 官方受控配音翻译 Prompt（支持音节数 + 术语表同时生效）
    public static func buildHomuraPrompt(
        sourceText: String,
        targetLanguage: String = "zh",
        targetSyllables: Int,
        terminology: [TerminologyTerm] = []
    ) -> String {
        let langName: String = {
            switch targetLanguage.lowercased() {
            case "zh", "zh-cn", "zh-hans": return "简体中文"
            case "en": return "英语"
            case "ja": return "日语"
            case "ko": return "韩语"
            case "es": return "西班牙语"
            default: return targetLanguage
            }
        }()

        let cleanSource = sourceText.trimmingCharacters(in: .whitespacesAndNewlines)
        // 只挑当前源句中实际命中的术语（避免无关术语干扰 2B/9B 小模型注意力）
        let lowerSource = cleanSource.lowercased()
        let activeTerms = terminology.filter { t in
            !t.en.isEmpty && !t.zh.isEmpty && lowerSource.contains(t.en.lowercased())
        }

        var lines: [String] = [
            "请将以下文本翻译为\(langName)，译文严格控制在 \(max(1, targetSyllables)) 个音节。"
        ]
        if !activeTerms.isEmpty {
            lines.append("请严格遵循以下术语对应关系进行翻译：")
            for term in activeTerms {
                lines.append("- \(term.en) -> \(term.zh)")
            }
        }
        lines.append("直接输出翻译结果，不要进行任何解释。")
        lines.append("")
        lines.append(cleanSource)
        return lines.joined(separator: "\n")
    }

    public func translate(units: [SpeechUnit], options: TranslateOptions,
                          progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [SpeechUnit] {
        // 自动探测或拉起本地 LLM 推理服务（Ollama / LM Studio / llama-server + 自动下载 Index-Homura-2B GGUF）；
        // 若本机未装任何本地 LLM 运行时但网关可用，自动无感降级到网关双向时长控制翻译，绝不让用户卡在报错页。
        let resolved = try await LocalLLMManager.ensureReady(options: options, progress: progress)
        if resolved.useGatewayFallback {
            progress(0.05, "未检测到本地 Ollama/llama.cpp，自动切换网关双向时长受控翻译…")
            return try await GatewayTranslateEngine().translate(units: units, options: options, progress: progress)
        }

        let baseURL = resolved.baseURL
        let model = resolved.model
        let apiKey = options.compatAPIKey
        let terms = options.terminology ?? []
        let syllablesPerSec = options.targetSyllablesPerSec > 0.5 ? options.targetSyllablesPerSec : 4.2

        let resultBox = Mutex(units)
        let sem = AsyncSemaphore(value: max(1, options.concurrency))
        let done = Mutex(0)
        let total = max(1, units.count)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for (idx, unit) in units.enumerated() {
                group.addTask {
                    await sem.wait()
                    defer { Task { await sem.signal() } }

                    let dur = max(0.8, unit.end - unit.start)
                    let targetSyl = Self.targetSyllableCount(duration: dur, syllablesPerSec: syllablesPerSec)
                    let prompt = Self.buildHomuraPrompt(
                        sourceText: unit.en,
                        targetLanguage: options.targetLanguage,
                        targetSyllables: targetSyl,
                        terminology: terms)

                    var zh = try await Self.callHomuraChat(
                        baseURL: baseURL, apiKey: apiKey, model: model, userPrompt: prompt)

                    // 若开启三步精修且音节偏差超过 25%，按偏差比例自适应修正目标音节重译一次
                    if options.quality == .threePass && dur >= 2.0 {
                        let actualSyl = Self.countSyllables(zh)
                        let diffRatio = abs(Double(actualSyl - targetSyl)) / Double(max(1, targetSyl))
                        if diffRatio > 0.25 && actualSyl > 0 {
                            let adjustedTarget = max(2, Int((Double(targetSyl * targetSyl) / Double(actualSyl)).rounded()))
                            let retryPrompt = Self.buildHomuraPrompt(
                                sourceText: unit.en,
                                targetLanguage: options.targetLanguage,
                                targetSyllables: adjustedTarget,
                                terminology: terms)
                            if let retryZh = try? await Self.callHomuraChat(
                                baseURL: baseURL, apiKey: apiKey, model: model, userPrompt: retryPrompt),
                               !retryZh.isEmpty {
                                let retrySyl = Self.countSyllables(retryZh)
                                if abs(retrySyl - targetSyl) < abs(actualSyl - targetSyl) {
                                    zh = retryZh
                                }
                            }
                        }
                    }

                    resultBox.with { r in
                        if !zh.isEmpty { r[idx].zh = zh }
                    }
                    let d = done.with { v -> Int in v += 1; return v }
                    progress(Double(d) / Double(total), "音节受控翻译 \(d)/\(total)")
                }
            }
            try await group.waitForAll()
        }
        return resultBox.wrapped
    }

    /// 调用本地 llama-server / Ollama / vLLM 的 /v1/chat/completions，注入 enable_thinking=false 与 temperature=0.3
    public static func callHomuraChat(
        baseURL: String, apiKey: String, model: String, userPrompt: String, retries: Int = 3
    ) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !OpenAICompatTranslateEngine.isLocalEndpoint(baseURL) {
            throw EngineError.engineFailure("Index-Homura 远端端点需要配置 API Key")
        }
        let urlString = OpenAICompatTranslateEngine.resolveChatCompletionsURL(baseURL)
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("Index-Homura Base URL 无效：\(baseURL)")
        }
        let payload: [String: Any] = [
            "model": model,
            "messages": [["role": "user", "content": userPrompt]],
            "temperature": 0.3,
            "max_tokens": max(512, userPrompt.count * 3),
            "chat_template_kwargs": ["enable_thinking": false],
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 180
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)

        var lastError = "unknown"
        for attempt in 0..<retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
                    let code = (resp as? HTTPURLResponse)?.statusCode ?? -1
                    lastError = "HTTP \(code): \(String(data: data.prefix(240), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw EngineError.engineFailure("Index-Homura 返回结构异常")
                }
                let cleaned = OpenAICompatTranslateEngine.stripThinkTags(content)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !cleaned.isEmpty { return cleaned }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            if attempt + 1 < retries {
                try await Task.sleep(for: .seconds(2 * (attempt + 1)))
            }
        }
        throw EngineError.engineFailure("Index-Homura 调用失败：\(lastError)")
    }
}

// MARK: - 本地大模型零门槛自启与智能降级管理器（Ollama / LM Studio / llama-server）

public enum LocalLLMManager {
    public struct ResolvedEndpoint: Sendable {
        public let baseURL: String
        public let model: String
        public let useGatewayFallback: Bool
    }

    private static let managedLlamaPort = 18089
    private static let managedProcess = Mutex<Process?>(nil)

    /// 探测本机 LLM 运行时状态（供应用设置页展示）
    public static func runtimeStatus() -> (llamaServerPath: String?, ollamaPath: String?) {
        let llama = SidecarPaths.which("llama-server")
            ?? (FileManager.default.isExecutableFile(atPath: NSHomeDirectory() + "/.ytb2zh/bin/llama-server")
                ? NSHomeDirectory() + "/.ytb2zh/bin/llama-server" : nil)
        let ollama = SidecarPaths.which("ollama")
            ?? (FileManager.default.isExecutableFile(atPath: "/Applications/Ollama.app/Contents/Resources/ollama")
                ? "/Applications/Ollama.app/Contents/Resources/ollama" : nil)
        return (llama, ollama)
    }

    public static func ensureReady(
        options: TranslateOptions,
        progress: @Sendable (Double, String?) -> Void
    ) async throws -> ResolvedEndpoint {
        let configuredURL = options.compatBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "http://127.0.0.1:11434/v1" : options.compatBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModel = options.compatModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "IndexTeam/Index-Homura-2B" : options.compatModel.trimmingCharacters(in: .whitespacesAndNewlines)

        // 1) 若非本地地址（用户配了云端 OpenAI 兼容服务且填了 Key），直接走配置值
        if !OpenAICompatTranslateEngine.isLocalEndpoint(configuredURL) && !options.compatAPIKey.isEmpty {
            return ResolvedEndpoint(baseURL: configuredURL, model: configuredModel, useGatewayFallback: false)
        }

        // 2) 探测用户配置的本地端口（如 Ollama 11434 / LM Studio 1234）是否已有可用模型
        if let models = try? await probeLocalModels(baseURL: configuredURL), !models.isEmpty {
            if models.contains(configuredModel) {
                return ResolvedEndpoint(baseURL: configuredURL, model: configuredModel, useGatewayFallback: false)
            }
            if let homura = models.first(where: { $0.lowercased().contains("homura") }) {
                return ResolvedEndpoint(baseURL: configuredURL, model: homura, useGatewayFallback: false)
            }
        }

        // 3) 探测内置托管的 llama-server 端口是否已在运行
        let managedURL = "http://127.0.0.1:\(managedLlamaPort)/v1"
        if let models = try? await probeLocalModels(baseURL: managedURL), let first = models.first {
            return ResolvedEndpoint(baseURL: managedURL, model: first, useGatewayFallback: false)
        }

        let (llamaPath, ollamaPath) = runtimeStatus()

        // 4) 若本机装有 llama-server：自动下载 Index-Homura-2B.Q4_K_M.gguf 并在后台拉起 llama-server
        if let llamaPath {
            let gguf = try await ModelStore.ensureHomuraGGUF(configured: configuredModel) { frac, msg in
                progress(frac * 0.15, msg)
            }
            progress(0.16, "正在启动本地 llama-server（Metal GPU 加速）…")
            if try await startManagedLlamaServer(executable: llamaPath, ggufPath: gguf) {
                return ResolvedEndpoint(baseURL: managedURL, model: "Index-Homura-2B", useGatewayFallback: false)
            }
        }

        // 5) 若本机装有 Ollama：自动下载 Index-Homura-2B.Q4_K_M.gguf 并自动导入到 Ollama
        if let ollamaPath {
            let gguf = try await ModelStore.ensureHomuraGGUF(configured: configuredModel) { frac, msg in
                progress(frac * 0.15, msg)
            }
            progress(0.16, "正在将 Index-Homura-2B 导入本地 Ollama…")
            if let importedModel = try? await importGGUFIntoOllama(ollamaPath: ollamaPath, ggufPath: gguf) {
                return ResolvedEndpoint(
                    baseURL: "http://127.0.0.1:11434/v1", model: importedModel, useGatewayFallback: false)
            }
        }

        // 6) 若 Ollama / LM Studio 里已有任意本地模型（如 qwen3 / qwen2.5 / deepseek），直接复用它
        for candidateURL in [configuredURL, "http://127.0.0.1:11434/v1", "http://127.0.0.1:1234/v1"] {
            if let models = try? await probeLocalModels(baseURL: candidateURL), let first = models.first {
                return ResolvedEndpoint(baseURL: candidateURL, model: first, useGatewayFallback: false)
            }
        }

        // 7) 兜底：若本机未装 Ollama / llama.cpp，自动无感回退到网关翻译（自带双向时长控制），避免新用户报错
        return ResolvedEndpoint(baseURL: configuredURL, model: configuredModel, useGatewayFallback: true)
    }

    private static func probeLocalModels(baseURL: String) async throws -> [String] {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/") { trimmed.removeLast() }
        let urlStr = trimmed.hasSuffix("/models") ? trimmed : "\(trimmed)/models"
        guard let url = URL(string: urlStr) else { return [] }
        var req = URLRequest(url: url)
        req.timeoutInterval = 2.0
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]] else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    private static func startManagedLlamaServer(executable: String, ggufPath: String) async throws -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = [
            "-m", ggufPath,
            "--host", "127.0.0.1",
            "--port", String(managedLlamaPort),
            "-ngl", "99",
            "-c", "4096",
            "--jinja",
        ]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try p.run()
        managedProcess.with { $0 = p }

        let managedURL = "http://127.0.0.1:\(managedLlamaPort)/v1"
        for _ in 0..<25 {
            try await Task.sleep(for: .milliseconds(400))
            if let models = try? await probeLocalModels(baseURL: managedURL), !models.isEmpty {
                return true
            }
        }
        return false
    }

    private static func importGGUFIntoOllama(ollamaPath: String, ggufPath: String) async throws -> String? {
        let runner = ProcessRunner()
        // 确保 ollama serve 已启动
        if (try? await probeLocalModels(baseURL: "http://127.0.0.1:11434/v1")) == nil {
            let serve = Process()
            serve.executableURL = URL(fileURLWithPath: ollamaPath)
            serve.arguments = ["serve"]
            serve.standardOutput = FileHandle.nullDevice
            serve.standardError = FileHandle.nullDevice
            try? serve.run()
            try? await Task.sleep(for: .seconds(2))
        }
        let modelName = "index-homura-2b"
        let modelfile = URL(fileURLWithPath: ModelStore.root).appendingPathComponent("Modelfile.homura")
        let content = """
        FROM "\(ggufPath)"
        PARAMETER temperature 0.3
        """
        try content.write(to: modelfile, atomically: true, encoding: .utf8)
        let r = try runner.run(ollamaPath, ["create", modelName, "-f", modelfile.path])
        guard r.code == 0 else { return nil }
        return modelName
    }
}
