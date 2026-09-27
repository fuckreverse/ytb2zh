import Foundation

// MARK: - 引擎通用错误

public enum EngineError: LocalizedError {
    case engineFailure(String)
    case notConfigured(String)

    public var errorDescription: String? {
        switch self {
        case .engineFailure(let msg): return msg
        case .notConfigured(let msg): return "未配置：\(msg)"
        }
    }
}
