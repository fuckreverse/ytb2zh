import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 任务中心：历史任务列表 / 编辑中间产物 / 断点续跑

@MainActor
struct JobCenterView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var job: PipelineJob
    @State private var jobs: [(id: String, status: JobStore.Status)] = []
    @State private var editingUnits: String?      // jobID
    @State private var editingTerms: String?
    private let store = JobStore()

    var body: some View {
        VStack(spacing: 0) {
            if jobs.isEmpty {
                Text("暂无任务").foregroundStyle(.secondary).padding(40)
            } else {
                List {
                    ForEach(jobs, id: \.id) { j in
                        JobRow(jobID: j.id, status: j.status,
                               onResume: { resume(j.id) },
                               onEditUnits: { editingUnits = j.id },
                               onEditTerms: { editingTerms = j.id },
                               onReveal: { reveal(j.id) })
                    }
                }
                .listStyle(.inset)
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .navigationTitle("任务中心")
        .onAppear(perform: reload)
        .sheet(item: Binding(
            get: { editingUnits.map { JobRef(id: $0) } },
            set: { editingUnits = $0?.id })) { ref in
            UnitsEditorView(jobID: ref.id) { reload() }
        }
        .sheet(item: Binding(
            get: { editingTerms.map { JobRef(id: $0) } },
            set: { editingTerms = $0?.id })) { ref in
            TerminologyEditorView(jobID: ref.id) { reload() }
        }
    }

    struct JobRef: Identifiable { let id: String }

    private func reload() {
        jobs = store.allJobs()
    }

    private func resume(_ jobID: String) {
        let status = store.loadStatus(jobID)
        let pending = Set(status.steps.filter { $0.value != .done }.keys.compactMap { StepID(rawValue: $0) })
        job.start(url: status.url, profile: Profile(name: status.profileName),
                  jobID: jobID, stepFilter: pending)
        dismiss()
    }

    private func reveal(_ jobID: String) {
        NSWorkspace.shared.activateFileViewerSelecting([store.jobDir(id: jobID)])
    }
}

@MainActor
struct JobRow: View {
    let jobID: String
    let status: JobStore.Status
    let onResume: () -> Void
    let onEditUnits: () -> Void
    let onEditTerms: () -> Void
    let onReveal: () -> Void

    private var doneCount: Int { status.steps.values.filter { $0 == .done }.count }
    private var hasFailed: Bool { status.steps.values.contains(.failed) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(jobID).font(.system(.caption, design: .monospaced))
                Text(status.profileName).font(.caption).foregroundStyle(.secondary)
                if hasFailed {
                    Text("有失败步骤").font(.caption2)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.red.opacity(0.15)))
                        .foregroundStyle(.red)
                }
                Spacer()
                Text("\(doneCount)/\(StepID.allCases.count)")
                    .font(.caption).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Button("续跑") { onResume() }.controlSize(.small)
                Button("编辑译文") { onEditUnits() }.controlSize(.small)
                Button("编辑术语") { onEditTerms() }.controlSize(.small)
                Button("打开目录") { onReveal() }.controlSize(.small)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - 译文单元编辑器（改 zh / voice 后从翻译步续跑）

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
                Text("译文编辑（\(units.count) 单元）").font(.headline)
                Spacer()
                Text("voice 留空 = 默认音色").font(.caption).foregroundStyle(.secondary)
            }.padding(12)
            List {
                ForEach(units.indices, id: \.self) { i in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(String(format: "#%d  [%.1fs-%.1fs] %@", i, units[i].start, units[i].end, units[i].en))
                            .font(.caption).foregroundStyle(.secondary)
                        HStack {
                            TextField("中文译文", text: Binding(
                                get: { units.indices.contains(i) ? units[i].zh : "" },
                                set: { if units.indices.contains(i) { units[i].zh = $0 } }))
                                .textFieldStyle(.roundedBorder)
                            TextField("voice", text: Binding(
                                get: { units.indices.contains(i) ? (units[i].voice ?? "") : "" },
                                set: { if units.indices.contains(i) { units[i].voice = $0.isEmpty ? nil : $0 } }))
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 150)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
            if !message.isEmpty {
                Text(message).font(.caption).foregroundStyle(.blue).padding(.horizontal, 12)
            }
            HStack {
                Button("取消") { dismiss() }
                Spacer()
                Button("保存") { save() }
                Button("保存并从翻译步续跑") {
                    save()
                    dismiss()
                    NotificationCenter.default.post(
                        name: .ytb2zhResumeJob, object: ResumeRequest(jobID: jobID, from: .translate))
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
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
            message = "保存失败：\(error.localizedDescription)"
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
            List {
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
                Text(message).font(.caption).foregroundStyle(.blue).padding(.horizontal, 12)
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
                        message = "保存失败：\(error.localizedDescription)"
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
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
