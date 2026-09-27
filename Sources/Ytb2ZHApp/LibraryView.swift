import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 媒体库：所有已产出成片的任务，一键秒播（直播目录或成片直读）
//       按频道/时间分组 + 搜索 + 视频详情（标题/简介/频道/播放量等，yt-dlp -J 自动补齐）

enum LibraryGroupMode: String, CaseIterable {
    case byChannel, byDate
    var label: String {
        switch self {
        case .byChannel: return "按频道"
        case .byDate: return "按时间"
        }
    }
}

@MainActor
final class LibraryModel: ObservableObject {
    struct Item: Identifiable {
        let id: String          // jobID
        let jobID: String
        let url: String
        let profileName: String
        let finalVideo: URL
        let createdAt: Date
        let title: String
        let thumbnailURL: URL?
        let channel: String?
        let duration: Double
        let details: VideoDetails?
    }

    @Published var items: [Item] = []
    @Published private(set) var isBackfilling = false
    @Published private(set) var backfilledCount = 0
    private let backfiller = MetaBackfiller()

    func reload(store: JobStore = JobStore()) {
        let meta = SubscriptionStore.shared.videoMeta
        let infoStore = VideoInfoStore.shared
        items = store.allJobs().compactMap { (id, st) in
            guard store.hasFinalVideo(id), !st.url.isEmpty, !st.isTrial else { return nil }
            let m = meta[st.url]
            let d = infoStore.details(for: st.url)
            let title = m?.title ?? d?.title
                ?? (CatalogVideo.youTubeID(st.url).map { "youtube-\($0)" } ?? String(st.url.prefix(60)))
            let thumb = (m?.thumbnail ?? d?.thumbnail ?? CatalogVideo.youTubeThumbnail(st.url))
                .flatMap(URL.init(string:))
            return Item(id: id, jobID: id, url: st.url, profileName: st.profileName,
                        finalVideo: store.finalVideo(id), createdAt: st.createdAt,
                        title: title, thumbnailURL: thumb,
                        channel: m?.channel ?? d?.channel,
                        duration: m?.duration ?? d?.duration ?? 0,
                        details: d)
        }
        .sorted { $0.createdAt > $1.createdAt }
        isBackfilling = true
        backfiller.backfill(urls: items.map(\.url)) { [weak self] in
            self?.backfilledCount += 1
            self?.reloadAfterBackfill()
        }
        if !backfiller.isRunning { isBackfilling = false }
    }

    /// 手动刷新时清空失败记录，允许重试拉取元数据
    func backfillReset() { backfiller.resetFailures() }

    /// 补齐途中增量刷新已入库条目的频道/时长/详情（保持用户滚动位置，不整体 reload）
    private func reloadAfterBackfill() {
        let meta = SubscriptionStore.shared.videoMeta
        let infoStore = VideoInfoStore.shared
        items = items.map { item in
            guard item.details == nil, let d = infoStore.details(for: item.url) else { return item }
            let m = meta[item.url]
            return Item(id: item.id, jobID: item.jobID, url: item.url, profileName: item.profileName,
                        finalVideo: item.finalVideo, createdAt: item.createdAt,
                        title: m?.title ?? d.title,
                        thumbnailURL: (m?.thumbnail ?? d.thumbnail ?? CatalogVideo.youTubeThumbnail(item.url))
                            .flatMap(URL.init(string:)),
                        channel: m?.channel ?? d.channel,
                        duration: m?.duration ?? d.duration,
                        details: d)
        }
    }

    // backfiller 的补齐任务在其自身 deinit 中取消
}

struct LibraryView: View {
    /// 库外新 Profile 兜底（优先用任务自身的 profile 快照）
    let profile: Profile
    let onPlayed: (() -> Void)?
    @StateObject private var model = LibraryModel()
    @State private var playing: LibraryModel.Item?
    @State private var detailItem: LibraryModel.Item?
    @State private var searchText = ""
    @AppStorage("library.groupMode") private var groupModeRaw = LibraryGroupMode.byChannel.rawValue

