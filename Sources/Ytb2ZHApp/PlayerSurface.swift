import SwiftUI
import AVKit

/// AppKit AVPlayerView 的 SwiftUI 包装。
///
/// 不用 AVKit-SwiftUI 的 `VideoPlayer`：其内部 VideoPlayerView 在 macOS 26 运行时
/// 初始化父类 AVPlayerView 类元数据时 demangle 失败（`So12AVPlayerViewC`），
/// 直接 fatalError abort（SIGABRT，见 DiagnosticReports 153641/153818）。
/// 走 AppKit AVPlayerView 完全绕开该元数据路径。
struct PlayerSurface: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .inline
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player { nsView.player = player }
    }
}
