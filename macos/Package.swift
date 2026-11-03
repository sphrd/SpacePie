// swift-tools-version:5.7
// SpacePie for macOS. Built by macos/build.sh as a universal (arm64 + x86_64) .app inside a .dmg.
import PackageDescription

let package = Package(
    name: "SpacePie",
    platforms: [.macOS(.v11)],
    targets: [
        .executableTarget(
            name: "SpacePie",
            path: "Sources/SpacePie"
        )
    ]
)
