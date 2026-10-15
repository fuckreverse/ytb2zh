import XCTest
@testable import Ytb2ZHCore

final class LocalMediaSourceTests: XCTestCase {
    func testFileURLPreservesSpacesAndChinese() {
        let file = URL(fileURLWithPath: "/tmp/英文 video.mp4")
        XCTAssertEqual(LocalMediaSource.url(for: file.absoluteString), file)
        XCTAssertEqual(LocalMediaSource.url(for: file.path), file)
    }

    func testPathsAreNotSearchQueriesEvenWhenMissing() {
        XCTAssertEqual(LocalMediaSource.url(for: " /tmp/missing.mp4\n")?.path, "/tmp/missing.mp4")
        XCTAssertNotNil(LocalMediaSource.url(for: "~/Movies/video.mov"))
        XCTAssertNotNil(LocalMediaSource.url(for: "./video.mkv"))
    }

    func testWebLinksAndKeywordsRemainOnlineInputs() {
        XCTAssertNil(LocalMediaSource.url(for: "https://example.com/video.mp4"))
        XCTAssertNil(LocalMediaSource.url(for: "English learning"))
        XCTAssertNil(LocalMediaSource.url(for: ""))
    }
}
