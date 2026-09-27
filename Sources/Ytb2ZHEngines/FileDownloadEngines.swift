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

// MARK: - 智能下载引擎：http(s) → yt-dlp，本地路径 → 文件导入

public struct SmartDownloadEngine: DownloadEngine {
    public let descriptor = EngineDescriptor(
        "auto", "智能（自动识别）", "http 走 yt-dlp，本地路径直接导入")

    public init() {}

    public func download(url: String, to dest: URL, options: DownloadOptions,
                         progress: @Sendable @escaping (Double, String?) -> Void) async throws -> URL {
        let lower = url.lowercased()
        if lower.hasPrefix("http://") || lower.hasPrefix("https://") {
            return try await YtDlpDownloadEngine().download(url: url, to: dest, options: options, progress: progress)
        }
        return try await FileImportEngine().download(url: url, to: dest, options: options, progress: progress)
    }
}
