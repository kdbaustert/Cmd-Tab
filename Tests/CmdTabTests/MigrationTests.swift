import Foundation
import XCTest

@testable import CmdTab

/// The one place in the app that rewrites settings a user already has.
///
/// Worth testing for what its failures look like rather than for how much code it is: each branch
/// runs once per install, before anything reads a preference, and every way it can be wrong is
/// silent. A guard that opens when it should not overwrites a value the user chose; one that closes
/// when it should not withholds a value they were owed. Neither raises anything — they surface
/// weeks later as a preference that is not what it was, with nothing to point at.
///
/// The key strings below are deliberately literals rather than references to `Migration`'s own
/// constants. They are the contract with data already sitting on disk, and a test that took them
/// from the source would keep passing through the one change that matters most: a rename, which
/// re-runs a completed migration against settings the user has since tuned by hand.
final class MigrationTests: XCTestCase {

    /// A throwaway domain per test. Cleared on the way in as well as out — a crashed run leaves the
    /// suite behind, and a migration that reads a done-key from the *previous* test would sit there
    /// doing nothing while every assertion still passed. See `ThrowawayDefaults` for the file.
    private static let group = "migration"
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

    /// Runs the real entry point with the domain stood in for and the log silenced. `messages` is
    /// returned rather than asserted on by default: what a migration *announces* is not the contract,
    /// but "it announced something" is the only way to tell a branch that ran from one that was
    /// skipped when both leave the same defaults behind.
    @discardableResult
    private func migrate() -> [String] {
        var messages: [String] = []
        Migration.run(in: defaults) { messages.append($0) }
        return messages
    }

    /// What the suite itself holds. `object(forKey:)` falls through to the registration domain,
    /// which is process-wide, so once any earlier test has touched a store that registers its
    /// defaults, an absent key reads back as its default and a nil assertion fails for nothing.
    private func stored(_ key: String) -> Any? {
        UserDefaults.standard.persistentDomain(forName: suiteName)?[key]
    }

    // MARK: - Idempotence

    /// The property every one of these has to have, and the only one whose absence is catastrophic
    /// rather than merely wrong: a migration that ran on version N must not run again on N+1, when
    /// the user has had a release to set these keys deliberately.
    ///
    /// Asserted by running twice with a *deliberate* change in between and checking the second pass
    /// leaves it alone — a second run that merely wrote the same value would pass a naive equality
    /// check while still being the bug.
    func testASecondRunDoesNotUndoWhatTheUserChangedAfterTheFirst() {
        defaults.set(false, forKey: "showBadges")
        defaults.set("#FF0000", forKey: "windowSnapHighlightColorHex")
        defaults.set(["a"], forKey: "windowLayouts")
        migrate()

        // The user's later intent, expressed on a build where these are real settings.
        defaults.set(true, forKey: "showDisplayBadges")
        defaults.set("#00FF00", forKey: "windowSnapOutlineColorHex")
        defaults.set(["b"], forKey: "windowLayouts")

        let second = migrate()
        XCTAssertEqual(second, [], "a completed migration must not announce anything on a re-run")
        XCTAssertEqual(defaults.bool(forKey: "showDisplayBadges"), true)
        XCTAssertEqual(defaults.string(forKey: "windowSnapOutlineColorHex"), "#00FF00")
        XCTAssertEqual(defaults.stringArray(forKey: "windowLayouts"), ["b"])
    }

    /// Every branch records that it ran, whether or not it had anything to carry across. Without
    /// this, an install with nothing to migrate would re-scan on every launch forever — and, worse,
    /// would migrate for real the moment the user set one of the retired keys by importing an old
    /// config.
    func testEveryDoneKeyIsSetEvenWhenThereIsNothingToMigrate() {
        migrate()
        for key in [
            "migratedBadgeSplit", "migratedRevivedSnapHighlightColor",
            "migratedDroppedSavedLayouts",
        ] {
            XCTAssertTrue(defaults.bool(forKey: key), key)
        }
    }

    // MARK: - showBadges -> showDisplayBadges + showSpaceBadges

    func testABadgesOptOutReachesBothNewKeys() {
        defaults.set(false, forKey: "showBadges")
        migrate()
        XCTAssertEqual(defaults.object(forKey: "showDisplayBadges") as? Bool, false)
        XCTAssertEqual(defaults.object(forKey: "showSpaceBadges") as? Bool, false)
    }

    /// True is the default for both new keys, so carrying it across would write today's default into
    /// the user's own defaults as though they had picked it. `BehaviorStore.resetAll` removes keys
    /// rather than writing defaults back, precisely so a future change to a default can still reach
    /// someone who once hit Reset — seeding `true` here would put that person permanently out of
    /// reach of it.
    func testABadgesOptInIsNotCarriedAcross() {
        defaults.set(true, forKey: "showBadges")
        migrate()
        XCTAssertNil(stored("showDisplayBadges"))
        XCTAssertNil(stored("showSpaceBadges"))
    }

    /// The retired key stays on disk: `retiredDefaultsKeys` sweeps it on the next reset, and removing
    /// it here would make the migration unrepeatable if it ever needed fixing.
    func testTheRetiredBadgesKeyIsLeftOnDisk() {
        defaults.set(false, forKey: "showBadges")
        migrate()
        XCTAssertEqual(defaults.object(forKey: "showBadges") as? Bool, false)
    }

    // MARK: - windowSnapHighlightColorHex -> outline + landing

