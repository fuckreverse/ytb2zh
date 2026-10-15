import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 任务中心：历史任务列表 / 编辑中间产物 / 断点续跑
//       列表带视频标题/频道/缩略图/任务时间，顶部状态筛选 + 搜索

/// 列表条目（jobID + 状态 + 元数据，元数据来自订阅 VideoMeta / VideoInfo，缺失时后台补齐）
struct JobListItem: Identifiable {
    let id: String              // jobID
    let status: JobStore.Status
    let url: String
    let title: String
    let channel: String?
    let thumbnailURL: String?
    let createdAt: Date
    let isRunning: Bool
    let doneCount: Int
    let hasFailed: Bool
    var failureMessage: String? = nil

    var hasFinalVideo: Bool { JobStore().hasFinalVideo(id) }
}

enum JobStatusFilter: String, CaseIterable, Identifiable {
    case all, running, failed, done, trial
    var id: String { rawValue }
    var label: String {
        switch self {
        case .all: return "全部"
        case .running: return "进行中"
        case .failed: return "有失败"
        case .done: return "已完成"
        case .trial: return "试转"
        }
    }
}

@MainActor
final class JobCenterModel: ObservableObject {
    @Published var items: [JobListItem] = []
    @Published private(set) var isBackfilling = false
    @Published private(set) var backfilledCount = 0
    private let backfiller = MetaBackfiller()

    func reload(store: JobStore = JobStore()) {
        let meta = SubscriptionStore.shared.videoMeta
        let infoStore = VideoInfoStore.shared
        items = store.allJobs().map { (id, st) in
            let m = meta[st.url]
            let d = infoStore.details(for: st.url)
            let title = m?.title ?? d?.title
                ?? (CatalogVideo.youTubeID(st.url).map { "youtube-\($0)" } ?? String(st.url.prefix(60)))
            let thumb = m?.thumbnail ?? d?.thumbnail ?? CatalogVideo.youTubeThumbnail(st.url)
            let steps = st.steps.values
            return JobListItem(
                id: id, status: st, url: st.url,
                title: title,
                channel: m?.channel ?? d?.channel,
                thumbnailURL: thumb,
                createdAt: st.createdAt,
                isRunning: steps.contains(.running),
                doneCount: steps.filter { $0 == .done }.count,
                hasFailed: steps.contains(.failed),
                failureMessage: steps.contains(.failed) ? Self.failureMessage(store: store, id: id) : nil)
        }
        backfillMissing()
    }

    private static func failureMessage(store: JobStore, id: String) -> String? {
        let log = store.jobDir(id: id).appendingPathComponent("log.txt")
        guard let handle = try? FileHandle(forReadingFrom: log) else { return nil }
        defer { try? handle.close() }
        guard let size = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: size > 8192 ? size - 8192 : 0)
        guard let data = try? handle.readToEnd(), let text = String(data: data, encoding: .utf8) else { return nil }
        return text.components(separatedBy: .newlines).last(where: { $0.contains("❌") })
    }

    /// 手动刷新时清空失败记录，允许重试拉取元数据
    func backfillReset() { backfiller.resetFailures() }

    private func backfillMissing() {
        guard !isBackfilling else { return }
        isBackfilling = true
        backfiller.backfill(urls: items.map(\.url)) { [weak self] in
            self?.backfilledCount += 1
            self?.reloadPreservingBackfill()
        }
        // backfill 同步判空后未启动时也要复位
        if !backfiller.isRunning { isBackfilling = false }
    }

    /// 补齐途中只重建条目元数据，不再次触发补齐
    private func reloadPreservingBackfill() {
        let meta = SubscriptionStore.shared.videoMeta
        let infoStore = VideoInfoStore.shared
        items = items.map { it in
            guard let d = infoStore.details(for: it.status.url) else { return it }
            let m = meta[it.status.url]
            return JobListItem(
                id: it.id, status: it.status, url: it.status.url,
                title: m?.title ?? d.title,
                channel: m?.channel ?? d.channel,
                thumbnailURL: m?.thumbnail ?? d.thumbnail ?? it.thumbnailURL,
                createdAt: it.createdAt,
                isRunning: it.isRunning, doneCount: it.doneCount, hasFailed: it.hasFailed, failureMessage: it.failureMessage)
        }
    }

    deinit { /* backfiller 的 task 在其自身 deinit 取消 */ }
}

@MainActor
struct JobCenterView: View {
    @ObservedObject var job: PipelineJob
    @StateObject private var model = JobCenterModel()
    @State private var editingUnits: String?      // jobID
    @State private var editingTerms: String?
    @State private var detail: String?            // 任务详情页 jobID
    @State private var searchText = ""
    @AppStorage("jobcenter.statusFilter") private var filterRaw = JobStatusFilter.all.rawValue
    private let store = JobStore()

