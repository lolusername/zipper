// swift-tools-version: 6.0
import PackageDescription
let package = Package(
    name: "Zipper",
    platforms: [.macOS(.v14)],
    products: [.library(name: "HandoffCore", targets: ["HandoffCore"]), .executable(name: "Zipper", targets: ["ZipperApp"])],
    targets: [
        .systemLibrary(name: "CArchive"),
        .target(name: "HandoffCore", dependencies: ["CArchive"]),
        .executableTarget(name: "ZipperApp", dependencies: ["HandoffCore"]),
        .testTarget(name: "HandoffCoreTests", dependencies: ["HandoffCore"])
    ],
    swiftLanguageModes: [.v5]
)
