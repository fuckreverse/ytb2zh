import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - App 入口

@main
struct Ytb2ZHAppMain: App {
    var body: some Scene {
        WindowGroup("ytb2zh 实时译配") {
            ContentView()
                .frame(minWidth: 1000, minHeight: 700)
                .tint(AppTheme.accent)
        }
        .windowStyle(.automatic)
    }
}

// MARK: - 主界面：侧栏导航（播放 / 媒体库 / 订阅 / 任务中心 / 转换设置）

enum AppPage: String, CaseIterable, Identifiable {
    case player = "播放"
    case library = "媒体库"
    case subscriptions = "订阅"
    case jobs = "任务中心"
    case settings = "视频转换"
    case app = "应用设置"

    var id: String { rawValue }
    var icon: String {
        switch self {
        case .player: return "play.tv"
        case .library: return "film.stack"
        case .subscriptions: return "antenna.radiowaves.left.and.right"
        case .jobs: return "list.bullet.rectangle"
        case .settings: return "slider.horizontal.3"
        case .app: return "gearshape"
        }
    }
}

struct ContentView: View {
    @AppStorage("appAppearance") private var appearance = "dark"
    @State private var page: AppPage = .player
    @State private var selectedTemplate: TemplateStore.Entry?
    @State private var workingProfile: Profile = .balanced
    /// 当前面板参数的基线（最近一次载入/保存的模板），用于检测“未保存的修改”
    @State private var baselineProfile: Profile = .balanced
    @State private var videoURL = ""
    @State private var refreshTemplates = UUID()
    @State private var job: PipelineJob?
    /// 待确认切换的模板（有未保存修改时先弹确认，防静默丢弃）
    @State private var pendingLoad: TemplateStore.Entry?
    @StateObject private var liveSession = LiveSession()

    private let templateStore = TemplateStore()

    var body: some View {
        HStack(spacing: 0) {
            SidebarView(page: $page).frame(width: 218)
            Divider()
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(L(page.rawValue)).font(.system(size: 15, weight: .semibold))
                    Spacer()
                    Label("让视频说中文", systemImage: "waveform")
                        .font(.caption).foregroundStyle(.secondary)
                    Button { page = .settings } label: {
                        Label("添加视频", systemImage: "plus")
                    }.buttonStyle(CinemaButtonStyle(prominent: true))
                }.padding(.horizontal, 28).padding(.vertical, 14)
                Divider().opacity(0.5)
                pageContent.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background(AppTheme.canvas)
        .buttonStyle(CinemaButtonStyle())
        .textFieldStyle(CinemaTextFieldStyle())
        .toggleStyle(CinemaToggleStyle())
        .menuStyle(CinemaMenuStyle())
        .progressViewStyle(CinemaProgressStyle())
        .labeledContentStyle(CinemaLabeledContentStyle())
        .preferredColorScheme(appearance == "dark" ? .dark : appearance == "light" ? .light : nil)
        .onReceive(NotificationCenter.default.publisher(for: .ytb2zhNavigate)) { note in
            if let target = note.object as? AppPage { page = target }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ytb2zhResumeJob)) { note in
            guard let req = note.object as? ResumeRequest else { return }
            page = .jobs
            resume(req)
        }
        .confirmationDialog("切换模板将放弃未保存的修改", isPresented: Binding(get: { pendingLoad != nil }, set: { if !$0 { pendingLoad = nil } }), titleVisibility: .visible, presenting: pendingLoad) { entry in
            Button("放弃修改，载入「\(entry.profile.name)」", role: .destructive) { loadTemplate(entry) }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("当前参数尚未保存为模板，切换会丢失修改。")
        }
    }

    @ViewBuilder private var pageContent: some View {
            switch page {
            case .player:
                LivePlayerView(profile: workingProfile, session: liveSession)
                    .navigationTitle("播放")
            case .library:
                LibraryView(profile: workingProfile, onPlayed: nil)
                    .navigationTitle("媒体库")
            case .subscriptions:
                SubscriptionsView(profile: workingProfile) { }
                    .navigationTitle("订阅")
            case .jobs:
                JobCenterView(job: job ?? PipelineJob())
            case .settings:
                SettingsPane(videoURL: $videoURL, workingProfile: $workingProfile,
                             selectedTemplate: $selectedTemplate, refreshTemplates: $refreshTemplates,
                             templateStore: templateStore, job: $job,
                             baselineProfile: $baselineProfile,
                             hasUnsavedChanges: hasUnsavedChanges,
                             onSelectTemplate: requestLoad, onDeleteTemplate: deleteTemplate)
                    .navigationTitle("视频转换")
            case .app:
                AppSettingsView()
                    .navigationTitle("应用设置")
            }
    }

    // MARK: 模板载入/删除（带未保存修改保护）

    private var hasUnsavedChanges: Bool {
        !workingProfile.isEqualIgnoringName(to: baselineProfile)
    }

    /// 请求载入模板；返回 true = 已立即载入，false = 已弹确认等待用户决定
    @discardableResult
    private func requestLoad(_ entry: TemplateStore.Entry) -> Bool {
        if entry.profile.isEqualIgnoringName(to: workingProfile) {
            // 内容相同（可能只是重命名/重新点同一个模板），直接对齐基线
            loadTemplate(entry)
            return true
        }
        if hasUnsavedChanges {
            pendingLoad = entry
            return false
        }
        loadTemplate(entry)
        return true
    }

    private func loadTemplate(_ entry: TemplateStore.Entry) {
        workingProfile = entry.profile
        baselineProfile = entry.profile
        selectedTemplate = entry
        page = .settings
    }

    private func deleteTemplate(_ entry: TemplateStore.Entry) {
        guard entry.location == .user else { return }
        try? templateStore.delete(entry.profile)
        if selectedTemplate?.id == entry.id { selectedTemplate = nil }
        refreshTemplates = UUID()
        AppLog.info("template", "已删除用户模板：\(entry.profile.name)")
    }

    /// 从某步续跑（译文/术语编辑器发起）
    @MainActor
    private func resume(_ req: ResumeRequest) {
        let store = JobStore()
        let status = store.loadStatus(req.jobID)
        var profile = Profile(name: status.profileName)
        // 从任务目录的 manifest 里取回参数（newJob 时写入的 profile）
        if let saved = store.readJSON(store.jobDir(id: req.jobID).appendingPathComponent("profile.json"),
                                      as: Profile.self) {
            profile = saved
        }
        let order = StepID.allCases
        let filter = Set(order.filter { order.firstIndex(of: $0)! >= order.firstIndex(of: req.from)! })
        let j = job ?? PipelineJob()
        job = j
        j.start(url: status.url, profile: profile, jobID: req.jobID, stepFilter: filter)
    }
}

