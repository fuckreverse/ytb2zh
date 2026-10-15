import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

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
            PageHeading(title: "设置你的译配工作空间", subtitle: "管理网络、模型服务与处理能力")
                .padding(24)
            CinemaTabs(values: Tab.allCases, selection: $tab, title: { $0.rawValue })
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 24).padding(.bottom, 20)

            Divider()

            switch tab {
            case .network: NetworkTab()
            case .providers: ProvidersTab(store: store)
            case .assign: AssignTab(store: store)
            }
        }
        .background(AppTheme.canvas)
        .navigationTitle("应用设置")
    }
}

// MARK: - 分页 1：网络设置

private struct NetworkTab: View {
    @AppStorage("appAppearance") private var appearance = "dark"
    @AppStorage(AppSettings.proxyKey) private var proxy = ""
    @AppStorage("youtubeCookieFile") private var youtubeCookieFile = ""
    @AppStorage("youtubeCookieSource") private var youtubeCookieSource = "netscape"
    @AppStorage(WebPotHarvestSetting.key) private var youtubeWebPOTEnabled = true
    @AppStorage(AppSettings.proxyForDownloadKey) private var forDownload = true
    @AppStorage(AppSettings.proxyForSearchKey) private var forSearch = true
    @AppStorage(AppSettings.proxyForEdgeTTSKey) private var forEdgeTTS = true
    // 存储位置
    @State private var jobRootPath = JobStore().root.path
    // PO Token 收割状态（诊断展示）
    @State private var potStatus = ""
    @State private var potHarvesting = false
    // 界面语言（AppleLanguages 覆盖 + 重启生效）
    @State private var langSelection: String = {
        let language = L10n.currentLanguage
        if language.hasPrefix("zh") { return "zh-Hans" }
        if language.hasPrefix("en") { return "en" }
        return "system"
    }()
    @State private var langNeedsRestart = false
    @State private var showLog = false

