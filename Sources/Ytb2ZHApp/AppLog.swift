import Foundation
import SwiftUI

// MARK: - 应用日志（内存环形缓冲 + 统一出口）
// 设计：
//  - 进程内单例环形缓冲（默认 2000 行），GUI 侧「应用日志」面板可查看/复制/导出；
//    避免散落 print（GUI 里 print 只进 stdout，用户看不到）
//  - 级别：debug/info/warn/error；类别：player/pipeline/library/subscriptions/settings/…
//  - 管线日志（jobDir/log.txt）仍按任务落盘；appendLog 时同步镜像进这里，
//    这样任务页看单任务日志，这里看全局时间线
//  - error/warn 同时镜像到 NSLog（进系统 Console，便于用户反馈时抓取）
//  - CLI（ytb2zh）不用它：CLI 的 stdout JSON 是接口契约，保持独立

enum AppLogLevel: String, Comparable {
    case debug, info, warn, error

    private var rank: Int {
        switch self {
        case .debug: 0
        case .info: 1
        case .warn: 2
        case .error: 3
        }
    }

    static func < (a: AppLogLevel, b: AppLogLevel) -> Bool { a.rank < b.rank }

    var badge: String {
        switch self {
        case .debug: "DEBUG"
        case .info: "INFO"
        case .warn: "WARN"
        case .error: "ERROR"
        }
    }
}

@MainActor
final class AppLog: ObservableObject {
    static let shared = AppLog()

    /// 环形缓冲上限（行）
    static let capacity = 2000

    struct Entry: Identifiable {
        let id = UUID()
        let date: Date
        let level: AppLogLevel
        let category: String
        let message: String

        var line: String {
            let df = DateFormatter()
            df.dateFormat = "HH:mm:ss.SSS"
            return "\(df.string(from: date)) [\(level.badge)] [\(category)] \(message)"
        }
    }

    @Published private(set) var entries: [Entry] = []
    private var buffer: [Entry] = []
    private let lock = NSLock()

    private init() {}

    static func debug(_ category: String, _ message: String) { shared.append(.debug, category, message) }
    static func info(_ category: String, _ message: String) { shared.append(.info, category, message) }
    static func warn(_ category: String, _ message: String) { shared.append(.warn, category, message) }
    static func error(_ category: String, _ message: String) { shared.append(.error, category, message) }

    /// 追加一条日志；warn/error 镜像到 NSLog（系统控制台可见）
    func append(_ level: AppLogLevel, _ category: String, _ message: String) {
        let e = Entry(date: Date(), level: level, category: category, message: message)
        lock.lock()
        buffer.append(e)
        if buffer.count > Self.capacity { buffer.removeFirst(buffer.count - Self.capacity) }
        lock.unlock()
        entries = buffer   // MainActor 上发布
        if level >= .warn {
            NSLog("[ytb2zh][\(level.badge)][\(category)] \(message)")
        }
    }

    func clear() {
        lock.lock()
        buffer.removeAll()
        lock.unlock()
        entries = []
    }

    /// 全部日志拼成文本（导出/复制用）
    var exportText: String {
        lock.lock()
        defer { lock.unlock() }
        return buffer.map(\.line).joined(separator: "\n")
    }
}

// MARK: - 日志查看面板（应用设置页「通用」分区里打开）

struct AppLogSheet: View {
    @ObservedObject private var log = AppLog.shared
    @State private var onlyWarn = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("应用日志（最近 \(AppLog.capacity) 行）").font(.headline)
                Spacer()
                Toggle("仅警告/错误", isOn: $onlyWarn)
                    .toggleStyle(.checkbox)
                    .font(.caption)
                Button("清空") { log.clear() }
                Button("复制全部") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(log.exportText, forType: .string)
                }
                Button("导出…") { export() }
                Divider().frame(height: 16)
                Button {
                    dismiss()
                } label: {
                    Label("关闭", systemImage: "xmark.circle.fill")
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(10)

            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 1) {
                        ForEach(filtered) { e in
                            Text(e.line)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(color(for: e.level))
                                .textSelection(.enabled)
                                .id(e.id)
                        }
                    }
                    .padding(8)
                }
                .onChange(of: filtered.count) { _ in
                    if let last = filtered.last { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
        }
        .frame(minWidth: 720, minHeight: 420)
    }

    private var filtered: [AppLog.Entry] {
        onlyWarn ? log.entries.filter { $0.level >= .warn } : log.entries
    }

    private func color(for level: AppLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .primary
        case .warn: .orange
        case .error: .red
        }
    }

    private func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ytb2zh-log.txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? log.exportText.write(to: url, atomically: true, encoding: .utf8)
    }
}
