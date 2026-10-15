import Foundation

/// Range/fragment downloader with multi-concurrent workers, durable checkpoints, and explicit refresh on expired URLs.
public enum NativeMediaDownloader {
    struct ByteChunk: Codable, Equatable, Sendable {
        var start: UInt64
        var end: UInt64
    }

    struct State: Codable, Sendable {
        var formatID: String
        var representationID: String?
        var videoID: String?
        var nextFragment = 0
        var bytes: UInt64 = 0
        var etag: String?
        var lastModified: String?
        var expectedBytes: UInt64?
        var completedChunks: [ByteChunk] = []

        init(formatID: String, representationID: String? = nil, videoID: String? = nil) {
            self.formatID = formatID
            self.representationID = representationID
            self.videoID = videoID
        }

        enum CodingKeys: String, CodingKey {
            case formatID, representationID, videoID, nextFragment, bytes, etag, lastModified, expectedBytes, completedChunks
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatID = try c.decode(String.self, forKey: .formatID)
            representationID = try c.decodeIfPresent(String.self, forKey: .representationID)
            videoID = try c.decodeIfPresent(String.self, forKey: .videoID)
            nextFragment = try c.decodeIfPresent(Int.self, forKey: .nextFragment) ?? 0
            bytes = try c.decodeIfPresent(UInt64.self, forKey: .bytes) ?? 0
            etag = try c.decodeIfPresent(String.self, forKey: .etag)
            lastModified = try c.decodeIfPresent(String.self, forKey: .lastModified)
            expectedBytes = try c.decodeIfPresent(UInt64.self, forKey: .expectedBytes)
            completedChunks = try c.decodeIfPresent([ByteChunk].self, forKey: .completedChunks) ?? []
        }

        mutating func recordChunk(start: UInt64, end: UInt64) {
            guard end >= start else { return }
            completedChunks.append(ByteChunk(start: start, end: end))
            normalizeChunks()
        }

        mutating func normalizeChunks() {
            completedChunks.sort { $0.start < $1.start }
            var merged: [ByteChunk] = []
            for chunk in completedChunks {
                if chunk.end < bytes { continue }
                let clippedStart = max(chunk.start, bytes)
                if let last = merged.last, clippedStart <= last.end + 1 {
                    merged[merged.count - 1].end = max(last.end, chunk.end)
                } else {
                    merged.append(ByteChunk(start: clippedStart, end: chunk.end))
                }
            }
            while let first = merged.first, first.start <= bytes {
                bytes = max(bytes, first.end + 1)
                merged.removeFirst()
            }
            completedChunks = merged
        }

        var totalDownloadedBytes: UInt64 {
            bytes + completedChunks.reduce(0) { $0 + ($1.end - $1.start + 1) }
        }

        func pendingChunks(total: UInt64, chunkSize: UInt64) -> [ByteChunk] {
            guard bytes < total else { return [] }
            let step = max(1, chunkSize)
            var gaps: [(UInt64, UInt64)] = []
            var cursor = bytes
            for chunk in completedChunks {
                if chunk.start > cursor {
                    gaps.append((cursor, min(total - 1, chunk.start - 1)))
                }
                if chunk.end + 1 > cursor {
                    cursor = chunk.end + 1
                }
                if cursor >= total { break }
            }
            if cursor < total {
                gaps.append((cursor, total - 1))
            }
            var result: [ByteChunk] = []
            for (gapStart, gapEnd) in gaps {
                var s = gapStart
                while s <= gapEnd {
                    let e = min(gapEnd, s + step - 1)
                    result.append(ByteChunk(start: s, end: e))
                    if e == UInt64.max { break }
                    s = e + 1
                }
            }
            return result
        }
    }

    /// 通用文件下载入口（供模型权重、工具二进制等直接复用同一套多并发 + 断点续传底层）。
    public static func downloadFile(
        url: URL,
        to target: URL,
        http: HTTPFetching,
        headers: [String: String] = [:],
        backupURLs: [URL]? = nil,
        concurrency: Int = 4,
        chunkSize: UInt64 = 1024 * 1024,
        progress: @Sendable (Double, String?) -> Void = { _, _ in }
    ) async throws -> URL {
        let formatID = url.lastPathComponent.isEmpty ? "file" : url.lastPathComponent
        let format = MediaFormat(
            formatID: formatID,
            kind: .muxed,
            url: url,
            protocolType: .https,
            backupURLs: backupURLs,
            requestHeaders: headers.isEmpty ? nil : headers
        )
        return try await download(
            format: format,
            to: target,
            http: http,
            concurrency: concurrency,
            chunkSize: chunkSize,
            progress: progress
        )
    }

