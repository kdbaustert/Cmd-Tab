import Foundation
import XCTest

@testable import CmdTab

/// The String Catalog, checked as a file rather than through the app.
///
/// It is the one build input that nothing else would notice was broken. A malformed catalogue fails
/// at `xcstringstool compile` time in `build.sh` — but `swift build` and the whole test suite pass
/// without it, so a bad edit would survive every check until someone tried to cut a release. And a
/// *silently wrong* catalogue is worse than a malformed one: because a missing key renders as the
/// key itself, and the keys here are the English text, every failure mode of this file looks exactly
/// like it working until a translation exists.
final class StringCatalogTests: XCTestCase {

    /// Located relative to this source file. The catalogue is a build input, not a test resource —
    /// it is deliberately not in the test bundle, and copying it there to test it would mean testing
    /// the copy.
    private static var catalogURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // CmdTabTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("Sources/CmdTab/Resources/Localizable.xcstrings")
    }

    private struct Catalog: Decodable {
        struct Entry: Decodable {
            struct Localization: Decodable {
                struct Unit: Decodable {
                    let state: String
                    let value: String
                }
                let stringUnit: Unit
            }
            let localizations: [String: Localization]
        }
        let sourceLanguage: String
        let version: String
        let strings: [String: Entry]
    }

    private func loadCatalog() throws -> Catalog {
        let data = try Data(contentsOf: Self.catalogURL)
        return try JSONDecoder().decode(Catalog.self, from: data)
    }

    func testTheCatalogExistsAndParses() throws {
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: Self.catalogURL.path),
            "Localizable.xcstrings is missing; build.sh silently skips the compile step without it")
        let catalog = try loadCatalog()
        XCTAssertEqual(catalog.sourceLanguage, "en")
        XCTAssertEqual(catalog.version, "1.0")
    }

    func testTheCatalogIsNotEmpty() throws {
        // A catalogue that parses but has lost its entries compiles to an empty strings table, and
        // an empty table is indistinguishable at runtime from a working one.
        XCTAssertGreaterThan(try loadCatalog().strings.count, 100)
    }

    /// English is the base language, so every entry's English value must be its own key. A mismatch
    /// means someone edited a translation into the base rather than into a locale, and the settings
    /// window would render text that no longer matches the source.
    func testEveryEntryHasEnglishMatchingItsKey() throws {
        for (key, entry) in try loadCatalog().strings {
            guard let english = entry.localizations["en"] else {
                XCTFail("no English localization for \(key.prefix(60))")
                continue
            }
            XCTAssertEqual(
                english.stringUnit.value, key,
                "English value diverged from its key: \(key.prefix(60))")
            XCTAssertEqual(english.stringUnit.state, "translated", "\(key.prefix(60))")
        }
    }

    /// Keys are the finished English sentence, so an empty or whitespace-only one is a bug in
    /// whatever produced the catalogue rather than a string anyone meant to add.
    func testNoBlankKeys() throws {
        for key in try loadCatalog().strings.keys {
            XCTAssertFalse(
                key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "blank catalogue key")
        }
    }

    /// `SettingsChrome.text` looks up the *finished* string, so a key containing an interpolation
    /// marker could never match anything at runtime — it would be a dead entry that looks alive.
    func testNoKeyCarriesAnUnresolvedInterpolation() throws {
        for key in try loadCatalog().strings.keys {
            XCTAssertFalse(key.contains("\\("), "interpolated key cannot match: \(key.prefix(60))")
        }
    }
}
