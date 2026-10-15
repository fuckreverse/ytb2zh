import Foundation
import Ytb2ZHCore

// MARK: - 术语提取引擎（翻译前从英文单元抽取领域语境 + 术语表，落盘 terminology.json 可人工修订）
// 同一次 LLM 调用顺带产出领域/语气/受众——不额外请求，翻译 prompt 据此先锚定专业领域再翻译。

public struct GatewayTerminologyEngine: TerminologyEngine {
    public let descriptor = EngineDescriptor(
        "gateway-terms", "网关 LLM 术语提取", "翻译前扫描全文，抽取领域语境与术语表")

    public init() {}

    public func extractTerms(units: [SpeechUnit], options: TerminologyOptions,
                             progress: @Sendable @escaping (Double, String?) -> Void) async throws -> TerminologyExtraction {
        let text = units.map(\.en).joined(separator: " ")
        guard !text.isEmpty else { return TerminologyExtraction() }
        progress(0.3, "请求 LLM 提取术语…")
        let system = """
        你是本地化术语工程师。先通读视频字幕判断其专业领域，再从字幕中抽取对翻译质量关键的领域术语、产品名、技术名词、人名。
        只抽"译法容易不一致或直译会错"的词，最多 \(options.maxTerms) 个，按重要性排序。
        返回 JSON 对象（不要其他内容）：
        {"domain":"一句话领域判断（如：人工智能/网络安全；生活哲理访谈则照实写，不要硬套科技）","tone":"语气基调（如：轻松教学/严肃专业/激动解说）","audience":"目标受众（如：入门者/从业者/普通观众）","terms":[{"en":"...","zh":"推荐中文译法","note":"一句话说明"}]}
        如果判断不了就填空字符串，不要编造。
        """
        let reply = try await OpenAICompatTranslateEngine.complete(
            protocol: options.apiProtocol,
            baseURL: options.endpoint,
            apiKey: options.apiKey,
            model: options.model,
            system: system,
            user: text)
        progress(0.8, "解析术语…")
        let obj = try Self.extractJSONObject(reply)
        let terms = Self.parseTerms(obj["terms"] as? [[String: Any]] ?? [])
        let domain = DomainContext(
            domain: (obj["domain"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            tone: (obj["tone"] as? String ?? "").trimmingCharacters(in: .whitespaces),
            audience: (obj["audience"] as? String ?? "").trimmingCharacters(in: .whitespaces))
        progress(1.0, "领域 \(domain.domain.isEmpty ? "未识别" : domain.domain) · 术语 \(terms.count) 条")
        return TerminologyExtraction(domain: domain.isEmpty ? nil : domain, terms: terms)
    }

    static func parseTerms(_ arr: [[String: Any]]) -> [TerminologyTerm] {
        var seen = Set<String>()
        return arr.compactMap { d -> TerminologyTerm? in
            guard let en = d["en"] as? String, let zh = d["zh"] as? String,
                  !en.isEmpty, !zh.isEmpty else { return nil }
            let key = en.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return TerminologyTerm(en: en.trimmingCharacters(in: .whitespaces),
                                   zh: zh.trimmingCharacters(in: .whitespaces),
                                   note: (d["note"] as? String) ?? "")
        }
    }

    /// 从 LLM 回复中抽 JSON 对象（剥代码栅栏，取首尾花括号之间）
    static func extractJSONObject(_ raw: String) throws -> [String: Any] {
        var text = raw.replacingOccurrences(of: "```json", with: "")
            .replacingOccurrences(of: "```", with: "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "` \n"))
        if let l = text.firstIndex(of: "{"), let r = text.lastIndex(of: "}") {
            text = String(text[l...r])
        }
        guard let data = text.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw EngineError.engineFailure("LLM 回复中无 JSON 对象：\(text.prefix(200))")
        }
        return obj
    }
}

public struct NullTerminologyEngine: TerminologyEngine {
    public let descriptor = EngineDescriptor("none", "不提取术语", "跳过术语步骤")
    public init() {}
    public func extractTerms(units: [SpeechUnit], options: TerminologyOptions,
                             progress: @Sendable @escaping (Double, String?) -> Void) async throws -> TerminologyExtraction {
        TerminologyExtraction()
    }
}
