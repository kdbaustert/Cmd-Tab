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
}
