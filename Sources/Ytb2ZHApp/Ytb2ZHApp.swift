import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - App 入口

@main
struct Ytb2ZHAppMain: App {
    var body: some Scene {
        WindowGroup("ytb2zh 实时译配") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 700)
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
    case settings = "转换设置"
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
        NavigationSplitView {
            SidebarView(page: $page, selected: $selectedTemplate,
                        refresh: $refreshTemplates, templateStore: templateStore,
                        onSelectTemplate: requestLoad, onDeleteTemplate: deleteTemplate)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240)
        } detail: {
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
                             onSelectTemplate: requestLoad)
                    .navigationTitle("转换设置")
            case .app:
                AppSettingsView()
                    .navigationTitle("应用设置")
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ytb2zhResumeJob)) { note in
            guard let req = note.object as? ResumeRequest else { return }
            page = .jobs
            resume(req)
        }
        .confirmationDialog("切换模板将放弃未保存的修改",
                            isPresented: Binding(get: { pendingLoad != nil },
                                                 set: { if !$0 { pendingLoad = nil } }),
                            titleVisibility: .visible,
                            presenting: pendingLoad) { entry in
            Button("放弃修改，载入「\(entry.profile.name)」", role: .destructive) {
                loadTemplate(entry)
            }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("你在「\(workingProfile.name)」基础上调整的参数尚未另存为模板，直接切换会丢失。可先点右上角「模板 → 另存为模板」保留。")
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
    @Binding var selected: TemplateStore.Entry?
    @Binding var refresh: UUID
    let templateStore: TemplateStore
    let onSelectTemplate: (TemplateStore.Entry) -> Bool
    let onDeleteTemplate: (TemplateStore.Entry) -> Void
    @State private var toDelete: TemplateStore.Entry?

    var body: some View {
        List(selection: $page) {
            Section {
                ForEach([AppPage.player, .library, .subscriptions, .jobs]) { p in
                    Label(L(p.rawValue), systemImage: p.icon).tag(p)
                }
            }
            Section("高级") {
                Label(L(AppPage.settings.rawValue), systemImage: AppPage.settings.icon).tag(AppPage.settings)
                Label(L(AppPage.app.rawValue), systemImage: AppPage.app.icon).tag(AppPage.app)
            }
            Section("模板起点（点击载入到转换设置）") {
                ForEach(templateStore.all()) { entry in
                    templateRow(entry)
                }
            }
        }
        .id(refresh)
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("模板决定引擎组合与参数；调整后可右上角「模板 → 另存为模板」；用户模板可右键删除")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
        }
        .confirmationDialog("删除模板「\(toDelete?.profile.name ?? "")」？",
                            isPresented: Binding(get: { toDelete != nil },
                                                 set: { if !$0 { toDelete = nil } }),
                            titleVisibility: .visible,
                            presenting: toDelete) { entry in
            Button("删除", role: .destructive) { onDeleteTemplate(entry) }
            Button("取消", role: .cancel) { }
        } message: { _ in
            Text("删除后不可恢复；内置模板无法删除。")
        }
    }

    @ViewBuilder
    private func templateRow(_ entry: TemplateStore.Entry) -> some View {
        Button {
            onSelectTemplate(entry)
        } label: {
            HStack(spacing: 6) {
                Image(systemName: entry.location == .builtin ? "lock.fill" : "person.crop.circle")
                    .foregroundStyle(entry.location == .builtin ? Color.secondary : Color.blue)
                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.profile.name)
                    if !entry.profile.blurb.isEmpty {
                        Text(entry.profile.blurb)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer()
                if entry.location == .user {
                    // 尾部删除按钮（仅用户模板；内置模板不可删）
                    Button {
                        toDelete = entry
                    } label: {
                        Image(systemName: "trash")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("删除此用户模板")
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            if entry.location == .user {
                Button("删除模板…", role: .destructive) { toDelete = entry }
            }
        }
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

            Form {
                Section("视频源 · 后台完整转换（质量优先，完成入媒体库）") {
                    TextField("YouTube URL", text: $videoURL, prompt: Text("粘贴视频 / 频道 / 播放列表地址"))
                        .textFieldStyle(.roundedBorder)
                    LabeledContent("预设") {
                        Picker("", selection: $workingProfile.name) {
                            ForEach(templateStore.all()) { e in
                                Text(e.profile.name).tag(e.profile.name)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 200)
                        .onChange(of: workingProfile.name) { oldName, newName in
                            guard oldName != newName,
                                  let e = templateStore.all().first(where: { $0.profile.name == newName }) else { return }
                            // 载入被拦截（弹了未保存确认）时回滚 Picker 显示，等用户确认后再真正切换
                            if !onSelectTemplate(e) {
                                workingProfile.name = oldName
                            }
                        }
                    }
                    // 当前模板说明（帮助新用户理解模板差异）
                    if let e = templateStore.all().first(where: { $0.profile.name == workingProfile.name }),
                       !e.profile.blurb.isEmpty {
                        Text(e.profile.blurb)
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    LabeledContent("代理 / 模型提供者") {
                        Text(AppSettings.proxy.isEmpty
                             ? "未设全局代理，用模板内置；点侧栏「应用设置」统一配置"
                             : "全局代理 \(AppSettings.proxy)；在侧栏「应用设置」修改")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                }

                Section {
                    EnginePickerRow(profile: $workingProfile)
                }

                ParameterPanel(profile: $workingProfile)
            }
            .formStyle(.grouped)

            Divider()

            RunBar(videoURL: videoURL, profile: workingProfile, job: $job)
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
            VStack(spacing: 12) {
                Text("另存为模板").font(.headline)
                Text("将保存当前面板的全部参数：引擎组合、翻译风格、音色、对齐调度、字幕与混音等")
                    .font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 300)
                TextField("模板名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
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
