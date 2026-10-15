import Foundation

/// Adapts MPD sliding windows to the native, checkpointed HLS segment consumer.
/// No external DASH downloader or runtime is used.
enum NativeDASHLiveDownloader {
    actor Adapter: HTTPFetching {
        let base: HTTPFetching
        var manifest: URL
        let representationID: String
        init(base: HTTPFetching, manifest: URL, representationID: String) {
            self.base = base; self.manifest = manifest; self.representationID = representationID
        }
        func updateManifest(_ url: URL) { manifest = url }
        func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
            let response = try await base.fetch(request)
            guard request.url == manifest, response.isOK else { return response }
            let formats = try DASHParser.formats(response.body, url: response.finalURL ?? manifest)
            guard let format = formats.first(where: { $0.representationID == representationID }), let fragments = format.fragments else {
                throw ExtractionError.parse("直播 MPD 中原表示流已消失")
            }
            var lines = ["#EXTM3U", "#EXT-X-TARGETDURATION:6"]
            if let first = fragments.first(where: { !$0.isInitialization })?.sequence { lines.append("#EXT-X-MEDIA-SEQUENCE:\(first)") }
            for fragment in fragments {
                if fragment.isInitialization {
                    var line = "#EXT-X-MAP:URI=\"\(fragment.url.absoluteString)\""
                    if let range = fragment.byteRange {
                        let bounds = range.split(separator: "-").compactMap { Int($0) }
                        if bounds.count == 2 { line += ",BYTERANGE=\"\(bounds[1]-bounds[0]+1)@\(bounds[0])\"" }
                    }
                    lines.append(line)
                } else {
                    if let range = fragment.byteRange {
                        let bounds = range.split(separator: "-").compactMap { Int($0) }
                        if bounds.count == 2 { lines.append("#EXT-X-BYTERANGE:\(bounds[1]-bounds[0]+1)@\(bounds[0])") }
                    }
                    lines += ["#EXTINF:\(fragment.duration ?? 6),", fragment.url.absoluteString]
                }
            }
            if format.isLive != true { lines.append("#EXT-X-ENDLIST") }
            return HTTPResponse(status: response.status, headers: response.headers, body: Data(lines.joined(separator: "\n").utf8), finalURL: manifest)
        }
    }
    static func download(format: MediaFormat, to target: URL, http: HTTPFetching,
                         duration: Double?, liveFromStart: Bool, refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                         progress: @Sendable(Double,String?)->Void) async throws -> URL {
        guard let manifest = format.manifestURL, let representationID = format.representationID else { throw ExtractionError.parse("直播 DASH 配置缺失") }
        let adapter = Adapter(base: http, manifest: manifest, representationID: representationID)
        var initial = format; initial.url = manifest
        let reload: (@Sendable () async throws -> MediaFormat)?
        if let refresh {
            reload = { @Sendable in
                var updated = try await refresh()
                guard updated.representationID == representationID, let manifest = updated.manifestURL else {
                    throw ExtractionError.parse("DASH refresh representation mismatch")
                }
                updated.url = manifest
                await adapter.updateManifest(manifest)
                return updated
            }
        } else { reload = nil }
        return try await NativeHLSDownloader.download(format: initial, to: target,
            http: adapter, refresh: reload, durationSeconds: duration,
            liveFromStart: liveFromStart, progress: progress)
    }
}