// MARK: - 侧栏：功能导航 + 模板起点

struct SidebarView: View {
    @Binding var page: AppPage
    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 18, weight: .black))
                    .foregroundStyle(.white).frame(width: 38, height: 38)
                    .background(AppTheme.accent.gradient, in: RoundedRectangle(cornerRadius: 12))
                Text("ytb2zh").font(.system(size: 23, weight: .heavy)).tracking(-1)
            }.padding(.top, 14).padding(.horizontal, 12)
            VStack(alignment: .leading, spacing: 6) {
                Text("探索与观看").font(.system(size: 10, weight: .semibold)).tracking(2)
                    .foregroundStyle(.secondary).padding(12)
                ForEach([AppPage.player, .library, .subscriptions]) { item in navItem(item) }
                Text("创作工作台").font(.system(size: 10, weight: .semibold)).tracking(2)
                    .foregroundStyle(.secondary).padding(12).padding(.top, 16)
                ForEach([AppPage.settings, .jobs]) { item in navItem(item) }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: "waveform.circle.fill").font(.title2).foregroundStyle(AppTheme.accent)
                Text("世界很大，听懂更多").font(.system(size: 12, weight: .semibold))
                Text("原声与中文，自由切换").font(.caption2).foregroundStyle(.secondary)
            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 14))
            navItem(.app)
        }.padding(16).background(AppTheme.sidebar)
    }

    private func navItem(_ item: AppPage) -> some View {
        Button { page = item } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon).font(.system(size: 16, weight: .medium)).frame(width: 22)
                Text(L(item.rawValue)).font(.system(size: 13, weight: page == item ? .semibold : .medium))
                Spacer()
                if page == item { Circle().fill(AppTheme.accent).frame(width: 5, height: 5) }
            }.padding(.horizontal, 14).padding(.vertical, 13)
                .foregroundStyle(page == item ? AppTheme.accent : .primary)
                .background(page == item ? AppTheme.accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
        }.buttonStyle(.plain).accessibilityAddTraits(page == item ? .isSelected : [])
    }
}

// MARK: - 转换设置页（高级）：视频源 + 引擎 + 参数 + 批量转换