    func testTheRetiredSnapColourSeedsBothOverlays() {
        defaults.set("#4E545A", forKey: "windowSnapHighlightColorHex")
        migrate()
        XCTAssertEqual(defaults.string(forKey: "windowSnapOutlineColorHex"), "#4E545A")
        XCTAssertEqual(defaults.string(forKey: "windowSnapLandingColorHex"), "#4E545A")
    }

    /// A colour chosen on this build is a later statement of intent than one chosen before the
    /// feature was withdrawn. The half that is already set survives; the half that is not still gets
    /// seeded, because the old single setting drove both overlays and leaving one grey would be a
    /// gesture the user never asked for.
    func testAColourAlreadyChosenOnThisBuildSurvives() {
        defaults.set("#4E545A", forKey: "windowSnapHighlightColorHex")
        defaults.set("#123456", forKey: "windowSnapOutlineColorHex")
        migrate()
        XCTAssertEqual(defaults.string(forKey: "windowSnapOutlineColorHex"), "#123456")
        XCTAssertEqual(defaults.string(forKey: "windowSnapLandingColorHex"), "#4E545A")
    }

    func testNothingIsSeededWhenTheRetiredColourWasNeverSet() {
        migrate()
        XCTAssertNil(stored("windowSnapOutlineColorHex"))
        XCTAssertNil(stored("windowSnapLandingColorHex"))
    }

    // MARK: - windowLayouts

    /// Deleted outright rather than left for the next reset, because it has nowhere to move to and
    /// can be arbitrarily large — a window frame per saved layout in the preferences of every user
    /// who ever saved one.
    func testTheSavedLayoutsListIsDeleted() {
        defaults.set([["x": 0.0]], forKey: "windowLayouts")
        let messages = migrate()
        XCTAssertNil(stored("windowLayouts"))
        XCTAssertEqual(messages.filter { $0.contains("saved-layouts") }.count, 1)
    }

    func testNothingIsAnnouncedWhenThereWereNoSavedLayouts() {
        let messages = migrate()
        XCTAssertTrue(messages.filter { $0.contains("saved-layouts") }.isEmpty, "\(messages)")
    }

    // MARK: - Incoming payloads

    /// `run` only sees this install's own defaults, and a config file from an older build arrives
    /// after it. The same rewrites, applied to the payload.
    func testAnOldPayloadsBadgesOptOutReachesBothNewKeys() {
        let upgraded = Migration.upgrade(["showBadges": false])
        XCTAssertEqual(upgraded["showDisplayBadges"] as? Bool, false)
        XCTAssertEqual(upgraded["showSpaceBadges"] as? Bool, false)
    }

    /// Only false, for the reason `testABadgesOptInIsNotCarriedAcross` gives.
    func testAnOldPayloadsBadgesOptInIsNotCarriedAcross() {
        let upgraded = Migration.upgrade(["showBadges": true])
        XCTAssertNil(upgraded["showDisplayBadges"])
        XCTAssertNil(upgraded["showSpaceBadges"])
    }

    /// Within one payload the successor key is the later statement, as a key set on this build is
    /// in `run`.
    func testASuccessorKeyThePayloadAlreadyCarriesWins() {
        let upgraded = Migration.upgrade([
            "showBadges": false, "showDisplayBadges": true,
            "windowSnapHighlightColorHex": "#4E545A", "windowSnapOutlineColorHex": "#123456",
        ])
        XCTAssertEqual(upgraded["showDisplayBadges"] as? Bool, true)
        XCTAssertEqual(upgraded["showSpaceBadges"] as? Bool, false)
        XCTAssertEqual(upgraded["windowSnapOutlineColorHex"] as? String, "#123456")
        XCTAssertEqual(upgraded["windowSnapLandingColorHex"] as? String, "#4E545A")
    }

    func testAPayloadWithNothingRetiredComesBackAsItWas() {
        let upgraded = Migration.upgrade(["maxColumns": 4])
        XCTAssertEqual(upgraded.count, 1)
        XCTAssertEqual(upgraded["maxColumns"] as? Int, 4)
    }
}

/// A `UserDefaults` suite a test can throw away without leaving a file behind.
///
/// `removePersistentDomain` empties a domain but does not delete it: cfprefsd leaves a 42-byte
/// plist under the suite's name. With a fresh UUID per test — which is what keeps one test's
/// leftovers out of the next — that was a new file in `~/Library/Preferences` per test per run,
/// and they had reached the thousands.
///
/// Deleting the file afterwards is not enough, measured: cfprefsd writes the emptied domain on its
/// own schedule, seconds later, and puts back a file deleted before it got there — with or
/// without a synchronize first, and `defaults delete` does the same. So the suites are named by
/// absolute path instead, which `CFPreferences` takes as the file to keep the domain in, and they
/// live in a directory of their own under the temporary directory. Whatever cfprefsd writes late
/// lands there, where the next run's `sweep` — and the system's own clean-up of temporary files —
/// clears it, and nothing reaches `~/Library/Preferences` at all.
enum ThrowawayDefaults {
    private static func directory(_ group: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("cmdtab-tests", isDirectory: true)
            .appendingPathComponent(group, isDirectory: true)
    }

    /// A fresh suite name in `group`'s directory.
    static func suiteName(in group: String) -> String {
        let directory = directory(group)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent(UUID().uuidString).path
    }

    static func remove(_ suiteName: String) {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(atPath: suiteName + ".plist")
    }

    /// Everything a previous run of `group` left, including a crashed one.
    static func sweep(_ group: String) {
        try? FileManager.default.removeItem(at: directory(group))
    }
}