    private let columns = [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 16)]

    private var groupMode: LibraryGroupMode {
        LibraryGroupMode(rawValue: groupModeRaw) ?? .byChannel
    }

    /// 搜索过滤后的条目（标题/频道/链接，大小写不敏感）
    private var filtered: [LibraryModel.Item] {
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return model.items }
        return model.items.filter {
            $0.title.lowercased().contains(q)
                || ($0.channel ?? "").lowercased().contains(q)
                || $0.url.lowercased().contains(q)
        }
    }

    /// 频道分组（按频道名字序），无频道信息归"未分组"
    private var channelGroups: [(name: String, items: [LibraryModel.Item])] {
        Dictionary(grouping: filtered) { $0.channel ?? "未分组" }
            .map { (name: $0.key, items: $0.value.sorted { $0.createdAt > $1.createdAt }) }
            .sorted { $0.name < $1.name }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("媒体库 · \(model.items.count) 部已完成")
                        .font(.headline)
                    if model.isBackfilling {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.mini)
                            Text("正在补齐视频信息…（已 \(model.backfilledCount)）")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                Picker("分组", selection: $groupModeRaw) {
                    ForEach(LibraryGroupMode.allCases, id: \.rawValue) { m in
                        Text(L(m.label)).tag(m.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                TextField("搜索标题 / 频道 / 链接", text: $searchText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 200)
                Button {
                    playing = nil
                    model.backfillReset()
                    model.reload()
                } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
            .padding(12)
            Divider()
            if model.items.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.stack.3d.up.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text("还没有完成的视频。去任务中心、实时播放或订阅预翻译生成成片后，会自动出现在这里。")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text("没有匹配「\(searchText)」的视频")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if groupMode == .byChannel {
                channelGroupedBody
            } else {
                dateGroupedBody
            }
        }
        .onAppear { model.reload() }
        .sheet(item: $playing) { item in
            ReplayPlayerSheet(profile: playProfile(item), url: item.url) {
                model.reload()
                onPlayed?()
            }
        }
        .sheet(item: $detailItem) { item in
            VideoInfoSheet(item: item) {
                playing = item
            }
        }
    }

    // 按频道分组：频道头 + 封面墙
    private var channelGroupedBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(channelGroups, id: \.name) { group in
                    HStack(spacing: 8) {
                        Image(systemName: "tv").foregroundStyle(.secondary)
                        Text(group.name).font(.headline)
                        Text("\(group.items.count) 部")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.top, 10)
                    LazyVGrid(columns: columns, spacing: 20) {
                        ForEach(group.items) { item in
                            card(item)
                        }
                    }
                    .padding(.bottom, 6)
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // 按时间：单一封面墙（原有布局）
    private var dateGroupedBody: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 20) {
                ForEach(filtered) { item in
                    card(item)
                }
            }
            .padding(16)
        }
    }

    /// 媒体库重播 sheet：自持会话，关闭即回收
    private struct ReplayPlayerSheet: View {
        let profile: Profile
        let url: String
        let onDismiss: () -> Void
        @StateObject private var session = LiveSession()

        var body: some View {
            LivePlayerView(profile: profile, autoStartURL: url, session: session)
                .frame(minWidth: 860, minHeight: 640)
                .onDisappear(perform: onDismiss)
        }
    }

    private func playProfile(_ item: LibraryModel.Item) -> Profile {
        JobStore().loadProfileSnapshot(id: item.jobID) ?? profile
    }

    private func card(_ item: LibraryModel.Item) -> some View {
        ZStack(alignment: .topTrailing) {
            Button {
                playing = item
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    ZStack(alignment: .bottomLeading) {
                        AsyncImage(url: item.thumbnailURL) { phase in
                            if let img = phase.image {
                                img.resizable().aspectRatio(16 / 9, contentMode: .fill)
                            } else {
                                Rectangle().fill(.quinary)
                                    .overlay(Image(systemName: "film").font(.title2).foregroundStyle(.secondary))
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        HStack(spacing: 4) {
                            Text(item.profileName)
                                .font(.caption2)
                                .padding(4)
                                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            if item.duration > 0 {
                                Text(LibraryView.durationText(item.duration))
                                    .font(.caption2.monospacedDigit())
                                    .padding(4)
                                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 4))
                            }
                        }
                        .padding(6)
                    }
                    Text(item.title)
                        .font(.callout)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text([item.channel, LibraryView.dateText(item.createdAt)].compactMap { $0 }
                        .joined(separator: " · "))
                        .font(.caption2).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // 信息按钮（叠在卡片右上角，点击只开详情不触发播放）
            Button {
                detailItem = item
            } label: {
                Image(systemName: "info.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.white, .black.opacity(0.55))
            }
            .buttonStyle(.plain)
            .help("查看视频信息（标题/简介/频道/播放量…）")
            .padding(6)
        }
    }

    /// "1:23:45"
    static func durationText(_ secs: Double) -> String {
        let s = Int(secs.rounded())
        guard s > 0 else { return "" }
        return String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
    }

    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 视频详情 sheet（原始标题/简介/频道/上传日期/播放量/点赞/标签）

struct VideoInfoSheet: View {
    let item: LibraryModel.Item
    let onPlay: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            AsyncImage(url: item.thumbnailURL) { phase in
                if let img = phase.image {
                    img.resizable().aspectRatio(16 / 9, contentMode: .fill)
                } else {
                    Rectangle().fill(.quinary)
                        .overlay(Image(systemName: "film").font(.largeTitle).foregroundStyle(.secondary))
                }
            }
            .frame(height: 220)
            .clipped()

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text(item.title)
                        .font(.title3.weight(.semibold))
                        .fixedSize(horizontal: false, vertical: true)

                    if let d = item.details {
                        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), alignment: .leading)],
                                  alignment: .leading, spacing: 8) {
                            if let ch = d.channel {
                                infoCell("频道", ch, extraURL: d.channelURL)
                            }
                            if let date = d.uploadDateText {
                                infoCell("上传日期", date)
                            }
                            if d.duration > 0 {
                                infoCell("时长", LibraryView.durationText(d.duration))
                            }
                            if let v = d.viewCount {
                                infoCell("播放量", VideoInfoSheet.countText(v))
                            }
                            if let v = d.likeCount {
                                infoCell("点赞数", VideoInfoSheet.countText(v))
                            }
                        }
                    } else {
                        Text("暂无详细元数据（点「刷新」重试自动补齐）")
                            .font(.caption).foregroundStyle(.secondary)
                    }

                    if let tags = item.details?.tags, !tags.isEmpty {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 6) {
                                ForEach(tags, id: \.self) { tag in
                                    Text(tag)
                                        .font(.caption)
                                        .padding(.horizontal, 8).padding(.vertical, 3)
                                        .background(.quinary, in: Capsule())
                                }
                            }
                        }
                    }

                    if let desc = item.details?.videoDescription, !desc.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("简介").font(.headline)
                            Text(desc)
                                .font(.callout)
                                .foregroundStyle(.primary.opacity(0.85))
                                .textSelection(.enabled)
                        }
                    }

                    Text(item.url)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                .padding(16)
            }

            Divider()
            HStack {
                Spacer()
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button {
                    dismiss()
                    onPlay()
                } label: {
                    Label("播放译制成片", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(minWidth: 560, minHeight: 620)
    }

    private func infoCell(_ label: String, _ value: String, extraURL: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            if let u = extraURL, let url = URL(string: u) {
                Link(value, destination: url).font(.callout).lineLimit(1)
            } else {
                Text(value).font(.callout).lineLimit(1).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(.quinary, in: RoundedRectangle(cornerRadius: 6))
    }

    /// 1_500_000_000 → "15.0 亿"；12000 → "1.2 万"；小数目千分位
    static func countText(_ n: Int) -> String {
        if n >= 100_000_000 {
            return String(format: "%.1f 亿", Double(n) / 100_000_000)
        }
        if n >= 10_000 {
            return String(format: "%.1f 万", Double(n) / 10_000)
        }
        return thousand(n)
    }

    static func thousand(_ n: Int) -> String {
        let s = String(n)
        var out = ""
        for (i, ch) in s.enumerated() {
            if i > 0, (s.count - i) % 3 == 0 { out += "," }
            out.append(ch)
        }
        return out
    }
}

// MARK: - 订阅：频道收藏 + 视频墙浏览 + 按需转换/实时播放
// 浏览是轻量的（只展示缓存的视频列表，手动刷新才拉网络）；
// 只有明确选中（单转 / 多选批量转 / 进播放页）才触发下载与转换。

@MainActor
final class SubscriptionRunner: ObservableObject {
    @Published var running = false
    @Published var progressText = ""
    @Published var doneCount = 0
    @Published var total = 0
    @Published var logLines: [String] = []

    func append(_ line: String) {
        logLines.append(line)
        AppLog.info("subscriptions", line)
    }

    /// 转换指定视频列表（单个或勾选批量）：同 URL+profile 已有成品跳过，
    /// 未完成的复用既有任务断点续跑，按序跑完整批量管线，完成即入库
    func convert(videos: [CatalogVideo], profile: Profile, onProgress: @escaping () -> Void) {
        guard !running, !videos.isEmpty else { return }
        running = true
        progressText = L10n.tr("检查待处理…")
        doneCount = 0; total = 0
        logLines = []
        let runProfile = AppSettings.applied(profile)

        Task {
            let store = JobStore()
            var pending: [CatalogVideo] = []
            for v in videos where !v.url.isEmpty {
                if let (id, _) = store.allJobs().first(where: {
                    $1.url == v.url && $1.profileName == runProfile.name
                }), store.hasFinalVideo(id) {
                    append(String(format: L10n.tr("跳过（已有成品）：%@"), v.title))
                    continue
                }
                pending.append(v)
            }

            total = pending.count
            if pending.isEmpty {
                append(L10n.tr("所选视频均已是成品，无需处理"))
                finish()
                return
            }

            for (i, v) in pending.enumerated() {
                SubscriptionStore.shared.record(v)
                let id: String
                if let existing = store.allJobs().first(where: {
                    $1.url == v.url && $1.profileName == runProfile.name
                })?.0 {
                    id = existing
                } else {
                    guard let nid = try? store.newJob(url: v.url, profile: runProfile) else {
                        append(String(format: L10n.tr("〔%lld/%lld〕任务创建失败：%@"), i + 1, total, v.title))
                        continue
                    }
                    id = nid
                }
                progressText = String(format: L10n.tr("〔%lld/%lld〕%@"), i + 1, total, v.title)
                append(String(format: L10n.tr("开始：%@"), v.title))
                await runJob(jobID: id, url: v.url, profile: runProfile)
                if store.hasFinalVideo(id) {
                    append(String(format: L10n.tr("完成：%@"), v.title))
                } else {
                    append(String(format: L10n.tr("失败（可在任务中心续跑）：%@"), v.title))
                }
                doneCount = i + 1
                onProgress()
            }
            finish()
        }
    }

    private func finish() {
        running = false
        progressText = total > 0 ? String(format: L10n.tr("完成 %lld/%lld"), doneCount, total) : L10n.tr("空闲")
    }

    private func runJob(jobID: String, url: String, profile: Profile) async {
        let (stream, cont) = AsyncStream<PipelineEvent>.makeStream(bufferingPolicy: .unbounded)
        guard let engines = try? EngineAssembly.engineSet(for: profile) else {
            append(String(format: L10n.tr("引擎装配失败（Profile: %@）"), profile.name))
            cont.finish()
            return
        }
        let store = JobStore()
        let pipeline = Pipeline(engines: engines, store: store, events: cont)
        Task.detached {
            try? await pipeline.run(videoURL: nil, url: url, profile: profile, jobID: jobID)
            cont.finish()
        }
        for await ev in stream {
            switch ev {
            case .stepStarted(let s):
                progressText = progressText + " · " + L10n.tr(Self.stepName(s))
            case .progress(_, _, let msg):
                if let msg, !msg.isEmpty { progressText = progressText + " · " + L10n.tr(msg) }
            case .log(let l):
                append(l)
            case .failed(_, let m):
                append(String(format: L10n.tr("失败：%@"), m))
            default:
                break
            }
        }
    }

    static func stepName(_ s: StepID) -> String {
        switch s {
        case .download: return "下载"
        case .separate: return "人声分离"
        case .transcribe: return "转录"
        case .segment: return "切分"
        case .summarize: return "术语"
        case .translate: return "翻译"
        case .synthesize: return "合成"
        case .schedule: return "调度"
        case .compose: return "合成"
        }
    }
}

struct SubscriptionsView: View {
    let profile: Profile
    let onChanged: () -> Void
    @StateObject private var runner = SubscriptionRunner()
    @ObservedObject private var store = SubscriptionStore.shared
    /// 记住上次选中的频道（按 URL 匹配，删掉后自动回落到第一个）
    @AppStorage("subscriptions.lastSubURL") private var lastSubURL = ""
    @State private var refreshing = false
    @State private var refreshError = ""
    @State private var showAdd = false
    @State private var newName = ""
    @State private var newURL = ""
    @State private var addError = ""
    /// 多选模式
    @State private var selecting = false
    @State private var checked: Set<String> = []
    @State private var detailVideo: CatalogVideo?
    @State private var playTarget: CatalogVideo?
    @State private var origTarget: CatalogVideo?
    @State private var renameTarget: SubscriptionStore.Subscription?
    @State private var renameText = ""

    private let columns = [GridItem(.adaptive(minimum: 200, maximum: 260), spacing: 16)]

    private var selectedSub: SubscriptionStore.Subscription? {
        store.subs.first(where: { $0.url == lastSubURL }) ?? store.subs.first
    }

    private var videos: [CatalogVideo] { selectedSub?.videos ?? [] }

    /// 当前 Profile 下 url → (jobID, 是否已有成品)；媒体库/任务复用同一套判定
    private var jobByURL: [String: (id: String, done: Bool)] {
        let st = JobStore()
        let name = profile.name
        var out: [String: (id: String, done: Bool)] = [:]
        for (id, s) in st.allJobs() where !s.url.isEmpty && s.profileName == name {
            let done = st.hasFinalVideo(id)
            if let old = out[s.url] {
                if done && !old.done { out[s.url] = (id, true) }
            } else {
                out[s.url] = (id, done)
            }
        }
        return out
    }

    /// 可勾选（未成成品）的视频
    private var selectableVideos: [CatalogVideo] {
        let jobs = jobByURL
        return videos.filter { jobs[$0.url]?.done != true && !$0.url.isEmpty }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            channelBar
            if runner.running { runnerBar }
            Divider()

            if store.subs.isEmpty {
                emptyState
            } else if videos.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "square.grid.3x3").font(.largeTitle).foregroundStyle(.secondary)
                    Text("该频道还没有视频列表，点右上角「刷新」拉取最新视频")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                videoWall
            }
        }
        .sheet(item: $detailVideo) { v in
            VideoConvertSheet(video: v, status: convertStatus(v), profileName: profile.name,
                              busy: runner.running,
                              onConvert: {
                                  detailVideo = nil
                                  runner.convert(videos: [v], profile: profile) { onChanged() }
                              },
                              onPlay: {
                                  detailVideo = nil
                                  playTarget = v
                              })
        }
        .sheet(item: $playTarget) { v in
            SubReplaySheet(profile: profile, url: v.url) {
                onChanged()
            }
        }
        .sheet(isPresented: $showAdd) { addSheet }
    }

    // MARK: 头部

    private var headerBar: some View {
        HStack {
            Text("订阅 · \(store.subs.count) 个频道").font(.headline)
            Spacer()
            Button {
                selecting.toggle()
                checked = []
            } label: {
                Label(selecting ? "取消选择" : "选择",
                      systemImage: selecting ? "checkmark.circle.fill" : "checkmark.circle")
            }
            .disabled(store.subs.isEmpty || videos.isEmpty)
            Button {
                showAdd = true
            } label: {
                Label("添加订阅", systemImage: "plus")
            }
        }
        .padding(12)
    }

    private var channelBar: some View {
        VStack(alignment: .leading, spacing: 0) {
        HStack(spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(store.subs) { sub in
                        channelCapsule(sub)
                    }
                    if store.subs.isEmpty {
                        Text("还没有订阅，点「添加订阅」收藏频道或播放列表")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 12)
            }
            Button {
                refreshSelected()
            } label: {
                if refreshing {
                    ProgressView().controlSize(.small)
                } else {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
            }
            .disabled(selectedSub == nil || refreshing || runner.running)
            .help("重新拉取当前频道的最新视频列表（手动）")
        }
        .padding(.bottom, 10)
        if !refreshError.isEmpty {
            Text(refreshError).font(.caption).foregroundStyle(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.bottom, 6)
        }
        }
    }

    private func channelCapsule(_ sub: SubscriptionStore.Subscription) -> some View {
        let isSel = sub.id == selectedSub?.id
        return Button {
            lastSubURL = sub.url
            refreshError = ""
            checked = []
        } label: {
            HStack(spacing: 6) {
                Image(systemName: isSel ? "tv.fill" : "tv")
                Text(sub.name).lineLimit(1)
                if !sub.videos.isEmpty {
                    Text(String(sub.videos.count))
                        .font(.caption2.monospacedDigit())
                        .opacity(0.8)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
            .background(isSel ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quinary),
                        in: Capsule())
            .foregroundStyle(isSel ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                renameText = sub.name
                renameTarget = sub
            } label: {
                Label("重命名…", systemImage: "pencil")
            }
            Button(role: .destructive) {
                store.remove(sub.id)
                checked = []
            } label: {
                Label("删除订阅", systemImage: "trash")
            }
        }
    }

    // MARK: 运行进度

    private var runnerBar: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(runner.progressText).lineLimit(1)
                Spacer()
                if runner.total > 0 {
                    Text("\(runner.doneCount)/\(runner.total)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if runner.total > 0 {
                ProgressView(value: Double(runner.doneCount), total: Double(max(runner.total, 1)))
            }
            if !runner.logLines.isEmpty {
                Text(runner.logLines.suffix(3).joined(separator: "\n"))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(3)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: 视频墙

    private var videoWall: some View {
        VStack(spacing: 0) {
            if selecting {
                selectBar
                Divider()
            }
            ScrollView {
                LazyVGrid(columns: columns, spacing: 18) {
                    ForEach(videos) { v in
                        if selecting {
                            selectCard(v)
                        } else {
                            wallCard(v)
                        }
                    }
                }
                .padding(16)
            }
        }
    }

    private var selectBar: some View {
        HStack(spacing: 12) {
            Text("已选 \(checked.count) 个").font(.callout.weight(.medium))
            Button("全选待转换") {
                checked = Set(selectableVideos.map(\.url))
            }
            .disabled(selectableVideos.isEmpty)
            Spacer()
            Button {
                runner.convert(videos: videos.filter { checked.contains($0.url) },
                               profile: profile) { onChanged() }
                selecting = false
                checked = []
            } label: {
                Label("批量转换 \(checked.count) 个", systemImage: "play.rectangle.on.rectangle")
            }
            .buttonStyle(.borderedProminent)
            .disabled(checked.isEmpty || runner.running)
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    /// 视频墙卡片：封面 + 状态角标，点卡片开详情
    private func wallCard(_ v: CatalogVideo) -> some View {
        Button {
            detailVideo = v
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    cover(v)
                    statusBadge(v)
                }
                Text(v.title)
                    .font(.callout)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(metaLine(v))
                    .font(.caption2).foregroundStyle(.secondary).lineLimit(1)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                origTarget = v
            } label: {
                Label("看原版（不翻译）", systemImage: "film")
            }
        }
    }

    /// 多选模式卡片：未完成的可勾选，已有成品的置灰
    private func selectCard(_ v: CatalogVideo) -> some View {
        let done = convertStatus(v) == .done
        let isOn = checked.contains(v.url)
        return Button {
            guard !done else { return }
            if isOn { checked.remove(v.url) } else { checked.insert(v.url) }
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                ZStack(alignment: .topLeading) {
                    cover(v).opacity(done ? 0.45 : 1)
                    HStack(spacing: 4) {
                        Image(systemName: done ? "checkmark.seal.fill"
                              : (isOn ? "checkmark.circle.fill" : "circle"))
                            .font(.title3)
                            .foregroundStyle(done ? .green
                                             : (isOn ? .blue : .white),
                                             isOn || done ? .clear : .black.opacity(0.45))
                        statusBadge(v)
                    }
                    .padding(6)
                }
                Text(v.title).font(.callout).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(done ? "已有译制成品，无需转换" : "点选加入批量转换")
    }

    private func cover(_ v: CatalogVideo) -> some View {
        ThumbImage(url: v.thumbnail ?? CatalogVideo.youTubeThumbnail(v.url))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func statusBadge(_ v: CatalogVideo) -> some View {
        Group {
            switch convertStatus(v) {
            case .done:
                badge("中文版", .green)
            case .pending:
                badge("转换中", .orange)
            case .fresh:
                EmptyView()
            }
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 6).padding(.vertical, 3)
            .background(color.opacity(0.85), in: RoundedRectangle(cornerRadius: 4))
            .foregroundStyle(.white)
    }

    private func metaLine(_ v: CatalogVideo) -> String {
        var parts: [String] = []
        if let ch = v.channel { parts.append(ch) }
        if v.duration > 0 {
            let s = Int(v.duration.rounded())
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        return parts.joined(separator: " · ")
    }

    private func convertStatus(_ v: CatalogVideo) -> SubConvertStatus {
        guard let j = jobByURL[v.url] else { return .fresh }
        return j.done ? .done : .pending
    }

    // MARK: 刷新 / 添加

    /// 视频 URL 判定（watch / youtu.be / shorts）；频道 tab、播放列表页返回 false
    private static func isVideoURL(_ u: String) -> Bool {
        let s = u.lowercased()
        return s.contains("watch?v=") || s.contains("youtu.be/") || s.contains("/shorts/")
    }

    private func refreshSelected() {
        guard let sub = selectedSub, !refreshing else { return }
        refreshing = true
        refreshError = ""
        let url = sub.url
        let subID = sub.id
        let proxy = AppSettings.effectiveProxy(fallback: profile.download.proxy)
        Task {
            var page = await Self.fetchPage(url: url, limit: 12, proxy: proxy)
            // 频道主页（@handle 等）首层返回的是 tab 条目（Videos/Shorts…）而非视频，
            // 优先挑 /videos tab 自动下钻一层取真正的视频列表
            if page.videos.contains(where: { !SubscriptionsView.isVideoURL($0.url) }) {
                let tab = page.videos.first(where: { $0.url.lowercased().hasSuffix("/videos") })?.url
                    ?? page.videos.first(where: { !SubscriptionsView.isVideoURL($0.url) })?.url
                if let tab, !tab.isEmpty {
                    page = await Self.fetchPage(url: tab, limit: 12, proxy: proxy)
                }
            }
            // 兜底：混入的非视频条目剔除（全部被剔则保留原样，避免空列表）
            let onlyVideos = page.videos.filter { SubscriptionsView.isVideoURL($0.url) }
            let vids = onlyVideos.isEmpty ? page.videos : onlyVideos
            refreshing = false
            if vids.isEmpty {
                refreshError = "未获取到视频（检查网络/代理与链接有效性）"
            } else {
                SubscriptionStore.shared.updateVideos(id: subID, videos: vids)
                autoName(subID: subID, pageTitle: page.title, videos: vids)
            }
        }
    }

    private static func fetchPage(url: String, limit: Int, proxy: String) async -> VideoCatalogService.CatalogPage {
        await Task.detached {
            (try? VideoCatalogService().searchPage(url, limit: limit, proxy: proxy))
                ?? VideoCatalogService.CatalogPage(title: nil, videos: [])
        }.value
    }

    /// 自动命名：占位名（「订阅 N」）在首次拉到列表后，用频道/播放列表标题命名；手动改过的不动
    private func autoName(subID: UUID, pageTitle: String?, videos: [CatalogVideo]) {
        let store = SubscriptionStore.shared
        guard let sub = store.subs.first(where: { $0.id == subID }), sub.autoNamed == true else { return }
        var candidates: [String] = []
        if let t = pageTitle, !t.isEmpty { candidates.append(t) }
        candidates.append(contentsOf: videos.compactMap(\.channel))
        if let name = candidates.first(where: { !$0.isEmpty }) {
            store.rename(id: subID, name: name, isAuto: true)
        }
    }

    private var addSheet: some View {
        VStack(spacing: 14) {
            Text("添加订阅").font(.headline)
            TextField("名称（可选，默认取链接）", text: $newName)
                .textFieldStyle(.roundedBorder)
            TextField("频道 / 播放列表 URL", text: $newURL)
                .textFieldStyle(.roundedBorder)
            if !addError.isEmpty {
                Text(addError).font(.caption).foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("订阅只保存频道并缓存视频列表，不会自动下载转换；\n浏览后按需单转、批量转或实时播放。")
                .font(.caption).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("取消") { showAdd = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("添加并拉取列表") {
                    let u = newURL.trimmingCharacters(in: .whitespaces)
                    guard u.hasPrefix("http") else {
                        addError = "请输入合法的频道或播放列表链接"
                        return
                    }
                    addError = ""
                    store.add(name: newName, url: u)
                    lastSubURL = u
                    newURL = ""; newName = ""
                    showAdd = false
                    refreshSelected()
                }
                .buttonStyle(.borderedProminent)
                .disabled(newURL.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "antenna.radiowaves.left.and.right")
                .font(.largeTitle).foregroundStyle(.secondary)
            Text("订阅频道或播放列表，浏览最新视频后按需转换：\n单部转换、勾选批量转换，或进播放页边下边译边播。")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("添加订阅") { showAdd = true }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// 视频 URL → 转换状态（订阅页/详情 sheet 共用）
private enum SubConvertStatus { case done, pending, fresh }

// MARK: - 视频转换详情 sheet（大封面 + 状态 + 转换/实时播放入口）

private struct VideoConvertSheet: View {
    let video: CatalogVideo
    let status: SubConvertStatus
    let profileName: String
    let busy: Bool
    let onConvert: () -> Void
    let onPlay: () -> Void
    let onOriginal: () -> Void
    @Environment(\.dismiss) private var dismiss

    private var statusText: (String, Color) {
        switch status {
        case .done: return ("已有译制成品，可直接播放", .green)
        case .pending: return ("有未完成的转换任务，重新转换会从断点续跑", .orange)
        case .fresh: return ("尚未转换", .secondary)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            ThumbImage(url: video.thumbnail ?? CatalogVideo.youTubeThumbnail(video.url))
                .frame(height: 220)
                .clipped()

            VStack(alignment: .leading, spacing: 10) {
                Text(video.title)
                    .font(.title3.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Text(metaLine).font(.caption).foregroundStyle(.secondary)
                Text(video.url)
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
                    .textSelection(.enabled).lineLimit(2)
                HStack(spacing: 6) {
                    Circle().fill(statusText.1).frame(width: 8, height: 8)
                    Text(statusText.0).font(.callout).foregroundStyle(statusText.1)
                }
                Text("转换模板：\(profileName)").font(.caption).foregroundStyle(.secondary)
            }
            .padding(16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider()
            HStack {
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button {
                    dismiss()
                    onOriginal()
                } label: {
                    Label("看原版", systemImage: "film")
                }
                .buttonStyle(.bordered)
                .help("不翻译，直接流式播放原声，进度条可任意拖动")
                Button {
                    dismiss()
                    onPlay()
                } label: {
                    Label(status == .done ? "播放译制成品" : "实时播放（边下边译）",
                          systemImage: "play.tv")
                }
                .buttonStyle(.bordered)
                .help(status == .done
                      ? "秒开已完成的译制成片"
                      : "进入实时播放器：先下载原声即可观看，播放中一键切换中文配音，也可转成成片")
                Button {
                    dismiss()
                    onConvert()
                } label: {
                    Label(status == .pending ? "继续转换" : "开始转换",
                          systemImage: "arrow.down.doc")
                }
                .buttonStyle(.borderedProminent)
                .disabled(busy)
                .help("后台跑完整批量管线（下载→转录→切分→翻译→配音→成片），完成自动入媒体库")
            }
            .padding(12)
        }
        .frame(minWidth: 520, minHeight: 480)
    }

    private var metaLine: String {
        var parts: [String] = []
        if let ch = video.channel { parts.append(ch) }
        if video.duration > 0 {
            let s = Int(video.duration.rounded())
            parts.append(String(format: "%d:%02d", s / 60, s % 60))
        }
        if let n = video.viewCount { parts.append(L10n.isEnglish ? "\(n) plays" : "\(n) 次播放") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - 订阅实时播放 sheet：自持会话，关闭即回收

private struct SubReplaySheet: View {
    let profile: Profile
    let url: String
    let onDismiss: () -> Void
    @StateObject private var session = LiveSession()

    var body: some View {
        LivePlayerView(profile: profile, autoStartURL: url, session: session)
            .frame(minWidth: 960, minHeight: 700)
            .onDisappear(perform: onDismiss)
    }
}
