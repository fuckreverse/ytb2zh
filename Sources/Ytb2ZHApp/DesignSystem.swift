import SwiftUI
import AppKit
import Ytb2ZHEngines

/// Product palette adapts to explicit appearance preferences as well as the system.
enum AppTheme {
    static let accent = Color(red: 0.98, green: 0.29, blue: 0.35)
    static let canvas = adaptive(light: 0xf5f5f8, dark: 0x101116)
    static let surface = adaptive(light: 0xffffff, dark: 0x1b1d25)
    static let sidebar = adaptive(light: 0xffffff, dark: 0x15161c)
    static let border = Color.primary.opacity(0.08)

    private static func adaptive(light: UInt32, dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
            return NSColor(srgbRed: Double((value >> 16) & 255) / 255,
                           green: Double((value >> 8) & 255) / 255,
                           blue: Double(value & 255) / 255, alpha: 1)
        })
    }
}

struct CinemaButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.controlSize) private var controlSize
    var prominent = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .padding(.horizontal, controlSize == .small || controlSize == .mini ? 10 : 18)
            .padding(.vertical, controlSize == .small || controlSize == .mini ? 7 : 11)
            .foregroundStyle(configuration.role == .destructive ? Color.red : prominent ? Color.white : Color.primary)
            .background(prominent ? AppTheme.accent : AppTheme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(AppTheme.border))
            .opacity(!isEnabled ? 0.4 : configuration.isPressed ? 0.7 : 1)
    }
}

