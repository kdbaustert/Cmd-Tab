import XCTest

@testable import CmdTab

/// Where the mirrored config file resolves to. The syncing itself is iCloud's job and not something
/// a unit test can stand in for; what is worth pinning down is the path arithmetic around it, since
/// a location that quietly resolved to the wrong file is exactly what "sync that never works" looks
/// like from the outside.
@MainActor
final class ConfigFileLocationTests: XCTestCase {
    /// The two locations must not name the same file. If they did, choosing iCloud Drive would leave
    /// the app writing to the local path and reporting success — sync that silently never happens.
    ///
    /// On a Mac with iCloud Drive switched off the documented behaviour is the opposite: fall back
    /// to the local path rather than write into a folder that syncs nowhere.
    func testTheLocationsNameDifferentFilesWhenICloudIsAvailable() {
        if ConfigFile.isICloudAvailable {
            XCTAssertNotEqual(ConfigFile.url(for: .iCloud), ConfigFile.url(for: .local))
        } else {
            XCTAssertEqual(ConfigFile.url(for: .iCloud), ConfigFile.url(for: .local))
        }
    }

    /// The iCloud path has to be inside the folder iCloud Drive actually syncs. Anywhere else under
    /// `Mobile Documents` belongs to a specific app's ubiquity container, which is the entitlement
    /// route this deliberately does not take.
    func testTheICloudPathSitsInICloudDrive() throws {
        try XCTSkipUnless(ConfigFile.isICloudAvailable, "iCloud Drive is not set up on this Mac")
        let url = try XCTUnwrap(ConfigFile.iCloudURL)
        XCTAssertTrue(url.path.contains("com~apple~CloudDocs"), url.path)
        XCTAssertEqual(url.lastPathComponent, "config.json")
    }

    /// Availability and the path have to agree in both directions: a nil path with the flag set, or
    /// a path with it clear, would each strand the picker in a state the UI cannot explain.
    func testAvailabilityAgreesWithThePath() {
        XCTAssertEqual(ConfigFile.isICloudAvailable, ConfigFile.iCloudURL != nil)
    }

    /// The raw values are persisted, so a rename would silently drop everyone back to the default.
    func testLocationsSurviveTheirStoredRawValue() {
        for location in ConfigFile.Location.allCases {
            XCTAssertEqual(ConfigFile.Location(rawValue: location.rawValue), location)
        }
        XCTAssertEqual(ConfigFile.Location.local.rawValue, "local")
        XCTAssertEqual(ConfigFile.Location.iCloud.rawValue, "iCloud")
    }

    /// An unreadable location key means the local path, not a crash and not iCloud: sync is opt-in,
    /// and the fallback for "no idea" has to be the one that touches nothing shared.
    func testAnUnknownStoredValueFallsBackToLocal() {
        XCTAssertNil(ConfigFile.Location(rawValue: "dropbox"))
    }

    /// Shown to the user, so it reads the way someone would type it.
    func testTheDisplayPathAbbreviatesTheHomeDirectory() {
        XCTAssertFalse(ConfigFile.displayPath(for: .local).hasPrefix("/Users/"))
    }

    /// Both locations end at the same filename. The watcher derives iCloud's `.config.json.icloud`
    /// placeholder from it, so a divergence here would break the not-yet-downloaded check that stops
    /// a second Mac overwriting the first.
    func testBothLocationsEndAtTheSameFilename() {
        XCTAssertEqual(ConfigFile.url(for: .local).lastPathComponent, "config.json")
        XCTAssertEqual(ConfigFile.url(for: .iCloud).lastPathComponent, "config.json")
    }

    // MARK: - The two switches

    /// Neither switch on means nothing is mirrored at all — no file written, no watcher running.
    func testNeitherSwitchMirrorsNothing() {
        XCTAssertFalse(ConfigFile.resolve(file: false, sync: false).enabled)
    }

    /// The dotfiles switch alone keeps the file on this Mac, exactly as it did before sync existed.
    func testTheFileSwitchAloneStaysLocal() {
        let resolved = ConfigFile.resolve(file: true, sync: false)
        XCTAssertTrue(resolved.enabled)
        XCTAssertEqual(resolved.location, .local)
    }

