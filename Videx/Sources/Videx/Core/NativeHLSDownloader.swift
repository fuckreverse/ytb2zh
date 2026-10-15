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

    struct PlannedSegment: Sendable {
        var index: Int
        var segment: Segment
        var fetchInitialization: MediaFragment?
        var nextInitializationIdentity: String?
    }

    public static func download(format initial: MediaFormat, to target: URL, http: HTTPFetching,
                                refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                                durationSeconds: Double? = nil, liveFromStart: Bool = false,
                                concurrency: Int = 4,
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
        let effectiveConcurrency = max(1, concurrency)
        @Sendable func get(_ url: URL, headers baseHeaders: [String: String], range: String? = nil) async throws -> HTTPResponse {
            var headers = baseHeaders
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
                let reqHeaders = format.requestHeaders ?? [:]
                let response = try await get(format.url, headers: reqHeaders)
                let playlist = try parse(response.text,base:response.finalURL ?? format.url)
                var segments=playlist.segments
                if state.lastSequence==nil && !playlist.endList && !liveFromStart { segments=Array(segments.suffix(3)) }

                var batch: [PlannedSegment] = []
                var expectedPrevSeq = state.lastSequence
                var projectedDuration = state.duration
                var runningInitIdentity = state.initializationIdentity
                for segment in segments where state.lastSequence==nil || segment.sequence > state.lastSequence! {
                    if let last=expectedPrevSeq,segment.sequence != last+1 { throw ExtractionError.parse("直播 DVR 分片已丢失，保留文件并停止，避免静默漏帧") }
                    if let limit=durationSeconds,projectedDuration >= limit { break }
                    var fetchInit: MediaFragment?
                    var nextInit = runningInitIdentity
                    if let initialization = segment.initialization {
                        let identity = initialization.url.path + (initialization.byteRange ?? "")
                        if runningInitIdentity != identity {
                            fetchInit = initialization
                            runningInitIdentity = identity
                        }
                        nextInit = runningInitIdentity
                    }
                    batch.append(PlannedSegment(
                        index: batch.count,
                        segment: segment,
                        fetchInitialization: fetchInit,
                        nextInitializationIdentity: nextInit
                    ))
                    expectedPrevSeq = segment.sequence
                    projectedDuration += segment.duration
                }

                for item in batch {
                    if let keyURL = item.segment.key, keys[keyURL] == nil {
                        keys[keyURL] = try await get(keyURL, headers: reqHeaders).body
                    }
                }

                if !batch.isEmpty {
                    let coordinator = HLSBatchCoordinator(
                        batch: batch,
                        headers: reqHeaders,
                        keys: keys,
                        state: state,
                        file: file,
                        stateURL: stateURL,
                        durationSeconds: durationSeconds,
                        get: get
                    )
                    let workers = min(effectiveConcurrency, batch.count)
                    if workers <= 1 {
                        do {
                            while let step = try await coordinator.stepOne() {
                                if let (frac, msg) = step { progress(frac, msg) }
                            }
                            state = await coordinator.currentState()
                        } catch {
                            state = await coordinator.currentState()
                            throw error
                        }
                    } else {
                        do {
                            try await withThrowingTaskGroup(of: (Double, String)?.self) { group in
                                var launched = 0
                                for _ in 0..<workers {
                                    launched += 1
                                    group.addTask { try await coordinator.stepOne() ?? nil }
                                }
                                while let completed = try await group.next() {
                                    if let (frac, msg) = completed {
                                        progress(frac, msg)
                                    }
                                    if launched < batch.count {
                                        launched += 1
                                        group.addTask { try await coordinator.stepOne() ?? nil }
                                    }
                                }
                            }
                            state = await coordinator.currentState()
                        } catch {
                            state = await coordinator.currentState()
                            throw error
                        }
                    }
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

private actor HLSBatchCoordinator {
    let batch: [NativeHLSDownloader.PlannedSegment]
    let headers: [String: String]
    let keys: [URL: Data]
    var state: NativeHLSDownloader.Checkpoint
    let file: FileHandle
    let stateURL: URL
    let durationSeconds: Double?
    let get: @Sendable (URL, [String: String], String?) async throws -> HTTPResponse

    var nextToDispatch = 0
    var nextToCommit = 0
    var buffered: [Int: (NativeHLSDownloader.PlannedSegment, Data)] = [:]

    init(
        batch: [NativeHLSDownloader.PlannedSegment],
        headers: [String: String],
        keys: [URL: Data],
        state: NativeHLSDownloader.Checkpoint,
        file: FileHandle,
        stateURL: URL,
        durationSeconds: Double?,
        get: @escaping @Sendable (URL, [String: String], String?) async throws -> HTTPResponse
    ) {
        self.batch = batch
        self.headers = headers
        self.keys = keys
        self.state = state
        self.file = file
        self.stateURL = stateURL
        self.durationSeconds = durationSeconds
        self.get = get
    }

    func currentState() -> NativeHLSDownloader.Checkpoint { state }

    private func popAndFetch() async throws -> (NativeHLSDownloader.PlannedSegment, Data, Data)? {
        guard nextToDispatch < batch.count else { return nil }
        let item = batch[nextToDispatch]
        nextToDispatch += 1
        var initBytes = Data()
        if let initialization = item.fetchInitialization {
            initBytes = try await get(initialization.url, headers, initialization.byteRange).body
        }
        let mediaBytes = try await get(item.segment.url, headers, item.segment.range).body
        return (item, initBytes, mediaBytes)
    }

    private func commit(item: NativeHLSDownloader.PlannedSegment, bytes: Data) throws -> (Double, String)? {
        buffered[item.index] = (item, bytes)
        var lastUpdate: (Double, String)?
        while let (nextItem, nextBytes) = buffered.removeValue(forKey: nextToCommit) {
            try file.seek(toOffset: state.bytes)
            try file.write(contentsOf: nextBytes)
            state.bytes += UInt64(nextBytes.count)
            state.lastSequence = nextItem.segment.sequence
            state.duration += nextItem.segment.duration
            state.initializationIdentity = nextItem.nextInitializationIdentity
            nextToCommit += 1
            try file.synchronize()
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
            lastUpdate = (
                durationSeconds.map { min(1, state.duration / max(0.001, $0)) } ?? 0,
                "HLS \(state.duration.rounded()) 秒"
            )
        }
        return lastUpdate
    }

    func stepOne() async throws -> (Double, String)?? {
        try Task.checkCancellation()
        guard let (item, initBytes, rawMedia) = try await popAndFetch() else { return nil }
        var media = rawMedia
        if let keyURL = item.segment.key, let keyData = keys[keyURL] {
            var sequenceIV = Data(repeating: 0, count: 16)
            let n = UInt64(max(0, item.segment.sequence))
            for i in 0..<8 { sequenceIV[15 - i] = UInt8((n >> (i * 8)) & 255) }
            media = try NativeHLSDownloader.decrypt(media, key: keyData, iv: item.segment.iv ?? sequenceIV)
        }
        let combined = initBytes + media
        guard !combined.isEmpty else { throw ExtractionError.parse("HLS 分片没有数据") }
        return .some(try commit(item: item, bytes: combined))
    }
}