    private var filter: JobStatusFilter { JobStatusFilter(rawValue: filterRaw) ?? .all }

    /// 筛选 + 搜索后的条目（标题/频道/链接，大小写不敏感）
    private var filtered: [JobListItem] {
        var list = model.items
        switch filter {
        case .all: break
        case .running: list = list.filter { $0.isRunning }
        case .failed: list = list.filter { $0.hasFailed && !$0.isRunning }
        case .done: list = list.filter { $0.doneCount == StepID.allCases.count && !$0.hasFailed }
        case .trial: list = list.filter { $0.status.isTrial }
        }
        let q = searchText.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return list }
        return list.filter {
            $0.title.lowercased().contains(q)
                || ($0.channel ?? "").lowercased().contains(q)
                || $0.url.lowercased().contains(q)
                || $0.id.lowercased().contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            if model.items.isEmpty {
                AppEmptyState(icon: "checklist", title: "让第一个视频说中文", message: "这里会记录处理进度、保存译文，并支持失败重试和断点续跑。", actionTitle: "新建转换") { navigate(to: .settings) }
            } else if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").font(.largeTitle).foregroundStyle(.secondary)
                    Text(searchText.isEmpty ? "没有该状态的任务" : "没有匹配「\(searchText)」的任务")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                CinemaList {
                    ForEach(filtered) { item in
                        JobRow(item: item,
                               onResume: { resume(item.id) },
                               onEditUnits: { editingUnits = item.id },
                               onEditTerms: { editingTerms = item.id },
                               onReveal: { reveal(item.id) },
                               onDetail: { detail = item.id })
                            .contentShape(Rectangle())
                            .onTapGesture { detail = item.id }
                    }
                }

            }
        }
        .background(AppTheme.canvas)
        .navigationTitle("任务中心")
        .onReceive(Timer.publish(every: 3, on: .main, in: .common).autoconnect()) { _ in reload() }
        .onAppear(perform: reload)
        .sheet(item: Binding(
            get: { editingUnits.map { JobRef(id: $0) } },
            set: { editingUnits = $0?.id })) { ref in
            CinemaPresentation {
                UnitsEditorView(jobID: ref.id) { reload() }
            }
        }
        .sheet(item: Binding(
            get: { editingTerms.map { JobRef(id: $0) } },
            set: { editingTerms = $0?.id })) { ref in
            CinemaPresentation {
                TerminologyEditorView(jobID: ref.id) { reload() }
            }
        }
        .sheet(item: Binding(
            get: { detail.map { JobRef(id: $0) } },
            set: { detail = $0?.id })) { ref in
            CinemaPresentation {
                JobDetailView(jobID: ref.id, job: job,
                              onEditUnits: { editingUnits = ref.id },
                              onEditTerms: { editingTerms = ref.id })
            }
        }
    }

    struct JobRef: Identifiable { let id: String }

    private var headerBar: some View {
        VStack(spacing: 14) {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(model.items.count) 个任务 · 进度与结果一目了然").font(.headline)
                if model.isBackfilling {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("正在补齐视频信息…（已 \(model.backfilledCount)）")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button { navigate(to: .settings) } label: { Label("新建转换", systemImage: "plus") }
                .buttonStyle(CinemaButtonStyle(prominent: true))
            }
            HStack(spacing: 12) {
            CinemaTabs(values: JobStatusFilter.allCases.map(\.rawValue), selection: $filterRaw, title: { value in JobStatusFilter.allCases.first(where: { $0.rawValue == value }).map { L10n.tr($0.label) } ?? value })

            .labelsHidden()

            .help("按任务状态筛选")
            TextField("搜索标题 / 频道 / 链接", text: $searchText)
                .textFieldStyle(CinemaTextFieldStyle())
                .frame(width: 200)
            Button {
                model.backfillReset()
                reload()
            } label: { Label("刷新", systemImage: "arrow.clockwise") }
            }
        }
        .padding(20)
    }

    private func reload() {
        model.reload()
    }

    private func resume(_ jobID: String) {
        let status = store.loadStatus(jobID)
        let pending = Set(status.steps.filter { $0.value != .done }.keys.compactMap { StepID(rawValue: $0) })
        job.start(url: status.url, profile: store.loadProfileSnapshot(id: jobID) ?? Profile(name: status.profileName),
                  jobID: jobID, stepFilter: pending)
    }

    private func reveal(_ jobID: String) {
        NSWorkspace.shared.activateFileViewerSelecting([store.jobDir(id: jobID)])
    }
}

/// 任务列表行：缩略图 + 标题 + 频道/时间/模板 + 状态徽标 + 操作按钮
@MainActor
struct JobRow: View {
    let item: JobListItem
    let onResume: () -> Void
    let onEditUnits: () -> Void
    let onEditTerms: () -> Void
    let onReveal: () -> Void
    var onDetail: () -> Void = {}

