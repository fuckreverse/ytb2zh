import XCTest
import Videx
@testable import Ytb2ZHEngines

final class VidexBridgeTests: XCTestCase {
    private func info(_ formats: [MediaFormat]) -> MediaInfo {
        MediaInfo(extractorID: "youtube", id: "test", title: "Test", webpageURL: URL(string: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")!, formats: formats)
    }
    private func format(_ id: String, _ kind: MediaKind, _ height: Int? = nil, hls: Bool = false) -> MediaFormat {
        MediaFormat(formatID: id, kind: kind, url: URL(string: "https://example.com/\(id)")!, container: "mp4",
                    videoCodec: kind == .audioOnly ? nil : "avc1.64001f", audioCodec: kind == .videoOnly ? nil : "mp4a.40.2",
                    height: height, protocolType: hls ? .hls : .https)
    }

    func testDownloadPrefers720AdaptiveOver360Muxed() {
        let selection = VidexDownloadEngine.select(info([format("18", .muxed, 360), format("136", .videoOnly, 720), format("140", .audioOnly)]), maxHeight: 720, preferAVC: true)
        guard case .merge(let video, let audio) = selection else { return XCTFail("应选高清合流") }
        XCTAssertEqual(video.formatID, "136")
        XCTAssertEqual(audio.formatID, "140")
    }

    func testProgressivePlaybackDoesNotReturnManifestAsMP4() {
        let media = info([format("muxed", .muxed, 720, hls: true)])
        XCTAssertEqual(VidexBridge.playableStream(media)?.kind, .hls(video: "https://example.com/muxed", audio: ""))
    }

    func testSeparateHLSPlayback() {
        let media = info([format("v", .videoOnly, 720, hls: true), format("a", .audioOnly, hls: true)])
        XCTAssertEqual(VidexBridge.playableStream(media)?.kind, .hls(video: "https://example.com/v", audio: "https://example.com/a"))
    }

    func testMuxedHLSMasterHasNoEmptyAudioRendition() {
        let master = OrigStreamServer.masterM3U8(videoProxied: "https://example.com/v", audioProxied: "", height: 720)
        XCTAssertTrue(master.contains("https://example.com/v"))
        XCTAssertFalse(master.contains("TYPE=AUDIO"))
        XCTAssertFalse(master.contains("AUDIO=\"aud\""))
    }

    func testHLSDownloadRemuxesPlaylist() async throws {
        guard let url = ProcessInfo.processInfo.environment["VIDEX_HLS_SMOKE_URL"].flatMap(URL.init(string:)) else {
            throw XCTSkip("设 VIDEX_HLS_SMOKE_URL 为本地 HLS 测试清单启用")
        }
        let target = FileManager.default.temporaryDirectory.appendingPathComponent("videx-hls-test-\(UUID().uuidString).mp4")
        defer { try? FileManager.default.removeItem(at: target) }
        let media = MediaFormat(formatID: "test", kind: .muxed, url: url, container: "mp4", protocolType: .hls)
        try await VidexDownloadEngine.fetchFormat(media, to: target, proxy: "", referer: nil, range: 0...1, progress: { _, _ in }, partialSeconds: 1)
        let data = try Data(contentsOf: target)
        XCTAssertGreaterThan(data.count, 1000)
        XCTAssertEqual(String(data: data[4..<8], encoding: .utf8), "ftyp")
    }

    // MARK: - Web POT 收割兜底决策

    func testHarvestTriggeredOnlyForRiskControlErrors() {
        XCTAssertTrue(VidexBridge.shouldHarvestPOT(.loginRequired(site: "youtube", reason: "bot")))
        XCTAssertTrue(VidexBridge.shouldHarvestPOT(.notExtractable(site: "youtube", reason: "无格式")))
        XCTAssertFalse(VidexBridge.shouldHarvestPOT(.network("超时")), "网络错误不该触发收割")
        XCTAssertFalse(VidexBridge.shouldHarvestPOT(.parse("坏 JSON")))
        XCTAssertFalse(VidexBridge.shouldHarvestPOT(.unsupportedURL(URL(string: "https://x.com")!)))
    }

    func testPOTcoversWebFamilyClients() {
        XCTAssertEqual(Set(VidexBridge.webFamilyClientKeys), ["web", "web_safari", "web_embedded", "mweb", "tv_samsung", "tv_downgraded", "tv_simply"])
        XCTAssertFalse(VidexBridge.webFamilyClientKeys.contains("visionos"), "免 POT 客户端无需注入")
    }
}
