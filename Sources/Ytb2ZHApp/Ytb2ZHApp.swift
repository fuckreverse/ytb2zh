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
    @State private var videoURL = ""
    @State private var refreshTemplates = UUID()
    @State private var job: PipelineJob?
    @StateObject private var liveSession = LiveSession()

    private let templateStore = TemplateStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(page: $page, selected: $selectedTemplate, workingProfile: $workingProfile,
                        refresh: $refreshTemplates, templateStore: templateStore)
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
                             templateStore: templateStore, job: $job)
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
    @Binding var workingProfile: Profile
    @Binding var refresh: UUID
    let templateStore: TemplateStore

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
            Section("模板起点（载入后到转换设置微调）") {
                ForEach(templateStore.all()) { entry in
                    Button {
                        workingProfile = entry.profile.derived(named: entry.profile.name)
                        selected = entry
                        page = .settings
                    } label: {
                        HStack {
                            Image(systemName: entry.location == .builtin ? "lock.fill" : "person.crop.circle")
                                .foregroundStyle(entry.location == .builtin ? Color.secondary : Color.blue)
                            Text(entry.profile.name)
                            Spacer()
                            Text(entry.location == .builtin ? "内置" : "用户")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .id(refresh)
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            Text("模板决定翻译风格与引擎组合；调整参数后可另存为用户模板")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
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

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Label("基于模板：\(workingProfile.name)", systemImage: "square.stack")
                    .font(.headline)
                Spacer()
                SaveTemplateMenu(profile: workingProfile, templateStore: templateStore) {
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
                        .onChange(of: workingProfile.name) { _, newName in
                            if let e = templateStore.all().first(where: { $0.profile.name == newName }) {
                                workingProfile = e.profile
                            }
                        }
                    }
                    LabeledContent("代理 / 模型提供者") {
                        Text(AppSettings.proxy.isEmpty
                             ? "未设全局代理，用模板内置；点侧栏「应用设置」统一配置"
                             : "全局代理 \(AppSettings.proxy)；在侧栏「应用设置」修改")
                            .foregroundStyle(.secondary)
                            .font(.callout)
                    }
                    LabeledContent("想边处理边看？") {
                        Text("改用侧栏「播放」页：处理到哪看到哪，无需等整片完成")
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

// MARK: - 保存/派生模板菜单

struct SaveTemplateMenu: View {
    let profile: Profile
    let templateStore: TemplateStore
    let onSaved: () -> Void
    @State private var newName = ""
    @State private var showSheet = false

    var body: some View {
        Menu {
            Button("另存为模板…") { showSheet = true }
            Divider()
            ForEach(["精准对齐", "从容解说", "仅字幕（不配音）"], id: \.self) { b in
                Button("从「\(b)」派生…") {
                    if let base = Profile.builtins.first(where: { $0.name == b }) {
                        newName = base.name + " 变体"
                        showSheet = true
                    }
                }
            }
        } label: {
            Label("模板", systemImage: "square.and.arrow.down")
        }
        .sheet(isPresented: $showSheet) {
            VStack(spacing: 12) {
                Text("模板名称").font(.headline)
                TextField("名称", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
                HStack {
                    Button("取消") { showSheet = false }
                    Button("保存") {
                        var p = profile
                        p.name = newName
                        try? templateStore.save(p)
                        showSheet = false
                        onSaved()
                    }
                    .keyboardShortcut(.return)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
            .padding(24)
        }
    }
}
