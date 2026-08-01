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
        let match = scoped.scope(code: 48, flags: ctrlCmd)
        XCTAssertEqual(match?.scope, .minimized)
        // The session ends when *these* come up, so the trigger has to hand its own modifiers over
        // rather than letting the session assume ⌘.
        XCTAssertEqual(match?.held, ctrlCmd)
    }

    /// Shift is the reverse-direction modifier for a held trigger, so ⇧ must still open it.
    func testScopedTriggerOpensWithShiftHeld() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "x", hotkey: hotkey(48, ctrlCmd), scope: .allWindows)
        ]
        XCTAssertNotNil(scoped.scope(code: 48, flags: ctrlCmd.union(.maskShift)))
    }

    func testUnboundScopedTriggerNeverMatches() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "x", hotkey: Hotkey(keyCode: -1, modifierRaw: 0), scope: .frontApp)
        ]
        XCTAssertNil(scoped.scope(code: -1, flags: []))
    }

    func testScopedTriggersResolveInOrder() {
        var scoped = ScopedTriggers()
        scoped.triggers = [
            ScopedTrigger(id: "first", hotkey: hotkey(48, ctrlCmd), scope: .minimized),
            ScopedTrigger(id: "second", hotkey: hotkey(48, ctrlCmd), scope: .allWindows),
        ]
        XCTAssertEqual(scoped.scope(code: 48, flags: ctrlCmd)?.scope, .minimized)
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
