// swift-tools-version: 6.0
import PackageDescription

// The product is "Cmd-Tab"; the target is CmdTab because a Swift module name cannot contain a
// hyphen. The bundle carries the hyphenated name.
let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "CmdTab",
            path: "Sources/CmdTab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "CmdTabTests",
            dependencies: ["CmdTab"],
            path: "Tests/CmdTabTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
