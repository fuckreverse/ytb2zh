import Foundation
import Videx

// MARK: - yt-dlp 按需安装器
//
// 默认零 yt-dlp 依赖：应用不捆绑二进制，Videx 原生提取优先。
// 仅当内置提取失败（或用户显式选用 yt-dlp 引擎）时，才从官方
// GitHub Releases 下载独立二进制到 ~/.ytb2zh/bin/ 并切换使用。

public enum YtDlpInstaller {

    /// 官方 macOS 通用二进制（latest 重定向到当前版本）
    public static let downloadURL = URL(string:
        "https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos")!

    /// 用户缓存安装路径（跨 App bundle 更新保留）
    public static var installPath: String { NSHomeDirectory() + "/.ytb2zh/bin/yt-dlp_macos" }

    /// 当前是否已有可用的 yt-dlp（缓存目录或 PATH），不发网络请求
    public static var availablePath: String? {
        if FileManager.default.isExecutableFile(atPath: installPath) { return installPath }
        return SidecarPaths.which("yt-dlp")
    }

    /// 确保二进制就绪：已安装则直接返回路径；否则下载（走代理）并 chmod。
    public static func ensureInstalled(proxy: String = "",
                                       progress: (@Sendable (String) -> Void)? = nil) async throws -> String {
        if let existing = availablePath { return existing }
        progress?("内置提取不可用，下载 yt-dlp 备用引擎…")
        // 二进制约 30-40MB，弱代理链路实测可达 10 分钟以上：专用长超时客户端
        // （request 600s 空闲上限 + resource 2400s 总时长上限）
        let client = URLSessionHTTPClient(proxy: proxy.isEmpty ? nil : proxy, timeout: 600)
        let response = try await client.fetch(.get(downloadURL))
        guard response.isOK, response.body.count > 1_000_000 else {
            throw EngineError.engineFailure(
                "yt-dlp 备用引擎下载失败：HTTP \(response.status)（\(response.body.count) 字节）")
        }

        let fm = FileManager.default
        let binDir = (installPath as NSString).deletingLastPathComponent
        try fm.createDirectory(atPath: binDir, withIntermediateDirectories: true)
        let tmp = binDir + "/.yt-dlp_macos.\(UUID().uuidString).tmp"
        try response.body.write(to: URL(fileURLWithPath: tmp))
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tmp)
        // 原子替换：下载中断/并发安装都不会留下半截可执行文件
        _ = try? fm.removeItem(atPath: installPath)
        try fm.moveItem(atPath: tmp, toPath: installPath)
        progress?("yt-dlp 就绪：\(installPath)")
        return installPath
    }

    /// 同步版：供同步调用点（VideoInfoService / OrigStreamService / VideoCatalogService）。
    /// 调用方应处于后台线程。
    public static func ensureInstalledSync(proxy: String = "") throws -> String {
        if let existing = availablePath { return existing }
        // Swift 6 严格并发：detached 闭包不能捕获 var 局部变量，用 Mutex 包装
        let result = Mutex<Result<String, Error>?>(nil)
        let semaphore = DispatchSemaphore(value: 0)
        Task.detached {
            let r: Result<String, Error>
            do { r = .success(try await ensureInstalled(proxy: proxy)) }
            catch { r = .failure(error) }
            result.with { $0 = r }
            semaphore.signal()
        }
        semaphore.wait()
        return try result.wrapped!.get()
    }
}
