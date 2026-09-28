// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation

/// 现代版 YouTube 挑战求解器（移植 yt-dlp/ejs 的 solver 思路到 JSC）。
///
/// 2025 下半年起 base.js 的挑战函数不再是"字符串进/字符串出"的旧协议，
/// 而是 URL 变换协议：函数签名 `(url, "s", sig)`，内部构造自家的 URL 类，
/// mutate 查询参数后由调用方读回。挑战函数靠语句 `x.set("alr","yes")`
/// 这一稳定标记定位，配合多候选一致性校验兜底。
///
/// 执行策略与 EJS 一致：不做片段截取，而是把 base.js 顶层语句过滤为
/// "定义类语句"（var/function/class/赋值），整段交给真实 JS 引擎求值，
/// 让 URL 类等全部依赖自然可用；系统 JavaScriptCore 自带 WebAssembly
/// 支持，覆盖未来挑战可能引入的 wasm 路径。
///
/// 提取算法已用 EJS golden player（74edf1a3，STS 20522）离线验证：
/// 分割 → IIFE 展开 → 过滤（12164/13172 条保留）→ 候选恰为 4 个标记点。
enum ModernChallenge {

    struct Extracted: Sendable {
        /// prelude + 过滤后的定义语句，可直接 evaluate。
        let script: String
        /// 可调用的挑战函数表达式（如 `["g.ba", "fY"]`）。
        let candidates: [String]
    }

    // MARK: - 提取

    static func extract(from playerJS: String) -> Extracted? {
        let statements = JSSplitter.topLevelStatements(in: playerJS)
        guard !statements.isEmpty else { return nil }

        var prelude: [String] = []
        var body: String?
        var param: String?
        var arg: String?

        for statement in statements {
            if let (p, b) = iifeBody(of: statement) {
                body = b
                param = p
                arg = iifeArgument(of: statement)
            } else {
                prelude.append(statement)
            }
        }
        guard let body else { return nil }

        let inner = JSSplitter.topLevelStatements(in: body)

        // 过滤：只保留定义类语句（EJS modifyPlayer 的正则近似）
        var kept: [String] = []
        var candidates: [String] = []
        for raw in inner {
            let statement = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !statement.isEmpty else { continue }
            // 嵌套 IIFE 调用（立即执行的初始化逻辑）丢弃
            if statement.hasPrefix("(function") { continue }
            guard isDefinition(statement) else { continue }
            kept.append(statement)
            if markerRange(in: statement) != nil, let name = candidateName(in: statement) {
                candidates.append(name)
            }
        }
        guard !candidates.isEmpty else { return nil }

        var script = prelude.joined(separator: ";\n")
        if !script.isEmpty { script += ";\n" }
        // IIFE 形参绑定在展开后丢失，补一个等价绑定：
        // 实参若是 prelude 里的简单标识符（如 _yt_player）则直接别名，
        // 否则退化为空对象。
        if let param {
            if let arg, arg.range(of: #"^[A-Za-z_$][\w$]*$"#, options: .regularExpression) != nil {
                script += "var \(param) = typeof \(arg) !== 'undefined' ? \(arg) : {};\n"
            } else {
                script += "var \(param) = {};\n"
            }
        }
        script += kept.joined(separator: ";\n")

        return Extracted(script: script, candidates: candidates)
    }

