import SwiftUI
import Ytb2ZHCore

// MARK: - 应用设置（全局）：网络设置 / 模型提供商 / 模型分配
// 与「转换设置」的分工：这里是应用级全局项（对所有模板与任务生效），
// 转换设置是当前模板的运行参数。
//  - 网络设置：代理 + 各用途开关 + 任务存储位置
//  - 模型提供商：多个提供商，每个可配多个模型，模型声明能力（识别/生成/翻译…）
//  - 模型分配：各阶段按所需能力筛选出可选模型，由用户选择；空 = 跟随模板

struct AppSettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case network = "网络设置"
        case providers = "模型提供商"
        case assign = "模型分配"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .network
    @StateObject private var store = ProviderStore()

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in
                    Text(t.rawValue).tag(t)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.vertical, 10)

            Divider()

            switch tab {
            case .network: NetworkTab()
            case .providers: ProvidersTab(store: store)
            case .assign: AssignTab(store: store)
            }
        }
        .navigationTitle("应用设置")
    }
}

// MARK: - 分页 1：网络设置

private struct NetworkTab: View {
    @AppStorage(AppSettings.proxyKey) private var proxy = ""
    @AppStorage(AppSettings.proxyForDownloadKey) private var forDownload = true
    @AppStorage(AppSettings.proxyForSearchKey) private var forSearch = true
    @AppStorage(AppSettings.proxyForEdgeTTSKey) private var forEdgeTTS = true
    // 存储位置
    @State private var jobRootPath = JobStore().root.path

