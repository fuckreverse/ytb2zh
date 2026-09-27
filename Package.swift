// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ytb2zh",
    platforms: [.macOS(.v14)],
    targets: [
        // MARK: - 核心库：模型 + 协议 + Profile/模板 + 任务状态（不依赖任何具体引擎）
        .target(name: "Ytb2ZHCore"),
        // MARK: - 引擎库：协议的具体实现（sidecar 包装 / API 客户端 / 纯算法）
        .target(name: "Ytb2ZHEngines", dependencies: ["Ytb2ZHCore"]),
        // MARK: - CLI：run / templates / providers，输出 JSON 事件流
        .executableTarget(name: "ytb2zh", dependencies: ["Ytb2ZHCore", "Ytb2ZHEngines"]),
        // MARK: - GUI：SwiftUI 客户端
        .executableTarget(name: "Ytb2ZHApp", dependencies: ["Ytb2ZHCore", "Ytb2ZHEngines"]),
        // MARK: - 测试
        .testTarget(name: "Ytb2ZHCoreTests", dependencies: ["Ytb2ZHCore"]),
        .testTarget(name: "Ytb2ZHEnginesTests", dependencies: ["Ytb2ZHEngines"]),
    ]
)
