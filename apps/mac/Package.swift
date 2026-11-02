// swift-tools-version: 6.0
// On-device core for the Mac companion: capture one window, read it with Vision,
// redact personal data, and build the payload for POST /v1/screen-contexts.
import PackageDescription

let package = Package(
    name: "ScreenContextCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ScreenContextCore", targets: ["ScreenContextCore"]),
        .executable(name: "sc-capture", targets: ["sc-capture"])
    ],
    targets: [
        .executableTarget(name: "camera-eval", dependencies: ["ScreenContextCore"]),
        .executableTarget(name: "replay-clip", dependencies: ["ScreenContextCore"]),
        .target(name: "ScreenContextCore"),
        .executableTarget(name: "sc-capture", dependencies: ["ScreenContextCore"]),
        .testTarget(name: "ScreenContextCoreTests", dependencies: ["ScreenContextCore"], resources: [.copy("Fixtures/tone.mp3")])
    ]
)
