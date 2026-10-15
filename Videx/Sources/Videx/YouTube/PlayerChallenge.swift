// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// 从 player base.js 中定位并提取 JS 挑战代码，交由 JSRuntime 求解。
///
/// 双通道设计：
/// - 现代（2025 下半年起）：URL 变换协议，整段过滤语句交给真实 JS 引擎，
///   由 `ModernChallenge` 提取候选并批量求解（支持 JSC 的 WebAssembly）。
/// - 经典（回退）：正则定位函数名 + 花括号配对截取自包含脚本。
///
/// 求解入口为批量 API（一次求值解全部输入）；单条便捷接口委托批量实现。
struct PlayerChallenge: Sendable {
    /// 经典协议的自包含挑战脚本（可直接 evaluate）。
    let script: String
    let decipherFunctionName: String?
    let nsigFunctionName: String?
    /// 现代协议提取结果；旧版 base.js 上为 nil。
    let modern: ModernChallenge.Extracted?
    /// 跨 format 的求解 memo（引用类型，实例共享时天然去重）。
    let memo: SolutionMemo
    var fullPlayerSource: String? = nil

    // MARK: - Extraction

    /// 从 base.js 源码提取挑战。经典与现代两路都失败才返回 nil。
    static func extract(from playerJS: String) -> PlayerChallenge? {
        let modern = ModernChallenge.extract(from: playerJS)

        let decipherName = findDecipherName(in: playerJS)
        let nsigName = findNsigName(in: playerJS)

        var snippets: [String] = []
        var collected = Set<String>()

        if let name = decipherName,
           let code = extractWithDependencies(named: name, in: playerJS, collected: &collected, depth: 0) {
            snippets.append(code)
        }
        if let name = nsigName, name != decipherName,
           let code = extractWithDependencies(named: name, in: playerJS, collected: &collected, depth: 0) {
            snippets.append(code)
        }

        let hasLegacy = (decipherName != nil || nsigName != nil) && !snippets.isEmpty
        guard hasLegacy || modern != nil || playerJS.contains("/s/player/") || playerJS.contains("signatureTimestamp") else { return nil }
        return PlayerChallenge(
            script: snippets.joined(separator: "\n"),
            decipherFunctionName: decipherName,
            nsigFunctionName: nsigName,
            modern: modern,
            memo: SolutionMemo(), fullPlayerSource: playerJS
        )
    }

    // MARK: Decipher 定位

    /// 签名 decipher 函数名。优先调用点模式，其次按函数体特征（split/join）兜底。
    static func findDecipherName(in js: String) -> String? {
        let callSitePatterns = [
            #"\.set\(\s*['"]signature['"]\s*,\s*([a-zA-Z0-9$]+)\s*\("#,
            #"([a-zA-Z0-9$]+)\s*=\s*([a-zA-Z0-9$]+)\s*\(\s*decodeURIComponent"#,
        ]
        for pattern in callSitePatterns {
            if let groups = RegexKit.firstMatch(pattern: pattern, in: js) {
                let name = groups.count >= 2 ? groups[groups.count - 1] : nil
                if let name, name.count >= 2 { return name }
            }
        }
        // 兜底：找包含 a=a.split("") 且 return a.join("") 的函数
        let bodyPattern = #"function\s+([a-zA-Z0-9$]{2,})\s*\(\s*\w{1,2}\s*\)\s*\{"#
        for name in RegexKit.allMatches(pattern: bodyPattern, in: js) {
            if let body = BraceMatcher.function(named: name, in: js),
               body.contains(".split(\"\")"), body.contains(".join(\"\")") {
                return name
            }
        }
        return nil
    }

    // MARK: nsig 定位

    /// n 参数挑战（节流解除）函数名。
    static func findNsigName(in js: String) -> String? {
        let patterns = [
            #"\.set\(\s*['"]n['"]\s*,\s*([a-zA-Z0-9$]+)\s*\("#,
            #"\.set\(\s*['"]nc['"]\s*,\s*([a-zA-Z0-9$]+)\s*\("#,
        ]
        for pattern in patterns {
            if let groups = RegexKit.firstMatch(pattern: pattern, in: js),
               let name = groups.last, name.count >= 2 {
                // 有时 set 的是变量而非函数，确认存在函数体
                if BraceMatcher.function(named: name, in: js) != nil { return name }
            }
        }
        return nil
    }

    // MARK: 依赖闭包提取

    /// 提取函数源码 + 其引用的全局对象/数组（递归两层）。
    static func extractWithDependencies(
        named name: String,
        in js: String,
        collected: inout Set<String>,
        depth: Int
    ) -> String? {
        guard depth <= 2, !collected.contains(name) else { return nil }
        collected.insert(name)

        guard let functionBody = BraceMatcher.function(named: name, in: js) else { return nil }
        var parts = [String(functionBody)]

        // 函数体内形如 `Xxx.` / `Xxx[` 的全局候选
        let referenced = Set(RegexKit.allMatches(
            pattern: #"\b([a-zA-Z0-9_$]{2,})\s*[.\[]"#,
            in: String(functionBody)
        ))
        for candidate in referenced {
            if collected.contains(candidate) { continue }
            if let global = BraceMatcher.globalValue(named: candidate, in: js) {
                collected.insert(candidate)
                parts.insert(String(global), at: 0)
            }
        }
        return parts.joined(separator: "\n")
    }

