import XCTest
@testable import Ytb2ZHEngines
import Ytb2ZHCore

final class LivePipelineLogicTests: XCTestCase {

    // MARK: 窗口划分

    /// 按目标窗长切窗：单元不跨窗、覆盖完整、顺序保持
    func testPlanWindowsCoversAllUnits() {
        // 0..120s，每 10s 一个单元 → 60s 窗口应切出 2 个窗口（各 6 个单元）
        let units = (0..<12).map { i in
            SpeechUnit(start: Double(i) * 10, end: Double(i) * 10 + 8, en: "u\(i)", zh: "第\(i)句")
        }
        let windows = LivePipeline.planWindows(units: units, target: 60.0)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].lowerBound, 0)
        XCTAssertEqual(windows[0].upperBound, 6)
        XCTAssertEqual(windows[1].lowerBound, 6)
        XCTAssertEqual(windows[1].upperBound, 12)
        // 窗口衔接无缝
        XCTAssertEqual(windows[0].upperBound, windows[1].lowerBound)
    }

    /// 超长单元独立成窗（不能丢单元）
    func testPlanWindowsOversizedUnit() {
        let units = [
            SpeechUnit(start: 0, end: 100, en: "long", zh: "超长"),
            SpeechUnit(start: 100, end: 110, en: "next", zh: "下一句"),
        ]
        let windows = LivePipeline.planWindows(units: units, target: 60.0)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0], 0..<1)
        XCTAssertEqual(windows[1], 1..<2)
    }

    /// 空输入
    func testPlanWindowsEmpty() {
        XCTAssertTrue(LivePipeline.planWindows(units: []).isEmpty)
    }

    // MARK: HLS playlist

    /// EVENT 型 playlist：含分片、ENDLIST 仅在终局出现
    func testPlaylistText() {
        let segs = [LiveSegment(name: "seg000.ts", duration: 60.123),
                    LiveSegment(name: "seg001.ts", duration: 58.5)]
        let open = LivePipeline.playlistText(segments: segs, target: 61, endlist: false)
        XCTAssertTrue(open.hasPrefix("#EXTM3U"))
        XCTAssertTrue(open.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertTrue(open.contains("#EXT-X-TARGETDURATION:61"))
        XCTAssertTrue(open.contains("#EXTINF:60.123,"))
        XCTAssertTrue(open.contains("seg000.ts"))
        XCTAssertFalse(open.contains("#EXT-X-ENDLIST"))

        let closed = LivePipeline.playlistText(segments: segs, target: 61, endlist: true)
        XCTAssertTrue(closed.contains("#EXT-X-ENDLIST"))
    }

    /// 追加语义：新 playlist 是旧 playlist 的前缀超集（EVENT 型不淘汰旧分片）
    func testPlaylistAppendIsSuperset() {
        let one = LivePipeline.playlistText(segments: [LiveSegment(name: "seg000.ts", duration: 60)],
                                            target: 60, endlist: false)
        let two = LivePipeline.playlistText(segments: [LiveSegment(name: "seg000.ts", duration: 60),
                                                       LiveSegment(name: "seg001.ts", duration: 59)],
                                            target: 60, endlist: false)
        XCTAssertTrue(two.hasPrefix(one))
    }
}

// MARK: - 端到端冒烟（不依赖网络：预置 words/units/translated 缓存，synth=none）

final class LivePipelineE2ETests: XCTestCase {

    /// 130s 合成视频 → 3 个窗口 → 分片/playlist/ENDLIST/final 成片全链路
    func testLivePipelineEndToEnd() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ytb2zh-live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = JobStore(root: root)
        let jobID = "livetest"
        try FileManager.default.createDirectory(at: store.jobDir(id: jobID), withIntermediateDirectories: true)

        // 1) 合成 130s 测试视频（testsrc2 + 正弦音）
        let source = store.source(jobID)
        try runFFmpeg(["-y", "-v", "error", "-f", "lavfi",
                       "-i", "testsrc2=size=320x240:rate=15:duration=130",
                       "-f", "lavfi", "-i", "sine=frequency=440:duration=130",
                       "-c:v", "libx264", "-preset", "ultrafast", "-c:a", "aac", source.path])
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))

        // 2) 预置产物：words（防触发 whisper）+ units（10 个单元跨 130s，恰好 3 窗）+ translated（跳过翻译）
        let words: [TimedWord] = (0..<10).map {
            TimedWord(start: Double($0) * 13, end: Double($0) * 13 + 10, text: "word\($0)")
        }
        try store.writeJSON(words, to: store.wordsJSON(jobID))
        let units: [SpeechUnit] = (0..<10).map {
            SpeechUnit(start: Double($0) * 13, end: Double($0) * 13 + 12, en: "sentence \($0)", zh: "第\($0)句解说内容")
        }
        try store.writeJSON(units, to: store.unitsJSON(jobID))
        try store.writeJSON(units, to: store.translatedJSON(jobID))

        // 3) Profile：synth=none（不需要网络 TTS），调度用 drift（空时长 → 无落位 → 原声分片）
        var profile = Profile(name: "e2e")
        profile.engines[StepID.synthesize.rawValue] = "none"

        let (stream, continuation) = AsyncStream<LiveEvent>.makeStream(bufferingPolicy: .unbounded)
        let events = Mutex<[LiveEvent]>([])
        let collector = Task {
            for await ev in stream { events.with { $0.append(ev) } }
        }
        try await LivePipeline().run(url: "e2e://local", profile: profile, jobID: jobID,
                                     store: store, events: continuation)
        continuation.finish()
        _ = await collector.value
        let evs = events.wrapped

        // 4) 断言：事件流 + 产物
        XCTAssertTrue(evs.contains { if case .readyToPlay = $0 { return true } else { return false } })
        XCTAssertTrue(evs.contains { if case .finished = $0 { return true } else { return false } })
        XCTAssertFalse(evs.contains { if case .failed = $0 { return true } else { return false } })

        let liveDir = store.jobDir(id: jobID).appendingPathComponent("live", isDirectory: true)
        let playlist = try String(contentsOf: liveDir.appendingPathComponent("live.m3u8"), encoding: .utf8)
        XCTAssertTrue(playlist.contains("#EXT-X-PLAYLIST-TYPE:EVENT"))
        XCTAssertTrue(playlist.contains("#EXT-X-ENDLIST"))
        XCTAssertEqual(playlist.components(separatedBy: "seg").count - 1, 3, "playlist 应含 3 个分片路径")
        for i in 0..<3 {
            let seg = liveDir.appendingPathComponent(String(format: "seg%03d.ts", i))
            XCTAssertTrue(FileManager.default.fileExists(atPath: seg.path), "缺少分片 \(seg.lastPathComponent)")
            let dur = ffprobeDuration(seg) ?? 0
            XCTAssertGreaterThan(dur, 5, "分片 \(i) 时长异常：\(dur)")
        }
        let final = store.finalVideo(jobID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: final.path))
        let finalDur = ffprobeDuration(final) ?? 0
        XCTAssertEqual(finalDur, 130, accuracy: 2.0, "成片时长应接近全片")
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.subtitles(jobID).path))
    }
}
