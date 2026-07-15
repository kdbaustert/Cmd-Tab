// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Overtab",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "Overtab",
            path: "Sources/Overtab",
            swiftSettings: [.swiftLanguageMode(.v5)]
        )
    ]
)
