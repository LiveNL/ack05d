// swift-tools-version:5.7
import PackageDescription

let package = Package(
    name: "ack05d",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(name: "ack05d", path: "Sources/ack05d")
    ]
)
