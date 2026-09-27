import Foundation
import Ytb2ZHCore

// MARK: - 媒体兼容性：AVPlayer 原生可播性判定与转码兜底
// yt-dlp 可能产出 webm/mkv（VP9/AV1），ffmpeg 管线能处理但 AVPlayer 播不了；
// 原声即播模式需要先转成 H.264 MP4。

public enum MediaCompat: Sendable {
    /// AVFoundation 原生支持的容器
    public static func isNativePlayable(_ url: URL) -> Bool {
        ["mp4", "m4v", "mov"].contains(url.pathExtension.lowercased())
    }

    /// 转码为 H.264 MP4（仅对不可播容器调用；已有产物直接复用）
    public static func transcodeToPlayableMP4(
        _ src: URL,
        progress: @Sendable @escaping (Double, String?) -> Void = { _, _ in }
    ) async throws -> URL {
        let dest = src.deletingLastPathComponent().appendingPathComponent("source_play.mp4")
        if let size = fileSize(dest.path), size > 1_000_000 { return dest }
        progress(0.05, "转码原片为 MP4（\(src.pathExtension.uppercased()) 容器 AVPlayer 不支持）")
        let res = try await Task.detached {
            try ProcessRunner().run(SidecarPaths.ffmpeg,
                ["-y", "-i", src.path, "-c:v", "libx264", "-preset", "veryfast",
                 "-c:a", "aac", "-movflags", "+faststart", dest.path])
        }.value
        guard res.code == 0, let size = fileSize(dest.path), size > 1_000 else {
            throw EngineError.engineFailure("ffmpeg 转码失败：\(String(res.stderr.suffix(400)))")
        }
        progress(1, nil)
        return dest
    }
}
