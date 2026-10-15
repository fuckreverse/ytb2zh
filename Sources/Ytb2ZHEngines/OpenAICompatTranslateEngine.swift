import Foundation
import Ytb2ZHCore

// MARK: - 多协议兼容翻译与 LLM 客户端（OpenAI Chat / Responses / Anthropic Messages / Google Gemini）

public struct OpenAICompatTranslateEngine: TranslateEngine {
    public let descriptor = EngineDescriptor(
        "compat", "标准协议兼容（OpenAI / Anthropic / Gemini）",
        "支持 Chat Completions、Anthropic Messages、Google Gemini 等主流协议端点")

    public init() {}

    public func translate(units: [SpeechUnit], options: TranslateOptions,
                          progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [SpeechUnit] {
        let proto = options.compatProtocol.isEmpty ? "openai" : options.compatProtocol
        return try await TranslateCore.runTranslate(units: units, options: options, progress: progress) { system, user in
            try await Self.complete(protocol: proto, baseURL: options.compatBaseURL,
                                    apiKey: options.compatAPIKey, model: options.compatModel,
                                    system: system, user: user)
        }
    }

    // MARK: - 统一多协议分发入口（供翻译、语义切分、术语提取、连通性测试共用）

    public static func complete(protocol proto: String, baseURL: String, apiKey: String,
                                model: String, system: String, user: String,
                                retries: Int = 4) async throws -> String {
        switch proto.lowercased() {
        case "responses", "gateway":
            return try await GatewayTranslateEngine.callLLM(
                endpoint: baseURL, model: model, apiKey: apiKey,
                system: system, user: user, retries: retries)
        case "anthropic", "claude":
            return try await anthropicMessages(
                baseURL: baseURL, apiKey: apiKey, model: model,
                system: system, user: user, retries: retries)
        case "gemini", "google":
            // 若用户填的是 Gemini 的 OpenAI 兼容地址（含 /openai），直接走 chatCompletion
            if baseURL.lowercased().contains("/openai") {
                return try await chatCompletion(
                    baseURL: baseURL, apiKey: apiKey, model: model,
                    system: system, user: user, retries: retries)
            }
            return try await geminiGenerateContent(
                baseURL: baseURL, apiKey: apiKey, model: model,
                system: system, user: user, retries: retries)
        default:
            return try await chatCompletion(
                baseURL: baseURL, apiKey: apiKey, model: model,
                system: system, user: user, retries: retries)
        }
    }

    // MARK: - URL 归一化与辅助方法

    /// 判断是否为本机推理端点（Ollama / LM Studio / vLLM 等允许免 API Key）
    public static func isLocalEndpoint(_ urlString: String) -> Bool {
        guard let host = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines))?.host?.lowercased() else {
            return false
        }
        return host == "127.0.0.1" || host == "localhost" || host == "::1" || host.hasSuffix(".local")
    }

    /// 剥离推理模型（DeepSeek-R1 / Qwen3 / QwQ / 豆包思考等）输出的 <think>...</think> 思考块
    public static func stripThinkTags(_ raw: String) -> String {
        guard raw.contains("<think>") else { return raw }
        let cleaned = raw.replacingOccurrences(
            of: #"<think>[\s\S]*?</think>"#,
            with: "",
            options: .regularExpression)
        return cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func resolveChatCompletionsURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasSuffix("/chat/completions") { return trimmed }
        if trimmed.hasSuffix("/") { return trimmed + "chat/completions" }
        return trimmed + "/chat/completions"
    }

    public static func resolveAnthropicMessagesURL(_ baseURL: String) -> String {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
        if trimmed.hasSuffix("/messages") { return trimmed }
        if trimmed.hasSuffix("/v1") { return trimmed + "/messages" }
        return trimmed + "/v1/messages"
    }

    public static func resolveGeminiURL(_ baseURL: String, model: String, apiKey: String) -> String {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
        if trimmed.isEmpty {
            trimmed = "https://generativelanguage.googleapis.com/v1beta"
        }
        let cleanModel = model.hasPrefix("models/") ? String(model.dropFirst("models/".count)) : model
        let path: String
        if trimmed.contains(":generateContent") {
            path = trimmed
        } else if trimmed.hasSuffix("/v1beta") || trimmed.hasSuffix("/v1") {
            path = "\(trimmed)/models/\(cleanModel):generateContent"
        } else {
            path = "\(trimmed)/v1beta/models/\(cleanModel):generateContent"
        }
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty && !path.contains("key=") {
            let sep = path.contains("?") ? "&" : "?"
            return "\(path)\(sep)key=\(key)"
        }
        return path
    }

    // MARK: - 1. OpenAI Chat Completions (/v1/chat/completions)

    public static func chatCompletion(baseURL: String, apiKey: String, model: String,
                                      system: String, user: String, retries: Int = 4) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !isLocalEndpoint(baseURL) {
            throw EngineError.engineFailure("API Key 未配置（请在「应用设置 → 模型提供商」中填写密钥）")
        }
        struct Body: Encodable {
            let model: String
            let messages: [Message]
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let urlString = resolveChatCompletionsURL(baseURL)
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("Base URL 无效：\(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Body(
            model: model,
            messages: [.init(role: "system", content: system),
                       .init(role: "user", content: user)]))

        var lastError = "unknown"
        for attempt in 0..<retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw EngineError.engineFailure("响应异常")
                }
                guard http.statusCode == 200 else {
                    lastError = "HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let choices = obj["choices"] as? [[String: Any]],
                      let first = choices.first,
                      let message = first["message"] as? [String: Any],
                      let content = message["content"] as? String else {
                    throw EngineError.engineFailure("chat/completions 返回结构异常")
                }
                let out = stripThinkTags(content).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            if attempt + 1 < retries {
                try await Task.sleep(for: .seconds(5 * (attempt + 1)))
            }
        }
        throw EngineError.engineFailure("LLM 调用失败：\(lastError)")
    }

    // MARK: - 2. Anthropic Messages API (/v1/messages)

    public static func anthropicMessages(baseURL: String, apiKey: String, model: String,
                                         system: String, user: String, retries: Int = 4) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !isLocalEndpoint(baseURL) {
            throw EngineError.engineFailure("Anthropic API Key 未配置")
        }
        struct Body: Encodable {
            let model: String
            let max_tokens: Int
            let system: String
            let messages: [Message]
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let urlString = resolveAnthropicMessagesURL(baseURL)
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("Anthropic Base URL 无效：\(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        }
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Body(
            model: model,
            max_tokens: 8192,
            system: system,
            messages: [.init(role: "user", content: user)]))

        var lastError = "unknown"
        for attempt in 0..<retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw EngineError.engineFailure("Anthropic 响应异常")
                }
                guard http.statusCode == 200 else {
                    lastError = "HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let contentArr = obj["content"] as? [[String: Any]] else {
                    throw EngineError.engineFailure("Anthropic messages 返回结构异常")
                }
                let text = contentArr.compactMap { item -> String? in
                    guard (item["type"] as? String) == "text" else { return nil }
                    return item["text"] as? String
                }.joined()
                let out = stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            if attempt + 1 < retries {
                try await Task.sleep(for: .seconds(5 * (attempt + 1)))
            }
        }
        throw EngineError.engineFailure("Anthropic 调用失败：\(lastError)")
    }

    // MARK: - 3. Google Gemini Native API (v1beta/models/{model}:generateContent)

    public static func geminiGenerateContent(baseURL: String, apiKey: String, model: String,
                                             system: String, user: String, retries: Int = 4) async throws -> String {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if key.isEmpty && !isLocalEndpoint(baseURL) {
            throw EngineError.engineFailure("Gemini API Key 未配置")
        }
        struct Part: Encodable { let text: String }
        struct Content: Encodable {
            let role: String?
            let parts: [Part]
        }
        struct Body: Encodable {
            let systemInstruction: Content
            let contents: [Content]
        }
        let urlString = resolveGeminiURL(baseURL, model: model, apiKey: key)
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("Gemini 接口地址无效：\(baseURL)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !key.isEmpty {
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        req.timeoutInterval = 300
        req.httpBody = try JSONEncoder().encode(Body(
            systemInstruction: .init(role: nil, parts: [.init(text: system)]),
            contents: [.init(role: "user", parts: [.init(text: user)])]))

        var lastError = "unknown"
        for attempt in 0..<retries {
            do {
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard let http = resp as? HTTPURLResponse else {
                    throw EngineError.engineFailure("Gemini 响应异常")
                }
                guard http.statusCode == 200 else {
                    lastError = "HTTP \(http.statusCode): \(String(data: data.prefix(300), encoding: .utf8) ?? "")"
                    throw URLError(.badServerResponse)
                }
                guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let candidates = obj["candidates"] as? [[String: Any]],
                      let first = candidates.first,
                      let content = first["content"] as? [String: Any],
                      let parts = content["parts"] as? [[String: Any]] else {
                    throw EngineError.engineFailure("Gemini 返回结构异常")
                }
                let text = parts.compactMap { $0["text"] as? String }.joined()
                let out = stripThinkTags(text).trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            if attempt + 1 < retries {
                try await Task.sleep(for: .seconds(5 * (attempt + 1)))
            }
        }
        throw EngineError.engineFailure("Gemini 调用失败：\(lastError)")
    }

    // MARK: - 远端模型列表拉取 (/v1/models) 与连通性检测

    public static func fetchModels(protocol proto: String, baseURL: String, apiKey: String) async throws -> [String] {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: #"/$"#, with: "", options: .regularExpression)
        for suffix in ["/chat/completions", "/responses", "/messages"] {
            if trimmed.hasSuffix(suffix) {
                trimmed = String(trimmed.dropLast(suffix.count))
            }
        }
        let urlString: String
        if proto.lowercased() == "gemini" && !trimmed.lowercased().contains("/openai") {
            let base = trimmed.isEmpty ? "https://generativelanguage.googleapis.com/v1beta" : trimmed
            let modelsPath = (base.hasSuffix("/v1beta") || base.hasSuffix("/v1")) ? "\(base)/models" : "\(base)/v1beta/models"
            urlString = key.isEmpty ? modelsPath : "\(modelsPath)?key=\(key)"
        } else if proto.lowercased() == "anthropic" && !trimmed.hasSuffix("/v1") {
            urlString = "\(trimmed)/v1/models"
        } else {
            urlString = "\(trimmed)/models"
        }
        guard let url = URL(string: urlString) else {
            throw EngineError.notConfigured("地址无效：\(urlString)")
        }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 20
        if !key.isEmpty {
            req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
            req.setValue(key, forHTTPHeaderField: "x-api-key")
            req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
            req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        }
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else {
            throw EngineError.engineFailure("响应异常")
        }
        guard http.statusCode == 200 else {
            throw EngineError.engineFailure("HTTP \(http.statusCode): \(String(data: data.prefix(240), encoding: .utf8) ?? "")")
        }
        guard let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.engineFailure("返回 JSON 格式无法识别")
        }
        var ids: [String] = []
        if let arr = obj["data"] as? [[String: Any]] {
            ids = arr.compactMap { $0["id"] as? String }
        } else if let arr = obj["models"] as? [[String: Any]] {
            ids = arr.compactMap { item -> String? in
                guard let name = (item["id"] as? String) ?? (item["name"] as? String) else { return nil }
                return name.hasPrefix("models/") ? String(name.dropFirst("models/".count)) : name
            }
        }
        return Array(Set(ids)).sorted()
    }
}
