import Foundation

/// JS 运行时抽象。
///
/// 设计动机：YouTube 播放器挑战（签名 decipher / nsig）本质是运行混淆 JS。
/// 上游 yt-dlp 自研解释器维护成本已被证明不可持续（2025.11 起官方要求外部
/// JS 运行时），因此本库直接采用真实 JS 引擎策略。默认实现为系统
/// JavaScriptCore（macOS/iOS 内建，零依赖）；通过此协议也可换接
/// node/deno 子进程等实现。
public protocol JSRuntime: Sendable {
    /// 在全新上下文中：先安装 `globalStubs`（键为脚本片段名，值为待执行
    /// 的 JS 语句），再执行 `code`，最后对 `expression` 求值并返回其字符串结果。
    /// - Throws: `ExtractionError.jsFailure`（含引擎异常信息）。
    func evaluate(
        code: String,
        globalStubs: [String: String],
        expression: String
    ) throws -> String
}
