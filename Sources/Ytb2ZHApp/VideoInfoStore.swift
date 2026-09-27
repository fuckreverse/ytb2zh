import Foundation
import Ytb2ZHEngines

// MARK: - 视频完整元数据仓库（url → VideoDetails，落 Application Support/Ytb2ZH/VideoInfo.json）

@MainActor
final class VideoInfoStore: ObservableObject {
    static let shared = VideoInfoStore()

    @Published private(set) var details: [String: VideoDetails] = [:]

    private let fm = FileManager.default
    private var fileURL: URL {
        let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ytb2ZH", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("VideoInfo.json")
    }

    private init() {
        if let data = try? Data(contentsOf: fileURL) {
            details = (try? JSONDecoder().decode([String: VideoDetails].self, from: data)) ?? [:]
        }
    }

    /// 按 URL 查详情；YouTube 链接归一化到 watch?v= 形式兑底（同视频多 URL 变体共存）
    func details(for url: String) -> VideoDetails? {
        if let d = details[url] { return d }
        if let id = CatalogVideo.youTubeID(url) {
            return details["https://www.youtube.com/watch?v=\(id)"]
        }
        return nil
    }

    func upsert(_ d: VideoDetails) {
        details[d.url] = d
        persist()
    }

    /// 待补齐的 URL（无详情记录的；YouTube 链接按视频 ID 归一化判重）
    func missingURLs(in urls: [String]) -> [String] {
        urls.filter { details(for: $0) == nil }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(details) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }
}
