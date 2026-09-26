import XCTest

@testable import CmdTab

/// Where the mirrored config file resolves to. The syncing itself is iCloud's job and not something
/// a unit test can stand in for; what is worth pinning down is the path arithmetic around it, since
/// a location that quietly resolved to the wrong file is exactly what "sync that never works" looks
/// like from the outside.
@MainActor
final class ConfigFileLocationTests: XCTestCase {
    /// Clears what a crashed run left of the one suite below — see `ThrowawayDefaults`.
    nonisolated override class func setUp() {
        super.setUp()
        ThrowawayDefaults.sweep("configfile")
    }

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

    /// Both locations end at the same filename, so moving the mirror between them moves one file
    /// rather than leaving the user to find a differently named copy in each place.
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

    // MARK: - What the file carries

    /// The two switches say how this Mac mirrors, not what the settings are. In the file they
    /// travelled over iCloud and flipped every other Mac's dotfiles switch.
    func testTheMirrorSwitchesAreNotCarriedInTheFile() {
        XCTAssertEqual(ConfigFile.mirrorKeys, ["useConfigFile", "syncSettingsViaICloud"])
    }

    /// A key a newer build wrote — or a typo, or a note — used to vanish from the file the first
    /// time anything changed here. Known keys are not carried forward: an owned one with no value
    /// here was cleared on purpose, and says so with `null`; a retired one is dead, and goes.
    func testKeysThisBuildDoesNotKnowSurviveTheRewrite() {
        let out = ConfigFile.filePayload(
            ["maxColumns": 4],
            preserving: [
                "fromANewerBuild": 1, "maxColumns": 9, "clearedHere": 3, "showBadges": false,
            ],
            known: ["maxColumns", "clearedHere", "showBadges"],
            clearable: ["maxColumns", "clearedHere"])

        XCTAssertEqual(out["fromANewerBuild"] as? Int, 1)
        XCTAssertEqual(out["maxColumns"] as? Int, 4, "this Mac's value wins for a key it owns")
        XCTAssertTrue(out["clearedHere"] is NSNull, "a reset has to reach the other Macs")
        XCTAssertNil(out["showBadges"], "a retired key may be live on an older build; left out")
    }

    func testWithNoFileThereIsNothingToPreserve() {
        let out = ConfigFile.filePayload(
            ["maxColumns": 4], preserving: nil, known: [], clearable: [])
        XCTAssertEqual(out.count, 1)
    }

    /// A `null` only replaces a line the file already had. A key nobody ever set stays out, or the
    /// file would carry a `null` for every setting in the app.
    func testAKeyNeverSetIsNotWrittenAsNull() {
        let out = ConfigFile.filePayload(
            ["maxColumns": 4], preserving: ["maxColumns": 4], known: ["maxColumns", "stickyMode"],
            clearable: ["maxColumns", "stickyMode"])
        XCTAssertNil(out["stickyMode"])
    }

    /// The whole of the reset path, both Macs, through the real encoder and the real `apply`:
    /// A sets a value, B takes it; A resets it; B's copy clears, and B's next write does not put
    /// the old value back into the file. Before, the reset reached the file as a missing line,
    /// which B read as "no change" — and B's next write restored the value, on both Macs.
    func testAResetOnOneMacClearsTheSettingOnTheOther() throws {
        let known: Set<String> = ["maxColumns"]
        let suite = ThrowawayDefaults.suiteName(in: "configfile")
        let other = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { ThrowawayDefaults.remove(suite) }

        // A publishes a value; B has taken it.
        let set = try roundTrip(
            ConfigFile.filePayload(
                ["maxColumns": 7], preserving: nil, known: known, clearable: known))
        SettingsIO.apply(ConfigFile.changes(from: nil, to: set), to: other)
        XCTAssertEqual(other.persistentDomain(forName: suite)?["maxColumns"] as? Int, 7)

        // A resets: its payload no longer has the key.
        let reset = try roundTrip(
            ConfigFile.filePayload([:], preserving: set, known: known, clearable: known))
        XCTAssertTrue(reset["maxColumns"] is NSNull)

        // B reads the edit and applies what moved.
        SettingsIO.apply(ConfigFile.changes(from: set, to: reset), to: other)
        XCTAssertNil(other.persistentDomain(forName: suite)?["maxColumns"])

        // B's next write keeps the reset rather than resurrecting 7.
        let next = ConfigFile.filePayload(
            other.persistentDomain(forName: suite) ?? [:], preserving: reset, known: known,
            clearable: known)
        XCTAssertTrue(next["maxColumns"] is NSNull)
    }

    /// Through the encoder and the decoder, so the `null` is the one a real file carries.
    private func roundTrip(_ payload: [String: Any]) throws -> [String: Any] {
        try XCTUnwrap(SettingsIO.encode(payload).flatMap(SettingsIO.decode))
    }

    // MARK: - What an edit changed

    /// Only what moved. Applying the whole file reverted anything changed in Settings since the
    /// last write — a key the file still holds at its old value was not edited.
    func testOnlyTheKeysAnEditMovedAreApplied() {
        let changes = ConfigFile.changes(
            from: ["maxColumns": 4, "stickyMode": false],
            to: ["maxColumns": 6, "stickyMode": false, "fade": true])
        XCTAssertEqual(Set(changes.keys), ["maxColumns", "fade"])
    }

    /// Nothing synced yet — launch, or arriving at a different file — and the file wins whole.
    func testWithNothingSyncedTheWholeFileIsNew() {
        XCTAssertEqual(ConfigFile.changes(from: nil, to: ["a": 1, "b": 2]).count, 2)
    }

    /// Absent means "leave alone" here as everywhere else in the file's contract; deleting a line
    /// is not a reset.
    func testALineDeletedFromTheFileIsNotAChange() {
        XCTAssertTrue(ConfigFile.changes(from: ["maxColumns": 4], to: [:]).isEmpty)
    }

    /// A reset arrives as `null`, and that is a change — the one a missing line is not.
    func testANullWhereAValueWasIsAChange() {
        let changes = ConfigFile.changes(from: ["maxColumns": 4], to: ["maxColumns": NSNull()])
        XCTAssertTrue(changes["maxColumns"] is NSNull)
    }

    /// A `null` still there on the next read has already been applied; it is not re-applied.
    func testANullStillThereIsNotAChange() {
        XCTAssertTrue(
            ConfigFile.changes(from: ["maxColumns": NSNull()], to: ["maxColumns": NSNull()])
                .isEmpty)
    }

    /// Compared as values, not as the objects that happened to hold them, so re-reading an
    /// unchanged list does not count as editing it.
    func testAnUnchangedListIsNotAChange() {
        XCTAssertTrue(
            ConfigFile.changes(
                from: ["excludedBundleIDs": ["a", "b"]], to: ["excludedBundleIDs": ["a", "b"]]
            ).isEmpty)
    }
}
