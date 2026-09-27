import SwiftUI
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 运行条 + 进度视图

@MainActor
final class PipelineJob: ObservableObject {
    @Published var running = false
    @Published var currentStep: StepID?
    @Published var stepProgress: [StepID: Double] = [:]
    @Published var lastMessage = ""
    @Published var error: String?
    @Published var outputURL: URL?
    @Published var logLines: [String] = []
    @Published private(set) var jobID: String?

    func start(url: String, profile: Profile) {
        start(url: url, profile: profile, jobID: nil, stepFilter: [])
    }

    /// resumeID 非空 = 续跑已有任务；stepFilter 非空 = 只跑指定步骤（如改完译文从翻译续跑）；
    /// trialSeconds 非空 = 试转模式（新独立任务，只处理前 N 秒验证配置）
    func start(url: String, profile: Profile, jobID resumeID: String? = nil,
               stepFilter: Set<StepID> = [], trialSeconds: Int? = nil) {
        guard !running else { return }
        running = true; error = nil; outputURL = nil
        logLines = []; stepProgress = [:]

        let store = JobStore()
        let jobID: String
        do {
            if let resumeID {
                jobID = resumeID
            } else {
                jobID = try store.newJob(url: url, profile: profile, trial: trialSeconds != nil)
            }
        } catch {
            self.error = error.localizedDescription
            AppLog.error("pipeline", "任务创建失败：\(error.localizedDescription)")
            running = false
            return
        }

        let (stream, cont) = AsyncStream<PipelineEvent>.makeStream()
        let engineSet: EngineSet
        do { engineSet = try EngineAssembly.engineSet(for: AppSettings.applied(profile)) }
        catch {
            self.error = error.localizedDescription
            AppLog.error("pipeline", "引擎装配失败：\(error.localizedDescription)")
            running = false
            return
        }
        let pipeline = Pipeline(engines: engineSet, store: store, events: cont)

        self.jobID = jobID
        appendLog(trialSeconds != nil
                  ? "—— 运行开始（试转：前 \(trialSeconds!) 秒）——"
                  : "—— 运行开始（\(resumeID == nil ? "新任务" : "续跑 \(resumeID!)")）——")
        Task {
            let runTask = Task.detached {
                try await pipeline.run(videoURL: URL?.none, url: url, profile: profile,
                                       jobID: jobID, stepFilter: stepFilter,
                                       trialSeconds: trialSeconds)
            }
            for await event in stream {
                handle(event)
            }
            _ = try? await runTask.value
            running = false
        }
    }

