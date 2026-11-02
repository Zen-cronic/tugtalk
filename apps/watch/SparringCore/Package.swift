// swift-tools-version: 6.0
// The watch's spoken practice round, as plain Swift with no UI or audio: the request it sends, the turn
// machine and the round's one number. The watch app links it; `swift test` runs its tests on the Mac.
import PackageDescription

let package = Package(
    name: "SparringCore",
    platforms: [.watchOS(.v11), .macOS(.v14)],
    products: [.library(name: "SparringCore", targets: ["SparringCore"])],
    targets: [
        .target(name: "SparringCore"),
        .testTarget(name: "SparringCoreTests", dependencies: ["SparringCore"])
    ]
)
