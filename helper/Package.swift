// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "safari-claude-helper",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HelperCore", targets: ["HelperCore"]),
        .executable(name: "safari-claude-helper", targets: ["safari-claude-helper"]),
    ],
    targets: [
        .target(name: "HelperCore"),
        .executableTarget(name: "safari-claude-helper", dependencies: ["HelperCore"]),
        .testTarget(name: "HelperCoreTests", dependencies: ["HelperCore"]),
    ],
    swiftLanguageModes: [.v5]
)
