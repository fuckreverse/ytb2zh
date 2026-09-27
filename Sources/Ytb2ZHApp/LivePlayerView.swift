import SwiftUI
import AVKit
import AVFoundation
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 实时播放器（浏览增强版）：播放列表网格浏览 → 原声即载即播 → 播放中切换中文配音
// 中文伪直播走本地 loopback HTTP（EVENT 型 playlist，磁盘直读分片，seek 仅限已配音区间）；
// 系统新版的 HLS 内容泵拒绝自定义 scheme（-12881），故不再使用 ResourceLoader。
//
// 原声/中文双模式：原声走 job 目录缓存（有缓存秒播，否则下载完即播）；
// 看原声时可一键启动中文配音管线（同一 job，下载步跳过、缓存全复用），
// 后台就绪后无缝切换（按当前观看秒数对位 seek），也可随时切回原声。

struct LivePlayerView: View {
    let profile: Profile
    /// 库/订阅点选进入时自动开始（秒开）
    var autoStartURL: String? = nil
    /// 会话由外部持有（主窗口共享，切页不丢任务）；sheet 场景由包装视图持有
    @ObservedObject var session: LiveSession
    @State private var url = ""
    @State private var query = ""
    @State private var results: [CatalogVideo] = []
    @State private var searching = false
    @State private var searchError = ""
    @State private var loadingMore = false
    @State private var loadedAll = true
    @State private var queryIsList = false
    @State private var hint = ""
    /// 浏览卡片状态角标：url → 状态（中文版就绪 / 已缓存原声）
    @State private var statuses: [String: BrowseStatus] = [:]

    enum BrowseStatus: Int {
        case fresh = 0, cached, chineseReady

        var badge: (text: String, color: Color)? {
            switch self {
            case .chineseReady: return ("中文版", .green)
            case .cached: return ("已缓存", .secondary)
            case .fresh: return nil
            }
        }
    }

    init(profile: Profile, autoStartURL: String? = nil, session: LiveSession) {
        self.profile = profile
        self.autoStartURL = autoStartURL
        _session = ObservedObject(wrappedValue: session)
    }

    var body: some View {
        VStack(spacing: 0) {
            // —— 地址栏
            HStack(spacing: 10) {
                Image(systemName: "dot.radiowaves.left.and.right")
                    .foregroundStyle(session.isRunning || session.converting ? .red : .secondary)
                TextField("YouTube URL（或从下方结果点选）", text: $url)
                    .textFieldStyle(.roundedBorder)
                    .disabled(session.isRunning || session.converting || session.downloadingOriginal)
                Button {
                    if VideoCatalogService.isLikelyListURL(url) { browseFromField(); return }
                    if session.isRunning { session.stop() } else { session.start(url: url, profile: profile) }
                } label: {
                    Label(session.isRunning ? "停止" : "实时中文",
                          systemImage: session.isRunning ? "stop.fill" : "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .help("边处理边播的中文字幕/配音版（处理约 4x 实时，跑在播放前面）；粘贴播放列表链接会自动转为浏览")
                Button {
                    if VideoCatalogService.isLikelyListURL(url) { browseFromField(); return }
                    session.startOriginal(url: url, profile: profile)
                } label: {
                    Label("原声播放", systemImage: "waveform")
                }
                .buttonStyle(.bordered)
                .disabled(session.isRunning || session.converting || session.downloadingOriginal
                          || url.trimmingCharacters(in: .whitespaces).isEmpty)
                .help("先只下载并播放原片；播放中可在播放器下方一键切换到中文配音")
            }
            .padding(EdgeInsets(top: 12, leading: 16, bottom: 6, trailing: 16))

            // —— 搜索浏览
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索 YouTube 关键词 / 粘贴频道或播放列表链接展开浏览", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(search)
                if searching { ProgressView().controlSize(.small) }
                Button("搜索", action: search)
                    .disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.horizontal, 16)

            if !searchError.isEmpty {
                Text(searchError).font(.caption).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }
            if !hint.isEmpty {
                Text(hint).font(.caption).foregroundStyle(.blue).frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
            }

            // —— 结果区：播放列表/频道 → 网格浏览；关键词 → 横向卡片带
            if queryIsList && !results.isEmpty {
                browsePanel
                    .padding(.vertical, 6)
                    .frame(maxHeight: 300)
            } else if !results.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(results) { v in catalogCard(v, wide: false) }
                    }
                    .padding(.horizontal, 16)
                }
                .frame(height: 150)
                .padding(.vertical, 8)
            }

