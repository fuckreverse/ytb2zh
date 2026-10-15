import SwiftUI
import AVKit
import Ytb2ZHCore
import Ytb2ZHEngines

// MARK: - 任务详情：中间产物浏览 / 预览 / 逐步重跑（调试再处理中心）
// 设计目标：一个视频往往要多次处理才能理想——这里把"看产物 → 改中间数据 → 从对应步重跑"串成一圈。

@MainActor
struct JobDetailView: View {
    let jobID: String
    @ObservedObject var job: PipelineJob
    var onEditUnits: () -> Void = {}
    var onEditTerms: () -> Void = {}
    @Environment(\.dismiss) private var dismiss
    @State private var status = JobStore.Status()
    @State private var files: [ArtifactFile] = []
    @State private var preview: ArtifactFile?
    @State private var showLog = false

    private let store = JobStore()

    // MARK: 产物模型

    struct ArtifactFile: Identifiable {
        let url: URL
        let isDir: Bool
        let size: Int64
        let modified: Date
        let step: String
        var id: String { url.path }
        var name: String { url.lastPathComponent }

        var ext: String { url.pathExtension.lowercased() }
        var isMedia: Bool { ["mp4", "wav", "mp3", "ts", "m4a", "mov"].contains(ext) }
        var isText: Bool { !isDir && ["json", "srt", "txt", "vtt", "m3u8"].contains(ext) }
        var previewable: Bool { isMedia || isText }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    stepsCard
                    debugLoopCard
                    artifactsCard
                    logCard
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(minWidth: 760, minHeight: 560)
        .navigationTitle("任务详情")
        .onAppear(perform: reload)
        .sheet(item: $preview) { f in
            CinemaPresentation {
                ArtifactPreviewSheet(file: f)
                    .frame(minWidth: 680, minHeight: 520)
            }
        }
        .sheet(isPresented: $showLog) {
            CinemaPresentation {
                LogSheet(jobID: jobID)
                    .frame(minWidth: 680, minHeight: 520)
            }
        }
    }

    // MARK: 头部

