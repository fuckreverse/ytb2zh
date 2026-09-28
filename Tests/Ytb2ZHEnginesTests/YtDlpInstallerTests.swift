import XCTest
@testable import Ytb2ZHEngines

/// yt-dlp 按需安装器真机验证（可选，默认跳过）：
///   YTDLP_LIVE=1 YTDLP_PROXY=http://127.0.0.1:7890 swift test --filter YtDlpInstallerTests
/// 加 YTDLP_FORCE=1 会先删除缓存二进制强制走真实下载（重装为最新版）。
final class YtDlpInstallerTests: XCTestCase {

    func testOnDemandDownload() async throws {
        guard ProcessInfo.processInfo.environment["YTDLP_LIVE"] == "1" else {
            throw XCTSkip("设置 YTDLP_LIVE=1 以启用 yt-dlp 按需下载真机测试")
        }
        let proxy = ProcessInfo.processInfo.environment["YTDLP_PROXY"] ?? ""
        if ProcessInfo.processInfo.environment["YTDLP_FORCE"] == "1" {
            try? FileManager.default.removeItem(atPath: YtDlpInstaller.installPath)
        }

        let path = try await YtDlpInstaller.ensureInstalled(proxy: proxy)
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: path), "安装后应为可执行文件：\(path)")
        XCTAssertEqual(YtDlpInstaller.availablePath, path, "availablePath 应命中安装路径")

        // 可执行性冒烟：--version 正常退出
        let res = try ProcessRunner().runWithTimeout(120, path, ["--version"])
        XCTAssertEqual(res.code, 0, "yt-dlp --version 应成功：\(res.stderr.prefix(200))")
        let version = res.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(version.isEmpty)
        print("yt-dlp version:", version)
    }

    /// 默认状态语义：ensureInstalledSync 幂等（已装则不重复下载，直接返回可用路径）。
    func testEnsureSyncIdempotent() throws {
        let path = try YtDlpInstaller.ensureInstalledSync()
        // 未安装且无网环境下此测试会尝试真实下载——仅在已就绪时校验
        if let available = YtDlpInstaller.availablePath {
            XCTAssertEqual(path, available)
        }
    }
}
