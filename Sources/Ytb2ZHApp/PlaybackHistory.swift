import Foundation
import CryptoKit

/// Positions belong to the source URL, so switching audio or using a new HLS port preserves them.
enum PlaybackHistory {
    private static func key(_ url: String) -> String {
        "playback.position." + SHA256.hash(data: Data(url.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func position(for url: String) -> Double {
        UserDefaults.standard.double(forKey: key(url))
    }
    static func save(_ seconds: Double, for url: String, duration: Double) {
        guard !url.isEmpty, seconds.isFinite, seconds >= 0 else { return }
        let value = duration > 0 && seconds >= duration - 5 ? 0 : seconds
        UserDefaults.standard.set(value, forKey: key(url))
    }
}
