import Foundation
import CSystemSupport

/// Downloads HLS segments natively; output is the concatenated transport/fMP4 stream.
/// The App's existing ffmpeg remuxer turns this stream into the requested container.
public enum NativeHLSDownloader {
    struct Segment {
        var url: URL
        var sequence: Int64
        var duration: Double
        var range: String?
        var initialization: MediaFragment?
        var key: URL?
        var iv: Data?
    }
    struct Playlist {
        var segments: [Segment]
        var endList: Bool
        var targetDuration: Double
    }
    struct Checkpoint: Codable {
        var formatID: String
        var videoID: String?
        var bytes: UInt64 = 0
        var lastSequence: Int64?
        var duration: Double = 0
        var initializationIdentity: String?
    }
    static func parse(_ text: String, base: URL) throws -> Playlist {
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.first == "#EXTM3U", !lines.contains(where: { $0.hasPrefix("#EXT-X-STREAM-INF:") }) else {
            throw ExtractionError.parse("HLS 下载需要媒体清单而非 master")
        }
        var sequence: Int64 = 0, duration: Double = 0, targetDuration: Double = 2
        var range: String?, lastRangeEnd = 0, map: MediaFragment?, key: URL?, iv: Data?
        var segments: [Segment] = []
        func url(_ value: String) throws -> URL {
            guard let result = URL(string: value, relativeTo: base)?.absoluteURL, ["http","https"].contains(result.scheme ?? "") else { throw ExtractionError.parse("HLS URI 无效") }
            return result
        }
        func byteRange(_ value: String) throws -> String {
            let fields = value.split(separator: "@")
            guard let first = fields.first, let size = Int(first), size > 0 else { throw ExtractionError.parse("HLS byte range 无效") }
            let start = fields.count > 1 ? Int(fields[1]) : lastRangeEnd
            guard let start, start >= 0, start <= Int.max - size else { throw ExtractionError.parse("HLS byte range 溢出") }
            lastRangeEnd = start + size
            return "\(start)-\(lastRangeEnd-1)"
        }
        for line in lines {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") { sequence = Int64(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0 }
            else if line.hasPrefix("#EXT-X-TARGETDURATION:") { targetDuration = Double(line.dropFirst("#EXT-X-TARGETDURATION:".count)) ?? 2 }
            else if line.hasPrefix("#EXTINF:") { duration = Double(line.dropFirst("#EXTINF:".count).split(separator:",").first ?? "0") ?? 0 }
            else if line.hasPrefix("#EXT-X-BYTERANGE:") { range = try byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count))) }
            else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = HLSParser.attributes(line)
                guard let raw = attrs["URI"] else { throw ExtractionError.parse("HLS 初始化 URI 缺失") }
                let mapRange = try attrs["BYTERANGE"].map(byteRange)
                map = MediaFragment(url: try url(raw), byteRange: mapRange, isInitialization: true)
            } else if line.hasPrefix("#EXT-X-KEY:") {
                let attrs = HLSParser.attributes(line)
                guard attrs["KEYFORMAT"] == nil || attrs["KEYFORMAT"] == "identity" else { throw ExtractionError.notExtractable(site: "hls", reason: "DRM HLS 不可下载") }
                switch attrs["METHOD"] {
                case "NONE": key = nil; iv = nil
                case "AES-128":
                    guard let raw = attrs["URI"] else { throw ExtractionError.parse("HLS AES key URI 缺失") }
                    key = try url(raw); iv = try attrs["IV"].map(hex)
                default: throw ExtractionError.notExtractable(site: "hls", reason: "HLS 加密方式不受支持")
                }
            } else if !line.isEmpty && !line.hasPrefix("#") {
                segments.append(Segment(url: try url(line), sequence: sequence, duration: duration, range: range,
                                        initialization: map, key: key, iv: iv))
                sequence += 1; range = nil
            }
        }
        return Playlist(segments: segments, endList: lines.contains("#EXT-X-ENDLIST"), targetDuration: max(0.1,targetDuration))
    }
    static func hex(_ value: String) throws -> Data {
        let value = value.hasPrefix("0x") ? String(value.dropFirst(2)) : value
        guard value.count <= 32, value.allSatisfy(\.isHexDigit) else { throw ExtractionError.parse("HLS IV 无效") }
        let padded = String(repeating: "0", count:32-value.count)+value
        var data = Data(), index = padded.startIndex
        while index < padded.endIndex {
            let end = padded.index(index, offsetBy:2)
            guard let byte = UInt8(padded[index..<end], radix:16) else { throw ExtractionError.parse("HLS IV 无效") }
            data.append(byte); index = end
        }
        return data
    }
    static func decrypt(_ data: Data, key: Data, iv: Data) throws -> Data {
        guard key.count == 16, iv.count == 16 else { throw ExtractionError.parse("HLS AES key/IV 长度无效") }
        var output = Data(count:data.count+16), length = 0
        let capacity = output.count
        let status = output.withUnsafeMutableBytes { out in
            data.withUnsafeBytes { input in key.withUnsafeBytes { k in iv.withUnsafeBytes { vector in
                CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                        k.baseAddress,16,vector.baseAddress,input.baseAddress,data.count,out.baseAddress,capacity,&length)
            } } }
        }
        guard status == kCCSuccess else { throw ExtractionError.parse("HLS AES 解密失败") }
        return output.prefix(length)
    }

    public static func download(format initial: MediaFormat, to target: URL, http: HTTPFetching,
                                refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                                durationSeconds: Double? = nil, liveFromStart: Bool = false,
                                progress: @Sendable (Double, String?) -> Void = { _,_ in }) async throws -> URL {
        let partial = target.appendingPathExtension("part"), stateURL = target.appendingPathExtension("hls-state.json")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state = Checkpoint(formatID: initial.formatID, videoID: initial.videoID)
        if let data = try? Data(contentsOf: stateURL), let saved = try? JSONDecoder().decode(Checkpoint.self, from: data),
           saved.formatID == initial.formatID, saved.videoID == initial.videoID, fm.fileExists(atPath: partial.path),
           (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0 >= saved.bytes {
            state = saved
        } else { try Data().write(to: partial, options:.atomic) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        try file.truncate(atOffset: state.bytes); try file.seek(toOffset:state.bytes)
        var format = initial, refreshes = 0, idle = 0, keys: [URL:Data] = [:]
        let client = RetryingHTTPClient(base:http)
        func get(_ url: URL, range: String? = nil) async throws -> HTTPResponse {
            var headers = format.requestHeaders ?? [:]
            if let range { headers["Range"] = "bytes=" + range }
            let response = try await client.fetch(.get(url,headers:headers))
            guard response.isOK else { throw ExtractionError.siteError(site:"hls",code:response.status,reason:"HLS 请求失败") }
            if let range {
                let bounds=range.split(separator:"-").compactMap{Int($0)}
                guard response.status==206,bounds.count==2,response.body.count==bounds[1]-bounds[0]+1 else { throw ExtractionError.parse("HLS byte range 响应不符") }
            }
            return response
        }
        while true {
            try Task.checkCancellation()
            let before = state.lastSequence
            do {
                let response = try await get(format.url)
                let playlist = try parse(response.text,base:response.finalURL ?? format.url)
                var segments=playlist.segments
                if state.lastSequence==nil && !playlist.endList && !liveFromStart { segments=Array(segments.suffix(3)) }
                for segment in segments where state.lastSequence==nil || segment.sequence > state.lastSequence! {
                    if let last=state.lastSequence,segment.sequence != last+1 { throw ExtractionError.parse("直播 DVR 分片已丢失，保留文件并停止，避免静默漏帧") }
                    if let limit=durationSeconds,state.duration >= limit { break }
                    var bytes=Data()
                    var nextInitialization = state.initializationIdentity
                    if let initialization=segment.initialization {
                        let identity=initialization.url.path + (initialization.byteRange ?? "")
                        if state.initializationIdentity != identity {
                            bytes += try await get(initialization.url,range:initialization.byteRange).body
                            nextInitialization=identity
                        }
                    }
                    var media=try await get(segment.url,range:segment.range).body
                    if let keyURL=segment.key {
                        if keys[keyURL]==nil { keys[keyURL]=try await get(keyURL).body }
                        var sequenceIV=Data(repeating:0,count:16)
                        let n=UInt64(max(0,segment.sequence))
                        for i in 0..<8 { sequenceIV[15-i]=UInt8((n >> (i*8)) & 255) }
                        media=try decrypt(media,key:keys[keyURL]!,iv:segment.iv ?? sequenceIV)
                    }
                    bytes += media
                    guard !bytes.isEmpty else { throw ExtractionError.parse("HLS 分片没有数据") }
                    try file.write(contentsOf:bytes);state.bytes+=UInt64(bytes.count)
                    state.lastSequence=segment.sequence;state.duration+=segment.duration
                    state.initializationIdentity = nextInitialization
                    try file.synchronize();try JSONEncoder().encode(state).write(to:stateURL,options:.atomic)
                    progress(durationSeconds.map{min(1,state.duration/max(0.001,$0))} ?? 0,"HLS \(state.duration.rounded()) 秒")
                }
                if playlist.endList || durationSeconds.map({state.duration >= $0}) == true { break }
                idle=before==state.lastSequence ? idle+1 : 0
                if idle>120 { throw ExtractionError.network("直播长时间无新分片，已保留续传状态") }
                try await Task.sleep(for:.seconds(min(10,max(0.5,playlist.targetDuration/2))))
                refreshes=0
            } catch let error as ExtractionError {
                if case .siteError(_,let code,_) = error,[403,410].contains(code),let refresh,refreshes<3 {
                    let updated=try await refresh()
                    guard updated.kind==initial.kind,updated.formatID==initial.formatID else { throw ExtractionError.parse("HLS 刷新格式不符") }
                    format=updated;refreshes+=1;continue
                }
                throw error
            }
        }
        guard state.bytes>0 else { throw ExtractionError.network("HLS 没有媒体数据") }
        try file.synchronize();try file.close()
        if fm.fileExists(atPath:target.path){try fm.removeItem(at:target)}
        try fm.moveItem(at:partial,to:target);try? fm.removeItem(at:stateURL)
        progress(1,"HLS 下载完成")
        return target
    }
}
