// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SoundCloudPlayer",
    platforms: [.macOS(.v13)],
    targets: [
        .executableTarget(
            name: "SoundCloudPlayer",
            path: "Sources/SoundCloudPlayer"
        )
    ]
)
