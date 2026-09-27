import Foundation
import Ytb2ZHCore

// MARK: - OpenAI 兼容翻译引擎（chat/completions；任意第三方兼容端点均可）

public struct OpenAICompatTranslateEngine: TranslateEngine {
    public let descriptor = EngineDescriptor(
        "compat", "OpenAI 兼容（chat/completions）", "任意 /v1/chat/completions 端点")

    public init() {}

    public func translate(units: [SpeechUnit], options: TranslateOptions,
                          progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [SpeechUnit] {
        guard !options.compatAPIKey.isEmpty else {
            throw EngineError.engineFailure("translate.compatAPIKey 未配置")
        }
        return try await TranslateCore.runTranslate(units: units, options: options, progress: progress) { system, user in
            try await Self.chatCompletion(baseURL: options.compatBaseURL, apiKey: options.compatAPIKey,
                                          model: options.compatModel, system: system, user: user)
        }
    }

    /// chat/completions 单次调用（带重试）
    static func chatCompletion(baseURL: String, apiKey: String, model: String,
                               system: String, user: String, retries: Int = 4) async throws -> String {
        struct Body: Encodable {
            let model: String
            let messages: [Message]
        }
        struct Message: Encodable {
            let role: String
            let content: String
        }
        let url = baseURL.hasSuffix("/")
            ? baseURL + "chat/completions" : baseURL + "/chat/completions"
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
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
                let out = content.trimmingCharacters(in: .whitespacesAndNewlines)
                if !out.isEmpty { return out }
                lastError = "空回复"
            } catch {
                lastError = error.localizedDescription
            }
            try await Task.sleep(for: .seconds(5 * (attempt + 1)))
        }
        throw EngineError.engineFailure("LLM 调用失败：\(lastError)")
    }
}
