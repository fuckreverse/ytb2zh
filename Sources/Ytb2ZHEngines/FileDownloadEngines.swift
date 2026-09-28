import Foundation
import Ytb2ZHCore

// MARK: - 本地文件导入引擎（url 为本地路径或 file:// URL）

public struct FileImportEngine: DownloadEngine {
    public let descriptor = EngineDescriptor(
        "file", "本地文件导入", "直接使用本地视频/音频文件，不联网")

    public init() {}

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let src: URL
        if url.hasPrefix("file://"), let u = URL(string: url) {
            src = u
        } else {
            src = URL(fileURLWithPath: (url as NSString).expandingTildeInPath)
        }
        guard FileManager.default.fileExists(atPath: src.path) else {
            throw EngineError.engineFailure("本地文件不存在：\(src.path)")
        }
        progress(0.3, "导入 \(src.lastPathComponent)")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.copyItem(at: src, to: dest)
        progress(1.0, "导入完成")
        return dest
    }
}

// MARK: - 智能下载引擎：Videx 原生优先（YouTube/B站/抖音/TikTok），
// 内置提取失败时才按需下载 yt-dlp 兑底（其余站点/HLS 场景），本地路径直接导入

public struct SmartDownloadEngine: DownloadEngine {
    public let descriptor = EngineDescriptor(
        "auto", "智能（自动识别）", "Videx 原生优先，内置提取失败时按需下载 yt-dlp 兑底，本地路径直接导入")

    public init() {}

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let lower = url.lowercased()
        guard lower.hasPrefix("http://") || lower.hasPrefix("https://") else {
            return try await FileImportEngine().download(url: url, to: dest, options: options, progress: progress)
        }
        if VidexBridge.canHandle(url) {
            do {
                return try await VidexDownloadEngine().download(
                    url: url, to: dest, options: options, progress: progress)
            } catch {
                // 内置提取失败才允许动用 yt-dlp：按需下载（已装则跳过）后切换使用
                do {
                    try await YtDlpInstaller.ensureInstalled(proxy: options.proxy) { msg in
                        progress(0.0, msg)
                    }
                } catch {
                    throw error  // 下载失败时抛 Videx 原生错误，避免混淆主因
                }
                progress(0.0, "Videx 失败（\(String(describing: error.localizedDescription).prefix(60))），切换 yt-dlp 兑底")
            }
        }
        return try await YtDlpDownloadEngine().download(url: url, to: dest, options: options, progress: progress)
    }
}
