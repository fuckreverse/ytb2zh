// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Videx",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "Videx", targets: ["Videx"]),
        .executable(name: "videx", targets: ["videx-cli"]),
    ],
    targets: [
        .target(name: "Videx", path: "Sources/Videx"),
        .executableTarget(
            name: "videx-cli",
            dependencies: ["Videx"],
            path: "Sources/videx-cli"
        ),
        .testTarget(
            name: "VidexTests",
            dependencies: ["Videx"],
            path: "Tests/VidexTests"
        ),
    ]
)
