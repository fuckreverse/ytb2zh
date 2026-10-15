import Foundation

/// Distinguishes file inputs from search queries, including missing absolute paths.
public enum LocalMediaSource {
    public static func url(for input: String) -> URL? {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("file:"), let url = URL(string: value), url.isFileURL {
            return url.standardizedFileURL
        }
        let path = (value as NSString).expandingTildeInPath
        guard path.hasPrefix("/") || value.hasPrefix("./") || value.hasPrefix("../") ||
                (!value.isEmpty && FileManager.default.fileExists(atPath: path)) else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }
}