    private var status: JobStore.Status { item.status }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ThumbImage(url: item.thumbnailURL)
                .frame(width: 106, height: 60)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(alignment: .bottomTrailing) {
                    if item.hasFinalVideo {
                        Text("有成片")
                            .font(.caption2.weight(.medium))
                            .padding(.horizontal, 5).padding(.vertical, 2)
                            .background(.green.opacity(0.9), in: RoundedRectangle(cornerRadius: 3))
                            .foregroundStyle(.white)
                            .padding(3)
                    }
                }
                .padding(.vertical, 2)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                        .help(item.title)
                    if status.isTrial {
                        Text("试转").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.orange.opacity(0.18)))
                            .foregroundStyle(.orange)
                            .help("试转任务：只处理前几分钟的小样，验证配置；确认后请用「开始转换」跑全片")
                    }
                    if item.isRunning {
                        HStack(spacing: 4) {
                            ProgressView().controlSize(.mini)
                            Text("进行中").font(.caption2).foregroundStyle(.orange)
                        }
                    }
                    if item.hasFailed {
                        Text("有失败步骤").font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(.red.opacity(0.15)))
                            .foregroundStyle(.red)
                    }
                    Spacer()
                    Text("\(item.doneCount)/\(StepID.allCases.count)")
                        .font(.caption).monospacedDigit().foregroundStyle(.secondary)
                }

                Text(metaLine)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1)
                    .help(item.url)

                ProgressView(value: Double(item.doneCount), total: Double(StepID.allCases.count))
                    .tint(item.hasFailed ? .red : AppTheme.accent)
                if let message = item.failureMessage {
                    Text(message).font(.caption).foregroundStyle(.red).lineLimit(2).textSelection(.enabled)
                } else if let step = StepID.allCases.first(where: { status.steps[$0.rawValue] == .running }) {
                    Text("正在\(step.label)").font(.caption).foregroundStyle(AppTheme.accent)
                }
                HStack(spacing: 8) {
                    Button("详情") { onDetail() }.controlSize(.small)
                    Button(item.hasFailed ? "重试" : "续跑") { onResume() }.controlSize(.small)
                        .disabled(item.isRunning)
                    // 成片尚未产出时，入口文案提示审核语义（翻译已就绪但未转换的任务尤其需要）
                    Button(composeDone ? "编辑译文" : "审核译文") { onEditUnits() }.controlSize(.small)
                        .help(composeDone ? "修改已出片任务的译文，改完可从合成步续跑重新出片"
                                         : "逐条核对/修改中文译文，改完点「保存并继续转换」出成片（不重翻）")
                    Button("编辑术语") { onEditTerms() }.controlSize(.small)
                    Button("打开目录") { onReveal() }.controlSize(.small)
                }
            }
        }
        .padding(12)
        .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    /// 频道 · 任务时间 · 模板名 · jobID（次要信息一行带完）
    private var metaLine: String {
        var parts: [String] = []
        if let ch = item.channel { parts.append(ch) }
        parts.append(JobCenterView.dateText(item.createdAt))
        parts.append(status.profileName)
        parts.append(item.id)
        return parts.joined(separator: " · ")
    }

    private var composeDone: Bool { status.steps[StepID.compose.rawValue] == .done }
}

