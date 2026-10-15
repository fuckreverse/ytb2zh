import XCTest
@testable import Ytb2ZHEngines
@testable import Ytb2ZHCore

final class ComposeEngineTests: XCTestCase {

    /// ffmpeg 可用性守卫（不可用时跳过，与 CoreTests 试转测试同模式）
    private func requireFFmpeg() throws {
        let r = try? ProcessRunner().run(SidecarPaths.ffmpeg, ["-hide_banner", "-version"])
        try XCTSkipUnless(r?.code == 0, "ffmpeg 不可用，跳过合成引擎测试")
    }

    // MARK: - 纯函数：滤镜表解析 / 渲染策略

    func testParseFilterNames() {
        let sample = """
          TSC allpass           A->A       Apply a two-pole all-pass filter.
         ... ass               V->V       Render ASS subtitles onto input video using the libass library.
         T.C drawtext          V->V       Draw text on top of video frames using libfreetype library.
         ... subtitles         V->V       Render text subtitles onto input video using the libass library.
        """
        let names = FFmpegCapabilities.parseFilterNames(sample)
        XCTAssertTrue(names.contains("subtitles"))
        XCTAssertTrue(names.contains("ass"))
        XCTAssertTrue(names.contains("drawtext"))
        XCTAssertFalse(names.contains("Render"), "描述文字不应被当作滤镜名")
        XCTAssertFalse(names.contains("A->A"), "输入输出标记不应被当作滤镜名")
    }

    func testSubtitleRendererPreferred() {
        XCTAssertEqual(SubtitleRenderer.preferred(hasSubtitlesFilter: true), .burn)
        XCTAssertEqual(SubtitleRenderer.preferred(hasSubtitlesFilter: false), .soft)
        XCTAssertEqual(SubtitleRenderer.allCases.count, 2)
    }

    // MARK: - 真机：本机 ffmpeg 带 libass，默认路径必须是烧录

    func testHasFilterOnThisMachine() throws {
        try requireFFmpeg()
        XCTAssertTrue(FFmpegCapabilities.hasFilter("subtitles"),
                      "打包的静态 ffmpeg 带 --enable-libass，默认路径应为烧录")
        XCTAssertTrue(FFmpegCapabilities.hasFilter("atempo"), "配音变速滤镜应在表中")
        XCTAssertFalse(FFmpegCapabilities.hasFilter("libx264"), "libx264 是编码器，不属于滤镜表")
        XCTAssertFalse(FFmpegCapabilities.hasFilter("definitely_not_a_filter_xyz"))
    }

    // MARK: - 端到端：lavfi 造 1s 小视频 + 单子句 mp3

    private func makeFixture(_ tmp: URL) throws -> (video: URL, cacheDir: URL) {
        let video = tmp.appendingPathComponent("in.mp4")
        try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                       "-i", "color=c=red:s=160x120:r=10:d=1",
                       "-c:v", "libx264", "-pix_fmt", "yuv420p", video.path])
        let cacheDir = tmp.appendingPathComponent("clauses", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                       "-i", "sine=frequency=440:d=0.5",
                       "-c:a", "libmp3lame", cacheDir.appendingPathComponent("u0_c0.mp3").path])
        return (video, cacheDir)
    }

    private func fixtureUnits() -> ([SpeechUnit], [UnitSchedule], [Placement]) {
        let units = [SpeechUnit(start: 0, end: 1, en: "hello world", zh: "你好，世界。")]
        let schedules = [UnitSchedule(unitIndex: 0, originalStart: 0, originalEnd: 1,
                                      newStart: 0.1, newEnd: 0.6, lead: -0.1)]
        let placements = [Placement(unitIndex: 0, clauseIndex: 0, text: "你好，世界。",
                                    at: 0.1, duration: 0.5, atempo: 1.0)]
        return (units, schedules, placements)
    }

    func testSidecarComposeEngineOutputs() async throws {
        try requireFFmpeg()
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("sidecar_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (video, cacheDir) = try makeFixture(tmp)
        let (units, schedules, placements) = fixtureUnits()
        let output = tmp.appendingPathComponent("out.mp4")

        let result = try await SidecarComposeEngine().compose(
            video: video, placements: placements, unitSchedules: schedules, units: units,
            cacheDir: cacheDir, output: output, options: ComposeOptions(), progress: { _, _ in })

        XCTAssertEqual(result, output)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertGreaterThan((try? FileManager.default
            .attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.intValue ?? 0, 2000)

        // 旁挂 SRT：存在、含译文、时间轴来自调度结果
        let sidecar = tmp.appendingPathComponent("out.srt")
        XCTAssertTrue(FileManager.default.fileExists(atPath: sidecar.path))
        let srtText = try String(contentsOf: sidecar, encoding: .utf8)
        XCTAssertTrue(srtText.contains("你好，世界。"))
        XCTAssertTrue(srtText.contains("00:00:00,100 --> 00:00:00,600"))
    }

    func testFFmpegComposeBurnPathUnchanged() async throws {
        try requireFFmpeg()
        try XCTSkipUnless(FFmpegCapabilities.hasFilter("subtitles"),
                          "本机 ffmpeg 无 libass，烧录路径不可用")
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("burn_\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }

        let (video, cacheDir) = try makeFixture(tmp)
        let (units, schedules, placements) = fixtureUnits()
        let output = tmp.appendingPathComponent("out.mp4")

        _ = try await FFmpegComposeEngine().compose(
            video: video, placements: placements, unitSchedules: schedules, units: units,
            cacheDir: cacheDir, output: output, options: ComposeOptions(), progress: { _, _ in })

        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        // 烧录路径不写旁挂 SRT（那是降级路径与旁挂引擎的行为）
        XCTAssertFalse(FileManager.default.fileExists(atPath: tmp.appendingPathComponent("out.srt").path))
    }

    // MARK: - 注册表：compose 步两个引擎都可被发现/校验

    func testComposeRegistryOffers() {
        let ids = EngineAssembly.registry().descriptors(for: .compose).map(\.id)
        XCTAssertEqual(ids, ["ffmpeg", "sidecar"])
        XCTAssertNotNil(EngineAssembly.registry().descriptor("sidecar", step: .compose))

        var profile = Profile(name: "test")
        profile.engines[StepID.compose.rawValue] = "sidecar"
        XCTAssertTrue(EngineAssembly.registry().validate(profile: profile).isEmpty)

        profile.engines[StepID.compose.rawValue] = "nope"
        XCTAssertFalse(EngineAssembly.registry().validate(profile: profile).isEmpty)
    }

    func testEngineSetResolvesSidecarComposer() throws {
        var profile = Profile(name: "test")
        profile.engines[StepID.compose.rawValue] = "sidecar"
        let set = try EngineAssembly.engineSet(for: profile)
        XCTAssertTrue(set.composer is SidecarComposeEngine)

        let set2 = try EngineAssembly.engineSet(for: Profile(name: "test"))
        XCTAssertTrue(set2.composer is FFmpegComposeEngine)
    }
}