    /// 日志同步落盘 jobDir/log.txt（跨续跑追加，供任务详情页查看），
    /// 并镜像进全局 AppLog（应用日志面板看全局时间线）
    private func appendLog(_ line: String) {
        AppLog.info("pipeline", line)
        guard let id = jobID else { return }
        let url = JobStore().jobDir(id: id).appendingPathComponent("log.txt")
        let data = Data((line + "\n").utf8)
        if let h = try? FileHandle(forWritingTo: url) {
            defer { try? h.close() }
            try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }

    @MainActor
    private func handle(_ e: PipelineEvent) {
        switch e {
        case .stepStarted(let s):
            currentStep = s
            stepProgress[s] = 0
            appendLog("▶ \(s.label)")
        case .progress(let s, let p, let m):
            stepProgress[s] = p
            if let m { lastMessage = "\(s.label)：\(m)" }
        case .stepFinished(let s, let info):
            stepProgress[s] = 1.0
            logLines.append("✅ \(s.label) \(info.isEmpty ? "" : String(describing: info))")
            appendLog("✅ \(s.label) \(info.isEmpty ? "" : String(describing: info))")
            if s == .compose, let out = info["output"] {
                outputURL = URL(fileURLWithPath: out)
            }
        case .log(let m):
            logLines.append(m)
            appendLog(m)
        case .failed(let s, let err):
            error = "\(s.label)：\(err)"
            logLines.append("❌ \(s.label)：\(err)")
            appendLog("❌ \(s.label)：\(err)")
        }
    }
}

struct RunBar: View {
    let videoURL: String
    let profile: Profile
    @Binding var job: PipelineJob?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    let j = PipelineJob()
                    job = j
                    j.start(url: videoURL, profile: profile)
                } label: {
                    Label("开始转换", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
                .disabled(disabled)
                .help(disabledHint)

                // 两段式：先跑到翻译停下，人工审核确认后再在任务中心继续转换
                Button {
                    let j = PipelineJob()
                    job = j
                    j.start(url: videoURL, profile: profile, jobID: nil,
                            stepFilter: [.download, .separate, .transcribe, .segment, .summarize, .translate])
                } label: {
                    Label("生成译文（先审核）", systemImage: "text.badge.checkmark")
                }
                .buttonStyle(.bordered)
                .disabled(disabled)
                .help("只跑到「翻译」就停下：下载→转录→切分→术语→翻译，不出成片。跑到翻译后到任务中心打开「审核译文」，人工确认/修改后点「保存并继续转换」再出片")

                // 试转：独立新任务只处理前 3 分钟，低成本验证全链路配置；确认没问题再全量转换
                Button {
                    let j = PipelineJob()
                    job = j
                    j.start(url: videoURL, profile: profile, jobID: nil,
                            stepFilter: [], trialSeconds: 180)
                } label: {
                    Label("试转前3分钟", systemImage: "gauge.with.needle")
                }
                .buttonStyle(.bordered)
                .disabled(disabled)
                .help("试转模式：新开独立任务，下载/转录/翻译/配音/成片全流程只跑前 3 分钟，快速验证配置。小样没问题后，再用「开始转换」跑全片（全片是新任务，互不影响）")

                if disabled && (job?.running ?? false) == false {
                    Text("先在上方填入视频地址")
                        .font(.caption).foregroundStyle(.secondary)
                }

                if let job, job.running {
                    ProgressView().controlSize(.small).padding(.horizontal, 6)
                    Text(job.lastMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let job, job.running == false, let out = job.outputURL {
                    Button("显示成片") {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    }
                } else if let job, job.running == false, job.outputURL == nil,
                          job.currentStep != nil, job.error == nil {
                    Text("未出成片：到任务中心「审核译文」，确认后继续转换")
                        .font(.caption).foregroundStyle(.orange)
                        .help("本任务停在中间步骤（如先生成译文待审核），或后续步骤尚未运行")
                }
            }
            .padding(12)

            if let job {
                PipelineProgressView(job: job)
                    .frame(maxHeight: 220)
            }
        }
        .background(.bar)
    }

    private var disabled: Bool {
        videoURL.trimmingCharacters(in: .whitespaces).isEmpty || (job?.running ?? false)
    }

    private var disabledHint: String {
        if job?.running == true { return "已有任务在运行" }
        return "先在上方填入视频地址"
    }
}

struct PipelineProgressView: View {
    @ObservedObject var job: PipelineJob

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(StepID.allCases, id: \.self) { step in
                HStack {
                    Image(systemName: icon(for: step))
                        .foregroundStyle(color(for: step))
                        .frame(width: 18)
                    Text(L(step.label)).frame(width: 72, alignment: .leading)
                    ProgressView(value: job.stepProgress[step] ?? 0)
                        .frame(maxWidth: 380)
                    if job.currentStep == step {
                        Text(String(format: "%d%%", Int((job.stepProgress[step] ?? 0) * 100)))
                            .font(.caption).monospacedDigit()
                            .frame(width: 42, alignment: .trailing)
                    } else {
                        Text("").frame(width: 42)
                    }
                }
            }
            if let err = job.error {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func icon(for step: StepID) -> String {
        guard let p = job.stepProgress[step] else { return "circle" }
        return p >= 1.0 ? "checkmark.circle.fill" : "circle"
    }

    private func color(for step: StepID) -> Color {
        guard let p = job.stepProgress[step] else { return .secondary }
        return p >= 1.0 ? .green : (job.currentStep == step ? .blue : .secondary)
    }
}
