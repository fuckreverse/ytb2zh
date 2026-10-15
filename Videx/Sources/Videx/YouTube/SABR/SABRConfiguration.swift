import Foundation

public struct SABRConfiguration: Codable, Sendable, Equatable {
    public var videoID: String
    public var itag: Int
    public var lastModified: UInt64?
    public var xtags: String?
    public var ustreamerConfig: String
    public var clientID: Int
    public var clientVersion: String
    public var userAgent: String
    public var visitorData: String?
    public var poToken: String?
    public var duration: Double?
    public var isLive: Bool
    public init(videoID: String, itag: Int, lastModified: UInt64? = nil, xtags: String? = nil,
                ustreamerConfig: String, clientID: Int, clientVersion: String, userAgent: String,
                visitorData: String? = nil, poToken: String? = nil, duration: Double? = nil, isLive: Bool = false) {
        self.videoID = videoID; self.itag = itag; self.lastModified = lastModified; self.xtags = xtags
        self.ustreamerConfig = ustreamerConfig; self.clientID = clientID; self.clientVersion = clientVersion
        self.userAgent = userAgent; self.visitorData = visitorData; self.poToken = poToken
        self.duration = duration; self.isLive = isLive
    }
    static func decodeBase64(_ value: String) -> Data? {
        var value = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        while value.count % 4 != 0 { value += "=" }
        return Data(base64Encoded: value)
    }
    var formatID: Data {
        var writer = Protobuf.Writer()
        writer.integer(1, UInt64(itag)); writer.integer(2, lastModified); writer.string(3, xtags)
        return writer.data
    }
    var clientInfo: Data {
        var writer = Protobuf.Writer()
        writer.string(1, "en"); writer.string(2, "US"); writer.string(14, visitorData)
        writer.string(15, userAgent); writer.integer(16, UInt64(clientID)); writer.string(17, clientVersion)
        return writer.data
    }
}
