// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "dfui",
    platforms: [.macOS(.v13)],
    targets: [
        .target(name: "DiskStats"),
        .executableTarget(name: "dfui", dependencies: ["DiskStats"]),
        // Not a .testTarget: neither swift-testing nor XCTest ships with the
        // Command Line Tools, so `swift test` cannot run without a full Xcode.
        // `swift run selftest` works with the toolchain we actually have.
        .executableTarget(name: "selftest", dependencies: ["DiskStats"]),
    ]
)
