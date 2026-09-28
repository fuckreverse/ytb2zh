import XCTest
@testable import Videx

final class YouTubeURLTests: XCTestCase {
    func testWatchURL() {
        XCTAssertEqual(
            YouTubeURL.videoID(from: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!),
            "dQw4w9WgXcQ"
        )
    }

    func testShortURL() {
        XCTAssertEqual(
            YouTubeURL.videoID(from: URL(string: "https://youtu.be/dQw4w9WgXcQ?t=3")!),
            "dQw4w9WgXcQ"
        )
    }

    func testShortsAndEmbedAndLive() {
        for path in ["/shorts/", "/embed/", "/live/", "/v/"] {
            XCTAssertEqual(
                YouTubeURL.videoID(from: URL(string: "https://www.youtube.com\(path)abcdefghijk")!),
                "abcdefghijk",
                "path=\(path)"
            )
        }
    }

    func testMobileAndMusicHosts() {
        XCTAssertEqual(
            YouTubeURL.videoID(from: URL(string: "https://m.youtube.com/watch?v=abcdefghijk")!),
            "abcdefghijk"
        )
        XCTAssertEqual(
            YouTubeURL.videoID(from: URL(string: "https://music.youtube.com/watch?v=abcdefghijk")!),
            "abcdefghijk"
        )
    }

    func testNonYouTube() {
        XCTAssertNil(YouTubeURL.videoID(from: URL(string: "https://vimeo.com/12345")!))
        XCTAssertNil(YouTubeURL.videoID(from: URL(string: "https://www.youtube.com/playlist?list=PL123")!))
    }
}
