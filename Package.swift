// swift-tools-version: 6.0
import Foundation
import PackageDescription

// 包根目录（Package.swift 自身路径推导，可移植：不依赖 cwd/机器路径）
let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().path
let sherpaLibPath = packageRoot + "/Frameworks/sherpa-onnx/lib"

// vendored 二进制缺失时给出明确指引（而非 SwiftPM 疑难报错）
if !FileManager.default.fileExists(atPath: packageRoot + "/Frameworks/whisper.xcframework") {
    fatalError("""
    缺少 vendored 原生依赖（Frameworks/ 目录）。请先运行：
        Scripts/bootstrap-deps.sh
    详见 README「从源码构建」。
    """)
}

let package = Package(
    name: "ytb2zh",
    platforms: [.macOS(.v14)],
    dependencies: [
        // 本地原生提取库（YouTube/Bilibili/抖音/TikTok），extraction only
        .package(path: "Videx"),
        .package(url: "https://github.com/markiv/SwiftUI-Shimmer.git", from: "1.5.1"),
    ],
    targets: [
        // MARK: - vendored 原生库
        // demucs.cpp（sevagh，MIT）源码内编（Sources/CDemucsCpp/demucs-src）+ C shim；
        // Eigen pinned dd8c71e 头文件 vendored 于 Sources/CDemucsCpp/eigen；BLAS → Accelerate
        .target(
            name: "CDemucsCpp",
            exclude: ["eigen"],
            cxxSettings: [
                .unsafeFlags(["-std=c++17", "-O3", "-DNDEBUG", "-DEIGEN_USE_BLAS", "-fno-fast-math",
                              "-I", "Sources/CDemucsCpp/eigen",
                              "-I", "Sources/CDemucsCpp/demucs-src"]),
            ],
            linkerSettings: [
                .linkedFramework("Accelerate"),
                .linkedLibrary("c++"),
            ]),
        // whisper.cpp 官方 xcframework（nightly b5130，Metal/CoreML 加速，裁剪为 macOS slice）
        .binaryTarget(name: "whisper", path: "Frameworks/whisper.xcframework"),
        // sherpa-onnx v1.13.8 osx-arm64 静态库（仅 arm64）+ 官方 c-api 头
        // 静态库在 Frameworks/sherpa-onnx/lib（缺失时先运行 Scripts/bootstrap-deps.sh）
        .target(
            name: "CSherpaOnnx",
            linkerSettings: [
                .linkedLibrary("c++"),
                .unsafeFlags([
                    "-L", sherpaLibPath,
                    "-lsherpa-onnx-c-api", "-lsherpa-onnx-core", "-lsherpa-onnx-cxx-api",
                    "-lonnxruntime", "-lkaldi-native-fbank-core", "-lkissfft-float",
                    "-lssentencepiece_core", "-lkaldi-decoder-core", "-lsherpa-onnx-kaldifst-core",
                    "-lsherpa-onnx-fst", "-lsherpa-onnx-fstfar", "-lespeak-ng", "-lpiper_phonemize", "-lucd",
                ]),
            ]),

        // MARK: - 核心库：模型 + 协议 + Profile/模板 + 任务状态（不依赖任何具体引擎）
        .target(name: "Ytb2ZHCore"),
        // MARK: - 引擎库：协议的具体实现（sidecar 包装 / API 客户端 / 纯算法）
        .target(name: "Ytb2ZHEngines", dependencies: [
            "Ytb2ZHCore",
            .product(name: "Videx", package: "Videx"),
            "whisper",
            "CSherpaOnnx",
            "CDemucsCpp",
        ]),
        // MARK: - CLI：run / templates / providers，输出 JSON 事件流
        .executableTarget(name: "ytb2zh", dependencies: ["Ytb2ZHCore", "Ytb2ZHEngines"]),
        // MARK: - GUI：SwiftUI 客户端
        .executableTarget(name: "Ytb2ZHApp", dependencies: ["Ytb2ZHCore", "Ytb2ZHEngines",
            .product(name: "Shimmer", package: "SwiftUI-Shimmer"),
        ]),
        // MARK: - 测试
        .testTarget(name: "Ytb2ZHCoreTests", dependencies: ["Ytb2ZHCore"]),
        .testTarget(name: "Ytb2ZHEnginesTests", dependencies: ["Ytb2ZHEngines"]),
    ]
)
