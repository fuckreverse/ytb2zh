import XCTest
@testable import Videx

final class BilibiliParseTests: XCTestCase {
    static let playurlFixture = """
    {
      "code": 0, "message": "0",
      "data": {
        "quality": 80,
        "dash": {
          "duration": 300,
          "video": [
            {"id": 116, "baseUrl": "https://upos.example.com/v116.m4s", "backupUrl": ["https://upos2.example.com/v116.m4s"],
             "codecs": "hev01", "mimeType": "video/mp4", "width": 1920, "height": 1080, "frameRate": "59.940",
             "bandwidth": 4500000},
            {"id": 80, "baseUrl": "https://upos.example.com/v80.m4s",
             "codecs": "avc1.640032", "mimeType": "video/mp4", "width": 1920, "height": 1080, "frameRate": "29.970",
             "bandwidth": 2500000}
          ],
          "audio": [
            {"id": 30280, "baseUrl": "https://upos.example.com/a30280.m4s", "codecs": "mp4a.40.2",
             "mimeType": "audio/mp4", "bandwidth": 320000},
            {"id": 30216, "baseUrl": "https://upos.example.com/a30216.m4s", "codecs": "mp4a.40.5",
             "mimeType": "audio/mp4", "bandwidth": 65000}
          ]
        }
      }
    }
    """

    func testParseDashFormats() throws {
        let json = try JSON(data: Data(Self.playurlFixture.utf8))
        let extractor = BilibiliExtractor()
        let formats = try extractor.parseFormats(json["data"])

        XCTAssertEqual(formats.count, 4)
        let videos = formats.filter { $0.kind == .videoOnly }
        XCTAssertEqual(videos.count, 2)
        // 按画质 ID 排序无关，标签应正确映射
        XCTAssertTrue(videos.contains { $0.formatID == "v-116" && $0.qualityLabel == "1080P 60帧" })
        XCTAssertTrue(videos.contains { $0.formatID == "v-80" && $0.qualityLabel == "1080P 高清" })
        XCTAssertEqual(videos.first { $0.formatID == "v-116" }?.backupURLs?.count, 1)

        let audios = formats.filter { $0.kind == .audioOnly }
        XCTAssertTrue(audios.contains { $0.formatID == "a-30280" && $0.qualityLabel == "高清音频" })
    }

    static let viewFixture = """
    {
      "code": 0,
      "data": {
        "bvid": "BV1GJ411x7h7", "aid": 666, "title": "测试视频",
        "desc": "描述", "duration": 600,
        "pic": "//i0.hdslb.com/bfs/archive/abc.jpg",
        "owner": {"mid": 42, "name": "UP主"},
        "stat": {"view": 12345, "coin": 6, "favorite": 7},
        "tname": "科技",
        "pubdate": 1702204800,
        "pages": [{"cid": 111, "part": "P1"}, {"cid": 222, "part": "P2"}]
      }
    }
    """

    func testBuildMediaInfo() throws {
        let json = try JSON(data: Data(Self.viewFixture.utf8))
        let extractor = BilibiliExtractor()
        let info = extractor.buildMediaInfo(
            view: json["data"],
            page: json["data"]["pages"][1],
            pageIndex: 2,
            formats: [],
            subtitles: []
        )
        XCTAssertEqual(info.id, "BV1GJ411x7h7")
        XCTAssertEqual(info.title, "测试视频 - P2 P2")
        XCTAssertEqual(info.uploader, "UP主")
        XCTAssertEqual(info.duration, 600)
        XCTAssertEqual(info.thumbnailURL?.absoluteString, "https://i0.hdslb.com/bfs/archive/abc.jpg")
        XCTAssertEqual(info.uploadDate, "20231210")
        XCTAssertEqual(info.extras["pages"], "2")
    }

    func testURLParsing() {
        XCTAssertEqual(
            BilibiliURL.videoRef(from: URL(string: "https://www.bilibili.com/video/BV1GJ411x7h7?p=2")!),
            BilibiliURL.VideoRef(bvid: "BV1GJ411x7h7", page: 2)
        )
        XCTAssertEqual(
            BilibiliURL.videoRef(from: URL(string: "https://www.bilibili.com/video/av170001")!),
            BilibiliURL.VideoRef(aid: "170001")
        )
        XCTAssertNotNil(BilibiliURL.videoRef(from: URL(string: "https://b23.tv/abc123")!))
        XCTAssertNil(BilibiliURL.videoRef(from: URL(string: "https://example.com/video/BV1xx")!))
        XCTAssertTrue(BilibiliURL.isShortLink(URL(string: "https://b23.tv/abc")!))
    }
}
