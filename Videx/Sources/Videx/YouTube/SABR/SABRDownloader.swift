import Foundation

public struct SABRDownloadOptions: Sendable {
    public var startSeconds: Double = 0
    public var durationSeconds: Double?
    public var liveFromStart = false
    public var resume = true
    public var retries = 3
    public init(startSeconds: Double = 0, durationSeconds: Double? = nil, liveFromStart: Bool = false, resume: Bool = true, retries: Int = 3) {
        self.startSeconds = startSeconds; self.durationSeconds = durationSeconds
        self.liveFromStart = liveFromStart; self.resume = resume; self.retries = retries
    }
}

/// Native SABR request/state machine. Only committed complete UMP media segments reach disk.
/// Tokens are supplied by the caller; no automatic attestation/provider is used.
public enum SABRDownloader {
    private struct Track: Codable {
        var id: Data
        var itag: UInt64
        var initialized = false
        var firstSequence: UInt64?
        var lastSequence: UInt64?
        var startMS: UInt64 = 0
        var endMS: UInt64 = 0
        var totalSegments: UInt64?
        var durationMS: UInt64?
    }
    private struct State: Codable {
        var videoID: String
        var itag: Int
        var lastModified: UInt64?
        var bytes: UInt64 = 0
        var tracks: [String: Track] = [:]
        var timeMS: UInt64
    }
    private struct Segment {
        var track: String
        var sequence: UInt64?
        var initialization: Bool
        var startMS: UInt64
        var durationMS: UInt64
        var expectedBytes: UInt64?
        var bytes = Data()
    }