    public static func download(format initial: MediaFormat, to target: URL, http: HTTPFetching,
                                refresh: (@Sendable () async throws -> MediaFormat)? = nil,
                                partialSeconds: Double? = nil, liveFromStart: Bool = false,
                                concurrency: Int = 4, chunkSize: UInt64 = 1024 * 1024,
                                progress: @Sendable (Double, String?) -> Void = { _, _ in }) async throws -> URL {
        if initial.protocolType == .sabr {
            return try await SABRDownloader.download(format: initial, to: target, http: http,
                options: SABRDownloadOptions(durationSeconds: partialSeconds), refresh: refresh, progress: progress)
        }
        if initial.protocolType == .dash && initial.isLive == true {
            return try await NativeDASHLiveDownloader.download(format: initial, to: target, http: http,
                duration: partialSeconds, liveFromStart: liveFromStart, refresh: refresh,
                concurrency: concurrency, progress: progress)
        }
        guard initial.protocolType != .hls else {
            return try await NativeHLSDownloader.download(format: initial, to: target, http: http,
                refresh: refresh, durationSeconds: partialSeconds, concurrency: concurrency, progress: progress)
        }
        let partial = target.appendingPathExtension("part"), checkpoint = target.appendingPathExtension("state.json")
        let fm = FileManager.default
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        var state = State(formatID: initial.formatID, representationID: initial.representationID, videoID: initial.videoID)
        if fm.fileExists(atPath: partial.path), let data = try? Data(contentsOf: checkpoint),
           let old = try? JSONDecoder().decode(State.self, from: data), old.formatID == initial.formatID,
           old.representationID == initial.representationID, old.videoID == initial.videoID,
           let diskSize = (try? fm.attributesOfItem(atPath: partial.path)[.size] as? NSNumber)?.uint64Value,
           diskSize >= old.bytes {
            state = old
            state.completedChunks = state.completedChunks.filter { $0.end < diskSize }
            state.normalizeChunks()
        } else { try Data().write(to: partial, options: .atomic) }
        let file = try FileHandle(forWritingTo: partial)
        defer { try? file.close() }
        let validCeiling = max(state.bytes, state.completedChunks.map { $0.end + 1 }.max() ?? state.bytes)
        try file.truncate(atOffset: validCeiling)
        try file.seek(toOffset: state.bytes)
        let client = RetryingHTTPClient(base: http)
        let effectiveConcurrency = max(1, concurrency)
        let effectiveChunkSize = max(1, chunkSize)

        if let fragments = initial.fragments, !fragments.isEmpty {
            var elapsed = fragments.prefix(state.nextFragment).compactMap(\.duration).reduce(0, +)
            var endFragment = state.nextFragment
            while endFragment < fragments.count {
                let fragment = fragments[endFragment]
                if let seconds = partialSeconds, elapsed >= seconds, !fragment.isInitialization { break }
                elapsed += fragment.duration ?? 0
                endFragment += 1
            }
            if state.nextFragment < endFragment {
                let coordinator = DASHFragmentCoordinator(
                    format: initial,
                    state: state,
                    endFragment: endFragment,
                    totalFragments: fragments.count,
                    file: file,
                    checkpoint: checkpoint,
                    client: client,
                    refresh: refresh
                )
                let totalTasks = endFragment - state.nextFragment
                let workers = min(effectiveConcurrency, totalTasks)
                if workers <= 1 {
                    while let update = try await coordinator.stepOne() {
                        if let update { progress(update.0, update.1) }
                    }
                } else {
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
                            if launched < totalTasks {
                                launched += 1
                                group.addTask { try await coordinator.stepOne() ?? nil }
                            }
                        }
                    }
                }
                state = await coordinator.currentState()
            }
        } else {
            let coordinator = RangeDownloadCoordinator(
                format: initial,
                state: state,
                chunkSize: effectiveChunkSize,
                file: file,
                checkpoint: checkpoint,
                client: client,
                refresh: refresh
            )
            // Phase 1: Probe / sequential validation until expectedBytes is known
            while let update = try await coordinator.stepProbe() {
                if let (frac, msg) = update {
                    progress(frac, msg)
                }
            }
            // Phase 2: Concurrent Range workers for remaining chunks
            while true {
                let count = await coordinator.prepareQueue()
                guard count > 0 else { break }
                let workers = min(effectiveConcurrency, count)
                if workers <= 1 {
                    while let update = try await coordinator.stepWorker() {
                        progress(update.0, update.1)
                    }
                } else {
                    try await withThrowingTaskGroup(of: (Double, String)?.self) { group in
                        for _ in 0..<workers {
                            group.addTask { try await coordinator.stepWorker() }
                        }
                        while let completed = try await group.next() {
                            if let (frac, msg) = completed {
                                progress(frac, msg)
                                group.addTask { try await coordinator.stepWorker() }
                            }
                        }
                    }
                }
            }
            state = await coordinator.currentState()
        }

        guard state.bytes > 0 else { throw ExtractionError.network("媒体没有可写入的数据") }
        try file.truncate(atOffset: state.bytes)
        try file.synchronize(); try file.close()
        if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
        try fm.moveItem(at: partial, to: target); try? fm.removeItem(at: checkpoint)
        progress(1, "下载完成")
        return target
    }
}

