import XCTest
@testable import Videx

/// 现代版挑战（URL 变换协议 + alr/yes 标记）的离线验证。
///
/// golden 数据来自 yt-dlp/ejs 仓库 tests.ts（player 74edf1a3，STS 20522）。
/// fixture：EJS 同款 golden base.js（2.6MB，与仓库内 Fixtures/ 保持一致）。
final class ModernChallengeTests: XCTestCase {
    let runtime = JavaScriptCoreRuntime()

    static func loadFixture() throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/youtube_golden_player_74edf1a3.js")
        return try String(contentsOf: url, encoding: .utf8)
    }
    static let nGoldens: [(input: String, expected: String)] = [
        ("IlLiA21ny7gqA2m4p37", "9nRTxrbM1f0yHg"),
        ("eabGFpsUKuWHXGh6FR4", "izmYqDEY6kl7Sg"),
        ("eabGF/ps%UK=uWHXGh6FR4", "LACmqlhaBpiPlgE-a"),
    ]
    /// EJS tests.ts 中 player 74edf1a3 的 sig 向量（共 2 条；
    /// 第二条为控制字符序列，用于覆盖转义路径）。
    static let sigGoldens: [(input: String, expected: String)] = [
        (
            "NJAJEij0EwRgIhAI0KExTgjfPk-MPM9MAdzyyPRt=BM8-XO5tm5hlMCSVpAiEAv7eP3CURqZNSPow8BXXAoazVoXgeMP7gH9BdylHCwgw=gwzz",
            "NJAJEij0EwRgIhAI0KExTgjfPk-MPM9MAdzyyPRt=BM8-XO5tm5hzMCSVpAiEAv7eP3CURqZNSPow8BXXAoazVoXgeMP7gH9BdylHCwgw=gwzl"
        ),
        (
            ModernChallengeTests.controlSeq([0x00, 0x01, 0x02, 0x25, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                             0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
                             0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
                             0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
                             0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49]),
            ModernChallengeTests.controlSeq([0x00, 0x01, 0x02, 0x25, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08, 0x09,
                             0x10, 0x11, 0x12, 0x13, 0x14, 0x15, 0x16, 0x17, 0x18, 0x19,
                             0x20, 0x21, 0x22, 0x23, 0x24, 0x25, 0x26, 0x27, 0x28, 0x29,
                             0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39,
                             0x40, 0x41, 0x42, 0x49, 0x44, 0x45, 0x46, 0x47, 0x48, 0x43])
        ),
    ]

    static func controlSeq(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self)
    }

    func loadFixture() throws -> String {
        try Self.loadFixture()
    }

    func testSplitSynthetic() {
        // 正则字面量 / 模板插值不干扰切分
        let js = """
        var a = { re: /x;{1,2}/g, tpl: `a${b}c` };
        callit(";");
        var d = 2;
        """
        let statements = JSSplitter.topLevelStatements(in: js)
        XCTAssertEqual(statements.count, 3, "切分错误: \(statements)")
    }

    func testGoldenExtract() throws {
        let source = try loadFixture()
        let extracted = ModernChallenge.extract(from: source)
        XCTAssertNotNil(extracted, "现代挑战提取失败")
        XCTAssertEqual(extracted?.candidates.count, 4, "候选数不符: \(extracted?.candidates ?? [])")
    }

    func testGoldenNsig() throws {
        let source = try loadFixture()
        let extracted = try XCTUnwrap(ModernChallenge.extract(from: source))
        for golden in Self.nGoldens {
            let result = try ModernChallenge.solve(extracted, n: golden.input, sig: nil, js: runtime)
            XCTAssertEqual(result.n, golden.expected, "nsig golden 不符: \(golden.input)")
            XCTAssertNil(result.sig)
        }
    }

    func testGoldenSig() throws {
        let source = try loadFixture()
        let extracted = try XCTUnwrap(ModernChallenge.extract(from: source))
        for golden in Self.sigGoldens {
            let result = try ModernChallenge.solve(extracted, n: nil, sig: golden.input, js: runtime)
            XCTAssertEqual(result.sig, golden.expected, "sig golden 不符")
            XCTAssertNil(result.n)
        }
    }

    func testGoldenCombined() throws {
        let source = try loadFixture()
        let extracted = try XCTUnwrap(ModernChallenge.extract(from: source))
        let result = try ModernChallenge.solve(
            extracted, n: "IlLiA21ny7gqA2m4p37",
            sig: Self.sigGoldens[0].input, js: runtime)
        XCTAssertEqual(result.n, "9nRTxrbM1f0yHg")
        XCTAssertEqual(result.sig, Self.sigGoldens[0].expected)
    }
}