    var body: some View {
        Form {
            Section("代理（留空 = 用各模板内置值）") {
                LabeledContent("代理地址") {
                    TextField("http://127.0.0.1:7890", text: $proxy)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                }
                LabeledContent("代理用于") {
                    HStack(spacing: 14) {
                        Toggle("视频下载", isOn: $forDownload).toggleStyle(.checkbox)
                        Toggle("YouTube 搜索", isOn: $forSearch).toggleStyle(.checkbox)
                        Toggle("Edge TTS 语音合成", isOn: $forEdgeTTS).toggleStyle(.checkbox)
                    }
                }
                .help("yt-dlp 下载、搜索取数与 edge-tts 走外网；百炼/兼容 API 直连国内或由 API 端自行处理，不受此开关影响")
            }

            Section("任务存储位置") {
                LabeledContent("当前目录") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(jobRootPath)
                            .font(.system(.caption, design: .monospaced))
                            .lineLimit(2)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                        HStack(spacing: 8) {
                            Button("更改…", action: chooseRoot)
                            Button("恢复默认", action: resetRoot)
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([JobStore().root])
                            } label: { Label("打开目录", systemImage: "folder") }
                        }
                        Text("新任务将存到这里；已有任务仍在原位置（迁移请整个移动 Jobs 文件夹后改到这里）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = "选择任务存储目录（新任务的 Jobs 根目录）"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: AppSettings.jobRootKey)
        jobRootPath = JobStore().root.path
    }

    private func resetRoot() {
        UserDefaults.standard.removeObject(forKey: AppSettings.jobRootKey)
        jobRootPath = JobStore().root.path
    }
}

// MARK: - 分页 2：模型提供商
// 注意：这里刻意不用 ForEach($store.providers) / ForEach($pr.models) 集合元素
// Binding 语法糖——行内删除会使底层数组缩短，同一布局事务里 TextField 内部的
// ValueAction 仍会读取已删除元素的旧 Binding（getter 对数组做下标访问），
// 触发 Fatal error: Index out of range（EXC_BREAKPOINT/SIGTRAP，
// 见 2026-09-27 Ytb2ZHApp-141115.ips 崩溃日志）。
// 改为值迭代 + 以 id 锚定的安全 Binding：get 用 first(where:) 永不越界
// （找不到时回退空值，行下一次渲染即消失），set 找不到锚点时静默丢弃。

private struct ProvidersTab: View {
    @ObservedObject var store: ProviderStore

    var body: some View {
        Form {
            ForEach(store.providers) { pr in
                ProviderSection(store: store, providerID: pr.id)
            }

            Section {
                Menu {
                    ForEach(ProviderKind.allCases) { k in
                        Button(k.label) { store.add(k) }
                    }
                } label: {
                    Label("添加提供商", systemImage: "plus")
                }
            }
        }
        .formStyle(.grouped)
        .onChange(of: store.providers) { _ in store.save() }
    }
}

private struct ProviderSection: View {
    @ObservedObject var store: ProviderStore
    let providerID: String

    var body: some View {
        let pr = providerBinding
        Section {
            LabeledContent("类型") {
                Picker("", selection: pr.kind) {
                    ForEach(ProviderKind.allCases) { k in
                        Text(k.label).tag(k)
                    }
                }
                .labelsHidden()
                .frame(width: 200)
            }
            LabeledContent("名称") {
                TextField("如 本地网关 / OpenAI / 硅基流动", text: pr.name)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 340)
            }
            if pr.wrappedValue.kind.needsBaseURL {
                LabeledContent(pr.wrappedValue.kind.baseURLLabel) {
                    TextField(pr.wrappedValue.kind.defaultBaseURL, text: pr.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                }
            }
            if pr.wrappedValue.kind.needsAPIKey {
                LabeledContent("API Key") {
                    SecureField("sk-…", text: pr.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 340)
                }
            }

            LabeledContent("模型（\(pr.wrappedValue.models.count)）") {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(pr.wrappedValue.models) { mo in
                        modelRow(mo.id)
                    }
                    Button {
                        store.addModel(providerID: providerID)
                    } label: {
                        Label("添加模型", systemImage: "plus.circle")
                    }
                    .buttonStyle(.link)
                }
            }
            .padding(.vertical, 4)

            Text(pr.wrappedValue.kind.hint)
                .font(.caption2).foregroundStyle(.secondary)

            HStack {
                Spacer()
                Button("删除此提供商", role: .destructive) {
                    store.removeProvider(id: providerID)
                }
                .buttonStyle(.link)
                .font(.caption)
            }
        } header: {
            Text(pr.wrappedValue.name.isEmpty ? "未命名提供商" : pr.wrappedValue.name)
        }
    }

    /// 以 providerID 锚定的安全 Binding：永不越界
    private var providerBinding: Binding<ProviderConfig> {
        Binding(
            get: { store.providers.first { $0.id == providerID } ?? ProviderConfig(name: "") },
            set: { new in
                guard let i = store.providers.firstIndex(where: { $0.id == providerID }) else { return }
                store.providers[i] = new
            })
    }

    /// 以 (providerID, modelID) 锚定的安全 Binding：永不越界
    private func modelBinding(_ modelID: String) -> Binding<ProviderModel> {
        Binding(
            get: {
                store.providers.first { $0.id == providerID }?.models.first { $0.id == modelID }
                    ?? ProviderModel(name: "")
            },
            set: { new in
                guard let pi = store.providers.firstIndex(where: { $0.id == providerID }),
                      let mi = store.providers[pi].models.firstIndex(where: { $0.id == modelID }) else { return }
                store.providers[pi].models[mi] = new
            })
    }

    private func modelRow(_ modelID: String) -> some View {
        HStack(spacing: 10) {
            TextField("模型 ID / 名称", text: modelBinding(modelID).name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
            ForEach(ModelCapability.allCases) { cap in
                Toggle(cap.label, isOn: capBinding(modelBinding(modelID), cap))
                    .toggleStyle(.checkbox)
                    .font(.caption)
            }
            Button {
                store.removeModel(providerID: providerID, modelID: modelID)
            } label: {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("删除该模型")
        }
    }

    private func capBinding(_ mo: Binding<ProviderModel>, _ cap: ModelCapability) -> Binding<Bool> {
        Binding(
            get: { mo.wrappedValue.capabilities.contains(cap) },
            set: { on in
                if on {
                    if !mo.wrappedValue.capabilities.contains(cap) { mo.wrappedValue.capabilities.append(cap) }
                } else {
                    mo.wrappedValue.capabilities.removeAll { $0 == cap }
                }
            })
    }
}

// MARK: - 分页 3：模型分配（按能力筛选）

private struct AssignTab: View {
    struct StageNeed: Identifiable {
        let step: StepID
        let capability: ModelCapability
        var id: String { step.rawValue }
    }

    @ObservedObject var store: ProviderStore
    @State private var stageModels: [String: String] = AppSettings.stageModels

    /// 各阶段所需的模型能力
    private let needs: [StageNeed] = [
        .init(step: .transcribe, capability: .transcribe),
        .init(step: .translate, capability: .translate),
        .init(step: .segment, capability: .segment),
        .init(step: .summarize, capability: .terminology),
        .init(step: .synthesize, capability: .tts),
    ]

    var body: some View {
        Form {
            Section {
                ForEach(needs) { n in
                    LabeledContent(n.step.label) {
                        VStack(alignment: .trailing, spacing: 2) {
                            Picker("", selection: binding(n.step)) {
                                Text("跟随模板").tag("")
                                ForEach(store.providers) { pr in
                                    ForEach(pr.models.filter { $0.capabilities.contains(n.capability) }) { mo in
                                        Text("\(pr.displayName) · \(mo.name)").tag("\(pr.id)|\(mo.id)")
                                    }
                                }
                            }
                            .labelsHidden()
                            .frame(width: 340)
                            Text("需要能力：\(n.capability.label)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("各阶段使用的模型（只列出声明了对应能力的模型）")
            } footer: {
                Text("能力在「模型提供商」页为每个模型勾选；选「跟随模板」用当前模板内置的引擎与参数。此处的分配优先于模板。")
            }
        }
        .formStyle(.grouped)
    }

    private func binding(_ step: StepID) -> Binding<String> {
        Binding(
            get: { stageModels[step.rawValue] ?? "" },
            set: { newValue in
                if newValue.isEmpty {
                    stageModels.removeValue(forKey: step.rawValue)
                } else {
                    stageModels[step.rawValue] = newValue
                }
                AppSettings.setStageModels(stageModels)
            })
    }
}

extension ProviderConfig {
    var displayName: String { name.isEmpty ? "未命名提供商" : name }
}
