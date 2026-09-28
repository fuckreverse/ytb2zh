import XCTest
@testable import Videx

final class ChallengeTests: XCTestCase {
    let runtime = JavaScriptCoreRuntime()

    /// 仿真实 base.js 结构的合成挑战：
    /// - decipher：var 助手对象 + 具名函数赋值 + set("signature", FN(x)) 调用点
    /// - nsig：set("n", NF(x)) 调用点
    static let fakeBaseJS = """
    (function(){ 'use strict';
      var lW = {
        Jk: function(a) { a.reverse(); },
        Sw: function(a, b) { var c = a[0]; a[0] = a[b % a.length]; a[b % a.length] = c; },
        Xz: function(a, b) { a.splice(0, b); }
      };
      // 模拟混淆调用点
      var c = "aabbcc"; d.set("signature", Dda(c));
      var e = "12345"; f.set("n", Efb(e));
      Dda = function(a) { var b = a.split(""); lW.Jk(b); lW.Sw(b, 3); lW.Xz(b, 1); return b.join(""); };
      var gArr = [9, 8, 7];
      Efb = function(h) { var t = h.split(""); t.forEach(function(ch, i){ t[i] = String.fromCharCode(ch.charCodeAt(0) ^ gArr[i % 3]); }); return t.join(""); };
    })();
    """

    // 手工推导期望值：
    // decipher("aabbcc"): split → reverse "ccbbaa" → Sw(b,3) 交换首尾索引3: "bcbcaa" → Xz 移除前1: "cbcaa"
    // nsig("12345"): '1'^9=8? '1'(49)^9=56='8'; '2'(50)^8=58=':'; '3'(51)^7=52='4'; '4'^9=61; '5'^8=61 → 手工另算不依赖此注释

    func testExtractAndDecipher() throws {
        let challenge = PlayerChallenge.extract(from: Self.fakeBaseJS)
        XCTAssertNotNil(challenge, "挑战提取失败")
        XCTAssertEqual(challenge?.decipherFunctionName, "Dda")
        XCTAssertNotNil(challenge?.nsigFunctionName)

        let result = try challenge!.decipher("aabbcc", js: runtime)
        XCTAssertEqual(result, "cbcaa", "decipher 结果不符")
    }

    func testNsigSolve() throws {
        let challenge = try XCTUnwrap(PlayerChallenge.extract(from: Self.fakeBaseJS))
        // 独立计算：'1'^9='8', '2'^8=':', '3'^7='4', '4'^9='=', '5'^8='='
        let solved = try challenge.solveNsig("12345", js: runtime)
        XCTAssertEqual(solved, "8:4==")
    }

    func testBraceMatcherSkipsStringsAndComments() {
        let js = """
        var obj = { a: "}{", b: '//{}', c: `template ${ { x: 1 } }` };
        function target(p) { return p + "}}"; }
        var after = 1;
        """
        let fn = BraceMatcher.function(named: "target", in: js)
        XCTAssertNotNil(fn)
        XCTAssertTrue(fn!.contains("return p +"))
        XCTAssertFalse(fn!.contains("var after"))
        let obj = BraceMatcher.globalValue(named: "obj", in: js)
        XCTAssertNotNil(obj)
    }

    func testBraceMatcherFunctionAssignmentForm() {
        let js = "var qT = function(a) { var b = a.split(\"\"); return b.join(\"\"); }; var rest = { v: 1 };"
        let fn = BraceMatcher.function(named: "qT", in: js)
        XCTAssertNotNil(fn)
        XCTAssertTrue(fn!.contains("a.split"))
    }

    func testDecipherFailureThrows() throws {
        let challenge = PlayerChallenge(script: "var x = 1;", decipherFunctionName: nil, nsigFunctionName: nil, modern: nil, memo: SolutionMemo())
        XCTAssertThrowsError(try challenge.decipher("abc", js: runtime))
    }

    func testExtractionOnGarbageReturnsNil() {
        XCTAssertNil(PlayerChallenge.extract(from: "var a = 1; function unrelated() { return 2; }"))
    }
}
