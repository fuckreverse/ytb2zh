import Foundation
import Ytb2ZHCore

// MARK: - 术语提取引擎（翻译前从英文单元抽取领域术语，落盘 terminology.json 可人工修订）

public struct GatewayTerminologyEngine: TerminologyEngine {
    public let descriptor = EngineDescriptor(
        "gateway-terms", "网关 LLM 术语提取", "翻译前扫描全文，抽取领域术语表")

    public init() {}

    public func extractTerms(units: [SpeechUnit], options: TerminologyOptions,
                             progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TerminologyTerm] {
        let text = units.map(\.en).joined(separator: " ")
        guard !text.isEmpty else { return [] }
        progress(0.3, "请求 LLM 提取术语…")
        let system = """
        你是本地化术语工程师。从视频字幕中抽取对翻译质量关键的领域术语、产品名、技术名词、人名。
        只抽"译法容易不一致或直译会错"的词，最多 \(options.maxTerms) 个，按重要性排序。
        返回 JSON 数组 [{"en":"...","zh":"推荐中文译法","note":"一句话说明"}]，不要其他内容。
        """
        let reply = try await GatewayTranslateEngine.callLLM(
            endpoint: options.endpoint, model: options.model, system: system, user: text)
        progress(0.8, "解析术语…")
        let arr = try GatewayTranslateEngine.extractJSONArray(reply)
        var seen = Set<String>()
        let terms = arr.compactMap { d -> TerminologyTerm? in
            guard let en = d["en"] as? String, let zh = d["zh"] as? String,
                  !en.isEmpty, !zh.isEmpty else { return nil }
            let key = en.lowercased()
            guard !seen.contains(key) else { return nil }
            seen.insert(key)
            return TerminologyTerm(en: en.trimmingCharacters(in: .whitespaces),
                                   zh: zh.trimmingCharacters(in: .whitespaces),
                                   note: (d["note"] as? String) ?? "")
        }
        progress(1.0, "术语 \(terms.count) 条")
        return terms
    }
}

public struct NullTerminologyEngine: TerminologyEngine {
    public let descriptor = EngineDescriptor("none", "不提取术语", "跳过术语步骤")
    public init() {}
    public func extractTerms(units: [SpeechUnit], options: TerminologyOptions,
                             progress: @Sendable @escaping (Double, String?) -> Void) async throws -> [TerminologyTerm] {
        []
    }
}
