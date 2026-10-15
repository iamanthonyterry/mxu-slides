// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TimecodeKit",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "TimecodeKit", targets: ["TimecodeKit"]),
    ],
    targets: [
        .target(name: "TimecodeKit"),
        .testTarget(name: "TimecodeKitTests", dependencies: ["TimecodeKit"]),
    ]
)
