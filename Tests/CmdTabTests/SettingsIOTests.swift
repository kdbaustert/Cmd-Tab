import Foundation
import XCTest

@testable import CmdTab

/// The other place in the app that rewrites settings a user already has — and unlike `Migration`,
/// this one is fed by a file the user is invited to edit.
///
/// `ConfigFile` watches that file and re-applies it at every launch and on every external edit, so
/// anything `apply` does with an unexpected value it does again, forever, with no way to intervene
/// from inside the app. That is what makes "what happens to a value we did not expect" a contract
/// worth pinning rather than an implementation detail: the failure mode is not a wrong preference,
/// it is an app that will not start.
///
/// The key strings are literals for the reason `MigrationTests` gives: they are the contract with a
/// file already on disk, and taking them from the source would let a rename pass unnoticed.
///
/// `@MainActor` sits on the test methods rather than the class because `setUpWithError` is
/// nonisolated and cannot touch main-actor state; only the calls into `SettingsIO` need the hop.
///
/// The JSON literals use `##"…"##`. The single-`#` form cannot hold this payload at all: a colour
/// is written `"#FF0000"`, and the `"#` that opens it closes the raw string.
final class SettingsIOTests: XCTestCase {

    /// A throwaway domain per test, cleared on the way in as well as out — a crashed run leaves the
    /// suite behind, and a stale value would let an assertion about "left alone" pass by accident.
    /// See `ThrowawayDefaults` for the file.
    private static let group = "settingsio"
    private var suiteName: String!
    private var defaults: UserDefaults!

    override class func setUp() {
        super.setUp()
        ThrowawayDefaults.sweep(group)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = ThrowawayDefaults.suiteName(in: Self.group)
        ThrowawayDefaults.remove(suiteName)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        defaults = nil
        ThrowawayDefaults.remove(suiteName)
        suiteName = nil
        try super.tearDownWithError()
    }

