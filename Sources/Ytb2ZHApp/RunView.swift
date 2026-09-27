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

    func start(url: String, profile: Profile) {
        start(url: url, profile: profile, jobID: nil, stepFilter: [])
    }

    /// resumeID 非空 = 续跑已有任务；stepFilter 非空 = 只跑指定步骤（如改完译文从翻译续跑）
    func start(url: String, profile: Profile, jobID resumeID: String?, stepFilter: Set<StepID>) {
        guard !running else { return }
        running = true; error = nil; outputURL = nil
        logLines = []; stepProgress = [:]

        let store = JobStore()
        let jobID: String
        do {
            if let resumeID {
                jobID = resumeID
            } else {
                jobID = try store.newJob(url: url, profile: profile)
            }
        } catch {
            self.error = error.localizedDescription
            running = false
            return
        }

        let (stream, cont) = AsyncStream<PipelineEvent>.makeStream()
        let engineSet: EngineSet
        do { engineSet = try EngineAssembly.engineSet(for: profile) }
        catch {
            self.error = error.localizedDescription
            running = false
            return
        }
        let pipeline = Pipeline(engines: engineSet, store: store, events: cont)

        Task {
            let runTask = Task.detached {
                try await pipeline.run(videoURL: URL?.none, url: url, profile: profile,
                                       jobID: jobID, stepFilter: stepFilter)
            }
            for await event in stream {
                handle(event)
            }
            _ = try? await runTask.value
            running = false
        }
    }

    @MainActor
    private func handle(_ e: PipelineEvent) {
        switch e {
        case .stepStarted(let s):
            currentStep = s
            stepProgress[s] = 0
        case .progress(let s, let p, let m):
            stepProgress[s] = p
            if let m { lastMessage = "\(s.label)：\(m)" }
        case .stepFinished(let s, let info):
            stepProgress[s] = 1.0
            logLines.append("✅ \(s.label) \(info.isEmpty ? "" : String(describing: info))")
            if s == .compose, let out = info["output"] {
                outputURL = URL(fileURLWithPath: out)
            }
        case .log(let m):
            logLines.append(m)
        case .failed(let s, let err):
            error = "\(s.label)：\(err)"
            logLines.append("❌ \(s.label)：\(err)")
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
                .disabled(videoURL.trimmingCharacters(in: .whitespaces).isEmpty || (job?.running ?? false))

                if let job, job.running {
                    ProgressView().controlSize(.small).padding(.horizontal, 6)
                    Text(job.lastMessage).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if let job, let out = job.outputURL {
                    Button("显示成片") {
                        NSWorkspace.shared.activateFileViewerSelecting([out])
                    }
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
                    Text(step.label).frame(width: 72, alignment: .leading)
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
