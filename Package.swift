// swift-tools-version: 6.0
import PackageDescription

// The product is "Cmd-Tab"; the target is CmdTab because a Swift module name cannot contain a
// hyphen. The bundle carries the hyphenated name.
let package = Package(
    name: "CmdTab",
    // Required for any target carrying a String Catalog. English is the base: the catalogue is the
    // infrastructure, and every entry currently translates to itself.
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Typed `UserDefaults` keys. Each setting's storage key and default value are declared once
        // in `Defaults.Keys` instead of being repeated across the key table, `init`, `reload()` and
        // the owned-keys list — four places that had to agree and no compiler check that they did.
        .package(url: "https://github.com/sindresorhus/Defaults", from: "9.0.9"),
        // Auto-update. Distributed as a binary XCFramework, which is why this is the first
        // dependency to leave a mark outside the compile: `build.sh` has to copy
        // `Sparkle.framework` into `Contents/Frameworks`, add an rpath so the executable can find
        // it there, and sign it separately — see the comments in that script.
        .package(url: "https://github.com/sparkle-project/Sparkle", from: "2.6.0"),
    ],
    targets: [
        .executableTarget(
            name: "CmdTab",
            dependencies: [
                .product(name: "Defaults", package: "Defaults"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/CmdTab",
            // Excluded rather than declared as a resource, and the difference matters: SwiftPM does
            // not compile `.xcstrings`. Declared, it would be copied verbatim into a
            // `CmdTab_CmdTab.bundle` where nothing can read it — `LocalizedStringKey` resolves
            // against `Bundle.main`, and an uncompiled catalogue is not a strings table anyway.
            // `build.sh` runs `xcrun xcstringstool compile` and writes the resulting `.lproj`
            // directories straight into `Contents/Resources`, which is where `Bundle.main` looks.
            exclude: ["Resources/Localizable.xcstrings"],
            // Swift 6 language mode. This app runs four background queues doing Accessibility IPC
            // alongside a tap callback on the main run loop, and the cost of a threading mistake is
            // not a corrupted value but a stalled tap — which the system answers by killing it and
            // taking every keystroke on the machine with it. See README, "Swift 6 language mode",
            // for the four places the compiler cannot check and why each is sound.
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
        .testTarget(
            name: "CmdTabTests",
            dependencies: ["CmdTab"],
            path: "Tests/CmdTabTests",
            swiftSettings: [.swiftLanguageMode(.v6)]
        ),
    ]
)
