import Foundation
import Ytb2ZHEngines

// MARK: - 视频完整元数据仓库（url → VideoDetails，落 Application Support/Ytb2ZH/VideoInfo.json）

// MARK: - 共享元数据补齐器：逐个串行拉取缺失的 VideoDetails（媒体库 / 任务中心共用）

@MainActor
final class MetaBackfiller: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var doneCount = 0
    /// 本会话内拉取失败的 URL（不重试；调用方手动刷新时可调 reset 清掉）
    private var failedURLs: Set<String> = []
    private var task: Task<Void, Never>?

    /// 对缺失详情的 URL 后台补齐；每补齐一条回调一次（调用方据此刷新列表）
    func backfill(urls: [String], onChange: @escaping () -> Void) {
        guard !isRunning else { return }
        let missing = Array(Set(VideoInfoStore.shared.missingURLs(in: urls)))
            .filter { !failedURLs.contains($0) }
        guard !missing.isEmpty else { return }
        isRunning = true
        doneCount = 0
        let proxy = AppSettings.effectiveProxy(fallback: "")
        task = Task { [weak self] in
            let service = VideoInfoService()
            for url in missing {
                if Task.isCancelled { break }
                let result = await Task.detached {
                    try? service.fetch(url, proxy: proxy)
                }.value
                guard let self else { break }
                if let d = result {
                    VideoInfoStore.shared.upsert(d)
                    self.failedURLs.remove(url)
                    self.doneCount += 1
                    onChange()
                } else {
                    self.failedURLs.insert(url)
                }
            }
            self?.isRunning = false
        }
    }

    /// 清空失败记录（手动刷新时允许重试）
    func resetFailures() { failedURLs.removeAll() }

    deinit { task?.cancel() }
}

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