    var body: some View {
        CinemaForm {
            CinemaSection("通用") {
                LabeledContent("界面外观") {
                    CinemaSelect("界面外观", selection: $appearance, options: [CinemaOption("system", L10n.tr("跟随系统")), CinemaOption("light", L10n.tr("浅色")), CinemaOption("dark", L10n.tr("深色"))]).frame(width: 260)
                }
                LabeledContent("界面语言") {
                    CinemaSelect("界面语言", selection: $langSelection, options: [CinemaOption("system", L10n.tr("跟随系统")), CinemaOption("zh-Hans", "简体中文"), CinemaOption("en", "English")])
                    .labelsHidden()
                    .frame(width: 200)
                    .onChange(of: langSelection) { _, newValue in
                        langNeedsRestart = L10n.setLanguage(newValue)
                    }
                }
                if langNeedsRestart {
                    HStack {
                        Text("切换后需重启应用生效")
                            .font(.caption2).foregroundStyle(.secondary)
                        Spacer()
                        Button("立即重启") { L10n.relaunch() }
                    }
                }
                LabeledContent("运行日志") {
                    Button("查看应用日志…") { showLog = true }
                        .sheet(isPresented: $showLog) { CinemaPresentation {  AppLogSheet()  } }
                }
            }

            CinemaSection("运行环境") {
                ForEach(["ffmpeg", "ffprobe"], id: \.self) { tool in
                    LabeledContent(tool) {
                        if SidecarPaths.which(tool) != nil {
                            Label("已安装", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Label("未安装", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
                        }
                    }
                }
                Text("安装命令：brew install ffmpeg")
                    .font(.system(.callout, design: .monospaced)).textSelection(.enabled)
                Text("语音识别模型会在首次使用时自动下载；配音密钥请在模型提供商中配置。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            CinemaSection("代理（留空 = 用各模板内置值）") {
                LabeledContent("代理地址") {
                    TextField("http://127.0.0.1:7890", text: $proxy)
                        .textFieldStyle(CinemaTextFieldStyle())
                        .frame(width: 340)
                }
                LabeledContent("代理用于") {
                    HStack(spacing: 14) {
                        Toggle("视频下载", isOn: $forDownload).toggleStyle(CinemaToggleStyle())
                        Toggle("YouTube 搜索", isOn: $forSearch).toggleStyle(CinemaToggleStyle())
                        Toggle("Edge TTS 语音合成", isOn: $forEdgeTTS).toggleStyle(CinemaToggleStyle())
                    }
                }
                .help("Videx 原生提取优先；备用 yt-dlp（按需自动下载）、搜索取数与 edge-tts 走外网；百炼/兼容 API 直连国内或由 API 端自行处理，不受此开关影响")
            }

            CinemaSection("YouTube 会话") {
                LabeledContent("会话文件格式") {
                    CinemaSelect("会话文件格式", selection: $youtubeCookieSource, options: [CinemaOption("netscape", "Netscape cookies.txt"), CinemaOption("firefox", "Firefox cookies.sqlite"), CinemaOption("chrome", "Chrome Cookies 数据库"), CinemaOption("safari", "Safari Cookies.binarycookies")]).frame(width: 260)
                }
                LabeledContent("Cookie 文件") {
                    HStack {
                        Text(youtubeCookieFile.isEmpty ? "未配置" : URL(fileURLWithPath: youtubeCookieFile).lastPathComponent)
                            .foregroundStyle(.secondary)
                        Button("选择会话文件…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = false
                            panel.allowsMultipleSelection = false
                            if panel.runModal() == .OK, let url = panel.url { youtubeCookieFile = url.path }
                        }
                        if !youtubeCookieFile.isEmpty { Button("清除") { youtubeCookieFile = "" } }
                    }
                }
                Text("只读取明确选择的会话文件中的 YouTube Cookie；浏览器数据库每次重新读取，Chrome 解密使用系统钥匙串。")
                    .font(.caption).foregroundStyle(.secondary)

                Toggle("Web PO Token 收割（实验）", isOn: $youtubeWebPOTEnabled)
                    .toggleStyle(CinemaToggleStyle())
                Text("提取时用内置 WebView 执行 BotGuard，为当前视频生成配套的媒体与字幕 PO Token。"
                     + "缓存按视频、会话和代理隔离，最长复用 6 小时；仍需满足视频的登录和访问权限。")
                    .font(.caption).foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Button("查看令牌状态", action: refreshPOTStatus)
                    Text(potStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                HStack(spacing: 8) {
                    Button("立即收割", action: harvestPOTNow)
                        .disabled(potHarvesting)
                    if potHarvesting { ProgressView().controlSize(.small) }
                }
            }

            CinemaSection("任务存储位置") {
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

        .scrollContentBackground(.hidden)
    }

    private func chooseRoot() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.message = L10n.tr("选择任务存储目录（新任务的 Jobs 根目录）")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: AppSettings.jobRootKey)
        jobRootPath = JobStore().root.path
    }

    // MARK: PO Token 收割（诊断）

    private func refreshPOTStatus() {
        if let token = WebPoTokenProvider.cached() {
            let formatter = DateFormatter()
            formatter.dateFormat = "HH:mm"
            potStatus = "缓存有效：\(token.videoID ?? "会话诊断")，有效至 \(formatter.string(from: token.expiresAt))"
        } else {
            potStatus = "无有效缓存（\(WebPoTokenProvider.cachePath) 不存在或已过期）"
        }
    }

    private func harvestPOTNow() {
        potHarvesting = true
        potStatus = "正在收割…"
        Task {
            do {
                let token = try await WebPoTokenProvider.harvest(bypassThrottle: true) { line in
                    AppLog.info("pot", line)
                }
                let formatter = DateFormatter()
                formatter.dateFormat = "HH:mm"
                potStatus = "会话生成测试成功，有效至 \(formatter.string(from: token.expiresAt))；下载时自动铸造视频 Token"
            } catch {
                potStatus = "收割失败：\(error.localizedDescription)"
            }
            potHarvesting = false
        }
    }

    private func resetRoot() {
        UserDefaults.standard.removeObject(forKey: AppSettings.jobRootKey)
        jobRootPath = JobStore().root.path
    }
}

// MARK: - 分页 2：模型提供商（Cherry Studio / Magpie 风格：左侧服务商列表 + 右侧配置面板 + 预设库弹窗）
// 注意：这里刻意不用 ForEach($store.providers) / ForEach($pr.models) 集合元素
// Binding 语法糖——行内删除会使底层数组缩短，同一布局事务里 TextField 内部的
// ValueAction 仍会读取已删除元素的旧 Binding（getter 对数组做下标访问），
// 触发 Fatal error: Index out of range（EXC_BREAKPOINT/SIGTRAP，
// 见 2026-09-27 Ytb2ZHApp-141115.ips 崩溃日志）。
// 改为值迭代 + 以 id 锚定的安全 Binding：get 用 first(where:) 永不越界
// （找不到时回退空值，行下一次渲染即消失），set 找不到锚点时静默丢弃。

private struct ProvidersTab: View {
    @ObservedObject var store: ProviderStore
    @State private var selectedID: String?
    @State private var sidebarFilter = ""
    @State private var showPresetSheet = false

    private var filteredProviders: [ProviderConfig] {
        let q = sidebarFilter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return store.providers }
        return store.providers.filter { pr in
            pr.name.lowercased().contains(q)
                || pr.kind.label.lowercased().contains(q)
                || pr.baseURL.lowercased().contains(q)
                || pr.models.contains { $0.name.lowercased().contains(q) }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // —— 左栏：已配置提供商列表 + 添加入口
            VStack(spacing: 0) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                        .font(.caption)
                    TextField("搜索已添加的服务商…", text: $sidebarFilter)
                        .textFieldStyle(.plain)
                        .font(.callout)
                    if !sidebarFilter.isEmpty {
                        Button {
                            sidebarFilter = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(AppTheme.surface)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
                .padding(10)

                Divider()

                if filteredProviders.isEmpty {
                    VStack(spacing: 8) {
                        Spacer()
                        Image(systemName: "server.rack")
                            .font(.title2)
                            .foregroundStyle(.tertiary)
                        Text(store.providers.isEmpty ? "尚未添加提供商" : "无匹配提供商")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                } else {
                    ScrollView {
                        LazyVStack(spacing: 4) {
                            ForEach(filteredProviders) { pr in
                                providerSidebarRow(pr)
                            }
                        }
                        .padding(8)
                    }
                }

                Divider()

                // 底部操作栏：打开预设库 + 快速按分类添加
                HStack(spacing: 8) {
                    Button {
                        showPresetSheet = true
                    } label: {
                        Label("添加提供商", systemImage: "plus.circle.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(CinemaButtonStyle(prominent: true))
                    .controlSize(.regular)

                    Menu {
                        ForEach(ProviderCategory.allCases) { cat in
                            Menu(L(cat.rawValue)) {
                                ForEach(ProviderPreset.all.filter { $0.category == cat }) { preset in
                                    Button(preset.name) {
                                        selectedID = store.addPreset(preset)
                                    }
                                }
                            }
                        }
                        Divider()
                        Menu("仅按底层协议新建空白项") {
                            ForEach(ProviderKind.allCases) { k in
                                Button(L(k.label)) {
                                    selectedID = store.add(k)
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "list.bullet.indent")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .menuStyle(CinemaMenuStyle())
                    .frame(width: 28)
                    .help("快速从分类菜单添加")
                }
                .padding(10)
            }
            .frame(width: 255)
            .background(AppTheme.surface.opacity(0.6))

            Divider()

            // —— 右栏：当前选中提供商详情或欢迎引导页
            if let currentID = effectiveSelectedID,
               store.providers.contains(where: { $0.id == currentID }) {
                ProviderDetailPane(
                    store: store,
                    providerID: currentID,
                    onOpenPresetLibrary: { showPresetSheet = true },
                    onDeleted: {
                        selectedID = store.providers.first?.id
                    }
                )
            } else {
                emptyWelcomePane
            }
        }
        .onAppear {
            if selectedID == nil { selectedID = store.providers.first?.id }
        }
        .onChange(of: store.providers) { _, _ in
            store.save()
            if let sel = selectedID, !store.providers.contains(where: { $0.id == sel }) {
                selectedID = store.providers.first?.id
            } else if selectedID == nil {
                selectedID = store.providers.first?.id
            }
        }
        .sheet(isPresented: $showPresetSheet) {
            CinemaPresentation {
                ProviderPresetPickerSheet { chosenPreset in
                    selectedID = store.addPreset(chosenPreset)
                }
            }
        }
    }

    private var effectiveSelectedID: String? {
        if let sel = selectedID, store.providers.contains(where: { $0.id == sel }) {
            return sel
        }
        return store.providers.first?.id
    }

    private func providerSidebarRow(_ pr: ProviderConfig) -> some View {
        let isSelected = effectiveSelectedID == pr.id
        return HStack(spacing: 10) {
            Text(pr.badgeText)
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(pr.enabled ? pr.badgeColor : Color.gray.opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(pr.displayName)
                    .font(.callout.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(pr.enabled ? .primary : .secondary)
                    .lineLimit(1)
                HStack(spacing: 4) {
                    Text(pr.kind.shortBadge)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    Text("·")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                    Text("\(pr.models.filter { !$0.name.isEmpty }.count) 模型")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 4)

            Circle()
                .fill(pr.enabled ? Color.green : Color.gray.opacity(0.35))
                .frame(width: 7, height: 7)
                .help(pr.enabled ? "已启用" : "已停用")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedID = pr.id
        }
        .contextMenu {
            Button(pr.enabled ? "停用此提供商" : "启用此提供商") {
                if let i = store.providers.firstIndex(where: { $0.id == pr.id }) {
                    store.providers[i].enabled.toggle()
                }
            }
            Divider()
            Button("删除此提供商", role: .destructive) {
                store.removeProvider(id: pr.id)
            }
        }
    }

    private var emptyWelcomePane: some View {
        let featuredIDs = [
            "openrouter", "opencode", "alibaba-bailian", "bytedance-ark",
            "deepseek", "siliconflow", "zhipu", "moonshot",
            "alibaba-bailian-tts", "anthropic", "gemini", "custom-responses",
        ]
        let featured = featuredIDs.compactMap { ProviderPreset.find($0) }

        return ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("快速接入主流大模型与语音服务")
                        .font(.title3.weight(.semibold))
                    Text("点击下方常用服务商即可一键带出接口地址、标准协议与推荐模型；只需填入 API Key 即可在「模型分配」中使用。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 12)], spacing: 12) {
                    ForEach(featured) { preset in
                        Button {
                            selectedID = store.addPreset(preset)
                        } label: {
                            HStack(spacing: 10) {
                                Text(preset.badgeText)
                                    .font(.system(size: 11, weight: .bold, design: .rounded))
                                    .foregroundStyle(.white)
                                    .frame(width: 34, height: 34)
                                    .background(preset.badgeColor)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(preset.name)
                                        .font(.callout.weight(.medium))
                                        .foregroundStyle(.primary)
                                        .lineLimit(1)
                                    Text(preset.kind.shortBadge)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                                    .foregroundStyle(Color.accentColor)
                            }
                            .padding(10)
                            .background(AppTheme.surface)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                            )
                        }
                        .buttonStyle(.plain)
                    }
                }

                HStack {
                    Button {
                        showPresetSheet = true
                    } label: {
                        Label("浏览全部 \(ProviderPreset.all.count) 个内置服务商与标准协议…", systemImage: "square.grid.2x2")
                    }
                    .buttonStyle(CinemaButtonStyle(prominent: true))
                }
            }
            .padding(28)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

// MARK: - 右侧提供商详情面板

private struct ProviderDetailPane: View {
    @ObservedObject var store: ProviderStore
    let providerID: String
    let onOpenPresetLibrary: () -> Void
    let onDeleted: () -> Void

    @State private var showAPIKey = false
    @State private var testingConnection = false
    @State private var connectionResult: (ok: Bool, message: String)?
    @State private var fetchingModels = false
    @State private var fetchedModels: [String] = []
    @State private var fetchError: String?
    @State private var showRemoteModelsSheet = false

    var body: some View {
        let pr = providerBinding
        let val = pr.wrappedValue
        let endpointPreview = val.kind.endpointPreview(
            baseURL: val.baseURL,
            sampleModel: val.models.first(where: { !$0.name.isEmpty })?.name ?? "model"
        )

        CinemaForm {
            // —— 顶部服务商名片与开关
            CinemaSection {
                HStack(spacing: 12) {
                    Text(val.badgeText)
                        .font(.system(size: 14, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(val.enabled ? val.badgeColor : Color.gray.opacity(0.5))
                        .clipShape(RoundedRectangle(cornerRadius: 9))

                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(val.displayName)
                                .font(.headline)
                            Text(val.kind.shortBadge)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12))
                                .foregroundStyle(Color.accentColor)
                                .clipShape(Capsule())
                        }
                        if let subtitle = val.preset?.subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }

                    Spacer()

                    if let keyURL = val.preset?.apiKeyURL, !keyURL.isEmpty, let url = URL(string: keyURL) {
                        Link(destination: url) {
                            Label("获取 API Key", systemImage: "key.fill")
                                .font(.caption)
                        }
                        .buttonStyle(CinemaButtonStyle())
                        .controlSize(.small)
                    }

                    Toggle("启用", isOn: pr.enabled)
                        .toggleStyle(CinemaToggleStyle())
                        .controlSize(.small)
                }
                .padding(.vertical, 2)
            }

            // —— 接口与标准协议设置
            CinemaSection("连接与标准协议") {
                LabeledContent("显示名称") {
                    TextField("如 OpenRouter / 字节火山方舟 / 阿里云百炼", text: pr.name)
                        .textFieldStyle(CinemaTextFieldStyle())
                        .frame(maxWidth: 420)
                }

                LabeledContent("标准协议 / 引擎") {
                    CinemaSelect("标准协议 / 引擎", selection: pr.kind, options: ProviderKind.allCases.map { CinemaOption($0, L10n.tr($0.label)) })
                    .labelsHidden()
                    .frame(maxWidth: 320, alignment: .leading)
                }

                if val.kind.needsBaseURL {
                    LabeledContent(L(val.kind.baseURLLabel)) {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 6) {
                                TextField(val.preset?.defaultBaseURL ?? val.kind.defaultBaseURL, text: pr.baseURL)
                                    .textFieldStyle(CinemaTextFieldStyle())
                                    .frame(maxWidth: 380)
                                if let def = val.preset?.defaultBaseURL ?? (val.kind.defaultBaseURL.isEmpty ? nil : val.kind.defaultBaseURL),
                                   !def.isEmpty, val.baseURL != def {
                                    Button("恢复默认") {
                                        pr.baseURL.wrappedValue = def
                                    }
                                    .controlSize(.small)
                                }
                            }
                            if !endpointPreview.isEmpty {
                                Text("完整端点预览：\(endpointPreview)")
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                }

                if val.kind.needsAPIKey {
                    LabeledContent("API Key") {
                        HStack(spacing: 6) {
                            Group {
                                if showAPIKey {
                                    TextField("粘贴 API Key（如 sk-...）", text: pr.apiKey)
                                } else {
                                    SecureField("粘贴 API Key（如 sk-...）", text: pr.apiKey)
                                }
                            }
                            .textFieldStyle(CinemaTextFieldStyle())
                            .frame(maxWidth: 340)

                            Button {
                                showAPIKey.toggle()
                            } label: {
                                Image(systemName: showAPIKey ? "eye.slash" : "eye")
                            }
                            .buttonStyle(CinemaButtonStyle())
                            .help(showAPIKey ? "隐藏密钥" : "显示密钥")

                            if val.kind.supportsConnectionTest {
                                Button {
                                    runConnectionTest(val)
                                } label: {
                                    if testingConnection {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("检测连通性")
                                    }
                                }
                                .controlSize(.small)
                                .disabled(testingConnection)
                            }
                        }
                    }
                }

                if let res = connectionResult {
                    HStack(spacing: 6) {
                        Image(systemName: res.ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundStyle(res.ok ? .green : .orange)
                        Text(res.message)
                            .font(.caption)
                            .foregroundStyle(res.ok ? .green : .orange)
                            .textSelection(.enabled)
                        Spacer()
                    }
                }

                Text(L(val.kind.hint))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            // —— 模型列表与能力勾选
            CinemaSection {
                if val.models.isEmpty {
                    Text("尚未配置模型，请点击下方「添加模型」或「从接口拉取模型」。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(val.models) { mo in
                        modelRow(mo.id)
                    }
                }

                HStack(spacing: 12) {
                    Button {
                        store.addModel(providerID: providerID)
                    } label: {
                        Label("手动添加模型", systemImage: "plus.circle")
                    }

                    if let preset = val.preset, !preset.recommendedModels.isEmpty {
                        Button {
                            store.addRecommendedModels(providerID: providerID)
                        } label: {
                            Label("填入推荐模型", systemImage: "sparkles")
                        }
                    }

                    if val.kind.supportsRemoteModels {
                        Button {
                            fetchRemoteModels(val)
                        } label: {
                            if fetchingModels {
                                HStack(spacing: 4) {
                                    ProgressView().controlSize(.small)
                                    Text("正在拉取…")
                                }
                            } else {
                                Label("从接口拉取模型 (/models)", systemImage: "arrow.down.circle")
                            }
                        }
                        .disabled(fetchingModels)
                    }

                    Spacer()
                }
                .padding(.top, 4)

                if let err = fetchError {
                    Text("拉取模型列表失败：\(err)")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .textSelection(.enabled)
                }
            } header: {
                HStack {
                    Text("模型与能力声明（\(val.models.count)）")
                    Spacer()
                    Text("勾选模型具备的能力，即可在「模型分配」页对应阶段中选用")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // —— 底部删除操作
            CinemaSection {
                HStack {
                    Button {
                        onOpenPresetLibrary()
                    } label: {
                        Label("继续从预设库添加其他提供商…", systemImage: "plus.square.on.square")
                    }
                    .buttonStyle(CinemaLinkStyle())
                    .font(.caption)

                    Spacer()

                    Button("删除此提供商", role: .destructive) {
                        store.removeProvider(id: providerID)
                        onDeleted()
                    }
                    .buttonStyle(CinemaLinkStyle())
                    .font(.caption)
                }
            }
        }

        .scrollContentBackground(.hidden)
        .onChange(of: providerID) { _, _ in
            connectionResult = nil
            fetchError = nil
        }
        .sheet(isPresented: $showRemoteModelsSheet) {
            CinemaPresentation {
                RemoteModelPickerSheet(
                    providerName: val.displayName,
                    remoteModels: fetchedModels,
                    existingNames: Set(val.models.map { $0.name.trimmingCharacters(in: .whitespaces) })
                ) { selectedNames in
                    // 若当前只有一个空行，先清掉空行
                    if let i = store.providers.firstIndex(where: { $0.id == providerID }),
                       store.providers[i].models.count == 1,
                       store.providers[i].models[0].name.trimmingCharacters(in: .whitespaces).isEmpty {
                        store.providers[i].models.removeAll()
                    }
                    for name in selectedNames {
                        store.addModel(providerID: providerID, name: name)
                    }
                }
            }
        }
    }

    // MARK: 连通性检测与远端模型拉取

    private func runConnectionTest(_ pr: ProviderConfig) {
        testingConnection = true
        connectionResult = nil
        let url = pr.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? (pr.preset?.defaultBaseURL ?? pr.kind.defaultBaseURL)
            : pr.baseURL
        let model = pr.models.first(where: { !$0.name.trimmingCharacters(in: .whitespaces).isEmpty })?.name ?? ""
        let proto = pr.kind.llmProtocolRaw
        let key = pr.apiKey

        Task {
            let start = Date()
            do {
                if !model.isEmpty {
                    let reply = try await OpenAICompatTranslateEngine.complete(
                        protocol: proto,
                        baseURL: url,
                        apiKey: key,
                        model: model,
                        system: "Reply with OK only.",
                        user: "ping",
                        retries: 1
                    )
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    let preview = String(reply.prefix(40)).replacingOccurrences(of: "\n", with: " ")
                    connectionResult = (true, "连通正常（\(ms) ms，模型 \(model) 回复：\(preview)）")
                } else {
                    let models = try await OpenAICompatTranslateEngine.fetchModels(
                        protocol: proto, baseURL: url, apiKey: key
                    )
                    let ms = Int(Date().timeIntervalSince(start) * 1000)
                    connectionResult = (true, "端点连通正常（\(ms) ms，发现 \(models.count) 个可用模型）")
                }
            } catch {
                connectionResult = (false, "检测失败：\(error.localizedDescription)")
            }
            testingConnection = false
        }
    }

    private func fetchRemoteModels(_ pr: ProviderConfig) {
        fetchingModels = true
        fetchError = nil
        let url = pr.baseURL.trimmingCharacters(in: .whitespaces).isEmpty
            ? (pr.preset?.defaultBaseURL ?? pr.kind.defaultBaseURL)
            : pr.baseURL
        let proto = pr.kind.llmProtocolRaw
        let key = pr.apiKey

        Task {
            do {
                let list = try await OpenAICompatTranslateEngine.fetchModels(
                    protocol: proto, baseURL: url, apiKey: key
                )
                if list.isEmpty {
                    fetchError = "接口返回模型列表为空，请手动输入模型 ID"
                } else {
                    fetchedModels = list
                    showRemoteModelsSheet = true
                }
            } catch {
                fetchError = error.localizedDescription
            }
            fetchingModels = false
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
            TextField("模型 ID / 名称（如 deepseek-chat / qwen-plus）", text: modelBinding(modelID).name)
                .textFieldStyle(CinemaTextFieldStyle())
                .frame(minWidth: 210, maxWidth: 260)
            ForEach(ModelCapability.allCases) { cap in
                Toggle(L(cap.label), isOn: capBinding(modelBinding(modelID), cap))
                    .toggleStyle(CinemaToggleStyle())
                    .font(.caption)
            }
            Spacer(minLength: 4)
            Button {
                store.removeModel(providerID: providerID, modelID: modelID)
            } label: {
                Image(systemName: "minus.circle")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(CinemaButtonStyle())
            .help("删除该模型")
        }
        .padding(.vertical, 2)
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

// MARK: - 弹窗 1：主流提供商与标准协议预设库（参考 Cherry Studio / Magpie）

private struct ProviderPresetPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var selectedCategory: String = "all"
    let onSelect: (ProviderPreset) -> Void

    private var filteredPresets: [ProviderPreset] {
        ProviderPreset.all.filter { p in
            let catMatch = (selectedCategory == "all") || (p.category.rawValue == selectedCategory)
            guard catMatch else { return false }
            let q = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !q.isEmpty else { return true }
            return p.name.lowercased().contains(q)
                || p.subtitle.lowercased().contains(q)
                || p.id.lowercased().contains(q)
                || p.defaultBaseURL.lowercased().contains(q)
                || p.recommendedModels.contains { $0.name.lowercased().contains(q) }
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部标题与搜索栏
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("添加模型提供商")
                        .font(.headline)
                    Text("选择国内外主流厂商预设（自动带出接口地址与推荐模型）或标准协议")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("搜索 OpenRouter / OpenCode / 阿里 / 字节 / DeepSeek…", text: $searchText)
                    .textFieldStyle(CinemaTextFieldStyle())
                    .frame(width: 280)
                Button("关闭") { dismiss() }
            }
            .padding(16)

            // 分类筛选标签条
            CinemaTabs(values: ["all"] + ProviderCategory.allCases.map(\.rawValue), selection: $selectedCategory, title: { category in
                category == "all" ? "全部 (\(ProviderPreset.all.count))" : "\(L10n.tr(category)) (\(ProviderPreset.all.filter { $0.category.rawValue == category }.count))"
            })

            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: 18) {
                    ForEach(ProviderCategory.allCases) { cat in
                        let items = filteredPresets.filter { $0.category == cat }
                        if !items.isEmpty {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(L(cat.rawValue))
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.secondary)
                                    .padding(.horizontal, 4)

                                LazyVGrid(columns: [GridItem(.adaptive(minimum: 310), spacing: 10)], spacing: 10) {
                                    ForEach(items) { preset in
                                        presetCard(preset)
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(16)
            }
        }
        .frame(width: 760, height: 560)
    }

    private func presetCard(_ preset: ProviderPreset) -> some View {
        Button {
            onSelect(preset)
            dismiss()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Text(preset.badgeText)
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(preset.badgeColor)
                    .clipShape(RoundedRectangle(cornerRadius: 9))

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(preset.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                        Spacer()
                        Text(preset.kind.shortBadge)
                            .font(.system(size: 10, weight: .medium))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.secondary.opacity(0.12))
                            .foregroundStyle(.secondary)
                            .clipShape(Capsule())
                    }
                    Text(preset.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !preset.recommendedModels.isEmpty {
                        Text("预置：\(preset.recommendedModels.map(\.name).prefix(3).joined(separator: "、"))")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppTheme.surface)
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(Color.primary.opacity(0.08), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 弹窗 2：从远端 /models 接口拉取并勾选模型

private struct RemoteModelPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    let providerName: String
    let remoteModels: [String]
    let existingNames: Set<String>
    let onAdd: ([String]) -> Void

    @State private var filter = ""
    @State private var selected: Set<String> = []

    private var filtered: [String] {
        let q = filter.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return remoteModels }
        return remoteModels.filter { $0.lowercased().contains(q) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("从「\(providerName)」选择模型")
                        .font(.headline)
                    Text("共发现 \(remoteModels.count) 个远端模型，勾选后点击「添加所选」")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                TextField("过滤模型 ID…", text: $filter)
                    .textFieldStyle(CinemaTextFieldStyle())
                    .frame(width: 220)
            }
            .padding(16)

            Divider()

            CinemaList {
                ForEach(filtered, id: \.self) { id in
                    let alreadyExists = existingNames.contains(id)
                    HStack {
                        Toggle(isOn: Binding(
                            get: { alreadyExists || selected.contains(id) },
                            set: { on in
                                guard !alreadyExists else { return }
                                if on { selected.insert(id) } else { selected.remove(id) }
                            }
                        )) {
                            Text(id)
                                .font(.system(.callout, design: .monospaced))
                        }
                        .toggleStyle(CinemaToggleStyle())
                        .disabled(alreadyExists)

                        Spacer()
                        if alreadyExists {
                            Text("已添加")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Divider()

            HStack {
                Text("已勾选 \(selected.count) 个新模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") { dismiss() }
                Button("添加所选 (\(selected.count))") {
                    onAdd(Array(selected).sorted())
                    dismiss()
                }
                .buttonStyle(CinemaButtonStyle(prominent: true))
                .disabled(selected.isEmpty)
            }
            .padding(14)
        }
        .frame(width: 540, height: 460)
    }
}

// MARK: - 分页 3：模型分配（按能力筛选，支持所有已启用的提供商）

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
        CinemaForm {
            CinemaSection {
                ForEach(needs) { n in
                    LabeledContent(L(n.step.label)) {
                        VStack(alignment: .trailing, spacing: 2) {
                            CinemaSelect(n.step.label, selection: binding(n.step), options: modelOptions(for: n))
                            .labelsHidden()
                            .frame(width: 380)
                            Text("需要能力：\(n.capability.label)")
                                .font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            } header: {
                Text("各阶段使用的模型（只列出已启用提供商中声明了对应能力的模型）")
            } footer: {
                Text("能力在「模型提供商」页为每个模型勾选；选「跟随模板」用当前模板内置的引擎与参数。此处的分配优先于模板，且翻译、语义切分、术语提取均已打通 OpenAI / Responses / Anthropic / Gemini 全协议。")
            }
        }

        .scrollContentBackground(.hidden)
    }

    private func modelOptions(for need: StageNeed) -> [CinemaOption<String>] {
        var result = [CinemaOption("", L10n.tr("跟随模板"))]
        for provider in store.providers where provider.enabled {
            for model in provider.models where !model.name.trimmingCharacters(in: .whitespaces).isEmpty && model.capabilities.contains(need.capability) {
                result.append(CinemaOption("\(provider.id)|\(model.id)", "\(provider.displayName) · \(model.name)（\(provider.kind.shortBadge)）"))
            }
        }
        return result
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
