import Foundation
import Ytb2ZHCore

// MARK: - 网关翻译引擎（秦总管 Responses API + 口语化重组织 prompt + 上下文分批）

public struct GatewayTranslateEngine: TranslateEngine {
    public let descriptor = EngineDescriptor(
        "gateway", "网关 LLM（Responses API）", "deepseek-v4-flash，中文语序重组织 prompt")

    public init() {}

    public func translate(units inputUnits: [SpeechUnit], options: TranslateOptions,
                          progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [SpeechUnit] {
        try await TranslateCore.runTranslate(units: inputUnits, options: options, progress: progress) { system, user in
            try await Self.callLLM(endpoint: options.endpoint, model: options.model,
                                   system: system, user: user)
        }
    }

    // MARK: prompt（三种风格）

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

    // MARK: Responses API 客户端（translate.py 移植）

    static func callLLM(endpoint: String, model: String, system: String, user: String,
                        retries: Int = 4) async throws -> String {
        struct Body: Encodable {
            let model: String
            let input: [Message]
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        var req = URLRequest(url: URL(string: endpoint)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Body(
            model: model,
            input: [.init(role: "system", content: system),
                    .init(role: "user", content: user)]))

        var lastError: String = "unknown"
        for attempt in 0..<retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw EngineError.engineFailure("网关响应异常")
                }
                guard http.statusCode == 200 else {
                    lastError = "HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                // 解析 output[] → message → output_text
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let outputs = obj["output"] as? [[String: Any]] else {
                    throw EngineError.engineFailure("网关返回结构异常")
                }
                var texts: [String] = []
                for o in outputs where (o["type"] as? String) == "message" {
                    if let contents = o["content"] as? [[String: Any]] {
                        for c in contents where (c["type"] as? String) == "output_text" {
                            if let t = c["text"] as? String { texts.append(t) }
                        }
                    }
                }
                let out = texts.joined().trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(for: .seconds(5 * (attempt + 1)))
        }
        throw EngineError.engineFailure("LLM 调用失败：\(lastError)")
    }

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

// MARK: - 简易异步信号量

actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(value: Int) { self.value = value }
    func wait() async {
        if value > 0 { value -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func signal() {
        if let w = waiters.first {
            waiters.removeFirst()
            w.resume()
        } else {
            value += 1
        }
    }
}
