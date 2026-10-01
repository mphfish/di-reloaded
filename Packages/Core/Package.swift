// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Core",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "ScanKit", targets: ["ScanKit"]),
        .library(name: "TreemapKit", targets: ["TreemapKit"]),
        .executable(name: "dir-bench", targets: ["dir-bench"]),
    ],
    targets: [
        .target(name: "CBulkAttr"),
        .target(name: "ScanKit", dependencies: ["CBulkAttr"]),
        .target(name: "TreemapKit", dependencies: ["ScanKit"]),
        .executableTarget(name: "dir-bench", dependencies: ["ScanKit", "TreemapKit"]),
        .testTarget(name: "ScanKitTests", dependencies: ["ScanKit"]),
        .testTarget(name: "TreemapKitTests", dependencies: ["TreemapKit", "ScanKit"]),
    ]
)
