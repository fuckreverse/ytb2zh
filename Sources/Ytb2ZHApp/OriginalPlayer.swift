import Foundation
import AVKit
import SwiftUI
import Ytb2ZHEngines

// MARK: - 原版播放 sheet：解析直链 → 起反代（见 Engines/OrigStreamServer）→ AVPlayerView 原生控制条（任意拖进度）

struct OriginalPlayerView: View {
    let url: String
    let proxy: String
    @Environment(\.dismiss) private var dismiss
    @State private var status = "解析原版流…"
    @State private var failed = false
    @State private var player: AVPlayer?
    @State private var server: OrigStreamServer?
    @State private var title = "原版播放"

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "film")
                Text(title).lineLimit(1).truncationMode(.tail)
                Spacer()
                if player == nil, !failed {
                    ProgressView().controlSize(.small)
                    Text(status).font(.callout).foregroundStyle(.secondary)
                }
                if failed {
                    Text(status).font(.callout).foregroundStyle(.red)
                        .lineLimit(3)
                }
                Button("关闭") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(12)

            Divider()
            if let player {
                PlayerNSView(player: player)
                    .frame(minWidth: 880, minHeight: 560)
            } else {
                VStack(spacing: 10) {
                    Image(systemName: failed ? "wifi.exclamationmark" : "film")
                        .font(.largeTitle).foregroundStyle(.secondary)
                    Text(failed ? "解析失败" : "正在取得原版直链…")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 920, minHeight: 640)
        .task { await start() }
        .onDisappear {
            player?.pause()
            server?.stop()
        }
    }

    private func start() async {
        do {
            let info = try await Task.detached {
                try OrigStreamService().resolve(url: url, proxy: proxy)
            }.value
            guard !Task.isCancelled else { return }
            title = info.title
            let srv = OrigStreamServer(kind: info.kind, proxy: proxy)
            try srv.start()
            guard let play = srv.localPlayURL else {
                throw EngineError.engineFailure("本地流服务未就绪")
            }
            server = srv
            let p = AVPlayer(url: play)
            player = p
            p.play()
        } catch {
            failed = true
            status = String(format: L10n.tr("失败：%@"), error.localizedDescription)
        }
    }
}

struct PlayerNSView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .default
        return v
    }

    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
