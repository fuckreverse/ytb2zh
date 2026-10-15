import SwiftUI
import UniformTypeIdentifiers

struct ConsoleLogRow: Identifiable {
    let id: String
    let text: String
    let level: AppLogLevel
    var category: String = ""
}

/// Shared controls for application and persisted task logs.
struct LogConsole: View {
    let rows: [ConsoleLogRow]
    let filename: String
    @State private var search = ""
    @State private var minimumLevel = "all"
    @State private var category = "all"
    @State private var follow = true
    @State private var exportError: String?

    private var categories: [String] { Set(rows.map(\.category).filter { !$0.isEmpty }).sorted() }
    private var filtered: [ConsoleLogRow] {
        rows.filter { row in
            (minimumLevel == "all" || row.level >= (AppLogLevel(rawValue: minimumLevel) ?? .debug)) &&
            (category == "all" || row.category == category) &&
            (search.isEmpty || row.text.localizedCaseInsensitiveContains(search))
        }
    }

    var body: some View {
        let visible = filtered
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("搜索日志内容", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain).help("清除搜索")
                }
                Picker("级别", selection: $minimumLevel) {
                    Text("全部级别").tag("all")
                    Text("信息及以上").tag("info")
                    Text("警告及以上").tag("warn")
                    Text("仅错误").tag("error")
                }.frame(width: 155)
                if !categories.isEmpty {
                    Picker("来源", selection: $category) {
                        Text("全部来源").tag("all")
                        ForEach(categories, id: \.self) { Text($0).tag($0) }
                    }.frame(width: 165)
                }
            }
            .padding(12)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    if visible.isEmpty {
                        VStack(spacing: 10) {
                            Image(systemName: rows.isEmpty ? "text.alignleft" : "line.3.horizontal.decrease.circle")
                                .font(.largeTitle).foregroundStyle(.secondary)
                            Text(rows.isEmpty ? "暂无日志" : "没有匹配的日志").font(.headline)
                            Text(rows.isEmpty ? "运行后，日志会自动显示在这里。" : "试试其他关键词，或调整级别与来源筛选。")
                                .font(.callout).foregroundStyle(.secondary)
                        }.frame(maxWidth: .infinity).padding(.vertical, 70)
                    } else {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(visible) { row in
                                HStack(alignment: .top, spacing: 10) {
                                    Image(systemName: symbol(row.level))
                                        .foregroundStyle(color(row.level)).frame(width: 16)
                                        .accessibilityLabel(row.level.badge)
                                    Text(row.text)
                                        .font(.system(size: 12, design: .monospaced))
                                        .foregroundStyle(row.level == .debug ? .secondary : .primary)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                }
                                .padding(.horizontal, 14).padding(.vertical, 7)
                                .background(row.level >= .warn ? color(row.level).opacity(0.07) : Color.clear)
                                .contextMenu {
                                    Button("复制此条") { copy(row.text) }
                                }
                                .id(row.id)
                                Divider().opacity(0.35)
                            }
                        }
                    }
                    Color.clear.frame(height: 1).id("log-bottom")
                }
                .background(Color(nsColor: .textBackgroundColor))
                .onAppear { if follow { proxy.scrollTo("log-bottom", anchor: .bottom) } }
                .onChange(of: visible.last?.id) { _, _ in
                    if follow { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
                .onChange(of: follow) { _, enabled in
                    if enabled { proxy.scrollTo("log-bottom", anchor: .bottom) }
                }
                Divider()
                HStack(spacing: 14) {
                    Text("\(visible.count) / \(rows.count)").monospacedDigit().foregroundStyle(.secondary)
                    Toggle("跟随最新", isOn: $follow).toggleStyle(.checkbox)
                        .help("回看历史日志时可关闭，避免新日志打断阅读")
                    Button("跳到最新") { proxy.scrollTo("log-bottom", anchor: .bottom) }
                        .disabled(visible.isEmpty)
                    Spacer()
                    Button("复制结果") { copy(visible.map(\.text).joined(separator: "\n")) }
                        .disabled(visible.isEmpty)
                    Menu("导出…") {
                        Button("导出当前结果") { export(visible) }.disabled(visible.isEmpty)
                        Button("导出全部日志") { export(rows) }.disabled(rows.isEmpty)
                    }
                }.font(.caption).padding(12)
            }
        }
        .onChange(of: categories) { _, values in
            if category != "all", !values.contains(category) { category = "all" }
        }
        .alert("日志导出失败", isPresented: Binding(get: { exportError != nil }, set: { if !$0 { exportError = nil } })) {
            Button("好") { exportError = nil }
        } message: { Text(exportError ?? "") }
    }

    private func color(_ level: AppLogLevel) -> Color {
        switch level {
        case .debug: .secondary
        case .info: .blue
        case .warn: .orange
        case .error: .red
        }
    }

    private func symbol(_ level: AppLogLevel) -> String {
        switch level {
        case .debug: "ellipsis.circle"
        case .info: "info.circle"
        case .warn: "exclamationmark.triangle"
        case .error: "xmark.octagon"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(_ values: [ConsoleLogRow]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = filename
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try values.map(\.text).joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8) }
        catch { exportError = error.localizedDescription }
    }
}