    /// Parses like `ConfigFile.readFromDisk` does, so these tests exercise the same object graph a
    /// real file produces — `NSNull` included. Building the dictionary in Swift instead would be
    /// testing a payload the app can never actually receive.
    @MainActor
    @discardableResult
    private func applying(
        _ json: String, ignoring ignored: Set<String> = [], replacing: Bool = false,
        file: StaticString = #filePath, line: UInt = #line
    ) throws -> [String] {
        let data = try XCTUnwrap(json.data(using: .utf8), file: file, line: line)
        let payload = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any], file: file, line: line)
        return SettingsIO.apply(
            payload, to: defaults, ignoring: ignored, replacingAbsentKeys: replacing)
    }

    /// What the suite *itself* holds, as opposed to what reading through it resolves to.
    ///
    /// `Defaults` registers every key's default into `NSRegistrationDomain`, which is process-wide
    /// and sits behind every `UserDefaults` instance — so `object(forKey: "maxColumns")` answers 0
    /// for a key that has just been removed exactly as readily as for one that was never set.
    /// Removal is only visible against the persistent domain, and asserting it any other way is a
    /// test that cannot fail.
    private func stored(_ key: String) -> Any? {
        UserDefaults.standard.persistentDomain(forName: suiteName)?[key]
    }

    // MARK: - Null

    /// The crash this file was added for. `UserDefaults.set(_:forKey:)` raises on a value that is not
    /// a property list, and `NSNull` — which is what JSON `null` decodes to — is not one. The test
    /// completing at all is most of the assertion: before the guard, this aborted the process.
    ///
    /// Removal rather than a skip, because an absent key is how "use the default" is written
    /// everywhere else in this app, and `null` is the only thing JSON has to say it with.
    @MainActor
    func testABareNullRemovesTheKeyRatherThanCrashing() throws {
        defaults.set(7, forKey: "maxColumns")

        let rejected = try applying(##"{"maxColumns": null}"##)

        XCTAssertNil(stored("maxColumns"))
        XCTAssertEqual(rejected, [], "null is understood, not refused")
    }

    /// The same value nested out of sight. `PropertyListSerialization` validates the whole graph,
    /// which is why the guard is one call rather than a walk over arrays and dictionaries — a check
    /// that only looked at the top level would have let this one through to the same abort.
    @MainActor
    func testANullInsideAnArrayIsRefusedRatherThanCrashing() throws {
        defaults.set(["com.apple.Safari"], forKey: "excludedBundleIDs")

        let rejected = try applying(##"{"excludedBundleIDs": ["com.apple.Mail", null]}"##)

        XCTAssertEqual(rejected, ["excludedBundleIDs"])
        XCTAssertEqual(
            defaults.stringArray(forKey: "excludedBundleIDs"), ["com.apple.Safari"],
            "a refused value must leave the old one standing")
    }

    /// Nested two deep, so the recursion is asserted rather than assumed from the one-level case.
    @MainActor
    func testANullNestedDeeperIsAlsoRefused() throws {
        let rejected = try applying(##"{"excludedBundleIDs": [["a", ["b", null]]]}"##)
        XCTAssertEqual(rejected, ["excludedBundleIDs"])
    }

    /// A `null` for something that was never set is not an error and not a write — the user is
    /// asking for a default they already have.
    @MainActor
    func testANullForAnUnsetKeyIsANoOp() throws {
        let rejected = try applying(##"{"maxColumns": null}"##)

        XCTAssertNil(stored("maxColumns"))
        XCTAssertEqual(rejected, [])
    }

    /// One bad key must not cost the user the rest of the file. The loop continues rather than
    /// returning, so a single stray `null` in a long config does not silently discard everything
    /// after it — which, given dictionary ordering, would be a different subset each launch.
    @MainActor
    func testAnUnusableValueDoesNotStopTheKeysAroundIt() throws {
        let rejected = try applying(
            ##"{"maxColumns": 4, "excludedBundleIDs": [null], "highlightColorHex": "#FF0000"}"##)

        XCTAssertEqual(rejected, ["excludedBundleIDs"])
        XCTAssertEqual(defaults.integer(forKey: "maxColumns"), 4)
        XCTAssertEqual(defaults.string(forKey: "highlightColorHex"), "#FF0000")
    }

    // MARK: - The ordinary path

    /// The guard must not have narrowed what a valid config can say. Every JSON value shape the
    /// app's own export can produce, round-tripped back in.
    @MainActor
    func testEveryOrdinaryJSONValueStillLandsUnchanged() throws {
        let rejected = try applying(
            ##"""
            {"maxColumns": 4, "highlightColorHex": "#00FF00", "stickyMode": true,
             "showDelayMs": 250, "excludedBundleIDs": ["com.apple.Mail"]}
            """##)

        XCTAssertEqual(rejected, [])
        XCTAssertEqual(defaults.integer(forKey: "maxColumns"), 4)
        XCTAssertEqual(defaults.string(forKey: "highlightColorHex"), "#00FF00")
        XCTAssertTrue(defaults.bool(forKey: "stickyMode"))
        XCTAssertEqual(defaults.double(forKey: "showDelayMs"), 250, accuracy: 0.0001)
        XCTAssertEqual(defaults.stringArray(forKey: "excludedBundleIDs"), ["com.apple.Mail"])
    }

    /// A key we do not own is not ours to write, however it is spelled — including a `null`, which
    /// must not become a licence to delete another app's preference out of our own domain.
    @MainActor
    func testAKeyOutsideTheAllowListIsIgnoredEvenWhenNull() throws {
        defaults.set("keep me", forKey: "somebodyElsesKey")

        let rejected = try applying(##"{"somebodyElsesKey": null, "alsoNotOurs": 1}"##)

        XCTAssertEqual(defaults.string(forKey: "somebodyElsesKey"), "keep me")
        XCTAssertNil(stored("alsoNotOurs"))
        XCTAssertEqual(rejected, [], "a key we ignore is not a key we refused")
    }

    /// A hand-edited config that mentions three settings means "change these three". Absent is not
    /// the same as `null`, and conflating them would turn every partial config into a reset.
    @MainActor
    func testAKeyAbsentFromThePayloadIsLeftAlone() throws {
        defaults.set(9, forKey: "maxColumns")

        try applying(##"{"highlightColorHex": "#123456"}"##)

        XCTAssertEqual(defaults.integer(forKey: "maxColumns"), 9)
    }

    // MARK: - The kind of value a setting holds

    /// A switch written as a string. `Defaults` would read it back as its default and say nothing,
    /// which leaves the hand edit apparently ignored; refused, it is named and the old value
    /// stands.
    @MainActor
    func testAValueOfTheWrongKindForARegisteredSettingIsRefused() throws {
        defaults.register(defaults: ["stickyMode": false])
        defaults.set(true, forKey: "stickyMode")

        let rejected = try applying(##"{"stickyMode": "yes"}"##)

        XCTAssertEqual(rejected, ["stickyMode"])
        XCTAssertEqual(stored("stickyMode") as? Bool, true)
    }

    // MARK: - Import replaces; the config file ignores its own switches

    /// An export carries only the keys that were set, so an import that merged left every setting
    /// at its default on the exporting Mac at whatever this one had. It replaces instead — except
    /// the two mirror switches, which a file that does not mention them must not turn off.
    @MainActor
    func testAnImportRemovesWhatTheFileDoesNotMentionButNotTheMirrorSwitches() throws {
        defaults.set(9, forKey: "maxColumns")
        defaults.set(true, forKey: "useConfigFile")

        try applying(##"{"highlightColorHex": "#123456"}"##, replacing: true)

        XCTAssertNil(stored("maxColumns"))
        XCTAssertEqual(stored("useConfigFile") as? Bool, true)
        XCTAssertEqual(defaults.string(forKey: "highlightColorHex"), "#123456")
    }

    /// What the config file passes through `ignoring`: a key it names is neither written nor, under
    /// `null`, removed — the file does not get to say how this Mac mirrors.
    @MainActor
    func testAnIgnoredKeyIsNeitherWrittenNorRemoved() throws {
        defaults.set(true, forKey: "useConfigFile")

        let rejected = try applying(
            ##"{"useConfigFile": null, "syncSettingsViaICloud": true}"##,
            ignoring: ["useConfigFile", "syncSettingsViaICloud"])

        XCTAssertEqual(stored("useConfigFile") as? Bool, true)
        XCTAssertNil(stored("syncSettingsViaICloud"))
        XCTAssertEqual(rejected, [])
    }

    // MARK: - What "your settings" are

    /// Only what was stored. The export and the config file used to carry every registered
    /// default as though it had been chosen, and an import then pinned them into the persistent
    /// domain, out of reach of any later change to the default.
    @MainActor
    func testThePayloadCarriesStoredSettingsAndNotRegisteredDefaults() {
        defaults.register(defaults: ["stickyMode": false])
        defaults.set(4, forKey: "maxColumns")
        defaults.set("x", forKey: "somebodyElsesKey")

        let payload = SettingsIO.currentPayload(
            stored: UserDefaults.standard.persistentDomain(forName: suiteName) ?? [:])

        XCTAssertEqual(payload["maxColumns"] as? Int, 4)
        XCTAssertNil(payload["stickyMode"], "a registered default is not a setting")
        XCTAssertNil(payload["somebodyElsesKey"], "not ours")
    }

    @MainActor
    func testThePayloadLeavesOutIgnoredKeys() {
        let payload = SettingsIO.currentPayload(
            stored: ["useConfigFile": true, "maxColumns": 4], ignoring: ["useConfigFile"])
        XCTAssertEqual(Set(payload.keys), ["maxColumns"])
    }

    // MARK: - Encoding

    /// `JSONSerialization` raises rather than throws on a NaN, and `try?` does not catch a raise:
    /// before the check this test took the whole test process down. The setting holding it is left
    /// out whole; the rest is written.
    @MainActor
    func testANonFiniteNumberIsLeftOutRatherThanCrashing() throws {
        let data = try XCTUnwrap(
            SettingsIO.encode([
                "maxColumns": 4, "showDelayMs": Double.nan,
                "nested": ["a": [1.0, Double.infinity]],
            ]))
        let decoded = try XCTUnwrap(SettingsIO.decode(data))
        XCTAssertEqual(decoded["maxColumns"] as? Int, 4)
        XCTAssertNil(decoded["showDelayMs"])
        XCTAssertNil(decoded["nested"], "found however deep it is")
    }

    // MARK: - Decoding a file

    /// A file from an older build says what it meant in the keys this one reads. Without it a fresh
    /// Mac adopting an old config came up with both markers on.
    func testDecodingCarriesARetiredKeyIntoItsSuccessors() {
        let payload = SettingsIO.decode(Data(##"{"showBadges": false}"##.utf8))
        XCTAssertEqual(payload?["showDisplayBadges"] as? Bool, false)
        XCTAssertEqual(payload?["showSpaceBadges"] as? Bool, false)
    }

    func testDecodingSomethingThatIsNotAnObjectIsNil() {
        XCTAssertNil(SettingsIO.decode(Data("[1, 2]".utf8)))
        XCTAssertNil(SettingsIO.decode(Data(##"{"a": 1"##.utf8)))
    }

    // MARK: - Bundle identifier lists

    /// `stringArray(forKey:)` answers nil for a whole list with one non-string in it, and both
    /// stores read nil as "none" — one stray number emptied the favourites.
    func testOneBadEntryNoLongerEmptiesABundleIDList() {
        defaults.set(["com.apple.Safari", 5, "com.apple.Mail"], forKey: "favoriteBundleIDs")
        XCTAssertEqual(
            defaults.bundleIDs(forKey: "favoriteBundleIDs"), ["com.apple.Safari", "com.apple.Mail"])
    }

    func testABundleIDListThatIsNotAListReadsAsEmpty() {
        defaults.set("com.apple.Safari", forKey: "excludedBundleIDs")
        XCTAssertEqual(defaults.bundleIDs(forKey: "excludedBundleIDs"), [])
        XCTAssertEqual(defaults.bundleIDs(forKey: "neverSet"), [])
    }
}