    /// EJS 的 alr/yes 标记：形如 `X.y("alr","yes")` 的调用。
    static func markerRange(in statement: String) -> Range<String.Index>? {
        statement.range(of: #"\(\s*["']alr["']\s*,\s*["']yes["']\s*\)"#, options: .regularExpression)
    }

    /// 定义类语句判定（EJS modifyPlayer 过滤的正则近似）：
    /// 保留声明、控制流与赋值语句，丢弃裸调用等立即执行的运行时语句。
    /// 赋值左值可以是任意成员链（含计算成员，如 `g.sB[Q[2]][Q[3]]=...`，
    /// 这正是 URL 类 prototype.set 的定义处，漏掉会直接导致求解失败）。
    static func isDefinition(_ statement: String) -> Bool {
        if statement.range(
            of: #"^(?:function\b|var\b|let\b|const\b|class\b|if\b|for\b|while\b|switch\b|try\b|return\b)"#,
            options: .regularExpression) != nil {
            return true
        }
        // 字符串字面量语句（"use strict" 等）
        if statement.range(of: #"^["']"#, options: .regularExpression) != nil { return true }
        return isMemberAssignment(statement)
    }

    /// 判断语句是否为成员/标识符赋值：`ident (.name | [...] 任意交替) = value`。
    /// 纯标量扫描以正确处理嵌套方括号（如 `g.sB[Q[2]][Q[3]]`）。
    static func isMemberAssignment(_ statement: String) -> Bool {
        let scalars = Array(statement.unicodeScalars)
        guard let first = scalars.first else { return false }
        let isIdentStart = (first >= "a" && first <= "z") || (first >= "A" && first <= "Z") || first == "_" || first == "$"
        guard isIdentStart else { return false }

        var i = 0
        let n = scalars.count
        // 首个标识符（this 也匹配）
        while i < n {
            let c = scalars[i]
            if (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "$" {
                i += 1
            } else { break }
        }
        // 成员链：.name 或 [平衡括号]
        while i < n {
            if scalars[i] == "." {
                i += 1
                guard i < n else { return false }
                let c = scalars[i]
                guard (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || c == "_" || c == "$" else { return false }
                while i < n {
                    let w = scalars[i]
                    if (w >= "a" && w <= "z") || (w >= "A" && w <= "Z") || (w >= "0" && w <= "9") || w == "_" || w == "$" {
                        i += 1
                    } else { break }
                }
            } else if scalars[i] == "[" {
                var depth = 0
                var inString: Unicode.Scalar? = nil
                while i < n {
                    let c = scalars[i]
                    if let delim = inString {
                        if c == "\\" { i += 1 }
                        else if c == delim { inString = nil }
                    } else if c == "'" || c == "\"" || c == "`" {
                        inString = c
                    } else if c == "[" {
                        depth += 1
                    } else if c == "]" {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    i += 1
                }
                guard depth == 0 else { return false }
            } else { break }
        }
        // 必须紧跟 `=`，且不是 ==/=>/复合赋值
        guard i < n, scalars[i] == "=" else { return false }
        if i + 1 < n, scalars[i + 1] == "=" { return false }
        if i > 0 {
            let prev = scalars[i - 1]
            if "+-*/%&|^<>!".contains(String(prev)) { return false }
        }
        return true
    }

    /// 从定义语句提取可调用名：`function X(` 或 `PATH=function`。
    static func candidateName(in statement: String) -> String? {
        for pattern in [
            #"^function\s*\*?\s*([A-Za-z_$][\w$]*)"#,
            #"^([A-Za-z_$][A-Za-z0-9_$.]*)\s*=\s*function\b"#,
        ] {
            if let groups = RegexKit.firstMatch(pattern: pattern, in: statement), let name = groups.last {
                return name
            }
        }
        return nil
    }

    /// 识别 `(function(g){...})(args)` 形态，返回 {形参名, 函数体}。
    ///
    /// 函数体内大量正则字面量会使括号配对失准，因此采用尾部锚点：
    /// 以 `})(实参)` 结尾定位函数体右边界，左边界取参数列表后的第一个 `{`。
    static func iifeBody(of statement: String) -> (param: String?, body: String)? {
        guard let head = RegexKit.firstMatch(
            pattern: #"^\(\s*function\s*\*?\s*\(\s*([A-Za-z_$][\w$]*)?\s*\)"#, in: statement)
        else { return nil }
        let param = head.count >= 2 ? head[1] : nil

        // 尾部锚点：...})(arg); 结束（$ 锚定，首次命中即尾部）
        guard let tail = statement.range(
            of: #"\}\s*\)\s*\(\s*[A-Za-z_$][\w$]*\s*\)\s*;?\s*$"#,
            options: .regularExpression) else { return nil }

        // 左边界：参数列表后第一个 '{'
        let scalars = Array(statement.unicodeScalars)
        let headEndScalar = head[0].endIndex.samePosition(in: statement.unicodeScalars)
            ?? statement.unicodeScalars.startIndex
        var i = statement.unicodeScalars.distance(from: statement.unicodeScalars.startIndex, to: headEndScalar)
        let n = scalars.count
        while i < n, scalars[i] != "{" { i += 1 }
        guard i < n else { return nil }
        let bodyStart = i + 1

        guard let tailStartScalar = tail.lowerBound.samePosition(in: statement.unicodeScalars) else { return nil }
        let bodyEnd = statement.unicodeScalars.distance(from: statement.unicodeScalars.startIndex, to: tailStartScalar)
        guard bodyStart < bodyEnd else { return nil }
        let body = String(String.UnicodeScalarView(scalars[bodyStart..<bodyEnd]))
        return (param, body)
    }

    /// IIFE 尾部实参：`(g)(_yt_player)` → `_yt_player`。
    static func iifeArgument(of statement: String) -> String? {
        RegexKit.firstMatch(pattern: #"\)\s*\(\s*([A-Za-z_$][\w$]*)\s*\)\s*;?\s*$"#, in: statement)?.last
    }

    // MARK: - 求解

    /// 求解通道：n（节流解除）或 sig（签名 decipher）。
    enum Channel {
        case n
        case sig
    }

    /// 批量求解：一次求值解一组输入（避免每条 URL 重新执行 2.6MB 脚本）。
    /// 返回 输入 → 结果 的映射；单个输入失败会记录在错误里但不影响其他输入，
    /// 全部失败才抛错（调用方可回退旧协议）。
    static func solveBatch(
        _ extracted: Extracted, channel: Channel, inputs: [String], js: JSRuntime
    ) throws -> [String: String] {
        guard !inputs.isEmpty else { return [:] }
        let candidateArray = extracted.candidates
            .map { jsStringLiteral($0) }
            .joined(separator: ",")
        let inputArray = inputs.map { jsStringLiteral($0) }.joined(separator: ",")
        // n 通道：sig 位传 undefined，input 写入 n；sig 通道相反（对齐 EJS
        // makeSolver 对 ({sig, n}) 的单通道调用约定）。
        let sigExpr = channel == .sig ? "encodeURIComponent(inputs[i])" : "undefined"
        let nExpr = channel == .n ? "inputs[i]" : "undefined"
        let resultKey = channel == .sig ? "sig" : "n"

        let solver = """
        (function () {
          var cands = [\(candidateArray)];
          var inputs = [\(inputArray)];
          var out = {};
          var errors = [];
          for (var i = 0; i < inputs.length; i++) {
            var results = new Set();
            for (var c = 0; c < cands.length; c++) {
              try {
                var fn = (new Function("return " + cands[c]))();
                var url = fn("https://www.youtube.com/watch?v=yt-dlp-wins", "s", \(sigExpr));
                url.set("n", \(nExpr));
                var proto = Object.getPrototypeOf(url);
                var keys = Object.keys(proto).concat(Object.getOwnPropertyNames(proto));
                for (var j = 0; j < keys.length; j++) {
                  if (["constructor", "set", "get", "clone"].indexOf(keys[j]) === -1) { url[keys[j]](); break; }
                }
                var s = url.get("s");
                var nOut = url.get("n");
                results.add(JSON.stringify({
                  sig: s ? decodeURIComponent(s) : null,
                  n: nOut === null || nOut === undefined ? null : String(nOut)
                }));
              } catch (e) { errors.push(inputs[i].slice(0, 12) + ": " + String(e)); }
            }
            if (results.size === 1) {
              var obj = JSON.parse(results.values().next().value);
              if (obj.\(resultKey) !== null) out[inputs[i]] = obj.\(resultKey);
            } else if (results.size > 1) {
              throw "modern challenge: ambiguous solutions for " + inputs[i].slice(0, 12);
            }
          }
          var solved = Object.keys(out).length;
          if (solved === 0) throw "modern challenge: no solutions: " + errors.join(" | ");
          return JSON.stringify({ out: out, partial: solved < inputs.length, errors: errors });
        })()
        """

        var stubs = JSShims.browserStubs
        stubs["xmlhttp"] = #"var XMLHttpRequest = { prototype: {} };"#

        let raw = try js.evaluate(code: extracted.script, globalStubs: stubs, expression: solver)
        guard let data = raw.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let out = obj["out"] as? [String: String] else {
            throw ExtractionError.jsFailure("现代挑战求解输出解析失败: \(raw.prefix(200))")
        }
        return out
    }

    /// 单输入便捷接口（测试用）。
    static func solve(
        _ extracted: Extracted, n: String?, sig: String?, js: JSRuntime
    ) throws -> (n: String?, sig: String?) {
        var outN: String?
        var outSig: String?
        if let n {
            outN = try solveBatch(extracted, channel: .n, inputs: [n], js: js)[n]
        }
        if let sig {
            outSig = try solveBatch(extracted, channel: .sig, inputs: [sig], js: js)[sig]
        }
        return (outN, outSig)
    }
}

/// JS 顶层语句分割器：按深度 0 的 `;` 切分，正确处理字符串、模板字面量
/// （含 ${} 插值）、正则字面量与注释。用于把 2-3MB 的 base.js 拆成可
/// 过滤的语句粒度。已用 EJS golden player 验证：干净切出
/// `var _yt_player={}` 与主 IIFE 两条语句。
enum JSSplitter {

    static func topLevelStatements(in source: String) -> [String] {
        var scalars = Array(source.unicodeScalars)
        guard !scalars.isEmpty else { return [] }
        scalars.append(" ")  // 哨兵，简化边界

        var statements: [String] = []
        var current: [Unicode.Scalar] = []
        current.reserveCapacity(4096)

        var depth = 0
        var lastWord = ""
        var prev: Unicode.Scalar = " "
        var i = 0
        let n = scalars.count

        // 模板插值栈：记录进入 ${ 时的 depth，遇到配对 } 退回字符串态
        var templateStack: [Int] = []
        var stringDelim: Unicode.Scalar? = nil
        var escaped = false

        func isWord(_ c: Unicode.Scalar) -> Bool {
            (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "_" || c == "$"
        }

        while i < n {
            let c = scalars[i]

            if let delim = stringDelim {
                current.append(c)
                if escaped { escaped = false }
                else if c == "\\" { escaped = true }
                else if delim == "`" && c == "$" && i + 1 < n && scalars[i + 1] == "{" {
                    // 进入 ${ 插值：连同 `{` 一起消费，深度 +1；
                    // 插值内的配对 `}` 使 depth-1 回到栈顶时即插值结束
                    templateStack.append(depth)
                    depth += 1
                    current.append("{")
                    stringDelim = nil
                    prev = "{"
                    i += 2
                    continue
                } else if c == delim { stringDelim = nil }
                prev = c
                i += 1
                continue
            }

            if !templateStack.isEmpty, c == "}", depth - 1 == templateStack.last! {
                depth -= 1
                templateStack.removeLast()
                current.append(c)
                stringDelim = "`"
                escaped = false
                prev = "`"
                i += 1
                continue
            }

            if c == "'" || c == "\"" || c == "`" {
                stringDelim = c
                escaped = false
                current.append(c)
                prev = c
                i += 1
                continue
            }

            if c == "/" && i + 1 < n && scalars[i + 1] == "/" {
                while i < n && scalars[i] != "\n" { current.append(scalars[i]); i += 1 }
                continue
            }
            if c == "/" && i + 1 < n && scalars[i + 1] == "*" {
                current.append(scalars[i]); current.append(scalars[i + 1]); i += 2
                while i + 1 < n && !(scalars[i] == "*" && scalars[i + 1] == "/") {
                    current.append(scalars[i]); i += 1
                }
                if i + 1 < n { current.append(scalars[i]); current.append(scalars[i + 1]) }
                i += 2
                prev = " "
                continue
            }

            // 正则字面量判定：前一个有效字符决定 `/` 是除法还是正则开头
            if c == "/" {
                let afterKeyword = JSKeywords.all.contains(lastWord)
                let divisionPossible = isWord(prev) || prev == ")" || prev == "]"
                    || prev == "\"" || prev == "'" || prev == "`"
                if afterKeyword || !divisionPossible {
                    var j = i + 1
                    var inClass = false
                    var regexEscaped = false
                    while j < n {
                        let rc = scalars[j]
                        if regexEscaped { regexEscaped = false }
                        else if rc == "\\" { regexEscaped = true }
                        else if rc == "[" { inClass = true }
                        else if rc == "]" { inClass = false }
                        else if rc == "/" && !inClass { break }
                        else if rc == "\n" { break }
                        j += 1
                    }
                    for k in i...min(j, n - 1) { current.append(scalars[k]) }
                    prev = "/"
                    lastWord = ""
                    i = j + 1
                    continue
                }
            }

            if c == "(" || c == "[" || c == "{" { depth += 1 }
            else if c == ")" || c == "]" || c == "}" { depth -= 1 }

            if c == ";" && depth == 0 {
                statements.append(String(String.UnicodeScalarView(current)).trimmingCharacters(in: .whitespacesAndNewlines))
                current.removeAll(keepingCapacity: true)
                prev = ";"
                lastWord = ""
                i += 1
                continue
            }

            if isWord(c) {
                lastWord = isWord(prev) ? lastWord + String(c) : String(c)
            } else {
                lastWord = ""
            }

            current.append(c)
            prev = c
            i += 1
        }

        let tail = String(String.UnicodeScalarView(current)).trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty { statements.append(tail) }
        return statements.filter { !$0.isEmpty }
    }
}

private enum JSKeywords {
    static let all: Set<String> = [
        "return", "typeof", "instanceof", "in", "of", "new", "delete", "void",
        "do", "else", "yield", "await", "case", "throw",
    ]
}