    private var header: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(jobID).font(.system(.headline, design: .monospaced))
                Text("\(status.profileName) · 创建于 \(Self.dateText(status.createdAt))").font(.caption).foregroundStyle(.secondary)
                Text(status.url).font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([store.jobDir(id: jobID)])
            } label: { Label("任务目录", systemImage: "folder") }
            if store.hasFinalVideo(jobID) {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([store.finalVideo(jobID)])
                } label: { Label("定位成片", systemImage: "film") }
            }
            Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
        }
        .padding(12)
    }

    // MARK: 步骤时间线 + 逐步重跑

    private var stepsCard: some View {
        CinemaSection("步骤") {
            VStack(spacing: 0) {
                ForEach(Array(StepID.allCases.enumerated()), id: \.element) { idx, step in
                    HStack(spacing: 10) {
                        stepIcon(step)
                        Text(L(step.label))
                        if job.running && job.currentStep == step {
                            Text("进行中…").font(.caption).foregroundStyle(.orange)
                        }
                        Spacer()
                        if let d = stepDate(step) {
                            Text(Self.dateText(d)).font(.caption2).foregroundStyle(.tertiary)
                        }
                        Button("从此步重跑") {
                            dismiss()
                            NotificationCenter.default.post(
                                name: .ytb2zhResumeJob, object: ResumeRequest(jobID: jobID, from: step))
                        }
                        .buttonStyle(CinemaLinkStyle())
                        .font(.caption)
                        .disabled(job.running)
                        .help("丢弃该步及之后的产物，从「\(step.label)」重新处理（前面产物保留复用）")
                    }
                    .padding(.vertical, 5)
                    if idx < StepID.allCases.count - 1 { Divider() }
                }
            }
        }
    }

    private func stepIcon(_ step: StepID) -> some View {
        let s = status.steps[step.rawValue]
        return Group {
            switch s {
            case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .running: ProgressView().controlSize(.mini)
            default: Image(systemName: "circle").foregroundStyle(.quaternary)
            }
        }
        .font(.callout)
    }

    private func stepDate(_ step: StepID) -> Date? {
        artifact(for: step).flatMap { u in files.first { $0.url == u } }?.modified
    }

    /// 每一步的"代表性产物"，存在才显示时间
    private func artifact(for step: StepID) -> URL? {
        let map: [StepID: [URL]] = [
            .download: [store.source(jobID)],
            .separate: [store.vocalsWav(jobID)],
            .transcribe: [store.wordsJSON(jobID)],
            .segment: [store.unitsJSON(jobID)],
            .summarize: [store.terminologyJSON(jobID)],
            .translate: [store.translatedJSON(jobID)],
            .synthesize: [store.clauseCache(jobID)],
            .schedule: [store.planJSON(jobID)],
            .compose: [store.finalVideo(jobID)],
        ]
        return (map[step] ?? []).first {
            (try? FileManager.default.attributesOfItem(atPath: $0.path)) != nil
        }
    }

    // MARK: 调试循环（改中间数据 → 续跑）

    private var debugLoopCard: some View {
        CinemaSection("多次精修（改完中间数据，从对应步骤重跑）") {
            HStack(spacing: 8) {
                Button {
                    dismiss()
                    onEditUnits()
                } label: { Label("改译文 / 配音文本", systemImage: "character.cursor.ibeam") }
                Button {
                    dismiss()
                    onEditTerms()
                } label: { Label("改术语表", systemImage: "book") }
                Text("保存后选「保存并从翻译步续跑」，之前的产物全部复用")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 中间产物列表

    private var artifactsCard: some View {
        CinemaSection("中间产物（\(files.filter { !$0.isDir }.count) 个文件）") {
            if files.isEmpty {
                Text("暂无产物").font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(files) { f in
                        HStack(spacing: 10) {
                            Image(systemName: icon(for: f))
                                .foregroundStyle(f.isMedia ? AppTheme.accent : Color.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(f.name).font(.system(.callout, design: .monospaced))
                                if !f.step.isEmpty {
                                    Text(f.step).font(.caption2).foregroundStyle(.secondary)
                                }
                            }
                            Spacer()
                            Text(f.isDir ? "目录" : Self.sizeText(f.size))
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                .frame(width: 72, alignment: .trailing)
                            Text(Self.dateText(f.modified))
                                .font(.caption2).foregroundStyle(.tertiary)
                            if f.previewable {
                                Button("预览") { preview = f }.buttonStyle(CinemaLinkStyle()).font(.caption)
                            }
                            Button {
                                NSWorkspace.shared.activateFileViewerSelecting([f.url])
                            } label: { Image(systemName: "arrow.up.right.square") }
                                .buttonStyle(CinemaLinkStyle())
                                .help("在 Finder 中显示")
                        }
                        .padding(.vertical, 4)
                        Divider()
                    }
                }
            }
        }
    }

    private func icon(for f: ArtifactFile) -> String {
        switch f.ext {
        case "mp4", "mov", "ts": return "film"
        case "wav", "mp3", "m4a": return "waveform"
        case "json": return "curlybraces"
        case "srt", "vtt": return "text.quote"
        case "m3u8": return "list.bullet"
        case "txt": return "doc.plaintext"
        default: return f.isDir ? "folder" : "doc"
        }
    }

    // MARK: 日志

    private var logCard: some View {
        CinemaSection("运行日志") {
            HStack {
                let log = store.jobDir(id: jobID).appendingPathComponent("log.txt")
                if FileManager.default.fileExists(atPath: log.path) {
                    Text("log.txt 随运行持续追加，跨续跑保留").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("查看全文") { showLog = true }.buttonStyle(CinemaLinkStyle())
                    Button {
                        NSWorkspace.shared.activateFileViewerSelecting([log])
                    } label: { Image(systemName: "arrow.up.right.square") }.buttonStyle(CinemaLinkStyle())
                } else {
                    Text("还没有日志（旧任务或尚未运行）").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: 数据

    private func reload() {
        status = store.loadStatus(jobID)
        files = Self.scan(jobDir: store.jobDir(id: jobID), store: store)
    }

    static func scan(jobDir: URL, store: JobStore) -> [ArtifactFile] {
        let stepNames: [String: String] = [
            "source.mp4": "下载", "audio16k.wav": "转录音频", "audio16k.json": "转录词级时间戳",
            "vocals.wav": "人声分离", "instrumental.wav": "人声分离（伴奏）",
            "words.json": "转录", "units.json": "语义切分（可编辑）",
            "terminology.json": "术语表+领域（可编辑）", "translated.json": "翻译结果（可编辑）",
            "clauses": "TTS 分句缓存", "plan.json": "对齐调度", "dub.wav": "配音轨",
            "zh.srt": "中文字幕", "final_zh.mp4": "成片", "live": "实时直播分片",
            "concat.txt": "合成清单", "final_list.txt": "成片拼接清单",
            "status.json": "状态元数据", "profile.json": "参数快照", "log.txt": "运行日志",
        ]
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: jobDir, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey], options: []) else { return [] }
        return items.compactMap { url in
            guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isDirectoryKey]) else { return nil }
            let isDir = vals.isDirectory ?? url.hasDirectoryPath
            let name = url.lastPathComponent
            let step: String
            if isDir {
                step = name == "clauses" ? "TTS 分句缓存" : name == "live" ? "实时直播分片" : name == "demucs_out" ? "人声分离" : ""
            } else {
                step = stepNames[name] ?? (name.hasSuffix(".mp3") ? "TTS 分句音频" : name.hasSuffix(".duration") ? "TTS 分句时长" : "")
            }
            return ArtifactFile(url: url, isDir: isDir,
                                size: Int64(vals.fileSize ?? 0),
                                modified: vals.contentModificationDate ?? Date(),
                                step: step)
        }
        .sorted { $0.url.lastPathComponent < $1.url.lastPathComponent }
    }

    static func sizeText(_ n: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
    }

    static func dateText(_ d: Date) -> String {
        d.formatted(date: .abbreviated, time: .shortened)
    }
}

// MARK: - 产物预览（媒体直接播，文本读前 256KB）

@MainActor
struct ArtifactPreviewSheet: View {
    let file: JobDetailView.ArtifactFile
    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(file.name).font(.headline)
                Text(file.isDir ? "目录" : JobDetailView.sizeText(file.size))
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            if file.isMedia {
                if let player {
                    PlayerSurface(player: player)
                } else {
                    Text("无法播放").foregroundStyle(.secondary)
                }
            } else {
                ScrollView {
                    Text(text)
                        .font(.system(.caption, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .textSelection(.enabled)
                }
            }
        }
        .onAppear {
            if file.isMedia {
                player = AVPlayer(url: file.url)
                player?.play()
            }
        }
        .onDisappear { player?.pause() }
    }

    private var text: String {
        guard let data = try? Data(contentsOf: file.url) else { return "（无法读取）" }
        let trimmed = data.prefix(256 * 1024)
        var s = String(data: trimmed, encoding: .utf8) ?? "（二进制内容，请在 Finder 中打开）"
        if data.count > 256 * 1024 { s += "\n\n…（已截断，全文请在 Finder 中打开）" }
        return s
    }
}

// MARK: - 日志全文

@MainActor
struct LogSheet: View {
    let jobID: String
    @Environment(\.dismiss) private var dismiss
    @State private var rows: [ConsoleLogRow] = []
    @State private var previousText: String?
    @State private var readError: String?

    private var file: URL { JobStore().jobDir(id: jobID).appendingPathComponent("log.txt") }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("运行日志").font(.title2.bold())
                    Text(jobID).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                    Text("每 2 秒刷新，跨续跑保留").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
                Button("关闭") { dismiss() }.keyboardShortcut(.cancelAction)
            }.padding(18)
            if let readError {
                Text(readError).font(.caption).foregroundStyle(.red).padding(.horizontal, 18).padding(.bottom, 8)
            }
            Divider()
            LogConsole(rows: rows, filename: "ytb2zh-\(jobID)-log.txt")
        }
        .frame(minWidth: 820, idealWidth: 1020, minHeight: 480, idealHeight: 640)
        .task {
            while !Task.isCancelled {
                await reload()
                do { try await Task.sleep(for: .seconds(2)) } catch { break }
            }
        }
    }

    private func reload() async {
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        do {
            let source = file
            let text = try await Task.detached(priority: .utility) {
                try String(contentsOf: source, encoding: .utf8)
            }.value
            guard !Task.isCancelled else { return }
            readError = nil
            guard text != previousText else { return }
            previousText = text
            rows = text.components(separatedBy: .newlines).enumerated().compactMap { index, line in
                guard !line.isEmpty else { return nil }
                let level: AppLogLevel
                if line.contains("❌") || line.contains("[ERROR]") || line.contains("失败") { level = .error }
                else if line.contains("⚠") || line.contains("[WARN]") || line.contains("警告") { level = .warn }
                else { level = .info }
                return ConsoleLogRow(id: String(index), text: line, level: level)
            }
        } catch { readError = error.localizedDescription }
    }
}
