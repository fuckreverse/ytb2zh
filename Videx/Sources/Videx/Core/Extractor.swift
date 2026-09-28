import Foundation

/// 站点提取器协议——库的核心扩展点。
///
/// 实现约束：实现类型必须是值语义或线程安全（Sendable），
/// 并发调用 extract 必须安全。
public protocol Extractor: Sendable {
    /// 稳定的提取器标识，如 "youtube"、"bilibili"。
    static var extractorID: String { get }
    var id: String { get }
    var displayName: String { get }
    /// 该提取器是否能处理此 URL（快速判断，不发网络请求）。
    func canHandle(_ url: URL) -> Bool
    /// 执行提取。
    func extract(_ url: URL, context: ExtractionContext) async throws -> MediaInfo
}

public extension Extractor {
    var id: String { Self.extractorID }
}

// MARK: - Extraction Context

/// 一次提取会话的依赖集合，由上层组装并传入。
/// 站点插件只依赖此抽象，不直接接触 URLSession/JSContext。
public struct ExtractionContext: Sendable {
    public let http: HTTPFetching
    public let js: JSRuntime
    public let cookies: CookieJar
    public let log: LogSink

    public init(
        http: HTTPFetching,
        js: JSRuntime,
        cookies: CookieJar = CookieJar(),
        log: LogSink = NullLogSink()
    ) {
        self.http = http
        self.js = js
        self.cookies = cookies
        self.log = log
    }

    /// 按选项构建默认上下文。
    public static func make(
        options: ExtractionOptions,
        httpFactory: (ExtractionOptions) -> HTTPFetching = { URLSessionHTTPClient(proxy: $0.proxy, timeout: $0.timeout) },
        js: JSRuntime = JavaScriptCoreRuntime()
    ) -> ExtractionContext {
        ExtractionContext(http: httpFactory(options), js: js, cookies: options.cookies, log: options.log)
    }
}

// MARK: - Options

/// 提取选项。
public struct ExtractionOptions: Sendable {
    /// 代理地址，如 "http://127.0.0.1:7890" 或 "socks5://127.0.0.1:7891"。
    public var proxy: String?
    public var cookies: CookieJar
    public var timeout: TimeInterval
    public var log: LogSink

    public init(
        proxy: String? = nil,
        cookies: CookieJar = CookieJar(),
        timeout: TimeInterval = 30,
        log: LogSink = NullLogSink()
    ) {
        self.proxy = proxy
        self.cookies = cookies
        self.timeout = timeout
        self.log = log
    }
}

// MARK: - Log

/// 日志钩子：库本身不打日志，交给上层决定去处。
public protocol LogSink: Sendable {
    func log(_ level: LogLevel, _ message: String)
}

public enum LogLevel: String, Sendable {
    case debug, info, warn, error
}

public struct NullLogSink: LogSink {
    public init() {}
    public func log(_ level: LogLevel, _ message: String) {}
}

/// 简单的 stderr 日志实现（CLI 调试用）。
public struct StderrLogSink: LogSink {
    public var minLevel: LogLevel
    public init(minLevel: LogLevel = .info) { self.minLevel = minLevel }

    public func log(_ level: LogLevel, _ message: String) {
        let order: [LogLevel] = [.debug, .info, .warn, .error]
        guard order.firstIndex(of: level)! >= order.firstIndex(of: minLevel)! else { return }
        FileHandle.standardError.write(Data("[\(level.rawValue)] \(message)\n".utf8))
    }
}

// MARK: - Registry

/// 提取器注册表：路由 URL 到对应站点插件。
public struct ExtractorRegistry: Sendable {
    private let extractors: [any Extractor]

    /// 内置注册表：YouTube + Bilibili + Douyin + TikTok。
    public static let standard = ExtractorRegistry(extractors: [
        YouTubeExtractor(),
        BilibiliExtractor(),
        DouyinExtractor(),
        TikTokExtractor(),
    ])

    public init(extractors: [any Extractor]) {
        self.extractors = extractors
    }

    /// 找到能处理该 URL 的提取器。
    public func extractor(for url: URL) -> (any Extractor)? {
        extractors.first { $0.canHandle(url) }
    }

    /// 一站式提取：路由 + 执行。
    public func extract(url: URL, options: ExtractionOptions = ExtractionOptions()) async throws -> MediaInfo {
        guard let extractor = extractor(for: url) else {
            throw ExtractionError.unsupportedURL(url)
        }
        let context = ExtractionContext.make(options: options)
        return try await extractor.extract(url, context: context)
    }

    public var allExtractorIDs: [String] { extractors.map(\.id) }
}
