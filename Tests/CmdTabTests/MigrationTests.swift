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

    /// A throwaway domain per test. `removePersistentDomain` on the way in as well as out — a
    /// crashed run leaves the suite behind, and a migration that reads a done-key from the *previous*
    /// test would sit there doing nothing while every assertion still passed.
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        try super.setUpWithError()
        suiteName = "com.cmdtab.tests.migration.\(UUID().uuidString)"
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    }

    override func tearDownWithError() throws {
        UserDefaults.standard.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        try super.tearDownWithError()
    }

    /// Runs the real entry point with both domains stood in for and the log silenced. `messages` is
    /// returned rather than asserted on by default: what a migration *announces* is not the contract,
    /// but "it announced something" is the only way to tell a branch that ran from one that was
    /// skipped when both leave the same defaults behind.
    @discardableResult
    private func migrate(from overtab: UserDefaults? = nil) -> [String] {
        var messages: [String] = []
        Migration.run(in: defaults, migratingFrom: overtab) { messages.append($0) }
        return messages
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
            "migratedDroppedSavedLayouts", "migratedFromOvertab",
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
        XCTAssertNil(defaults.object(forKey: "showDisplayBadges"))
        XCTAssertNil(defaults.object(forKey: "showSpaceBadges"))
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
        XCTAssertNil(defaults.object(forKey: "windowSnapOutlineColorHex"))
        XCTAssertNil(defaults.object(forKey: "windowSnapLandingColorHex"))
    }

    // MARK: - windowLayouts

    /// Deleted outright rather than left for the next reset, because it has nowhere to move to and
    /// can be arbitrarily large — a window frame per saved layout in the preferences of every user
    /// who ever saved one.
    func testTheSavedLayoutsListIsDeleted() {
        defaults.set([["x": 0.0]], forKey: "windowLayouts")
        let messages = migrate()
        XCTAssertNil(defaults.object(forKey: "windowLayouts"))
        XCTAssertEqual(messages.filter { $0.contains("saved-layouts") }.count, 1)
    }

    func testNothingIsAnnouncedWhenThereWereNoSavedLayouts() {
        let messages = migrate()
        XCTAssertTrue(messages.filter { $0.contains("saved-layouts") }.isEmpty, "\(messages)")
    }

    // MARK: - Overtab rename

    func testTunedSettingsComeAcrossFromTheOldDomain() throws {
        let overtab = try makeOvertabDomain([
            "mode": "windows", "iconSize": 96, "excludedBundleIDs": ["com.apple.Finder"],
        ])
        migrate(from: overtab)
        XCTAssertEqual(defaults.string(forKey: "mode"), "windows")
        XCTAssertEqual(defaults.integer(forKey: "iconSize"), 96)
        XCTAssertEqual(defaults.stringArray(forKey: "excludedBundleIDs"), ["com.apple.Finder"])
    }

    /// The new build's own value wins. Someone who installed Cmd-Tab fresh, tuned it, and only then
    /// had an old Overtab domain turn up — a restored backup, a synced home directory — must not
    /// have the older value dragged over the top of it.
    func testAValueTheNewBuildAlreadyHasIsNotClobbered() throws {
        let overtab = try makeOvertabDomain(["iconSize": 96])
        defaults.set(48, forKey: "iconSize")
        migrate(from: overtab)
        XCTAssertEqual(defaults.integer(forKey: "iconSize"), 48)
    }

    /// Only the five keys named in `Migration.keys` travel. The old domain can hold anything at all,
    /// including keys whose meaning changed between the two apps.
    func testKeysOutsideTheListAreLeftBehind() throws {
        let overtab = try makeOvertabDomain(["mode": "windows", "somethingElse": "value"])
        migrate(from: overtab)
        XCTAssertEqual(defaults.string(forKey: "mode"), "windows")
        XCTAssertNil(defaults.object(forKey: "somethingElse"))
    }

    /// The overwhelmingly common case — a machine that never ran Overtab — and the one where a
    /// crash would be worst, since this runs before the app has drawn anything.
    func testAMissingOldDomainIsNotAnError() {
        let messages = migrate(from: nil)
        XCTAssertTrue(messages.filter { $0.contains("Overtab") }.isEmpty, "\(messages)")
        XCTAssertTrue(defaults.bool(forKey: "migratedFromOvertab"))
    }

    private var overtabSuiteName: String?

    private func makeOvertabDomain(_ contents: [String: Any]) throws -> UserDefaults {
        let name = "com.cmdtab.tests.overtab.\(UUID().uuidString)"
        overtabSuiteName = name
        UserDefaults.standard.removePersistentDomain(forName: name)
        let old = try XCTUnwrap(UserDefaults(suiteName: name))
        for (key, value) in contents { old.set(value, forKey: key) }
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: name) }
        return old
    }
}
