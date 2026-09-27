import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - App 入口

@main
struct Ytb2ZHAppMain: App {
    var body: some Scene {
        WindowGroup("Ytb2ZH") {
            ContentView()
                .frame(minWidth: 1080, minHeight: 700)
        }
        .windowStyle(.automatic)
    }
}

// MARK: - 主界面：左侧模板/任务，右侧参数 + 运行

struct ContentView: View {
    @State private var selectedTemplate: TemplateStore.Entry?
    @State private var workingProfile: Profile = .balanced
    @State private var videoURL = ""
    @State private var refreshTemplates = UUID()
    @State private var job: PipelineJob?
    @State private var showJobCenter = false

    private let templateStore = TemplateStore()

    var body: some View {
        NavigationSplitView {
            SidebarView(selected: $selectedTemplate, workingProfile: $workingProfile,
                        refresh: $refreshTemplates, templateStore: templateStore)
                .navigationSplitViewColumnWidth(min: 220, ideal: 260)
        } detail: {
            VStack(spacing: 0) {
                // 模板起点信息
                HStack {
                    Label("基于模板：\(workingProfile.name)", systemImage: "square.stack")
                        .font(.headline)
                    Spacer()
                    Button("任务中心") { showJobCenter = true }
                        .controlSize(.regular)
                    SaveTemplateMenu(profile: workingProfile, templateStore: templateStore) {
                        refreshTemplates = UUID()
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)

                Divider()

                Form {
                    Section("视频源") {
                        TextField("YouTube URL", text: $videoURL)
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
                    }

                    EnginePickerRow(profile: $workingProfile)
                    ParameterPanel(profile: $workingProfile)
                }
                .formStyle(.grouped)

                Divider()

                RunBar(videoURL: videoURL, profile: workingProfile, job: $job)
            }
        }
        .sheet(isPresented: $showJobCenter) {
            JobCenterView(job: job ?? PipelineJob())
                .frame(minWidth: 700, minHeight: 480)
        }
        .onReceive(NotificationCenter.default.publisher(for: .ytb2zhResumeJob)) { note in
            guard let req = note.object as? ResumeRequest else { return }
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

// MARK: - 侧栏：模板列表

struct SidebarView: View {
    @Binding var selected: TemplateStore.Entry?
    @Binding var workingProfile: Profile
    @Binding var refresh: UUID
    let templateStore: TemplateStore

    var body: some View {
        List {
            Section("模板（点按载入为起点）") {
                ForEach(templateStore.all()) { entry in
                    Button {
                        workingProfile = entry.profile.derived(named: entry.profile.name)
                        selected = entry
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
            Text("调整参数后可另存为用户模板")
                .font(.caption2).foregroundStyle(.secondary)
                .padding(8)
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
