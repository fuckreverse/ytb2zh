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
        .systemLibrary(name: "CSystemSupport"),
        .target(name: "Videx", dependencies: ["CSystemSupport"], path: "Sources/Videx", resources: [.copy("YouTube/Resources")]),
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