struct SettingsPane: View {
    @Binding var videoURL: String
    @Binding var workingProfile: Profile
    @Binding var selectedTemplate: TemplateStore.Entry?
    @Binding var refreshTemplates: UUID
    let templateStore: TemplateStore
    @Binding var job: PipelineJob?
    @Binding var baselineProfile: Profile
    let hasUnsavedChanges: Bool
    let onSelectTemplate: (TemplateStore.Entry) -> Bool
    let onDeleteTemplate: (TemplateStore.Entry) -> Void
    @State private var templateToDelete: TemplateStore.Entry?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("基于模板：\(workingProfile.name)", systemImage: "square.stack")
                    .font(.headline)
                if hasUnsavedChanges {
                    Text("有未保存的修改")
                        .font(.caption).foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 2)
                        .background(Capsule().fill(.orange.opacity(0.15)))
                        .help("参数已偏离模板默认值；点右上角「模板 → 另存为模板」可保留，直接切模板会丢弃")
                }
                Spacer()
                SaveTemplateMenu(profile: workingProfile, templateStore: templateStore) { saved in
                    baselineProfile = saved
                    refreshTemplates = UUID()
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            CinemaForm {
                CinemaSection {
                    PageHeading(title: "把精彩内容，变成中文", subtitle: "选择视频与场景，译配完成后自动保存到媒体库")
                    HStack {
                        TextField("视频链接或本地视频路径", text: $videoURL)
                            .textFieldStyle(CinemaTextFieldStyle()).controlSize(.large)
                        LocalVideoPicker { file in
                            videoURL = file.absoluteString
                        }
                        .buttonStyle(CinemaButtonStyle())
                    }
                    VideoSourcePreview(source: videoURL, proxy: AppSettings.effectiveProxy(fallback: workingProfile.download.proxy))
                    if !videoURL.isEmpty {
                        Label(VideoCatalogService.isLikelyListURL(videoURL) ? "频道与播放列表可在播放页展开浏览" : (LocalMediaSource.url(for: videoURL) != nil ? "本地视频已选定，可先试转 3 分钟" : "视频链接已填入，可先试转 3 分钟"), systemImage: "link")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                CinemaSection("选择场景") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 230), spacing: 12)], spacing: 12) {
                        ForEach(templateStore.all()) { entry in
                            Button { _ = onSelectTemplate(entry) } label: {
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack {
                                        Image(systemName: entry.profile.engines["synthesize"] == "none" ? "captions.bubble" : "waveform")
                                        Text(entry.profile.name).font(.headline)
                                        Spacer()
                                        if entry.profile.name == workingProfile.name {
                                            Image(systemName: "checkmark.circle.fill")
                                        }
                                    }
                                    Text(L(entry.profile.blurb)).font(.caption).foregroundStyle(.secondary)
                                        .lineLimit(3).frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)
                                }
                                .padding(14)
                                .background(entry.profile.name == workingProfile.name ? AppTheme.accent.opacity(0.09) : AppTheme.surface,
                                            in: RoundedRectangle(cornerRadius: 12))
                                .overlay(RoundedRectangle(cornerRadius: 12).stroke(entry.profile.name == workingProfile.name ? AppTheme.accent : Color.primary.opacity(0.08)))
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if entry.location == .user {
                                    Button("删除模板", role: .destructive) {
                                        templateToDelete = entry
                                    }
                                }
                            }
                        }
                    }.id(refreshTemplates)
                }

                ParameterPanel(profile: $workingProfile)
            }

            .scrollContentBackground(.hidden)
            .frame(maxWidth: 1100)
            .frame(maxWidth: .infinity)

            Divider()

            RunBar(videoURL: videoURL, profile: workingProfile, job: $job)
        }
        .confirmationDialog("删除这个模板？", isPresented: Binding(get: { templateToDelete != nil }, set: { if !$0 { templateToDelete = nil } }), presenting: templateToDelete) { entry in
            Button("删除模板", role: .destructive) { onDeleteTemplate(entry) }
            Button("取消", role: .cancel) { }
        } message: { entry in
            Text("删除「\(entry.profile.name)」后不可恢复。")
        }
    }
}

// MARK: - 保存模板菜单（保存当前面板全部参数为用户模板）

struct SaveTemplateMenu: View {
    let profile: Profile
    let templateStore: TemplateStore
    let onSaved: (Profile) -> Void
    @State private var newName = ""
    @State private var showSheet = false

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }

    private var isDuplicateName: Bool {
        !trimmedName.isEmpty && templateStore.all().contains { $0.profile.name == trimmedName }
    }

    var body: some View {
        Menu {
            Button("另存为模板…") {
                newName = ""
                showSheet = true
            }
        } label: {
            Label("模板", systemImage: "square.and.arrow.down")
        }
        .sheet(isPresented: $showSheet) {
            CinemaPresentation {
                VStack(spacing: 12) {
                    Text("另存为模板").font(.headline)
                    Text("将保存当前面板的全部参数：引擎组合、翻译风格、音色、对齐调度、字幕与混音等")
                        .font(.callout).foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 300)
                    TextField("模板名称", text: $newName)
                        .textFieldStyle(CinemaTextFieldStyle())
                        .frame(width: 260)
                    if isDuplicateName {
                        Label("同名模板已存在，保存将覆盖它", systemImage: "exclamationmark.triangle")
                            .font(.callout).foregroundStyle(.orange)
                    }
                    HStack {
                        Button("取消") { showSheet = false }
                        Button("保存") {
                            var p = profile
                            p.name = newName.trimmingCharacters(in: .whitespaces)
                            do { try templateStore.save(p) } catch { return }
                            showSheet = false
                            onSaved(p)
                        }
                        .keyboardShortcut(.return)
                        .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
                .padding(24)
            }
        }
    }
}
