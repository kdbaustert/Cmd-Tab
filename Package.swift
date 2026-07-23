// swift-tools-version: 6.0
import PackageDescription

// The product is "Cmd-Tab"; the target is CmdTab because a Swift module name cannot contain a
// hyphen. The bundle carries the hyphenated name.
let package = Package(
    name: "CmdTab",
    platforms: [.macOS(.v14)],
    dependencies: [
        // The settings window's chrome: a real toolbar-tab pane switcher that sizes itself to each
        // pane, in place of a `TabView` in a fixed-size window.
        .package(url: "https://github.com/sindresorhus/Settings", from: "3.1.1"),
        // Typed `UserDefaults` keys. Each setting's storage key and default value are declared once
        // in `Defaults.Keys` instead of being repeated across the key table, `init`, `reload()` and
        // the owned-keys list — four places that had to agree and no compiler check that they did.
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.9"),
    ],
    targets: [
        .executableTarget(
            name: "CmdTab",
            dependencies: [
                // The settings package nests `Pane`/`PaneIdentifier` inside a namespace enum called
                // `Settings`, which collides with SwiftUI's own `Settings` scene type. See
                // `SettingsPaneHost.swift` for how that is kept contained — module aliasing does
                // *not* solve it, because SwiftPM keeps the original name usable in source.
                .product(name: "Settings", package: "Settings"),
                .product(name: "Defaults", package: "Defaults"),
            ],
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
