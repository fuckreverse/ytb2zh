import Foundation

/// Retry only idempotent reads. POST retries belong to their protocol state machine.
public struct RetryingHTTPClient: HTTPFetching {
    public var base: HTTPFetching
    public var retries: Int
    public var delay: TimeInterval
    public init(base: HTTPFetching, retries: Int = 3, delay: TimeInterval = 0.5) { self.base = base; self.retries = retries; self.delay = delay }
    public func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        guard ["GET", "HEAD"].contains(request.method) else { return try await base.fetch(request) }
        var last: Error = ExtractionError.network("请求未执行")
        for attempt in 0...max(0, retries) {
            try Task.checkCancellation()
            do {
                let response = try await base.fetch(request)
                if ![408,429,500,502,503,504].contains(response.status) || attempt == retries { return response }
                let retryAfter = response.headers.first { $0.key.lowercased() == "retry-after" }?.value
                let wait = retryAfter.flatMap(Double.init) ?? delay * pow(2, Double(attempt))
                try await Task.sleep(for: .seconds(min(60, max(0, wait))))
            } catch is CancellationError { throw CancellationError() }
            catch {
                last = error
                guard attempt < retries else { throw error }
                try await Task.sleep(for: .seconds(min(30, max(0, delay) * pow(2, Double(attempt)))))
            }
        }
        throw last
    }
}

/// Byte-rate scheduling applies equally to direct, HLS, DASH and SABR requests.
public actor RateLimitedHTTPClient: HTTPFetching {
    let base: HTTPFetching
    let bytesPerSecond: Int?
    var availableAt = ContinuousClock.now
    public init(base: HTTPFetching, bytesPerSecond: Int?) { self.base = base; self.bytesPerSecond = bytesPerSecond }
    public func fetch(_ request: HTTPRequest) async throws -> HTTPResponse {
        let response = try await base.fetch(request)
        if let rate = bytesPerSecond, rate > 0 {
            let now = ContinuousClock.now
            availableAt = max(now, availableAt).advanced(by: .seconds(Double(response.body.count)/Double(rate)))
            try await ContinuousClock().sleep(until: availableAt)
        }
        return response
    }
}
