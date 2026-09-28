// 提取逻辑部分参考/移植自 yt-dlp（Unlicense，公有领域）。
import Foundation
import CryptoKit

/// TikTok 网页 WAF 挑战求解（2026 版，纯原生 PoW，无需 JS 引擎）。
///
/// 挑战页形如：
///   <p id="wci" class="_wafchallengeid">      ← 需要写入的 cookie 名
///   <p id="cs"  class="<base64 挑战数据>">     ← {"v":{"a","b","c"},"s"}
///   <p id="rci" class="waforiginalreid">      ← 可选的第二 cookie 名
///   <p id="rs"  class="<值>">                 ← 第二 cookie 的值
///
/// 求解：expected = b64(v.c)；base = sha256(b64(v.a))；
/// 从 1 开始枚举 i，找到 sha256(base || str(i)) == expected，
/// 把 d = b64(str(i)) 写回 JSON，整体再 base64 作为 cookie 值。
public enum WAFChallenge {

    public struct Solution: Equatable, Sendable {
        /// cookie 名 → 值（写入 .tiktok.com 域）。
        public var cookies: [String: String]
    }

    /// 从挑战页 HTML 提取并求解。不是挑战页（可能直接成功）返回 nil。
    public static func solve(fromHTML html: String) throws -> Solution? {
        guard let data = attribute(of: "cs", in: html), !data.isEmpty else {
            // 无 cs 元素：若也不是正常页面（如 "Please wait..."），报告异常
            if html.contains("Please wait...") {
                throw ExtractionError.siteError(site: "tiktok", code: 403, reason: "WAF 挑战页缺少 cs 数据，无法求解")
            }
            return nil
        }

        // base64 宽容解码（服务端可能截断了 padding）
        guard let payload = lenientBase64Decode(data),
              let jsonAny = try? JSONSerialization.jsonObject(with: payload),
              let json = jsonAny as? [String: Any],
              let v = json["v"] as? [String: Any],
              let challenge = v["c"] as? String,
              let baseSeed = v["a"] as? String,
              let expected = lenientBase64Decode(challenge),
              let seed = lenientBase64Decode(baseSeed)
        else {
            throw ExtractionError.siteError(site: "tiktok", code: 403, reason: "WAF 挑战数据解码失败")
        }

        // PoW：sha256(seed || str(i)) == expected
        guard let proof = powProof(seed: seed, expected: expected) else {
            throw ExtractionError.siteError(site: "tiktok", code: 403, reason: "WAF 挑战求解失败（2_000_000 次内未命中）")
        }

        // 组装 cookie JSON：原数据 + d 字段
        var object = json
        object["d"] = Data(proof.utf8).base64EncodedString()
        guard let cookiePayload = try? JSONSerialization.data(withJSONObject: object) else {
            throw ExtractionError.siteError(site: "tiktok", code: 403, reason: "WAF 挑战结果序列化失败")
        }
        let cookieValue = cookiePayload.base64EncodedString()

        var cookies: [String: String] = [:]
        if let name = attribute(of: "wci", in: html), !name.isEmpty {
            cookies[name] = cookieValue
        } else {
            cookies["_wafchallengeid"] = cookieValue
        }
        // 可选的第二组（rci/rs）
        if let rciName = attribute(of: "rci", in: html), !rciName.isEmpty,
           let rsValue = attribute(of: "rs", in: html), !rsValue.isEmpty {
            cookies[rciName] = rsValue
        }
        return Solution(cookies: cookies)
    }

    // MARK: - 内部

    /// sha256 工作量证明；上限 200 万次（实测通常几十次内命中）。
    static func powProof(seed: Data, expected: Data) -> String? {
        for i in 1...2_000_000 {
            let number = String(i)
            var hasher = SHA256()
            hasher.update(data: seed)
            hasher.update(data: Data(number.utf8))
            if Data(hasher.finalize()) == expected {
                return number
            }
        }
        return nil
    }

    /// 提取 <p id="X" class="..."> 的 class 属性值。
    static func attribute(of id: String, in html: String) -> String? {
        guard let groups = RegexKit.firstMatch(
            pattern: #"<p[^>]+id="\#(id)"[^>]*class="([^"]*)""#, in: html),
            groups.count > 1
        else { return nil }
        return groups[1]
    }

    /// 容错 base64：补齐 padding 后解码。
    static func lenientBase64Decode(_ string: String) -> Data? {
        var value = string
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
            .replacingOccurrences(of: " ", with: "")
        let remainder = value.count % 4
        if remainder > 0 {
            value += String(repeating: "=", count: 4 - remainder)
        }
        return Data(base64Encoded: value)
    }
}
