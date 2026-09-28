import XCTest
@testable import Videx

final class WBISignerTests: XCTestCase {
    /// golden 值由独立 Python 实现按官方算法交叉验证生成。
    func testMixinKey() {
        let mixin = WBISigner.mixinKey(
            imgKey: "7cd084941338484aae1ad9425b84077c",
            subKey: "4932cab0ddb7986faeb9d0a51b1f9d45"
        )
        XCTAssertEqual(mixin, "6f1d0124ab3c1082474e93ba70404bd8")
        XCTAssertEqual(mixin.count, 32)
    }

    func testSignedParams() {
        let signed = WBISigner.signedParams(
            ["foo": "one", "bar": "two", "baz": "three'"],
            mixinKey: "6f1d0124ab3c1082474e93ba70404bd8",
            timestamp: 1702204800
        )
        XCTAssertEqual(signed["wts"], "1702204800")
        // value 中的 ' 应被过滤
        XCTAssertEqual(signed["baz"], "three")
        XCTAssertEqual(signed["w_rid"], "f056ee155f0eed99911d880659938594")
    }

    func testKeyFromImageURL() {
        XCTAssertEqual(
            WBISigner.keyFromImageURL("https://i0.hdslb.com/bfs/wbi/7cd084941338484aae1ad9425b84077c.png"),
            "7cd084941338484aae1ad9425b84077c"
        )
        XCTAssertNil(WBISigner.keyFromImageURL("nokey"))
    }
}
