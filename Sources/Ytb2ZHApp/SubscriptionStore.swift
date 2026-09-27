import Foundation
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 订阅与视频元数据（GUI 层持久化，JSON 落 Application Support/Ytb2ZH/）

@MainActor
final class SubscriptionStore: ObservableObject {
    static let shared = SubscriptionStore()

    struct Subscription: Codable, Identifiable {
        var id: UUID = UUID()
        var name: String
        var url: String
        var addedAt: Date = Date()
        var lastChecked: Date?
        var videos: [CatalogVideo] = []
    }

    @Published private(set) var subs: [Subscription] = []
    /// url → 视频元数据（标题/缩略图，媒体库展示用）
    private(set) var videoMeta: [String: CatalogVideo] = [:]

    private let fm = FileManager.default
    private var appDir: URL {
        let d = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ytb2ZH", isDirectory: true)
        try? fm.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    private var subsURL: URL { appDir.appendingPathComponent("Subscriptions.json") }
    private var metaURL: URL { appDir.appendingPathComponent("VideoMeta.json") }

    private init() { load() }

    func add(name: String, url: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        subs.append(Subscription(name: n.isEmpty ? "订阅 \(subs.count + 1)" : n,
                                 url: url.trimmingCharacters(in: .whitespaces)))
        persistSubs()
    }

    func remove(_ id: UUID) {
        subs.removeAll { $0.id == id }
        persistSubs()
    }

    func updateVideos(id: UUID, videos: [CatalogVideo]) {
        guard let i = subs.firstIndex(where: { $0.id == id }) else { return }
        subs[i].videos = videos
        subs[i].lastChecked = Date()
        // 同步进元数据索引（媒体库标题/缩略图来源）
        var mutated = false
        for v in videos where videoMeta[v.url] == nil {
            videoMeta[v.url] = v
            mutated = true
        }
        persistSubs()
        if mutated { persistMeta() }
    }

    func record(_ v: CatalogVideo) {
        guard videoMeta[v.url] == nil else { return }
        videoMeta[v.url] = v
        persistMeta()
    }

    func meta(for url: String) -> CatalogVideo? { videoMeta[url] }

    private func load() {
        if let data = try? Data(contentsOf: subsURL) {
            subs = (try? JSONDecoder().decode([Subscription].self, from: data)) ?? []
        }
        if let data = try? Data(contentsOf: metaURL) {
            videoMeta = (try? JSONDecoder().decode([String: CatalogVideo].self, from: data)) ?? [:]
        }
    }

    private func persistSubs() {
        if let data = try? JSONEncoder().encode(subs) { try? data.write(to: subsURL, options: .atomic) }
    }

    private func persistMeta() {
        if let data = try? JSONEncoder().encode(videoMeta) { try? data.write(to: metaURL, options: .atomic) }
    }
}
