import Foundation
import JavaScriptCore

/// 系统框架 JavaScriptCore 的默认实现。
///
/// 每次求值创建全新 JSContext，无共享可变状态，天然线程安全。
/// JSContext 本身非 Sendable，但只在方法栈内使用、不跨 await，
/// 因此结构体无需 @unchecked。
public struct JavaScriptCoreRuntime: JSRuntime {
    public init() {}

    public func evaluate(
        code: String,
        globalStubs: [String: String],
        expression: String
    ) throws -> String {
        guard let context = JSContext() else {
            throw ExtractionError.jsFailure("无法创建 JSContext")
        }

        var failure: String?
        context.exceptionHandler = { _, exception in
            if failure == nil { failure = exception?.toString() ?? "unknown JS exception" }
        }

        for stub in globalStubs.values.sorted() {
            context.evaluateScript(stub)
            if let failure { throw ExtractionError.jsFailure("stub 执行失败: \(failure)") }
        }

        context.evaluateScript(code)
        if let failure { throw ExtractionError.jsFailure("挑战代码执行失败: \(failure)") }

        guard let value = context.evaluateScript(expression) else {
            throw ExtractionError.jsFailure("表达式无结果: \(expression)")
        }
        if let failure { throw ExtractionError.jsFailure("表达式求值失败: \(failure)") }

        guard let result = value.toString(), result != "undefined" else {
            throw ExtractionError.jsFailure("表达式返回 undefined: \(expression)")
        }
        return result
    }
}
