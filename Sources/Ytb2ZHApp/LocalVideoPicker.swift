import SwiftUI
import UniformTypeIdentifiers

struct LocalVideoPicker: View {
    let onSelect: (URL) -> Void

    var body: some View {
        Button {
            let panel = NSOpenPanel()
            panel.title = L10n.tr("打开本地视频")
            panel.allowedContentTypes = [.movie, .video, .mpeg4Movie, .quickTimeMovie,
                UTType(filenameExtension: "mkv") ?? .movie,
                UTType(filenameExtension: "webm") ?? .movie,
                UTType(filenameExtension: "avi") ?? .movie]
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let file = panel.url { onSelect(file) }
        } label: {
            Label("打开本地视频", systemImage: "folder")
        }
        .help("选择英文视频，生成中文字幕与中文配音")
    }
}
