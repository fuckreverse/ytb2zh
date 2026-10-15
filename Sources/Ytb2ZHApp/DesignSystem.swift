import SwiftUI
import Ytb2ZHEngines

/// Shared semantic colors keep the interface legible in both system appearances.
enum AppTheme {
    static let accent = Color.indigo
    static let canvas = Color(nsColor: .windowBackgroundColor)
    static let surface = Color(nsColor: .controlBackgroundColor)
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
            Text(L(title)).font(.system(size: 25, weight: .bold))
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
                    .buttonStyle(.borderedProminent).controlSize(.large)
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
            .padding(12)
            .background(AppTheme.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16)
                .stroke(hovering ? AppTheme.accent.opacity(0.45) : Color.primary.opacity(0.06), lineWidth: 1))
            .shadow(color: .black.opacity(hovering ? 0.08 : 0.025), radius: hovering ? 12 : 4, y: 3)
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
