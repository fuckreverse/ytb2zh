import XCTest
@testable import Ytb2ZHEngines

final class VideoCatalogServiceTests: XCTestCase {

    func testParseEntryFull() {
        let e: [String: Any] = [
            "id": "dQw4w9WgXcQ",
            "title": "Rick Astley - Never Gonna Give You Up",
            "url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ",
            "duration": 212,
            "channel": "Rick Astley",
            "thumbnail": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        ]
        let v = VideoCatalogService.parseEntry(e)
        XCTAssertNotNil(v)
        XCTAssertEqual(v?.id, "dQw4w9WgXcQ")
        XCTAssertEqual(v?.duration, 212)
        XCTAssertEqual(v?.channel, "Rick Astley")
        XCTAssertEqual(v?.thumbnail, "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }

    /// 只有 id（11 位视频号）时自动补 watch URL
    func testParseEntryMinimalBuildsWatchURL() {
        let e: [String: Any] = ["id": "abcdefghijk", "title": "T"]
        let v = VideoCatalogService.parseEntry(e)
        XCTAssertEqual(v?.url, "https://www.youtube.com/watch?v=abcdefghijk")
        XCTAssertEqual(v?.duration, 0)
    }

    /// duration_string "1:23:45" / "12:34" 解析
    func testParseEntryDurationString() {
        let a = VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t", "duration_string": "1:23:45"])
        XCTAssertEqual(a?.duration, 3600 + 23 * 60 + 45)
        let b = VideoCatalogService.parseEntry(["id": "zyxwvutsrqp", "title": "t2", "duration_string": "12:34"])
        XCTAssertEqual(b?.duration, 12 * 60 + 34)
    }

    /// thumbnails 数组兜底取末位（通常分辨率最高）
    func testParseEntryThumbnailsFallback() {
        let e: [String: Any] = [
            "id": "qwertyuiopa", "title": "t",
            "thumbnails": [["url": "low.jpg"], ["url": "high.jpg"]],
        ]
        XCTAssertEqual(VideoCatalogService.parseEntry(e)?.thumbnail, "high.jpg")
    }

    /// 无 id 无 url 的条目（如频道聚合层）丢弃
    func testParseEntryDropsEmpty() {
        XCTAssertNil(VideoCatalogService.parseEntry(["title": "channel aggregate"]))
    }
}

// MARK: YouTube ID / 缩略图提取

extension VideoCatalogServiceTests {
    func testYouTubeIDExtraction() {
        XCTAssertEqual(CatalogVideo.youTubeID("https://www.youtube.com/watch?v=dQw4w9WgXcQ&t=30"), "dQw4w9WgXcQ")
        XCTAssertEqual(CatalogVideo.youTubeID("https://youtu.be/dQw4w9WgXcQ"), "dQw4w9WgXcQ")
        XCTAssertEqual(CatalogVideo.youTubeID("https://www.youtube.com/shorts/abcdefghijk"), "abcdefghijk")
        XCTAssertEqual(CatalogVideo.youTubeID("https://www.youtube.com/embed/abcdefghijk"), "abcdefghijk")
        XCTAssertNil(CatalogVideo.youTubeID("https://www.youtube.com/@somechannel/videos"))
        XCTAssertNil(CatalogVideo.youTubeID("https://vimeo.com/12345"))
        XCTAssertEqual(CatalogVideo.youTubeThumbnail("https://youtu.be/dQw4w9WgXcQ"),
                       "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg")
    }
}

// MARK: 列表链接判定 / 参数构造 / 数值解析

extension VideoCatalogServiceTests {
    func testIsLikelyListURL() {
        XCTAssertTrue(VideoCatalogService.isLikelyListURL("https://www.youtube.com/playlist?list=PL123"))
        XCTAssertTrue(VideoCatalogService.isLikelyListURL("https://www.youtube.com/@somechannel/videos"))
        XCTAssertTrue(VideoCatalogService.isLikelyListURL("https://www.youtube.com/channel/UCxxxx/videos"))
        XCTAssertTrue(VideoCatalogService.isLikelyListURL("https://www.youtube.com/watch?list=PL123"))
        // watch + list 混合：按单视频处理（下载带 --no-playlist）
        XCTAssertFalse(VideoCatalogService.isLikelyListURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=PL123"))
        XCTAssertFalse(VideoCatalogService.isLikelyListURL("https://www.youtube.com/watch?v=dQw4w9WgXcQ"))
        XCTAssertFalse(VideoCatalogService.isLikelyListURL("https://youtu.be/dQw4w9WgXcQ"))
        XCTAssertFalse(VideoCatalogService.isLikelyListURL("swift ui 教程"))
        XCTAssertFalse(VideoCatalogService.isLikelyListURL(""))
    }

    func testListArgsKeywordAndOffset() {
        let kw = VideoCatalogService.listArgs(query: "swift 教程", limit: 24, offset: 0, proxy: "")
        XCTAssertTrue(kw.last == "ytsearch24:swift 教程")
        XCTAssertFalse(kw.contains("--playlist-start"))

        let off = VideoCatalogService.listArgs(query: "https://youtube.com/playlist?list=PL1",
                                               limit: 24, offset: 24, proxy: "http://127.0.0.1:7890")
        XCTAssertEqual(off[off.firstIndex(of: "--playlist-start")! + 1], "25")
        XCTAssertTrue(off.contains("http://127.0.0.1:7890"))
        XCTAssertEqual(off.last, "https://youtube.com/playlist?list=PL1")

        // offset=0 不带 playlist-start
        let first = VideoCatalogService.listArgs(query: "https://youtube.com/playlist?list=PL1",
                                                 limit: 24, offset: 0, proxy: "")
        XCTAssertFalse(first.contains("--playlist-start"))
    }

    func testParseEntryViewCountAndThumbFallback() {
        XCTAssertEqual(VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t", "view_count": 12345])?.viewCount, 12345)
        XCTAssertEqual(VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t", "view_count": 12.0])?.viewCount, 12)
        XCTAssertEqual(VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t", "view_count": "972"])?.viewCount, 972)
        XCTAssertNil(VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t"])?.viewCount)
        // 无 thumbnail 字段时兜底 hqdefault
        XCTAssertEqual(VideoCatalogService.parseEntry(["id": "abcdefghijk", "title": "t"])?.thumbnail,
                       "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
    }
}

// MARK: - VideoInfoService（单视频完整元数据）

final class VideoInfoServiceTests: XCTestCase {

    func testInfoArgs() {
        let a = VideoInfoService.infoArgs(url: "https://youtu.be/abcdefghijk", proxy: "http://127.0.0.1:7890")
        XCTAssertEqual(a, ["-J", "--no-warnings", "--skip-download", "--no-playlist",
                           "--proxy", "http://127.0.0.1:7890", "https://youtu.be/abcdefghijk"])
        let b = VideoInfoService.infoArgs(url: "https://youtu.be/abcdefghijk", proxy: "")
        XCTAssertFalse(b.contains("--proxy"))
    }

    /// 完整字段解析：简介/频道/频道链接/上传日期/播放量/点赞/标签
    func testParseFull() {
        let e: [String: Any] = [
            "title": "Never Gonna Give You Up",
            "description": "The classic 1987 hit.\nLine two.",
            "channel": "Rick Astley",
            "channel_url": "https://www.youtube.com/@RickAstleyYT",
            "upload_date": "20091025",
            "duration": 212,
            "view_count": 1_500_000_000,
            "like_count": 17_000_000,
            "tags": ["rick astley", "80s"],
            "thumbnail": "https://i.ytimg.com/vi/dQw4w9WgXcQ/hqdefault.jpg",
        ]
        let d = VideoInfoService.parse(e, url: "https://www.youtube.com/watch?v=dQw4w9WgXcQ")
        XCTAssertNotNil(d)
        XCTAssertEqual(d?.title, "Never Gonna Give You Up")
        XCTAssertEqual(d?.videoDescription, "The classic 1987 hit.\nLine two.")
        XCTAssertEqual(d?.channel, "Rick Astley")
        XCTAssertEqual(d?.channelURL, "https://www.youtube.com/@RickAstleyYT")
        XCTAssertEqual(d?.uploadDateText, "2009-10-25")
        XCTAssertEqual(d?.duration, 212)
        XCTAssertEqual(d?.viewCount, 1_500_000_000)
        XCTAssertEqual(d?.likeCount, 17_000_000)
        XCTAssertEqual(d?.tags, ["rick astley", "80s"])
    }

    /// 宽容解析：uploader 兜底 channel、duration 字符串、缺 tags/thumbnail
    func testParseTolerant() {
        let e: [String: Any] = [
            "title": "T", "uploader": "Some Channel",
            "duration": "972",
        ]
        let d = VideoInfoService.parse(e, url: "https://youtu.be/abcdefghijk")
        XCTAssertEqual(d?.channel, "Some Channel")
        XCTAssertEqual(d?.duration, 972)
        XCTAssertEqual(d?.thumbnail, "https://i.ytimg.com/vi/abcdefghijk/hqdefault.jpg")
        XCTAssertEqual(d?.tags, [])
        XCTAssertNil(d?.uploadDateText)
    }

    /// 无标题 → 拒绝
    func testParseRejectsNoTitle() {
        XCTAssertNil(VideoInfoService.parse(["duration": 10], url: "https://youtu.be/abcdefghijk"))
        XCTAssertNil(VideoInfoService.parse(["title": ""], url: "https://youtu.be/abcdefghijk"))
    }

    /// VideoDetails Codable 往返 + 非法上传日期
    func testDetailsCodableRoundtrip() throws {
        let d = VideoDetails(url: "u", title: "t", videoDescription: "d", channel: "c",
                             uploadDate: "20260927", duration: 30, viewCount: 5, likeCount: 1,
                             tags: ["a"], thumbnail: "th")
        let data = try JSONEncoder().encode(d)
        let back = try JSONDecoder().decode(VideoDetails.self, from: data)
        XCTAssertEqual(back, d)
        XCTAssertNil(VideoDetails(url: "u", title: "t", uploadDate: "bad").uploadDateText)
    }
}
