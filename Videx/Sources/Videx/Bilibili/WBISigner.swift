import Foundation
import CryptoKit

/// B 站 WBI 签名（w_rid）。
///
/// 算法（来自公开的 bilibili-API-collect 文档）：
/// 1. nav 接口取 img_key / sub_key（URL 文件名部分）；
/// 2. 按 mixinKeyEncTab 置换拼接取前 32 位得 mixin_key；
/// 3. 参数加 wts=当前秒级时间戳，过滤 value 中 !'()* 字符，
///    按 key 字典序排序 urlencode，md5(query + mixin_key) 即 w_rid。
public enum WBISigner {
    /// 固定置换表（官方文档值，极少变动）。
    public static let mixinKeyEncTab: [Int] = [
        46, 47, 18, 2, 53, 8, 23, 32, 15, 50, 10, 31, 58, 3, 45, 35, 27, 43, 5, 49,
        33, 9, 42, 19, 29, 28, 14, 39, 12, 38, 41, 13, 37, 48, 7, 16, 24, 55, 40,
        61, 26, 17, 0, 1, 60, 51, 30, 4, 22, 25, 54, 21, 56, 59, 6, 63, 57, 62, 11,
        36, 20, 34, 44, 52,
    ]

    /// img_url/sub_url 文件名 → 原始 key。
    public static func keyFromImageURL(_ url: String) -> String? {
        let filename = url.split(separator: "/").last.map(String.init) ?? url
        guard filename.contains("."), filename.count > 4 else { return nil }
        return String(filename.split(separator: ".").first ?? "")
    }

    /// 原始 key 对 → mixin key（32 位）。
    public static func mixinKey(imgKey: String, subKey: String) -> String {
        let combined = imgKey + subKey
        return mixinKeyEncTab.prefix(32).compactMap { i in
            i < combined.count ? Array(combined)[i] : nil
        }.map(String.init).joined()
    }

    /// 对参数签名，返回包含 wts 与 w_rid 的完整参数表。
    public static func signedParams(
        _ params: [String: String],
        mixinKey: String,
        timestamp: Int
    ) -> [String: String] {
        var signed = params
        signed["wts"] = String(timestamp)
        // 过滤 value 中的 !'()*（官方文档要求）
        let filtered = signed.mapValues { value in
            String(value.filter { !"!'()*".contains($0) })
        }
        let query = QueryString.encode(filtered)
        var result = filtered
        result["w_rid"] = md5Hex(query + mixinKey)
        return result
    }

    static func md5Hex(_ string: String) -> String {
        Insecure.MD5.hash(data: Data(string.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
