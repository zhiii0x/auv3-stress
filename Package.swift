// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "auv3-stress",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "auv3-stress", path: "Sources/auv3-stress"),
        .testTarget(name: "auv3-stressTests", dependencies: ["auv3-stress"], path: "Tests/auv3-stressTests"),
    ]
)
