import Foundation

/// 线程安全可变盒（并发任务间共享状态的最小工具）
public final class Mutex<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()

    public init(_ value: T) { self.value = value }

    public func with<R>(_ body: (inout T) throws -> R) rethrows -> R {
        lock.lock(); defer { lock.unlock() }
        return try body(&value)
    }

    public var wrapped: T {
        lock.lock(); defer { lock.unlock() }
        return value
    }
}
