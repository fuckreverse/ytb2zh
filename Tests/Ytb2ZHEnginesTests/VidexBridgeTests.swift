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

    func testModelStoreAndYtDlpInstallerShareResumableDownloader() async throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("unified-dl-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: dir) }

        let totalSize = 2 * 1024 * 1024 + 512 // > 2MB (3 chunks of 1MB)
        let payload = Data((0..<totalSize).map { UInt8($0 & 0xFF) })

        // 1) ModelStore.download 断网续传校验
        let modelDest = dir.appendingPathComponent("ggml-test.bin")
        let modelHTTP1 = MockRangeServer(payload: payload, failRange: "bytes=1048576-2097151")
        do {
            try await ModelStore.download(
                url: "https://example.com/ggml-test.bin",
                to: modelDest.path,
                proxy: "",
                label: "测试模型",
                http: modelHTTP1
            ) { _, _ in }
            XCTFail("首轮模型下载应在中断点抛错")
        } catch {}
        XCTAssertTrue(fm.fileExists(atPath: modelDest.path + ".part"), "中断后应保留 .part 文件")
        XCTAssertTrue(fm.fileExists(atPath: modelDest.path + ".state.json"), "中断后应保留 .state.json 检查点")

        let modelHTTP2 = MockRangeServer(payload: payload, failRange: nil)
        try await ModelStore.download(
            url: "https://example.com/ggml-test.bin",
            to: modelDest.path,
            proxy: "",
            label: "测试模型",
            http: modelHTTP2
        ) { _, _ in }
        XCTAssertEqual(try Data(contentsOf: modelDest), payload)
        let resumedRanges = await modelHTTP2.requestedRanges
        XCTAssertFalse(resumedRanges.contains("bytes=0-1048575"), "ModelStore 续传不应重新下载已完成的首个 1MB 分块")

        // 2) YtDlpInstaller.install 断网续传与可执行权限校验
        let binDest = dir.appendingPathComponent("yt-dlp_macos")
        let binHTTP1 = MockRangeServer(payload: payload, failRange: "bytes=1048576-2097151")
        do {
            _ = try await YtDlpInstaller.install(to: binDest.path, http: binHTTP1, minimumBytes: 1_000_000)
            XCTFail("首轮 yt-dlp 安装应在中断点抛错")
        } catch {}
        XCTAssertFalse(fm.fileExists(atPath: binDest.path), "中断时不应留下半截目标二进制")
        XCTAssertTrue(fm.fileExists(atPath: binDest.path + ".staging.part"), "中断时应保留 staging.part 供续传")

        let binHTTP2 = MockRangeServer(payload: payload, failRange: nil)
        let installedPath = try await YtDlpInstaller.install(to: binDest.path, http: binHTTP2, minimumBytes: 1_000_000)
        XCTAssertEqual(installedPath, binDest.path)
        XCTAssertTrue(fm.isExecutableFile(atPath: binDest.path), "安装完成后应具备可执行权限")
        XCTAssertEqual(try Data(contentsOf: binDest), payload)
        let binResumedRanges = await binHTTP2.requestedRanges
        XCTAssertFalse(binResumedRanges.contains("bytes=0-1048575"), "YtDlpInstaller 续传不应重复下载首块")
    }
}

private actor MockRangeServer: HTTPFetching {
    let payload: Data
    let failRange: String?
    var requestedRanges: [String] = []

    init(payload: Data, failRange: String?) {
        self.payload = payload
        self.failRange = failRange
    }

    func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard let rangeHeader = request.headers["Range"], rangeHeader.hasPrefix("bytes=") else {
            return HTTPResponse(status: 200, headers: ["ETag": "\"m1\""], body: payload)
        }
        requestedRanges.append(rangeHeader)
        if rangeHeader == failRange {
            throw ExtractionError.network("simulated network drop")
        }
        let parts = rangeHeader.dropFirst("bytes=".count).split(separator: "-").compactMap { Int($0) }
        let start = parts[0]
        let end = min(payload.count - 1, parts[1])
        return HTTPResponse(
            status: 206,
            headers: [
                "Content-Range": "bytes \(start)-\(end)/\(payload.count)",
                "ETag": "\"m1\"",
            ],
            body: Data(payload[start...end])
        )
    }
}