    /// The point of the sync switch being its own control: it starts the mirror on its own, with no
    /// need to opt into a dotfiles file first.
    func testTheSyncSwitchAloneStartsTheMirrorInICloud() {
        let resolved = ConfigFile.resolve(file: false, sync: true)
        XCTAssertTrue(resolved.enabled)
        XCTAssertEqual(resolved.location, .iCloud)
    }

    /// Both on is the case worth pinning down: one file, in iCloud Drive. A second copy under
    /// `~/.config` would diverge from it the moment either changed, leaving two files each claiming
    /// to be the settings and nothing to say which one wins.
    func testBothSwitchesKeepOneFileAndPutItInICloud() {
        let resolved = ConfigFile.resolve(file: true, sync: true)
        XCTAssertTrue(resolved.enabled)
        XCTAssertEqual(resolved.location, .iCloud)
    }

    /// Turning the dotfiles switch off must not stop a running sync — they are independent, and the
    /// mirror stays up as long as either one asks for it.
    func testTurningOffTheFileSwitchLeavesSyncRunning() {
        XCTAssertTrue(ConfigFile.resolve(file: false, sync: true).enabled)
    }

    // MARK: - Which copy wins when the mirror moves

    /// Starting to mirror adopts whatever is already there. This is the dotfiles case — a fresh
    /// checkout has to come up configured — and it is the same rule launch follows.
    func testStartingToMirrorLetsAnExistingFileWin() {
        XCTAssertTrue(ConfigFile.destinationWins(wasMirroring: false, leaving: .local))
        XCTAssertTrue(ConfigFile.destinationWins(wasMirroring: false, leaving: .iCloud))
    }

    /// Joining a sync set adopts the copy already in iCloud: another Mac published it, and it is
    /// the shared state this one is opting into.
    func testTurningSyncOnLetsTheCloudCopyWin() {
        XCTAssertTrue(ConfigFile.destinationWins(wasMirroring: true, leaving: .local))
    }

    /// Turning sync **off** must not adopt the local file. It is a leftover from before sync was
    /// turned on and can be arbitrarily old, so letting it win reverts every setting the moment the
    /// switch is flipped — a silent loss rather than a move. The live settings are published over
    /// it instead.
    func testTurningSyncOffPublishesTheLiveSettingsRatherThanRevertingToAStaleFile() {
        XCTAssertFalse(ConfigFile.destinationWins(wasMirroring: true, leaving: .iCloud))
    }

    // MARK: - Adopting a file that is already there

    /// The dotfiles case, and the one `destinationWins` above could never reach on its own: it only
    /// runs once mirroring has been asked for, and on a fresh checkout nobody has asked. An install
    /// with neither key written and a `config.json` already on disk turns the mirror on itself, so
    /// the checkout really is the whole of the setup.
    func testAFreshInstallAdoptsAFileThatIsAlreadyThere() {
        XCTAssertTrue(
            ConfigFile.shouldAdoptExistingFile(
                fileKeyWritten: false, syncKeyWritten: false, fileExists: true))
    }

    /// Nothing to adopt. The ordinary first launch on a machine with no dotfiles.
    func testAFreshInstallWithNoFileAdoptsNothing() {
        XCTAssertFalse(
            ConfigFile.shouldAdoptExistingFile(
                fileKeyWritten: false, syncKeyWritten: false, fileExists: false))
    }

    /// **Absent is not false**, and this is the case the whole rule turns on. Unticking the switch
    /// leaves the file on disk deliberately — it may be tracked — and writes `false` to the key. A
    /// rule that looked only at the file would turn the mirror back on at the next launch and
    /// overwrite the user's live settings with the copy they had just walked away from.
    func testAnInstallThatTurnedTheMirrorOffIsNotOverruledByTheLeftoverFile() {
        XCTAssertFalse(
            ConfigFile.shouldAdoptExistingFile(
                fileKeyWritten: true, syncKeyWritten: false, fileExists: true))
    }

    /// The sync switch counts as having decided too. Someone who has been through that control has
    /// had this question put to them, and the mirror they ended up with is theirs.
    func testHavingTouchedTheSyncSwitchCountsAsHavingDecided() {
        XCTAssertFalse(
            ConfigFile.shouldAdoptExistingFile(
                fileKeyWritten: false, syncKeyWritten: true, fileExists: true))
    }
}
