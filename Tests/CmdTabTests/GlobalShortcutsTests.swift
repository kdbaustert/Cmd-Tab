import CoreGraphics
import XCTest

@testable import CmdTab

/// Matching for the three kinds of global chord added alongside tiling: direct activation, the
/// all-windows pair, and scoped triggers.
final class GlobalShortcutsTests: XCTestCase {
    private let ctrlCmd = CGEventFlags.maskControl.union(.maskCommand)

    private func hotkey(_ code: Int, _ flags: CGEventFlags) -> Hotkey {
        Hotkey(keyCode: code, modifierRaw: flags.rawValue)
    }

    // MARK: - Direct activation

    func testDirectActivationMatchesItsChord() {
        var activations = DirectActivations()
        activations.entries = [
            DirectActivation(bundleID: "com.apple.Safari", hotkey: hotkey(1, ctrlCmd))
        ]
        XCTAssertEqual(activations.bundleID(code: 1, flags: ctrlCmd), "com.apple.Safari")
    }

    /// Exact match, so an extra modifier falls through to the app in front rather than jumping.
    func testDirectActivationIgnoresAnExtraModifier() {
        var activations = DirectActivations()
        activations.entries = [
            DirectActivation(bundleID: "com.apple.Safari", hotkey: hotkey(1, ctrlCmd))
        ]
        XCTAssertNil(activations.bundleID(code: 1, flags: ctrlCmd.union(.maskAlternate)))
    }

    /// An entry added but never bound carries the -1 sentinel; nothing may match it, or a stray
    /// keypress with no modifiers would activate an app.
    func testUnboundDirectActivationNeverMatches() {
        var activations = DirectActivations()
        activations.entries = [
            DirectActivation(bundleID: "com.apple.Safari", hotkey: Hotkey(keyCode: -1, modifierRaw: 0))
        ]
        XCTAssertNil(activations.bundleID(code: -1, flags: []))
    }

    func testDirectActivationReportsDuplicateChords() {
        var activations = DirectActivations()
        activations.entries = [
            DirectActivation(bundleID: "a", hotkey: hotkey(1, ctrlCmd)),
            DirectActivation(bundleID: "b", hotkey: hotkey(1, ctrlCmd)),
        ]
        XCTAssertEqual(activations.conflicts(with: "a"), ["b"])
        // The earlier entry wins, every time — order is what makes that deterministic.
        XCTAssertEqual(activations.bundleID(code: 1, flags: ctrlCmd), "a")
    }

    // MARK: - All windows

    func testAllWindowsChordsAreUnboundByDefault() {
        let shortcuts = AllWindowsShortcuts()
        XCTAssertNil(shortcuts.action(code: 1, flags: ctrlCmd))
    }

    func testAllWindowsDistinguishesHideFromShow() {
        var shortcuts = AllWindowsShortcuts()
        shortcuts.hideAll = hotkey(1, ctrlCmd)
        shortcuts.showAll = hotkey(2, ctrlCmd)
        switch shortcuts.action(code: 1, flags: ctrlCmd) {
        case .hide: break
        default: XCTFail("expected hide")
        }
        switch shortcuts.action(code: 2, flags: ctrlCmd) {
        case .show: break
        default: XCTFail("expected show")
        }
    }

    // MARK: - Scoped triggers

