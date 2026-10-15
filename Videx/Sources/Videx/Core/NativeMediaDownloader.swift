import Foundation

/// Range/fragment downloader with durable checkpoints and explicit refresh on expired URLs.
public enum NativeMediaDownloader {
    struct State: Codable {
        var formatID: String
        var representationID: String?
        var videoID: String?
        var nextFragment = 0
        var bytes: UInt64 = 0
        var etag: String?
        var lastModified: String?
        var expectedBytes: UInt64?
    }
    public static func download(format initial: MediaFormat, to target: URL, http: HTTPFetching,
                                refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                                partialSeconds: Double? = nil, liveFromStart: Bool = false,
                                progress: @Sendable (Double, String?) -> Void = { _, _ in }) async throws -> URL {
        if initial.protocolType == .sabr {
            return try await SABRDownloader.download(format: initial, to: target, http: http,
                options: SABRDownloadOptions(durationSeconds: partialSeconds), refresh: refresh, progress: progress)
        }
        if initial.protocolType == .dash && initial.isLive == true {
            return try await NativeDASHLiveDownloader.download(format: initial, to: target, http: http,
                duration: partialSeconds, liveFromStart: liveFromStart, refresh: refresh, progress: progress)
        }
        guard initial.protocolType != .hls else {
            return try await NativeHLSDownloader.download(format: initial, to: target, http: http, refresh: refresh, durationSeconds: partialSeconds, progress: progress)
        }
        let partial = target.appendingPathExtension("part"), checkpoint = target.appendingPathExtension("state.json")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state = State(formatID: initial.formatID, representationID: initial.representationID, videoID: initial.videoID)
        if fm.fileExists(atPath: partial.path), let data = try? Data(contentsOf: checkpoint),
           let old = try? JSONDecoder().decode(State.self, from: data), old.formatID == initial.formatID,
           old.representationID == initial.representationID, old.videoID == initial.videoID,
           (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value ?? 0 >= old.bytes {
            state = old
        } else { try Data().write(to: partial, options: .atomic) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        try file.truncate(atOffset: state.bytes); try file.seek(toOffset: state.bytes)
        var format = initial, refreshes = 0
        let client = RetryingHTTPClient(base: http)
        func save(_ data: Data) throws {
            try file.write(contentsOf: data); state.bytes += UInt64(data.count)
            try file.synchronize(); try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
        }
        if let fragments = format.fragments, !fragments.isEmpty {
            var elapsed = fragments.prefix(state.nextFragment).compactMap(\.duration).reduce(0,+)
            while state.nextFragment < (format.fragments?.count ?? 0) {
                try Task.checkCancellation()
                let fragment = format.fragments![state.nextFragment]
                if let seconds = partialSeconds, elapsed >= seconds, !fragment.isInitialization { break }
                var headers = format.requestHeaders ?? [:]
                if let range = fragment.byteRange { headers["Range"] = "bytes=" + range }
                let response = try await client.fetch(.get(fragment.url, headers: headers))
                if [403,410].contains(response.status), let refresh, refreshes < 3 {
                    let updated = try await refresh()
                    guard updated.formatID == format.formatID, updated.representationID == format.representationID,
                          updated.fragments?.count == format.fragments?.count else { throw ExtractionError.parse("刷新后的 DASH 分片身份不一致") }
                    format = updated; refreshes += 1; continue
                }
                guard response.isOK, !response.body.isEmpty else { throw ExtractionError.network("DASH 分片 HTTP \(response.status)") }
                if let range = fragment.byteRange {
                    let offsets = range.split(separator:"-").compactMap { Int($0) }
                    guard response.status == 206, offsets.count == 2, response.body.count == offsets[1] - offsets[0] + 1 else { throw ExtractionError.parse("DASH 字节范围响应不符") }
                }
                state.nextFragment += 1
                try save(response.body)
                elapsed += fragment.duration ?? 0
                progress(Double(state.nextFragment) / Double(max(1, fragments.count)), "下载 DASH 分片")
            }
        } else {
            var complete = false
            while !complete {
                try Task.checkCancellation()
                var headers = format.requestHeaders ?? [:]
                let start = state.bytes, end = start + 1024 * 1024 - 1
                headers["Range"] = "bytes=\(start)-\(end)"
                if let validator = state.etag ?? state.lastModified { headers["If-Range"] = validator }
                let candidates = [format.url] + (format.backupURLs ?? [])
                var selected: HTTPResponse?
                for url in candidates {
                    var request = HTTPRequest.get(url, headers: headers)
                    request.maximumResponseBytes = 1024 * 1024 + 1
                    let response = try await client.fetch(request)
                    if response.isOK || response.status == 416 { selected = response; break }
                    if ![403,404,410,429,500,502,503,504].contains(response.status) { throw ExtractionError.network("媒体 HTTP \(response.status)") }
                }
                guard let response = selected else {
                    if let refresh, refreshes < 3 {
                        let updated = try await refresh()
                        guard updated.formatID == format.formatID, updated.kind == format.kind else { throw ExtractionError.parse("刷新后的媒体格式不一致") }
                        format = updated; refreshes += 1; continue
                    }
                    throw ExtractionError.network("媒体地址均不可用，已保留续传文件")
                }
                func header(_ name: String) -> String? { response.headers.first { $0.key.lowercased() == name }?.value }
                if response.status == 416 {
                    let total = header("content-range")?.split(separator: "/").last.flatMap { UInt64($0) }
                    guard total == state.bytes else { throw ExtractionError.parse("媒体 Range 越界且长度不符") }
                    complete = true; continue
                }
                if response.status == 200 {
                    // Server ignored Range or validator changed: restart instead of appending a second copy.
                    try file.truncate(atOffset: 0); try file.seek(toOffset: 0); state.bytes = 0
                    state.etag = header("etag"); state.lastModified = header("last-modified")
                    try save(response.body); complete = true
                } else {
                    guard let contentRange = header("content-range"),
                          let match = RegexKit.firstMatch(pattern: #"^bytes (\d+)-(\d+)/(\d+|\*)$"#, in: contentRange),
                          UInt64(match[1]) == start, let last = UInt64(match[2]), last >= start,
                          last - start + 1 == UInt64(response.body.count), !response.body.isEmpty else {
                        throw ExtractionError.parse("媒体 Range 响应不符，拒绝拼接损坏文件")
                    }
                    if start > 0, let old = state.etag, let new = header("etag"), old != new { throw ExtractionError.parse("媒体 ETag 已改变，拒绝拼接") }
                    if let old = state.expectedBytes, let new = UInt64(match[3]), old != new { throw ExtractionError.parse("媒体总长度已改变，拒绝拼接") }
                    state.expectedBytes = UInt64(match[3]) ?? state.expectedBytes
                    state.etag = header("etag") ?? state.etag; state.lastModified = header("last-modified") ?? state.lastModified
                    try save(response.body)
                    complete = state.expectedBytes.map { state.bytes >= $0 } ?? false
                }
                progress(state.expectedBytes.map { min(1, Double(state.bytes) / max(1,Double($0))) } ?? 0, "下载 \(state.bytes) 字节")
            }
        }
        guard state.bytes > 0 else { throw ExtractionError.network("媒体没有可写入的数据") }
        try file.synchronize(); try file.close()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: partial, to: target); try? fm.removeItem(at: checkpoint)
        progress(1, "下载完成")
        return target
    }
}