            Divider()

            // —— 播放器
            if let player = session.player {
                PlayerSurface(player: player)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.quaternary.opacity(0.4))
                    VStack(spacing: 8) {
                        if session.isRunning || session.downloadingOriginal {
                            ProgressView()
                            Text(session.downloadingOriginal
                                 ? "下载原声中，完成后立即播放\n（看过的视频会直接秒播缓存）"
                                 : "准备中：下载 → 转录 → 语义切分完成、首个配音分片生成后自动开播\n看过的视频会用缓存直接重播")
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        } else {
                            Image(systemName: "tv").font(.largeTitle).foregroundStyle(.secondary)
                            Text("输入视频地址或搜索点选开始；播放列表会展开成可点选的封面墙，\n先看原声、再一键切换中文配音")
                                .font(.callout).foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                        }
                    }
                }
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            }

            // —— 原声 / 中文配音 切换条（播放中随时切换）
            if session.player != nil {
                toggleBar
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
            }

            // —— 实时双语字幕（仅中文模式，跟随播放时间）
            if let player = session.player, session.mode == .chinese {
                Text(session.currentSubtitle.isEmpty ? " " : session.currentSubtitle)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .animation(.default, value: session.currentSubtitle)
                    .id(player)
            }

            Divider()

            // —— 状态区
            statusBar
        }
        .onAppear {
            if let u = autoStartURL, session.player == nil, !session.isRunning, !session.finished {
                session.start(url: u, profile: profile)
            }
            refreshStatuses()
        }
        .onChange(of: session.finished) { _, _ in refreshStatuses() }
        .onChange(of: session.chineseReady) { _, _ in refreshStatuses() }
        .onDisappear { session.player?.pause() }   // 切页暂停播放，但处理任务继续跑
    }

    // MARK: 子视图与动作

    private var browsePanel: some View {
        VStack(spacing: 8) {
            HStack {
                Text("播放列表 · \(results.count) 个视频")
                    .font(.callout.weight(.medium))
                if let last = results.last, let ch = last.channel {
                    Text("· \(ch)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                if loadingMore { ProgressView().controlSize(.small) }
                if !loadedAll {
                    Button("加载更多", action: loadMore)
                        .disabled(loadingMore || searching)
                }
            }
            .padding(.horizontal, 16)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 230, maximum: 300), spacing: 14)], spacing: 14) {
                    ForEach(results) { v in catalogCard(v, wide: true) }
                }
                .padding(.horizontal, 16)
                .padding(.bottom, 8)
            }
        }
    }

    private var toggleBar: some View {
        HStack(spacing: 12) {
            // 原声
            Button {
                session.switchToOriginal()
            } label: {
                Label(session.mode == .original ? "原声中" : "原声",
                      systemImage: session.mode == .original ? "waveform" : "waveform.circle")
            }
            .buttonStyle(.bordered)
            .tint(session.mode == .original ? .accentColor : .secondary)
            .disabled(session.mode == .original || session.sourceURL == nil)
            .help("切换回原片原声（中文版继续在后台处理缓存）")

            // 中文配音
            if session.mode == .chinese {
                Label("中文配音中", systemImage: "character.bubble")
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 5))
            } else if session.chineseReady {
                Button {
                    session.switchToChinese()
                } label: {
                    Label(session.converting ? "切换中文配音（处理中）" : "切换中文配音",
                          systemImage: "character.bubble")
                }
                .buttonStyle(.bordered)
                .tint(.green)
                .help("中文版分片已就绪，从当前观看位置无缝续看")
            } else if session.converting {
                Label(session.downloadingOriginal ? "中文配音：排队中" : "中文配音：准备中", systemImage: "arrow.triangle.2.circlepath")
                    .foregroundStyle(.orange).font(.callout)
            } else {
                Button {
                    session.beginChinese()
                } label: {
                    Label("转中文配音", systemImage: "character.bubble")
                }
                .buttonStyle(.bordered)
                .tint(.blue)
                .disabled(session.downloadingOriginal)
                .help("后台开始转译配音（原声不中断，处理约 4x 实时），就绪后这里会变成「切换中文配音」")
            }

            // —— 倍速（跨原声/中文/live/成片保留）
            Menu {
                ForEach(LiveSession.speedOptions, id: \.self) { r in
                    Button {
                        session.playbackRate = r
                    } label: {
                        if session.playbackRate == r {
                            Label(LiveSession.rateLabel(r), systemImage: "checkmark")
                        } else {
                            Text(LiveSession.rateLabel(r))
                        }
                    }
                }
            } label: {
                Label(LiveSession.rateLabel(session.playbackRate), systemImage: "speedometer")
                    .fixedSize()
            }
            .menuStyle(.borderedButton)
            .menuIndicator(.visible)
            .fixedSize()
            .help("播放倍速（对原声/中文配音均生效）")

            Spacer()

            if session.converting {
                VStack(alignment: .trailing, spacing: 2) {
                    Text("\(session.convertingPhase.isEmpty ? "处理中" : session.convertingPhase)：已配音 \(LivePlayerView.mmss(session.dubbedSeconds)) / 全片 \(LivePlayerView.mmss(session.totalSeconds))")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    ProgressView(value: session.totalSeconds > 0
                                 ? min(1, session.dubbedSeconds / max(1, session.totalSeconds))
                                 : session.convertingProgress)
                        .frame(width: 260)
                }
            }
        }
    }

    private var statusBar: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(session.mode == .original && session.player != nil ? "原声播放" : session.phaseTitle)
                    .font(.headline)
                Spacer()
                if session.totalSeconds > 0 && (session.mode == .chinese || session.converting) {
                    Text("已配音 \(Self.mmss(session.dubbedSeconds)) / 全片 \(Self.mmss(session.totalSeconds))")
                        .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if session.isRunning || session.downloadingOriginal, !session.converting {
                ProgressView(value: session.progress)
            }
            if !session.detail.isEmpty {
                Text(session.detail).font(.caption).foregroundStyle(.secondary)
            }
            if !session.errorText.isEmpty {
                Label(session.errorText, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red).font(.callout)
            }
            if session.finished {
                Label(session.mode == .original
                      ? "中文配音已全部完成：点上方「切换中文配音」从当前位置无缝续看"
                      : "播放完成，成片与字幕已写入任务目录",
                      systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green).font(.callout)
            }
        }
        .padding(12)
        .frame(maxHeight: 140, alignment: .top)
    }

    // MARK: 搜索 / 浏览

    /// 地址栏误粘贴播放列表时转为浏览
    private func browseFromField() {
        query = url
        hint = "已识别为播放列表/频道：在下方展开为封面墙，点选视频即可播放"
        search()
    }

    private func search() { load(reset: true) }
    private func loadMore() { load(reset: false) }

    private func load(reset: Bool) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if reset { searching = true; loadingMore = false } else { loadingMore = true }
        if reset { searchError = ""; hint = "" }
        let isList = VideoCatalogService.isLikelyListURL(q)
        let offset = reset ? 0 : results.count
        let proxy = AppSettings.effectiveProxy(fallback: profile.download.proxy)
        Task.detached {
            do {
                let found = try VideoCatalogService().search(q, limit: 24, offset: offset, proxy: proxy)
                await MainActor.run {
                    if reset {
                        results = found
                        queryIsList = isList
                        if found.isEmpty { searchError = "无结果（或网络/代理不可用）" }
                    } else {
                        let known = Set(results.map(\.id))
                        results += found.filter { !known.contains($0.id) }
                    }
                    loadedAll = found.count < 24
                    refreshStatuses()
                    searching = false; loadingMore = false
                }
            } catch {
                await MainActor.run {
                    searchError = error.localizedDescription
                    searching = false; loadingMore = false
                }
            }
        }
    }

    /// 从任务库扫每个视频的状态（中文版就绪 / 已缓存原声），驱动卡片角标
    private func refreshStatuses() {
        let store = JobStore()
        var map: [String: (status: BrowseStatus, prefer: Bool)] = [:]
        for (id, st) in store.allJobs() where !st.url.isEmpty {
            let s: BrowseStatus = store.hasFinalVideo(id) ? .chineseReady
                : (store.existingSource(id) != nil ? .cached : .fresh)
            let preferSameProfile = st.profileName == profile.name
            if let prev = map[st.url] {
                let rank = s.rawValue * 2 + (preferSameProfile ? 1 : 0)
                let prevRank = prev.status.rawValue * 2 + (prev.prefer ? 1 : 0)
                if rank > prevRank { map[st.url] = (s, preferSameProfile) }
            } else {
                map[st.url] = (s, preferSameProfile)
            }
        }
        statuses = map.mapValues(\.status)
    }

    // MARK: 播放动作

    /// 点卡片：已有中文版 → 中文秒播；否则原声即载即播 + 可切换
    private func smartPlay(_ v: CatalogVideo) {
        url = v.url
        if statuses[v.url] == .chineseReady
            || LiveSession.findReplay(url: v.url, profile: profile) != nil {
            session.start(url: v.url, profile: profile)
        } else {
            session.startOriginal(url: v.url, profile: profile)
        }
    }

    private func catalogCard(_ v: CatalogVideo, wide: Bool) -> some View {
        let width: CGFloat = wide ? 260 : 208
        return Button {
            smartPlay(v)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                ZStack(alignment: .bottomTrailing) {
                    ThumbImage(url: v.thumbnail)
                        .frame(width: width, height: width * 9 / 16)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if let badge = statuses[v.url]?.badge {
                        Label(badge.text, systemImage: statuses[v.url] == .chineseReady ? "checkmark.circle.fill" : "arrow.down.circle")
                            .font(.caption2)
                            .padding(3)
                            .background(.black.opacity(0.65), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(badge.color == .secondary ? Color.white : Color.green)
                            .padding(4)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    }
                    if v.duration > 0 {
                        Text(Self.mmss(v.duration))
                            .font(.caption2.monospacedDigit())
                            .padding(3)
                            .background(.black.opacity(0.7), in: RoundedRectangle(cornerRadius: 4))
                            .foregroundStyle(.white)
                            .padding(4)
                    }
                }
                .frame(width: width)
                Text(v.title)
                    .font(.caption)
                    .lineLimit(2)
                    .frame(width: width, alignment: .leading)
                HStack(spacing: 6) {
                    if let ch = v.channel {
                        Text(ch).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    if let vc = v.viewCountText {
                        Text("· \(vc)").font(.caption2).foregroundStyle(.tertiary).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button {
                url = v.url
                session.startOriginal(url: v.url, profile: profile)
            } label: {
                Label("播放原声", systemImage: "waveform")
            }
            Button {
                url = v.url
                session.start(url: v.url, profile: profile)
            } label: {
                Label("直接转中文配音", systemImage: "character.bubble")
            }
        }
    }

    static func mmss(_ t: Double) -> String {
        let s = max(0, Int(t))
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%02d:%02d", s / 60, s % 60)
    }

}

// MARK: - 会话模型
@MainActor
final class LiveSession: ObservableObject {
    enum Mode { case chinese, original }

    @Published var phaseTitle = "待机"
    @Published var progress: Double = 0
    @Published var detail = ""
    @Published var isRunning = false
    @Published var finished = false
    @Published var errorText = ""
    @Published var dubbedSeconds: Double = 0
    @Published var totalSeconds: Double = 0
    @Published var player: AVPlayer?
    @Published var currentSubtitle = ""
    // —— 原声/中文双模式状态
    @Published var mode: Mode = .chinese
    @Published var sourceURL: URL?              // 可播放的原片文件（job 目录缓存）
    @Published var chineseReady = false         // 中文版分片/成片就绪，可切换
    @Published var converting = false           // 中文配音管线后台运行中（原声播放不中断）
    @Published var convertingPhase = ""
    @Published var convertingProgress: Double = 0
    @Published var downloadingOriginal = false
    @Published var playbackRate: Float = 1.0 {
        didSet {
            // 播放中即时生效；暂停时只记住，下次开播按新倍速
            guard playbackRate != oldValue, let p = player, p.rate > 0 else { return }
            p.rate = playbackRate
        }
    }

    static let speedOptions: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0]

    static func rateLabel(_ r: Float) -> String {
        r == Float(Int(r)) ? String(format: "%gx", r) : String(format: "%.2gx", r)
    }

    private var runTask: Task<Void, Never>?
    private var timeObserver: Any?
    private var cues: [SrtCue] = []
    private var watchedSeconds: Double = 0
    private var liveToken: String?
    private var activeJobID: String?
    private var activeURL = ""
    private var activeProfile: Profile = .balanced

    // MARK: 启动：中文实时（原有路径）

    func start(url: String, profile: Profile) {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        reset()
        mode = .chinese
        let profile = AppSettings.applied(profile)   // 全局代理覆盖（不改名称，重播/复用匹配不受影响）
        activeURL = u; activeProfile = profile

        // —— 重播秒开：同 URL+profile 的已完成任务直接复用（live 目录优先，无则成片直读）
        if let hit = Self.findReplay(url: u, profile: profile) {
            playChineseReplay(hit)
            return
        }

        phaseTitle = "准备"
        isRunning = true
        let store = JobStore()
        // 复用已有 job（原声播放/历史任务的同 URL job，下载/转录缓存全继承），避免重新下载
        let jobID: String
        if let existing = Self.findExistingJobID(url: u, profileName: profile.name, store: store) {
            jobID = existing
        } else {
            do { jobID = try store.newJob(url: u, profile: profile) } catch {
                errorText = "任务创建失败：\(error.localizedDescription)"; isRunning = false; return
            }
        }
        activeJobID = jobID
        sourceURL = store.existingSource(jobID)

        runTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .unbounded)
            let work = Task.detached {
                do {
                    try await LivePipeline().run(url: u, profile: profile, jobID: jobID,
                                                 store: store, events: continuation)
                } catch is CancellationError {
                    continuation.yield(.log("已停止（已完成的分片保留在任务目录）"))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            for await ev in stream {
                guard let self else { break }
                self.handle(ev)
            }
            work.cancel()   // 观察端退出时通知管线
        }
    }

    // MARK: 启动：原声即载即播

    /// 优先级：中文成品秒播（该视频已转换过）→ 原片缓存秒播 → 下载原片后播放
    func startOriginal(url: String, profile: Profile) {
        let u = url.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { return }
        reset()
        let applied = AppSettings.applied(profile)
        activeURL = u; activeProfile = applied

        let store = JobStore()
        // 已有中文成品：直接播中文（与点「实时中文」一致）
        if let hit = Self.findReplay(url: u, profile: applied) {
            mode = .chinese
            playChineseReplay(hit)
            return
        }

        mode = .original
        // 已缓存原片 → 秒播（优先复用现成 job，转换时缓存全继承）
        activeJobID = Self.findExistingJobID(url: u, profileName: applied.name, store: store)
        if let id = activeJobID, let src = store.existingSource(id) {
            sourceURL = src
            Task { await self.playSource(src) }
            return
        }

        // 下载原片 → 播放（成品 job，后续转换免二次下载）
        let jobID: String
        do { jobID = try store.newJob(url: u, profile: applied) } catch {
            errorText = "任务创建失败：\(error.localizedDescription)"; return
        }
        activeJobID = jobID
        downloadingOriginal = true
        isRunning = true
        phaseTitle = "下载原声"
        progress = 0
        let dest = store.source(jobID)

        runTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .unbounded)
            let work = Task.detached {
                do {
                    let engines = try EngineAssembly.engineSet(for: applied)
                    let file = try await engines.downloader.download(
                        url: u, to: dest, options: applied.download) { p, msg in
                        continuation.yield(.phase("下载原声", max(0, min(0.999, p)), msg))
                    }
                    continuation.yield(.sourceReady(file))
                } catch is CancellationError {
                    // stop()：静默取消
                } catch {
                    continuation.yield(.failed("原声下载失败：\(error.localizedDescription)"))
                }
                continuation.finish()
            }
            for await ev in stream {
                guard let self else { break }
                self.handle(ev)
            }
            work.cancel()
        }
    }

    // MARK: 播放中切换

    /// 原声 ↔ 中文；未就绪时点中文则先启动后台配音
    func switchToOriginal() {
        guard mode != .original, let src = sourceURL else { return }
        let watched = watchedSeconds
        mode = .original
        currentSubtitle = ""
        // 容器不被 AVPlayer 支持（旧 webm/mkv 缓存）→ 走转码兜底
        guard MediaCompat.isNativePlayable(src) else {
            Task { await self.playSource(src) }
            return
        }
        player = AVPlayer(url: src)
        startSubtitleTracking()
        phaseTitle = "原声播放"
        totalSeconds = ffprobeDuration(src) ?? totalSeconds
        let dur = ffprobeDuration(src) ?? 0
        let target = dur > 0 ? min(watched, dur - 1) : watched
        if target > 1 { player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) }
        startPlayback()
    }

    func switchToChinese() {
        guard mode != .chinese else { return }
        let watched = watchedSeconds

        // 1) live 分片目录（自己转换出的伪直播）→ 秒切并 seek 到当前位置
        if liveToken == nil, let id = activeJobID {
            let m3u8 = JobStore().jobDir(id: id).appendingPathComponent("live").appendingPathComponent("live.m3u8")
            if FileManager.default.fileExists(atPath: m3u8.path) {
                liveToken = LiveMediaStore.shared.register(dir: m3u8.deletingLastPathComponent())
            }
        }
        if let token = liveToken {
            mode = .chinese
            phaseTitle = "实时配音"
            player = Self.makePlayer(token: token)
            startSubtitleTracking()
            let target = dubbedSeconds > 0 ? min(watched, max(0, dubbedSeconds - 1)) : watched
            if target > 1 { player?.seek(to: CMTime(seconds: target, preferredTimescale: 600)) }
            startPlayback()
            return
        }
        // 2) 有成片但非本会话产物（批量管线等）→ 直接播成片
        if let hit = Self.findReplay(url: activeURL, profile: activeProfile) {
            mode = .chinese
            playChineseReplay(hit)
            return
        }
        // 3) 什么都没有：启动后台配音（原声继续播）
        if !converting, !isRunning { beginChinese() }
    }

    /// 在原声播放时启动中文配音管线（同 job 断点续跑：下载/转录/切分缓存全复用）
    func beginChinese() {
        guard !converting, !isRunning else { return }
        guard !activeURL.isEmpty else { return }
        if let hit = Self.findReplay(url: activeURL, profile: activeProfile) {
            mode = .chinese
            playChineseReplay(hit)
            return
        }
        let store = JobStore()
        let realProfile = effectiveProfileForJob(store)
        let jobID: String
        if let id = activeJobID {
            jobID = id
        } else if let existing = Self.findExistingJobID(url: activeURL, profileName: activeProfile.name, store: store) {
            jobID = existing; activeJobID = existing
        } else {
            do { jobID = try store.newJob(url: activeURL, profile: activeProfile) } catch {
                errorText = "任务创建失败：\(error.localizedDescription)"; return
            }
            activeJobID = jobID
        }
        if sourceURL == nil { sourceURL = store.existingSource(jobID) }

        converting = true
        isRunning = true
        if mode == .original {
            convertingPhase = "准备"; convertingProgress = 0
        } else {
            phaseTitle = "准备"
        }
        let url = activeURL
        runTask = Task { [weak self] in
            let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .unbounded)
            let work = Task.detached {
                do {
                    try await LivePipeline().run(url: url, profile: realProfile, jobID: jobID,
                                                 store: store, events: continuation)
                } catch is CancellationError {
                    continuation.yield(.log("已停止（已完成的分片保留在任务目录）"))
                } catch {
                    continuation.yield(.failed(error.localizedDescription))
                }
                continuation.finish()
            }
            for await ev in stream {
                guard let self else { break }
                self.handle(ev)
            }
            work.cancel()
        }
    }

    func stop() {
        runTask?.cancel()
        runTask = nil
        let wasConverting = converting, wasDownloading = downloadingOriginal
        converting = false
        downloadingOriginal = false
        if isRunning {
            isRunning = false
            phaseTitle = wasConverting && mode == .original ? "原声播放" : "已停止"
            AppLog.info("player", "已停止播放/转换")
        }
        // 中文模式下播放器对齐旧行为：暂停；原声模式静默保留播放
        if mode == .chinese { player?.pause() }
        if wasDownloading { player = nil; currentSubtitle = ""; stopSubtitleTracking() }
    }

    /// 任务的 profile 快照优先（缓存按任务口径复用），无快照用当前会话 profile；
    /// 快照同样要叠加全局设置（代理/模型分配），否则模型改名后快照还带旧值
    private func effectiveProfileForJob(_ store: JobStore) -> Profile {
        if let id = activeJobID, let snap = store.loadProfileSnapshot(id: id) {
            return AppSettings.applied(snap)
        }
        return activeProfile
    }

    // MARK: 内部播放

    /// 原片播放入口：容器 AVPlayer 不支持（webm/mkv 缓存）时先转码 MP4
    private func playSource(_ file: URL) async {
        var playable = file
        if !MediaCompat.isNativePlayable(file) {
            phaseTitle = "转码原片"
            detail = "缓存原片是 \(file.pathExtension.uppercased()) 容器，AVPlayer 不支持，转码 MP4 中…"
            do {
                playable = try await MediaCompat.transcodeToPlayableMP4(file) { [weak self] p, m in
                    Task { @MainActor [weak self] in
                        self?.progress = p
                        if let m { self?.detail = m }
                    }
                }
                sourceURL = playable
            } catch {
                errorText = "原片转码失败：\(error.localizedDescription)"
                phaseTitle = "失败"
                return
            }
        }
        playFile(playable)
    }

    private func playFile(_ file: URL) {
        phaseTitle = "原声播放"
        progress = 0
        totalSeconds = ffprobeDuration(file) ?? 0
        player = AVPlayer(url: file)
        startSubtitleTracking()
        startPlayback()
    }

    private func playChineseReplay(_ hit: ReplayHit) {
        mode = .chinese
        chineseReady = true
        finished = true; progress = 1
        phaseTitle = "重播（缓存命中）"
        sourceURL = hit.source
        loadCues(from: hit.srt)
        totalSeconds = ffprobeDuration(hit.finalVideo) ?? (cues.last?.end ?? 0)
        dubbedSeconds = totalSeconds
        if let liveDir = hit.liveDir {
            let token = LiveMediaStore.shared.register(dir: liveDir)
            liveToken = token
            player = Self.makePlayer(token: token)
        } else {
            player = AVPlayer(url: hit.finalVideo)   // 批量管线产物：成片直读
        }
        startSubtitleTracking()
        startPlayback()
    }

    private func reset() {
        runTask?.cancel()
        runTask = nil
        errorText = ""; finished = false; detail = ""
        progress = 0; dubbedSeconds = 0; totalSeconds = 0
        stopSubtitleTracking()
        player = nil; cues = []; currentSubtitle = ""
        mode = .chinese
        chineseReady = false; converting = false
        convertingPhase = ""; convertingProgress = 0
        downloadingOriginal = false
        sourceURL = nil; liveToken = nil
        watchedSeconds = 0; activeJobID = nil; activeURL = ""
    }

    // MARK: 事件

    private func handle(_ ev: LiveEvent) {
        switch ev {
        case .phase(let title, let p, let d):
            if mode == .original, converting {
                convertingPhase = title
                convertingProgress = p
            } else {
                phaseTitle = title
                progress = p
            }
            if let d { detail = d }
            // 原片就绪探测（进入非下载阶段说明下载完成，可切回原声）
            if sourceURL == nil, let id = activeJobID, title != "下载" {
                sourceURL = JobStore().existingSource(id)
            }
        case .log(let m):
            detail = m
        case .srtUpdated(let srt):
            loadCues(from: srt)
        case .readyToPlay(let token):
            chineseReady = true
            liveToken = token
            if mode == .chinese {
                player = Self.makePlayer(token: token)
                startSubtitleTracking()
                startPlayback()
            } else {
                convertingPhase = "中文版已就绪"
                convertingProgress = 1
            }
        case .sourceReady(let file):
            sourceURL = file
            if mode == .original {
                downloadingOriginal = false
                isRunning = false
                Task { await self.playSource(file) }
            }
        case .streamed(let dubbed, let total):
            dubbedSeconds = dubbed
            totalSeconds = total
            progress = total > 0 ? dubbed / total : 0
            if mode == .chinese { phaseTitle = "实时配音" }
        case .finished:
            finished = true
            isRunning = false
            converting = false
            progress = 1
            detail = ""
            chineseReady = true
            if mode == .original {
                convertingPhase = "已完成"
                convertingProgress = 1
            }
        case .failed(let m):
            errorText = m
            AppLog.error("player", m)
            isRunning = false
            converting = false
            downloadingOriginal = false
            phaseTitle = "失败"
        }
    }

    /// 统一开播入口：带当前倍速（新建/切换播放器后倍速不丢）
    private func startPlayback() {
        guard let p = player else { return }
        p.playImmediately(atRate: playbackRate)
    }

    // MARK: 字幕

    private func loadCues(from srt: URL) {
        guard let text = try? String(contentsOf: srt, encoding: .utf8) else { return }
        cues = SrtCue.parse(text)
    }

    private func startSubtitleTracking() {
        guard let player, timeObserver == nil else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            let t = time.seconds
            Task { @MainActor [weak self] in self?.tick(at: t) }
        }
    }

    private func stopSubtitleTracking() {
        if let obs = timeObserver, let player { player.removeTimeObserver(obs) }
        timeObserver = nil
        currentSubtitle = ""
    }

    private func tick(at t: Double) {
        watchedSeconds = t
        if mode == .chinese {
            currentSubtitle = cues.first(where: { $0.contains(t) })?.text ?? ""
        } else if !currentSubtitle.isEmpty {
            currentSubtitle = ""
        }
    }

    // MARK: 查找辅助

    /// 重播命中：live 目录优先（秒开+全片 seek），否则成片直读（批量管线产物）
    struct ReplayHit {
        let liveDir: URL?
        let finalVideo: URL
        let srt: URL
        var source: URL?
    }

    static func findReplay(url: String, profile: Profile) -> ReplayHit? {
        let store = JobStore()
        let fm = FileManager.default
        for (id, st) in store.allJobs() where st.url == url && st.profileName == profile.name {
            guard store.hasFinalVideo(id) else { continue }
            let live = store.jobDir(id: id).appendingPathComponent("live", isDirectory: true)
                .appendingPathComponent("live.m3u8")
            let liveDir: URL? = fm.fileExists(atPath: live.path) ? live.deletingLastPathComponent() : nil
            return ReplayHit(liveDir: liveDir, finalVideo: store.finalVideo(id), srt: store.subtitles(id),
                             source: store.existingSource(id))
        }
        return nil
    }

    /// 已缓存原片（source.*）的现成 job：同名 profile 优先，其次任意
    static func findExistingJobID(url: String, profileName: String, store: JobStore) -> String? {
        let jobs = store.allJobs().filter { $0.1.url == url }
        let withSource = jobs.filter { store.existingSource($0.id) != nil }
        return withSource.first(where: { $0.status.profileName == profileName })?.id
            ?? withSource.first?.id
    }

    // MARK: 伪直播播放器（本地 loopback HTTP，系统 HLS 引擎原生拉取）

    static func makePlayer(token: String) -> AVPlayer? {
        let port = LiveHTTPServer.shared.start()
        guard port != 0, let url = URL(string: "http://127.0.0.1:\(port)/\(token)/live.m3u8") else { return nil }
        return AVPlayer(url: url)
    }
}

// MARK: - SRT cue 解析（字幕同步显示）

struct SrtCue: Equatable {
    let start: Double
    let end: Double
    let text: String

    func contains(_ t: Double) -> Bool { t >= start && t < end }

    static func parse(_ srt: String) -> [SrtCue] {
        var cues: [SrtCue] = []
        let blocks = srt.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n\n")
        for block in blocks {
            let lines = block.split(separator: "\n", omittingEmptySubsequences: false)
            guard let tsLine = lines.first(where: { $0.contains("-->") }) else { continue }
            let parts = tsLine.components(separatedBy: "-->")
            guard parts.count == 2,
                  let start = timestamp(parts[0]), let end = timestamp(parts[1]) else { continue }
            let text = lines.drop(while: { !$0.contains("-->") }).dropFirst()
                .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !text.isEmpty { cues.append(SrtCue(start: start, end: end, text: text)) }
        }
        return cues
    }

    private static func timestamp(_ s: String) -> Double? {
        let comps = s.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: ",", with: ".")
            .split(separator: ":")
        guard comps.count == 3,
              let h = Double(comps[0]), let m = Double(comps[1]), let sec = Double(comps[2])
        else { return nil }
        return h * 3600 + m * 60 + sec
    }
}