    func testScopedTriggerMatchesAndCarriesItsHeldModifiers() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "x", hotkey: hotkey(48, ctrlCmd), scope: .minimized)
        ]
        let match = scoped.trigger(code: 48, flags: ctrlCmd)
        XCTAssertEqual(match?.scope, .minimized)
        // The session ends when *these* come up, so the trigger has to hand its own modifiers over
        // rather than letting the session assume ⌘.
        XCTAssertEqual(match?.hotkey.heldModifiers, ctrlCmd)
    }

    /// Shift is the reverse-direction modifier for a held trigger, so ⇧ must still open it.
    func testScopedTriggerOpensWithShiftHeld() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "x", hotkey: hotkey(48, ctrlCmd), scope: .allWindows)
        ]
        XCTAssertNotNil(scoped.trigger(code: 48, flags: ctrlCmd.union(.maskShift)))
    }

    func testUnboundScopedTriggerNeverMatches() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "x", hotkey: Hotkey(keyCode: -1, modifierRaw: 0), scope: .frontApp)
        ]
        XCTAssertNil(scoped.trigger(code: -1, flags: []))
    }

    func testScopedTriggersResolveInOrder() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "first", hotkey: hotkey(48, ctrlCmd), scope: .minimized),
            ScopedTrigger(id: "second", hotkey: hotkey(48, ctrlCmd), scope: .allWindows),
        ]
        XCTAssertEqual(scoped.trigger(code: 48, flags: ctrlCmd)?.scope, .minimized)
    }

    // MARK: - Scoped trigger presets

    /// A legacy four-element row — every config written before presets existed — parses with
    /// every preset inheriting.
    func testLegacyScopedTriggerRowParsesWithDefaultOverrides() {
        let scoped = ScopedTriggers(stored: [["x", 48, 1_048_840, "minimized"] as [Any]])
        XCTAssertEqual(scoped.triggers.count, 1)
        XCTAssertTrue(scoped.triggers[0].overrides.isDefault)
    }

    func testScopedTriggerOverridesRoundTripThroughTheirStoredForm() {
        var overrides = ScopedTrigger.Overrides()
        overrides.layout = .list
        overrides.panelPosition = .cursor
        overrides.sortOrder = .alphabetical
        overrides.groupWindowsByApp = false
        overrides.windowThumbnailTiles = true
        overrides.staysOpen = true
        XCTAssertEqual(ScopedTrigger.Overrides(stored: overrides.stored), overrides)
    }

    /// Untouched presets serialize to nothing at all, which is what keeps the stored row in the
    /// four-element shape a pre-preset build still reads (its parser requires exactly four).
    func testDefaultOverridesSerializeToAnEmptyDictionary() {
        XCTAssertTrue(ScopedTrigger.Overrides().stored.isEmpty)
    }

    func testFiveElementRowCarriesItsOverrides() {
        let scoped = ScopedTriggers(stored: [
            ["x", 48, 1_048_840, "allWindows", ["layout": "list", "staysOpen": true]] as [Any]
        ])
        XCTAssertEqual(scoped.triggers[0].overrides.layout, .list)
        XCTAssertTrue(scoped.triggers[0].overrides.staysOpen)
        XCTAssertNil(scoped.triggers[0].overrides.sortOrder)
    }

    /// Value-tolerant the way the row parser is row-tolerant: a hand-edited or newer-build value
    /// falls back to inheriting; the trigger and its other presets survive.
    func testMalformedOverrideValuesCostOnlyThemselves() {
        let scoped = ScopedTriggers(stored: [
            ["x", 48, 1_048_840, "allWindows",
             ["layout": "hexagonal", "sortOrder": 7, "staysOpen": true]] as [Any]
        ])
        XCTAssertEqual(scoped.triggers.count, 1)
        XCTAssertNil(scoped.triggers[0].overrides.layout)
        XCTAssertNil(scoped.triggers[0].overrides.sortOrder)
        XCTAssertTrue(scoped.triggers[0].overrides.staysOpen)
    }

    // MARK: - Config file

    /// The path is what someone puts in a dotfiles repo, so it must not drift.
    @MainActor
    func testConfigFileLivesUnderDotConfig() {
        XCTAssertTrue(ConfigFile.url.path.hasSuffix("/cmdtab/config.json"))
    }

    @MainActor
    func testConfigDisplayPathIsAbbreviated() {
        XCTAssertFalse(ConfigFile.displayPath.hasPrefix("/Users/"))
    }
}
