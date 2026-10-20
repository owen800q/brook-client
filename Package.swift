// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "BrookClient",
    platforms: [.macOS(.v12)],
    targets: [
        // Pure, side-effect-free logic: link parsing, CIDRs, route planning, config.
        .target(name: "BrookCore"),
        // Menu-bar AppKit app: process management + UI.
        .executableTarget(name: "BrookClient", dependencies: ["BrookCore"]),
        .testTarget(
            name: "BrookCoreTests",
            dependencies: ["BrookCore"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