    public static func download(format initialFormat: MediaFormat, to target: URL, http: HTTPFetching,
                                options: SABRDownloadOptions = SABRDownloadOptions(),
                                refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                                progress: @Sendable (Double, String?) -> Void = { _, _ in }) async throws -> URL {
        guard var config = initialFormat.sabr else { throw ExtractionError.parse("缺少 SABR 配置") }
        guard options.startSeconds >= 0, options.startSeconds.isFinite, options.startSeconds * 1000 < Double(UInt64.max), options.durationSeconds.map({ $0 >= 0 && $0.isFinite && (options.startSeconds + $0) * 1000 < Double(UInt64.max) }) ?? true, config.duration.map({ $0 >= 0 && $0.isFinite && $0 * 1000 < Double(UInt64.max) }) ?? true else { throw ExtractionError.parse("SABR 起点无效") }
        let partial = target.appendingPathExtension("part"), checkpoint = target.appendingPathExtension("sabr-state.json")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state = State(videoID: config.videoID, itag: config.itag, lastModified: config.lastModified, timeMS: UInt64(options.startSeconds * 1000))
        if options.resume, fm.fileExists(atPath: partial.path), let data = try? Data(contentsOf: checkpoint),
           let saved = try? JSONDecoder().decode(State.self, from: data), saved.videoID == state.videoID,
           saved.itag == state.itag, saved.lastModified == state.lastModified,
           (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0 >= saved.bytes {
            state = saved
        } else {
            try Data().write(to: partial, options: .atomic)
        }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        try file.truncate(atOffset: state.bytes); try file.seek(toOffset: state.bytes)
        var url = initialFormat.url, requestNumber = 0, failures = 0, stalls = 0
        var playbackCookie: Data?, contexts: [UInt64: Data] = [:], sendContexts = Set<UInt64>()
        var pending: [UInt64: Segment] = [:]
        var waitMS: UInt64 = 0
        var liveHead: UInt64?
        let endMS = options.durationSeconds.map { UInt64((options.startSeconds + max(0, $0)) * 1000) }
        func finished() -> Bool {
            guard let track = state.tracks.values.first(where: { $0.itag == UInt64(config.itag) }) else { return false }
            if let endMS, track.endMS >= endMS { return true }
            if !config.isLive {
                if let duration = track.durationMS ?? config.duration.map({ UInt64($0 * 1000) }), track.endMS >= duration || duration - track.endMS <= 1 { return true }
                if let total = track.totalSegments, total > 0, let last = track.lastSequence, last >= total - 1 { return true }
            }
            return false
        }
        func milliseconds(_ ticks: UInt64, scale: UInt64) throws -> UInt64 {
            guard scale > 0 else { throw ExtractionError.parse("SABR time scale is zero") }
            let value = Double(ticks) * 1000 / Double(scale)
            guard value.isFinite, value < Double(UInt64.max) else { throw ExtractionError.parse("SABR timestamp overflow") }
            return UInt64(value)
        }
        while !finished() {
            try Task.checkCancellation()
            if waitMS > 0 {
                // Cancellable server/ad backoff. No busy loop and no automatic token generation.
                try await Task.sleep(for: .milliseconds(min(waitMS, 300000)))
                waitMS = 0
            }
            requestNumber += 1
            let before = state.bytes
            do {
                guard let ustreamer = SABRConfiguration.decodeBase64(config.ustreamerConfig) else { throw ExtractionError.parse("SABR ustreamer 配置无效") }
                var abr = Protobuf.Writer()
                abr.integer(28, state.timeMS)
                abr.integer(40, initialFormat.kind == .audioOnly ? 1 : 0)
                abr.integer(46, initialFormat.isDRC == true ? 1 : 0)
                if [3,5,28,101].contains(config.clientID) {
                    var capabilities = Protobuf.Writer(); capabilities.integer(5, 0)
                    for codec in 0...10 {
                        var video = Protobuf.Writer(); video.integer(1, UInt64(codec)); video.integer(2, 1); video.integer(15, 1)
                        capabilities.bytes(1, video.data)
                    }
                    abr.bytes(38, capabilities.data)
                }
                var streamer = Protobuf.Writer()
                streamer.bytes(1, config.clientInfo); streamer.bytes(2, config.poToken.flatMap(SABRConfiguration.decodeBase64)); streamer.bytes(3, playbackCookie)
                for type in sendContexts.sorted() {
                    if let value = contexts[type] {
                        var context = Protobuf.Writer(); context.integer(1, type); context.bytes(2, value)
                        streamer.bytes(5, context.data)
                    } else { streamer.integer(6, type) }
                }
                var payload = Protobuf.Writer()
                payload.bytes(1, abr.data); payload.integer(4, state.timeMS); payload.bytes(5, ustreamer)
                payload.bytes(initialFormat.kind == .audioOnly ? 16 : 17, config.formatID)
                payload.bytes(19, streamer.data)
                for track in state.tracks.values {
                    if track.initialized { payload.bytes(2, track.id) }
                    if let first = track.firstSequence, let last = track.lastSequence {
                        var range = Protobuf.Writer(); range.bytes(1, track.id)
                        range.integer(2, track.startMS); range.integer(3, track.endMS - track.startMS)
                        range.integer(4, first); range.integer(5, last)
                        var time = Protobuf.Writer(); time.integer(1, track.startMS); time.integer(2, track.endMS - track.startMS); time.integer(3, 1000)
                        range.bytes(6, time.data); payload.bytes(3, range.data)
                    }
                }
                guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw ExtractionError.parse("SABR URL 无效") }
                components.queryItems = (components.queryItems ?? []).filter { $0.name != "rn" } + [URLQueryItem(name: "rn", value: String(requestNumber))]
                var headers = initialFormat.requestHeaders ?? [:]
                headers.merge(["Content-Type":"application/x-protobuf", "Accept":"application/vnd.yt-ump", "Accept-Encoding":"identity", "User-Agent":config.userAgent]) { _, new in new }
                let response = try await http.fetch(HTTPRequest(method: "POST", url: components.url!, headers: headers, body: payload.data, maximumResponseBytes: 64 * 1024 * 1024))
                if response.status == 403 || response.status == 410 {
                    guard let refresh, failures < options.retries else { throw ExtractionError.network("SABR 地址失效，需要重新提取") }
                    let updated = try await refresh()
                    guard let next = updated.sabr, next.videoID == config.videoID, next.itag == config.itag,
                          next.lastModified == config.lastModified else { throw ExtractionError.notExtractable(site: "youtube", reason: "SABR 流身份变化，不能拼接旧媒体") }
                    url = updated.url; config = next; failures += 1; continue
                }
                guard response.isOK else { throw ExtractionError.network("SABR HTTP \(response.status)") }
                let parts = try UMP.decode(response.body)
                pending.removeAll()
                for part in parts {
                    if part.type == 21 {
                        var reader = WireReader(part.data); let header = try reader.umpInteger()
                        guard var segment = pending[header] else { continue }
                        let bytes = try reader.read(reader.remaining)
                        guard segment.bytes.count + bytes.count <= 64 * 1024 * 1024 else { throw ExtractionError.parse("SABR 分片过大") }
                        segment.bytes.append(bytes); pending[header] = segment
                        continue
                    }
                    if part.type == 22 {
                        var reader = WireReader(part.data); let header = try reader.umpInteger()
                        guard let segment = pending.removeValue(forKey: header), var track = state.tracks[segment.track] else { continue }
                        if let expected = segment.expectedBytes, expected != UInt64(segment.bytes.count) { throw ExtractionError.parse("SABR 分片长度不符") }
                        let duplicate = segment.initialization ? track.initialized : (segment.sequence.map { $0 <= (track.lastSequence ?? 0) && track.lastSequence != nil } ?? true)
                        if !duplicate {
                            if let last = track.lastSequence, let sequence = segment.sequence, !segment.initialization, (last == UInt64.max || sequence != last + 1) {
                                throw ExtractionError.parse("SABR 分片序号不连续")
                            }
                            if track.itag == UInt64(config.itag) {
                                try file.write(contentsOf: segment.bytes); state.bytes += UInt64(segment.bytes.count)
                            }
                            if segment.initialization { track.initialized = true }
                            else {
                                track.firstSequence = track.firstSequence ?? segment.sequence
                                track.lastSequence = segment.sequence
                                if track.firstSequence == segment.sequence { track.startMS = segment.startMS }
                                let (segmentEnd, overflow) = segment.startMS.addingReportingOverflow(segment.durationMS)
                                guard !overflow else { throw ExtractionError.parse("SABR segment time overflow") }
                                track.endMS = max(track.endMS, segmentEnd)
                            }
                            state.tracks[segment.track] = track
                            if track.itag == UInt64(config.itag) { state.timeMS = max(state.timeMS, track.endMS) }
                            try file.synchronize()
                            try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
                        }
                        continue
                    }
                    // Control frames use protobuf; unknown frame types are safely ignored.
                    guard [20,31,35,42,43,44,45,46,57,58,59].contains(part.type) else { continue }
                    let message = try Protobuf.Message(part.data)
                    switch part.type {
                    case 42:
                        guard let id = message.bytes(2), let format = try message.message(2), let itag = format.integer(1) else { throw ExtractionError.parse("SABR 格式初始化缺少 ID") }
                        if let video = message.string(1), video != config.videoID { throw ExtractionError.parse("SABR 响应视频 ID 不符") }
                        let key = id.base64EncodedString()
                        if state.tracks[key] == nil {
                            if itag == UInt64(config.itag), state.tracks.values.contains(where: { $0.itag == itag }) { throw ExtractionError.parse("SABR 服务器切换格式") }
                            var track = Track(id: id, itag: itag)
                            track.totalSegments = message.integer(4)
                            if let ticks = message.integer(9), let scale = message.integer(10), scale > 0 { track.durationMS = try milliseconds(ticks, scale: scale) }
                            state.tracks[key] = track
                        }
                    case 20:
                        guard let header = message.integer(1), let id = message.bytes(13) else { throw ExtractionError.parse("SABR 媒体头缺失") }
                        if let video = message.string(2), video != config.videoID { throw ExtractionError.parse("SABR 媒体视频 ID 不符") }
                        if (message.integer(7) ?? 0) != 0 { throw ExtractionError.parse("SABR 压缩媒体尚不可读取") }
                        let key = id.base64EncodedString()
                        guard state.tracks[key] != nil else { throw ExtractionError.parse("SABR 媒体尚未初始化") }
                        let time = try message.message(15), scale = max(1, time?.integer(3) ?? 1000)
                        pending[header] = Segment(track: key, sequence: message.integer(9), initialization: message.integer(8) == 1,
                            startMS: try message.integer(11) ?? milliseconds(time?.integer(1) ?? 0, scale: scale),
                            durationMS: try message.integer(12) ?? milliseconds(time?.integer(2) ?? 0, scale: scale), expectedBytes: message.integer(14))
                    case 35: playbackCookie = message.bytes(7); waitMS = max(waitMS, message.integer(4) ?? 0)
                    case 43:
                        if let raw = message.string(1), let redirect = URL(string: raw), redirect.scheme == "https",
                           redirect.host?.hasSuffix(".googlevideo.com") == true { url = redirect }
                        else { throw ExtractionError.parse("SABR 重定向不是受信媒体地址") }
                    case 44: throw ExtractionError.siteError(site: "youtube", code: Int((try message.message(3))?.integer(1) ?? 0), reason: message.string(1) ?? "SABR 服务错误")
                    case 58:
                        if let status = message.integer(1), status != 1 { throw ExtractionError.loginRequired(site: "youtube", reason: "SABR 要求有效的外部 PO Token（本次不启用自动 Token provider）") }
                    case 57:
                        if let type = message.integer(1), let value = message.bytes(3) {
                            if message.integer(5) != 2 || contexts[type] == nil { contexts[type] = value }
                            if message.integer(4) == 1 { sendContexts.insert(type) }
                        }
                    case 59:
                        sendContexts.formUnion(try message.integers(1))
                        sendContexts.subtract(try message.integers(2))
                        for type in try message.integers(3) { contexts.removeValue(forKey: type); sendContexts.remove(type) }
                    case 31:
                        liveHead = message.integer(4)
                        if state.bytes == 0, !options.liveFromStart, options.startSeconds == 0, let liveHead { state.timeMS = liveHead }
                    case 45:
                        let seek = message.integer(1) ?? 0, scale = max(1, message.integer(2) ?? 1000)
                        state.timeMS = try milliseconds(seek, scale: scale)
                    case 46:
                        guard let refresh else { throw ExtractionError.network("SABR 要求刷新播放器响应") }
                        let updated = try await refresh()
                        guard let next = updated.sabr, next.videoID == config.videoID, next.itag == config.itag else { throw ExtractionError.parse("SABR 刷新格式不符") }
                        config = next; url = updated.url
                    default: break
                    }
                }
                if !pending.isEmpty { throw ExtractionError.parse("SABR 响应结束但分片不完整") }
                failures = 0
                stalls = state.bytes == before ? stalls + 1 : 0
                if stalls > (config.isLive ? 120 : 8) { throw ExtractionError.network("SABR 无媒体进展，已保留可续传状态") }
                if stalls > 0 { waitMS = max(waitMS, 1000) }
                if config.isLive, stalls > 5, let refresh {
                    let updated = try await refresh()
                    if let next = updated.sabr { config = next; url = updated.url }
                }
                let total = endMS ?? config.duration.map { UInt64($0 * 1000) }
                progress(total.map { min(1, Double(state.timeMS) / max(1, Double($0))) } ?? 0, "SABR \(state.bytes) 字节")
            } catch let error as ExtractionError {
                switch error {
                case .loginRequired, .notExtractable, .siteError: throw error
                default:
                    failures += 1
                    guard failures <= options.retries else { throw error }
                    waitMS = UInt64(min(30000, 500 * (1 << min(failures, 6))))
                }
            }
        }
        guard state.bytes > 0 else { throw ExtractionError.notExtractable(site: "youtube", reason: "SABR 没有媒体数据") }
        try file.synchronize(); try file.close()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: partial, to: target)
        try? fm.removeItem(at: checkpoint)
        progress(1, "SABR 下载完成")
        return target
    }
}