struct CinemaWelcome: View {
    let paste: () -> Void
    var body: some View {
        HStack(spacing: 28) {
            VStack(alignment: .leading, spacing: 16) {
                Label("无限精彩 · 用中文看", systemImage: "waveform")
                    .font(.system(size: 11, weight: .bold)).tracking(2)
                    .foregroundStyle(.white.opacity(0.65))
                Text("好内容，\n不必有语言距离。")
                    .font(.system(size: 36, weight: .bold)).tracking(-1)
                    .fixedSize(horizontal: false, vertical: true)
                Text("把世界的故事，变成熟悉的声音。\n搜索视频，或粘贴链接开启中文观看。")
                    .font(.system(size: 13)).foregroundStyle(.white.opacity(0.65)).lineSpacing(5)
                Button(action: paste) { Label("粘贴链接，开始观看", systemImage: "play.fill") }
                    .buttonStyle(CinemaButtonStyle(prominent: true))
            }
            Spacer(minLength: 0)
            ZStack {
                Circle().stroke(.white.opacity(0.06), lineWidth: 1).frame(width: 230, height: 230)
                Circle().stroke(.white.opacity(0.09), lineWidth: 1).frame(width: 175, height: 175)
                RoundedRectangle(cornerRadius: 24).fill(.white.opacity(0.07))
                    .frame(width: 164, height: 112).rotationEffect(.degrees(-12)).offset(x: -12, y: -8)
                RoundedRectangle(cornerRadius: 24)
                    .fill(LinearGradient(colors: [AppTheme.accent, Color(red: 0.49, green: 0.18, blue: 0.48)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 164, height: 112).rotationEffect(.degrees(9))
                    .shadow(color: AppTheme.accent.opacity(0.25), radius: 35, y: 15)
                Image(systemName: "play.fill").font(.system(size: 36)).offset(x: 3)
            }.frame(width: 240, height: 240).accessibilityHidden(true)
        }
        .foregroundStyle(.white).padding(36)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(LinearGradient(colors: [Color(red: 0.16, green: 0.12, blue: 0.21), Color(red: 0.10, green: 0.11, blue: 0.17)], startPoint: .topLeading, endPoint: .bottomTrailing), in: RoundedRectangle(cornerRadius: 24))
        .overlay(RoundedRectangle(cornerRadius: 24).stroke(.white.opacity(0.08)))
    }
}

extension Notification.Name {
    static let ytb2zhNavigate = Notification.Name("ytb2zhNavigate")
}

func navigate(to page: AppPage) {
    NotificationCenter.default.post(name: .ytb2zhNavigate, object: page)
}

struct PageHeading: View {
    let title: String
    let subtitle: String
    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(L(title)).font(.system(size: 28, weight: .bold)).tracking(-0.6)
            Text(L(subtitle)).font(.callout).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppEmptyState: View {
    let icon: String
    let title: String
    let message: String
    var actionTitle: String? = nil
    var action: () -> Void = {}
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 82, height: 82)
                .background(AppTheme.accent.opacity(0.09), in: RoundedRectangle(cornerRadius: 24))
            Text(L(title)).font(.title2.weight(.semibold))
            Text(L(message)).font(.callout).foregroundStyle(.secondary)
                .multilineTextAlignment(.center).frame(maxWidth: 370)
                .fixedSize(horizontal: false, vertical: true)
            if let actionTitle {
                Button(L(actionTitle), action: action)
                    .buttonStyle(CinemaButtonStyle(prominent: true)).controlSize(.large)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct MediaCardStyle: ViewModifier {
    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func body(content: Content) -> some View {
        content
            .padding(10)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(hovering ? AppTheme.accent.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.22 : 0.06), radius: hovering ? 18 : 6, y: 6)
            .offset(y: hovering && !reduceMotion ? -4 : 0)
            .overlay(alignment: .center) {
                if hovering {
                    Image(systemName: "play.fill").font(.title2).foregroundStyle(.white)
                        .padding(16).background(.black.opacity(0.6), in: Circle())
                        .allowsHitTesting(false).offset(y: -25)
                }
            }
            .onHover { hovering = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: hovering)
    }
}

struct VideoSourcePreview: View {
    let source: String
    let proxy: String
    @State private var details: VideoDetails?
    @State private var loading = false
    @State private var message = ""
    @State private var requestID = UUID()
    private var input: String { source.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        if let url = URL(string: input), ["https", "http"].contains(url.scheme?.lowercased() ?? ""), !VideoCatalogService.isLikelyListURL(input) {
            HStack(spacing: 14) {
                ThumbImage(url: details?.thumbnail ?? CatalogVideo.youTubeThumbnail(input))
                    .frame(width: 128, height: 72).clipped().clipShape(RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(details?.title ?? "视频已添加").font(.headline).lineLimit(2)
                    Text(details?.channel ?? url.host ?? "").font(.caption).foregroundStyle(.secondary)
                    if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                }
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button("读取视频信息") { fetch() }.disabled(loading)
            }
            .onChange(of: source) { _, _ in
                requestID = UUID(); loading = false; message = ""
                details = VideoInfoStore.shared.details(for: input)
            }
            .onAppear { details = VideoInfoStore.shared.details(for: input) }
        }
    }

    private func fetch() {
        let requested = input
        let token = UUID()
        requestID = token; loading = true; message = ""
        let effectiveProxy = proxy
        Task {
            do {
                let result = try await Task.detached {
                    try VideoInfoService().fetch(requested, proxy: effectiveProxy)
                }.value
                guard requestID == token, input == requested else { return }
                details = result
                VideoInfoStore.shared.upsert(result)
            } catch {
                guard requestID == token, input == requested else { return }
                message = "暂时无法读取信息，你仍可尝试转换视频。"
            }
            loading = false
        }
    }
}

/// Shared pill navigation avoids platform segmented-control chrome.
struct CinemaTabs<Value: Hashable>: View {
    let values: [Value]
    @Binding var selection: Value
    let title: (Value) -> String
    var body: some View {
        HStack(spacing: 6) {
            ForEach(values, id: \.self) { value in
                Button { selection = value } label: {
                    Text(L(title(value))).font(.system(size: 12, weight: .semibold))
                        .padding(.horizontal, 16).padding(.vertical, 9)
                        .foregroundStyle(selection == value ? Color.white : Color.primary.opacity(0.65))
                        .background(selection == value ? AppTheme.accent : AppTheme.surface, in: Capsule())
                }.buttonStyle(.plain).accessibilityAddTraits(selection == value ? .isSelected : [])
            }
        }
    }
}
