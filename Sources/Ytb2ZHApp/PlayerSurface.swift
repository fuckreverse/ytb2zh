import SwiftUI
import AVKit

/// Keep AVPlayerView for reliable macOS rendering; all visible controls belong to the product.
struct PlayerSurface: View {
    let player: AVPlayer
    @State private var playing = false
    @State private var playbackRate: Float = 1
    @State private var previousVolume = 1.0
    @State private var position = 0.0
    @State private var duration = 0.0
    @State private var volume = 1.0
    @State private var scrubbing = false
    @State private var hovering = false
    private let clock = Timer.publish(every: 0.3, on: .main, in: .common).autoconnect()

    var body: some View {
        ZStack(alignment: .bottom) {
            CinemaVideoCanvas(player: player)
            LinearGradient(colors: [.clear, .black.opacity(0.85)], startPoint: .top, endPoint: .bottom)
                .frame(height: 120).allowsHitTesting(false)
            VStack(spacing: 8) {
                CinemaSlider(value: Binding(get: { position }, set: { value in
                    position = value
                    player.seek(to: CMTime(seconds: value, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                }), range: 0...max(duration, 1), step: 0.1)
                    .disabled(duration <= 0).accessibilityLabel("播放进度")
                    .simultaneousGesture(DragGesture(minimumDistance: 0).onChanged { _ in scrubbing = true }.onEnded { _ in scrubbing = false })
                HStack(spacing: 16) {
                    control(playing ? "pause.fill" : "play.fill", title: playing ? "暂停" : "播放") {
                        if playing { player.pause() } else { player.playImmediately(atRate: playbackRate) }
                        playing = player.rate != 0
                    }
                    control("gobackward.10", title: "后退 10 秒") { seek(-10) }
                    control("goforward.10", title: "前进 10 秒") { seek(10) }
                    Text("\(timestamp(position)) / \(timestamp(duration))")
                        .font(.system(size: 11, weight: .medium, design: .monospaced))
                    Spacer(minLength: 8)
                    control(volume == 0 ? "speaker.slash.fill" : "speaker.wave.2.fill", title: volume == 0 ? "取消静音" : "静音") {
                        if volume > 0 { previousVolume = volume; volume = 0 }
                        else { volume = previousVolume }
                        player.volume = Float(volume)
                    }
                    CinemaSlider(value: Binding(get: { volume }, set: { volume = $0; player.volume = Float($0) }), range: 0...1, step: 0.02)
                        .frame(width: 70).accessibilityLabel("音量")
                    control("arrow.up.left.and.arrow.down.right", title: "切换全屏") { NSApp.keyWindow?.toggleFullScreen(nil) }
                }
            }.padding(.horizontal, 20).padding(.bottom, 16).foregroundStyle(.white)
                .opacity(hovering || !playing || scrubbing ? 1 : 0.75)
        }
        .background(.black)
        .onHover { hovering = $0 }
        .onAppear { volume = Double(player.volume); update() }
        .onReceive(clock) { _ in update() }
    }

    private func control(_ icon: String, title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(width: 28, height: 28).contentShape(Rectangle())
        }.buttonStyle(.plain).help(L(title)).accessibilityLabel(L(title))
    }

    private func update() {
        playing = player.rate != 0
        if player.rate > 0 { playbackRate = player.rate }
        if !scrubbing {
            let seconds = player.currentTime().seconds
            if seconds.isFinite { position = max(0, seconds) }
        }
        let seconds = player.currentItem?.duration.seconds ?? 0
        duration = seconds.isFinite ? max(0, seconds) : 0
    }

    private func seek(_ delta: Double) {
        let target = min(max(duration, 0), max(0, position + delta))
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600))
        position = target
    }

    private func timestamp(_ value: Double) -> String {
        let seconds = Int(max(0, value))
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// AVKit's SwiftUI VideoPlayer crashes during metadata initialization on macOS 26.
private struct CinemaVideoCanvas: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }
    func updateNSView(_ view: AVPlayerView, context: Context) {
        if view.player !== player { view.player = player }
    }
}