extension JobCenterView {
    /// "09-27 14:30"
    static func dateText(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
}

// MARK: - 译文单元编辑器（改 zh / voice；审核后从合成步续跑，人工译文优先）

@MainActor
struct UnitsEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    var onSaved: () -> Void
    @State private var units: [SpeechUnit] = []
    @State private var loaded = false
    @State private var message = ""
    private let store = JobStore()

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("译文审核/编辑（\(units.count) 单元）").font(.headline)
                Spacer()
                Text("voice 留空 = 默认音色").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            CinemaList {
                ForEach(units.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "#%d  [%.1fs-%.1fs] %@", i, units[i].start, units[i].end, units[i].en))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("中文译文", text: Binding(
                                get: { units.indices.contains(i) ? units[i].zh : "" },
                                set: { if units.indices.contains(i) { units[i].zh = $0 } }))
                                .textFieldStyle(CinemaTextFieldStyle())
                            TextField("voice", text: Binding(
                                get: { units.indices.contains(i) ? (units[i].voice ?? "") : "" },
                                set: { if units.indices.contains(i) { units[i].voice = $0.isEmpty ? nil : $0 } }))
                                .textFieldStyle(CinemaTextFieldStyle())
                                .frame(width: 150)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(AppTheme.accent).padding(.horizontal, 12)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { save() }
                // 主路径：确认译文 → 从合成步继续（保留人工译文，只重做配音/调度/成片）
                Button("保存并继续转换") {
                    save()
                    dismiss()
                    NotificationCenter.default.post(
                        name: .ytb2zhResumeJob, object: ResumeRequest(jobID: jobID, from: .synthesize))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(CinemaButtonStyle(prominent: true))
                .help("使用当前译文（含人工修改）直接合成配音、调度、出成片；不再重新翻译")
                // 次路径：改完术语想整体重翻
                Button("保存并重新翻译") {
                    save()
                    dismiss()
                    NotificationCenter.default.post(
                        name: .ytb2zhResumeJob, object: ResumeRequest(jobID: jobID, from: .translate))
                }
                .help("丢弃全部译文重新机器翻译（人工修改会被覆盖）。适合改完术语表后重翻，而不适合微调译文")
            }
            .padding(12)
        }
        .frame(minWidth: 720, minHeight: 520)
        .onAppear {
            units = store.readJSON(store.translatedJSON(jobID), as: [SpeechUnit].self)
                ?? store.readJSON(store.unitsJSON(jobID), as: [SpeechUnit].self) ?? []
            loaded = true
        }
    }

    private func save() {
        do {
            try store.writeJSON(units, to: store.translatedJSON(jobID))
            message = "已保存"
            onSaved()
        } catch {
            message = String(format: L10n.tr("保存失败：%@"), error.localizedDescription)
        }
    }
}

// MARK: - 术语表编辑器（改 zh 后从翻译步续跑）

@MainActor
struct TerminologyEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let jobID: String
    var onSaved: () -> Void
    @State private var terms: [TerminologyTerm] = []
    @State private var domainCtx = DomainContext()
    @State private var newEN = ""
    @State private var newZH = ""
    @State private var message = ""
    private let store = JobStore()

    var body: some View {
        VStack(spacing: 0) {
            Text("术语表（\(terms.count) 条）").font(.headline).padding(12)
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("领域（翻译时优先于「科技视频」人设）").font(.caption).foregroundStyle(.secondary)
                    HStack {
                        TextField("领域，如 人工智能/网络安全", text: $domainCtx.domain)
                        TextField("语气基调", text: $domainCtx.tone)
                        TextField("目标受众", text: $domainCtx.audience)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            CinemaList {
                ForEach(terms.indices, id: \.self) { i in
                    HStack {
                        TextField("EN", text: Binding(
                            get: { terms.indices.contains(i) ? terms[i].en : "" },
                            set: { if terms.indices.contains(i) { terms[i].en = $0 } }))
                            .frame(width: 200)
                        TextField("中文", text: Binding(
                            get: { terms.indices.contains(i) ? terms[i].zh : "" },
                            set: { if terms.indices.contains(i) { terms[i].zh = $0 } }))
                        TextField("备注", text: Binding(
                            get: { terms.indices.contains(i) ? terms[i].note : "" },
                            set: { if terms.indices.contains(i) { terms[i].note = $0 } }))
                            .foregroundStyle(.secondary)
                            .frame(width: 160)
                        Button {
                            _ = terms.remove(at: i)
                        } label: {
                            Image(systemName: "trash").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            HStack {
                TextField("新术语 EN", text: $newEN).frame(width: 200)
                TextField("中文译法", text: $newZH)
                Button("添加") {
                    guard !newEN.isEmpty, !newZH.isEmpty else { return }
                    terms.append(TerminologyTerm(en: newEN, zh: newZH))
                    newEN = ""; newZH = ""
                }
            }
            .padding(.horizontal, 12)
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(AppTheme.accent).padding(.horizontal, 12)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存并从翻译步续跑") {
                    do {
                        try store.writeJSON(
                            TerminologyExtraction(domain: domainCtx.isEmpty ? nil : domainCtx, terms: terms),
                            to: store.terminologyJSON(jobID))
                        onSaved()
                        dismiss()
                        NotificationCenter.default.post(
                            name: .ytb2zhResumeJob, object: ResumeRequest(jobID: jobID, from: .translate))
                    } catch {
                        message = String(format: L10n.tr("保存失败：%@"), error.localizedDescription)
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(CinemaButtonStyle(prominent: true))
            }
            .padding(12)
        }
        .frame(minWidth: 640, minHeight: 440)
        .onAppear {
            if let doc = TerminologyExtraction.load(from: store.terminologyJSON(jobID)) {
                terms = doc.terms
                domainCtx = doc.domain ?? DomainContext()
            }
        }
    }
}

// MARK: - 跨视图续跑请求

struct ResumeRequest {
    let jobID: String
    let from: StepID
}

extension Notification.Name {
    static let ytb2zhResumeJob = Notification.Name("ytb2zhResumeJob")
}