// MARK: - Concurrent DASH Fragment Coordinator

private actor DASHFragmentCoordinator {
    var format: MediaFormat
    var state: NativeMediaDownloader.State
    let endFragment: Int
    let totalFragments: Int
    let file: FileHandle
    let checkpoint: URL
    let client: HTTPFetching
    let refresh: (@Sendable () async throws -> MediaFormat)?

    var nextToDispatch: Int
    var refreshes = 0
    var generation = 0
    var refreshTask: Task<MediaFormat, Error>?
    var buffered: [Int: Data] = [:]

    init(
        format: MediaFormat,
        state: NativeMediaDownloader.State,
        endFragment: Int,
        totalFragments: Int,
        file: FileHandle,
        checkpoint: URL,
        client: HTTPFetching,
        refresh: (@Sendable () async throws -> MediaFormat)?
    ) {
        self.format = format
        self.state = state
        self.endFragment = endFragment
        self.totalFragments = totalFragments
        self.file = file
        self.checkpoint = checkpoint
        self.client = client
        self.refresh = refresh
        self.nextToDispatch = state.nextFragment
    }

    func currentState() -> NativeMediaDownloader.State { state }

    private func popAndFetch() async throws -> (index: Int, fragment: MediaFragment, generation: Int, response: HTTPResponse)? {
        guard nextToDispatch < endFragment, let fragments = format.fragments, nextToDispatch < fragments.count else {
            return nil
        }
        let idx = nextToDispatch
        nextToDispatch += 1
        let gen = generation
        let fragment = fragments[idx]
        var headers = format.requestHeaders ?? [:]
        if let range = fragment.byteRange { headers["Range"] = "bytes=" + range }
        let response = try await client.fetch(.get(fragment.url, headers: headers))
        return (idx, fragment, gen, response)
    }

    private func retryFetch(index: Int) async throws -> (fragment: MediaFragment, generation: Int, response: HTTPResponse) {
        guard let fragments = format.fragments, index < fragments.count else {
            throw ExtractionError.parse("刷新后的 DASH 分片身份不一致")
        }
        let gen = generation
        let fragment = fragments[index]
        var headers = format.requestHeaders ?? [:]
        if let range = fragment.byteRange { headers["Range"] = "bytes=" + range }
        let response = try await client.fetch(.get(fragment.url, headers: headers))
        return (fragment, gen, response)
    }

    private func refreshFormat(failedGeneration: Int) async throws -> Bool {
        if generation > failedGeneration { return true }
        if let existing = refreshTask {
            _ = try await existing.value
            return true
        }
        guard let refresh, refreshes < 3 else { return false }
        let currentFormat = format
        let task = Task<MediaFormat, Error> {
            let updated = try await refresh()
            guard updated.formatID == currentFormat.formatID,
                  updated.representationID == currentFormat.representationID,
                  updated.fragments?.count == currentFormat.fragments?.count else {
                throw ExtractionError.parse("刷新后的 DASH 分片身份不一致")
            }
            return updated
        }
        refreshTask = task
        do {
            let updated = try await task.value
            refreshTask = nil
            format = updated
            refreshes += 1
            generation += 1
            return true
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func commit(index: Int, data: Data) throws -> (Double, String)? {
        buffered[index] = data
        var lastProgress: (Double, String)?
        while let nextData = buffered.removeValue(forKey: state.nextFragment) {
            try file.seek(toOffset: state.bytes)
            try file.write(contentsOf: nextData)
            state.bytes += UInt64(nextData.count)
            state.nextFragment += 1
            try file.synchronize()
            try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
            lastProgress = (Double(state.nextFragment) / Double(max(1, totalFragments)), "下载 DASH 分片")
        }
        return lastProgress
    }

    func stepOne() async throws -> (Double, String)?? {
        try Task.checkCancellation()
        guard var current = try await popAndFetch() else { return nil }
        while true {
            try Task.checkCancellation()
            let response = current.response
            if [403, 410].contains(response.status) {
                if try await refreshFormat(failedGeneration: current.generation) {
                    let retried = try await retryFetch(index: current.index)
                    current = (current.index, retried.fragment, retried.generation, retried.response)
                    continue
                }
            }
            guard response.isOK, !response.body.isEmpty else {
                throw ExtractionError.network("DASH 分片 HTTP \(response.status)")
            }
            if let range = current.fragment.byteRange {
                let offsets = range.split(separator: "-").compactMap { Int($0) }
                guard response.status == 206, offsets.count == 2,
                      response.body.count == offsets[1] - offsets[0] + 1 else {
                    throw ExtractionError.parse("DASH 字节范围响应不符")
                }
            }
            return .some(try commit(index: current.index, data: response.body))
        }
    }
}

// MARK: - Concurrent HTTP Range Coordinator

private actor RangeDownloadCoordinator {
    var format: MediaFormat
    var state: NativeMediaDownloader.State
    let chunkSize: UInt64
    let file: FileHandle
    let checkpoint: URL
    let client: HTTPFetching
    let refresh: (@Sendable () async throws -> MediaFormat)?

    var queue: [NativeMediaDownloader.ByteChunk] = []
    var refreshes = 0
    var generation = 0
    var refreshTask: Task<MediaFormat, Error>?
    var probed = false
    var complete = false

    init(
        format: MediaFormat,
        state: NativeMediaDownloader.State,
        chunkSize: UInt64,
        file: FileHandle,
        checkpoint: URL,
        client: HTTPFetching,
        refresh: (@Sendable () async throws -> MediaFormat)?
    ) {
        self.format = format
        self.state = state
        self.chunkSize = chunkSize
        self.file = file
        self.checkpoint = checkpoint
        self.client = client
        self.refresh = refresh
    }

    func currentState() -> NativeMediaDownloader.State { state }

    private func makeRangeRequest(url: URL, chunk: NativeMediaDownloader.ByteChunk) -> HTTPRequest {
        var headers = format.requestHeaders ?? [:]
        headers["Range"] = "bytes=\(chunk.start)-\(chunk.end)"
        if let validator = state.etag ?? state.lastModified {
            headers["If-Range"] = validator
        }
        var request = HTTPRequest.get(url, headers: headers)
        let span = chunk.end >= chunk.start ? (chunk.end - chunk.start + 1) : chunkSize
        request.maximumResponseBytes = Int(min(UInt64(Int.max - 1), span)) + 1
        return request
    }

    private func popAndFetchPrimary() async throws -> (chunk: NativeMediaDownloader.ByteChunk, generation: Int, candidates: [URL], firstResponse: HTTPResponse)? {
        guard !complete, !queue.isEmpty else { return nil }
        let chunk = queue.removeFirst()
        let gen = generation
        let candidates = [format.url] + (format.backupURLs ?? [])
        let request = makeRangeRequest(url: candidates[0], chunk: chunk)
        let response = try await client.fetch(request)
        return (chunk, gen, candidates, response)
    }

    private func fetchCandidate(url: URL, chunk: NativeMediaDownloader.ByteChunk) async throws -> HTTPResponse {
        let request = makeRangeRequest(url: url, chunk: chunk)
        return try await client.fetch(request)
    }

    private func snapshotCandidates(for chunk: NativeMediaDownloader.ByteChunk) -> (generation: Int, candidates: [URL]) {
        (generation, [format.url] + (format.backupURLs ?? []))
    }

    private func refreshFormat(failedGeneration: Int) async throws -> Bool {
        if generation > failedGeneration { return true }
        if let existing = refreshTask {
            _ = try await existing.value
            return true
        }
        guard let refresh, refreshes < 3 else { return false }
        let currentFormat = format
        let task = Task<MediaFormat, Error> {
            let updated = try await refresh()
            guard updated.formatID == currentFormat.formatID, updated.kind == currentFormat.kind else {
                throw ExtractionError.parse("刷新后的媒体格式不一致")
            }
            return updated
        }
        refreshTask = task
        do {
            let updated = try await task.value
            refreshTask = nil
            format = updated
            refreshes += 1
            generation += 1
            return true
        } catch {
            refreshTask = nil
            throw error
        }
    }

    private func fetchChunkWithFallbacks(_ chunk: NativeMediaDownloader.ByteChunk, initial: (generation: Int, candidates: [URL], firstResponse: HTTPResponse)?) async throws -> HTTPResponse {
        var currentGen: Int
        var candidates: [URL]
        var firstResp: HTTPResponse?

        if let initial {
            currentGen = initial.generation
            candidates = initial.candidates
            firstResp = initial.firstResponse
        } else {
            let snap = snapshotCandidates(for: chunk)
            currentGen = snap.generation
            candidates = snap.candidates
            firstResp = nil
        }

        while true {
            try Task.checkCancellation()
            var selected: HTTPResponse?
            for (idx, url) in candidates.enumerated() {
                let response: HTTPResponse
                if idx == 0, let first = firstResp {
                    response = first
                    firstResp = nil
                } else {
                    response = try await fetchCandidate(url: url, chunk: chunk)
                }
                if response.isOK || response.status == 416 {
                    selected = response
                    break
                }
                if ![403, 404, 410, 429, 500, 502, 503, 504].contains(response.status) {
                    throw ExtractionError.network("媒体 HTTP \(response.status)")
                }
            }
            if let selected { return selected }
            if try await refreshFormat(failedGeneration: currentGen) {
                let snap = snapshotCandidates(for: chunk)
                currentGen = snap.generation
                candidates = snap.candidates
                firstResp = nil
                continue
            }
            throw ExtractionError.network("媒体地址均不可用，已保留续传文件")
        }
    }

    private func applyProbeOrSequentialResponse(_ response: HTTPResponse, requested: NativeMediaDownloader.ByteChunk) throws -> (Double, String)? {
        func header(_ name: String) -> String? { response.headers.first { $0.key.lowercased() == name }?.value }
        let start = requested.start

        if response.status == 416 {
            let total = header("content-range")?.split(separator: "/").last.flatMap { UInt64($0) }
            guard total == state.bytes else { throw ExtractionError.parse("媒体 Range 越界且长度不符") }
            complete = true
            return nil
        }
        if response.status == 200 {
            // Server ignored Range or validator changed: restart instead of appending a second copy.
            try file.truncate(atOffset: 0)
            try file.seek(toOffset: 0)
            state.bytes = 0
            state.completedChunks.removeAll()
            state.etag = header("etag")
            state.lastModified = header("last-modified")
            try file.write(contentsOf: response.body)
            state.bytes = UInt64(response.body.count)
            state.expectedBytes = state.bytes
            try file.synchronize()
            try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
            complete = true
            let total = state.expectedBytes ?? state.bytes
            return (total > 0 ? min(1, Double(state.bytes) / Double(total)) : 1, "下载 \(state.bytes) 字节")
        }
        let (last, total) = try validatePartialResponse(response, start: start)
        state.expectedBytes = total ?? state.expectedBytes
        state.etag = header("etag") ?? state.etag
        state.lastModified = header("last-modified") ?? state.lastModified
        let update = try writeChunkData(response.body, start: start, end: last)
        if let exp = state.expectedBytes, state.bytes >= exp {
            complete = true
        }
        return update
    }

    private func validatePartialResponse(_ response: HTTPResponse, start: UInt64) throws -> (last: UInt64, total: UInt64?) {
        func header(_ name: String) -> String? { response.headers.first { $0.key.lowercased() == name }?.value }
        guard response.status == 206,
              let contentRange = header("content-range"),
              let match = RegexKit.firstMatch(pattern: #"^bytes (\d+)-(\d+)/(\d+|\*)$"#, in: contentRange),
              UInt64(match[1]) == start,
              let last = UInt64(match[2]),
              last >= start,
              last - start + 1 == UInt64(response.body.count),
              !response.body.isEmpty else {
            throw ExtractionError.parse("媒体 Range 响应不符，拒绝拼接损坏文件")
        }
        if start > 0, let old = state.etag, let new = header("etag"), old != new {
            throw ExtractionError.parse("媒体 ETag 已改变，拒绝拼接")
        }
        let parsedTotal = UInt64(match[3])
        if let old = state.expectedBytes, let new = parsedTotal, old != new {
            throw ExtractionError.parse("媒体总长度已改变，拒绝拼接")
        }
        return (last, parsedTotal)
    }

    private func writeChunkData(_ data: Data, start: UInt64, end: UInt64) throws -> (Double, String) {
        try file.seek(toOffset: start)
        try file.write(contentsOf: data)
        state.recordChunk(start: start, end: end)
        try file.synchronize()
        try JSONEncoder().encode(state).write(to: checkpoint, options: .atomic)
        let downloaded = state.totalDownloadedBytes
        let frac = state.expectedBytes.map { min(1, Double(downloaded) / max(1, Double($0))) } ?? 0
        return (frac, "下载 \(downloaded) 字节")
    }

    private func commitWorkerResponse(_ response: HTTPResponse, requested: NativeMediaDownloader.ByteChunk) throws -> (Double, String) {
        func header(_ name: String) -> String? { response.headers.first { $0.key.lowercased() == name }?.value }
        let (last, total) = try validatePartialResponse(response, start: requested.start)
        state.expectedBytes = total ?? state.expectedBytes
        state.etag = header("etag") ?? state.etag
        state.lastModified = header("last-modified") ?? state.lastModified
        if last < requested.end {
            queue.insert(NativeMediaDownloader.ByteChunk(start: last + 1, end: requested.end), at: 0)
        }
        let update = try writeChunkData(response.body, start: requested.start, end: last)
        if let exp = state.expectedBytes, state.bytes >= exp {
            complete = true
        }
        return update
    }

    func stepProbe() async throws -> (Double, String)?? {
        try Task.checkCancellation()
        if complete { return nil }
        if probed && state.expectedBytes != nil { return nil }
        if let exp = state.expectedBytes, exp > 0, state.bytes >= exp {
            complete = true
            return nil
        }
        let nextChunk: NativeMediaDownloader.ByteChunk
        if let exp = state.expectedBytes {
            let pending = state.pendingChunks(total: exp, chunkSize: chunkSize)
            guard let first = pending.first else {
                complete = true
                return nil
            }
            nextChunk = first
        } else {
            nextChunk = NativeMediaDownloader.ByteChunk(start: state.bytes, end: state.bytes + chunkSize - 1)
        }
        let response = try await fetchChunkWithFallbacks(nextChunk, initial: nil)
        probed = true
        let update = try applyProbeOrSequentialResponse(response, requested: nextChunk)
        return .some(update)
    }

    func prepareQueue() -> Int {
        guard !complete, let total = state.expectedBytes, state.bytes < total else {
            if let total = state.expectedBytes, state.bytes >= total { complete = true }
            queue = []
            return 0
        }
        queue = state.pendingChunks(total: total, chunkSize: chunkSize)
        if queue.isEmpty { complete = true }
        return queue.count
    }

    func stepWorker() async throws -> (Double, String)? {
        try Task.checkCancellation()
        guard let popped = try await popAndFetchPrimary() else { return nil }
        let response = try await fetchChunkWithFallbacks(
            popped.chunk,
            initial: (popped.generation, popped.candidates, popped.firstResponse)
        )
        return try commitWorkerResponse(response, requested: popped.chunk)
    }
}