    // MARK: - Solving（批量，现代优先，经典回退）

    /// 批量解签名（signatureCipher 的 s 值）。
    /// 现代通道一次求值解全部输入；失败或缺失的逐条走经典通道。
    func decipherBatch(_ signatures: [String], js runtime: JSRuntime) -> [String: String] {
        let unique = Set(signatures).filter { memo.sig[$0] == nil }.sorted()
        guard !unique.isEmpty else { return memo.sig }

        var solved: [String: String] = [:]
        if let modern {
            solved = (try? ModernChallenge.solveBatch(modern, channel: .sig, inputs: unique, js: runtime)) ?? [:]
        }
        let missing = unique.filter { solved[$0] == nil }
        if !missing.isEmpty, let source = fullPlayerSource,
           let upstream = try? NativeEJSSolver.solve(player: source, channel: "sig", inputs: missing, runtime: runtime) {
            solved.merge(upstream) { _, new in new }
        }
        // 经典回退：仅补齐现代通道未解出的
        for s in unique where solved[s] == nil {
            guard decipherFunctionName != nil else { break }
            if let value = try? legacyDecipher(s, js: runtime) {
                solved[s] = value
            }
        }
        memo.mergeSig(solved)
        return memo.sig
    }

    /// 批量解 n 参数挑战（节流解除）。
    func solveNsigBatch(_ ns: [String], js runtime: JSRuntime) -> [String: String] {
        let unique = Set(ns).filter { memo.nsig[$0] == nil }.sorted()
        guard !unique.isEmpty else { return memo.nsig }

        var solved: [String: String] = [:]
        if let modern {
            solved = (try? ModernChallenge.solveBatch(modern, channel: .n, inputs: unique, js: runtime)) ?? [:]
        }
        let missing = unique.filter { solved[$0] == nil }
        if !missing.isEmpty, let source = fullPlayerSource,
           let upstream = try? NativeEJSSolver.solve(player: source, channel: "n", inputs: missing, runtime: runtime) {
            solved.merge(upstream) { _, new in new }
        }
        for n in unique where solved[n] == nil {
            guard nsigFunctionName != nil else { break }
            if let value = try? legacyNsig(n, js: runtime) {
                solved[n] = value
            }
        }
        memo.mergeNsig(solved)
        return memo.nsig
    }

    /// 单条便捷接口（兼容旧调用点）。
    func decipher(_ signature: String, js runtime: JSRuntime) throws -> String {
        guard let value = decipherBatch([signature], js: runtime)[signature] else {
            throw ExtractionError.jsFailure("decipher 失败（现代与经典通道均未解出）")
        }
        return value
    }

    /// 单条便捷接口（兼容旧调用点）。
    func solveNsig(_ n: String, js runtime: JSRuntime) throws -> String {
        guard let value = solveNsigBatch([n], js: runtime)[n] else {
            throw ExtractionError.jsFailure("nsig 求解失败（现代与经典通道均未解出）")
        }
        return value
    }

    // MARK: 经典通道

    private func legacyDecipher(_ signature: String, js runtime: JSRuntime) throws -> String {
        guard let name = decipherFunctionName else {
            throw ExtractionError.jsFailure("未提取到经典 decipher 函数")
        }
        return try runtime.evaluate(
            code: script,
            globalStubs: JSShims.browserStubs,
            expression: "\(name)(\(jsStringLiteral(signature)))"
        )
    }

    private func legacyNsig(_ n: String, js runtime: JSRuntime) throws -> String {
        guard let name = nsigFunctionName else {
            throw ExtractionError.jsFailure("未提取到经典 nsig 函数")
        }
        return try runtime.evaluate(
            code: script,
            globalStubs: JSShims.browserStubs,
            expression: "\(name)(\(jsStringLiteral(n)))"
        )
    }
}

/// 求解结果 memo（线程安全；PlayerChallenge 为值类型，跨 format 共享时
/// 通过此类去重，避免同一输入重复执行挑战脚本）。
final class SolutionMemo: @unchecked Sendable {
    private let lock = NSLock()
    private var sigStorage: [String: String] = [:]
    private var nsigStorage: [String: String] = [:]

    var sig: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return sigStorage
    }

    var nsig: [String: String] {
        lock.lock(); defer { lock.unlock() }
        return nsigStorage
    }

    func mergeSig(_ values: [String: String]) {
        guard !values.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for (k, v) in values where sigStorage[k] == nil { sigStorage[k] = v }
    }

    func mergeNsig(_ values: [String: String]) {
        guard !values.isEmpty else { return }
        lock.lock(); defer { lock.unlock() }
        for (k, v) in values where nsigStorage[k] == nil { nsigStorage[k] = v }
    }
}

/// 把 Swift 字符串变成合法的单引号 JS 字符串字面量。
func jsStringLiteral(_ value: String) -> String {
    var out = "'"
    for char in value.unicodeScalars {
        switch char {
        case "'": out += "\\'"
        case "\\": out += "\\\\"
        case "\n": out += "\\n"
        case "\r": out += "\\r"
        default: out += String(char)
        }
    }
    return out + "'"
}
