import CoreGraphics
import XCTest

@testable import CmdTab

/// Action bindings, and the trigger/action modifier collision that used to disable all eleven
/// actions silently while misrouting their keys into type-to-filter.
final class SwitcherShortcutsTests: XCTestCase {
    private let option: CGEventFlags = .maskAlternate
    private let control: CGEventFlags = .maskControl
    private let shift: CGEventFlags = .maskShift

    private func hotkey(_ modifiers: CGEventFlags, key: Int = 48) -> Hotkey {
        Hotkey(keyCode: key, modifierRaw: modifiers.rawValue)
    }

    // MARK: - Matching

    /// Exact modifier match is what keeps ⌥Q (quit) distinct from ⌥⇧Q (force-quit) — a subset match
    /// would make one of them shadow the other.
    func testExactModifierMatchSeparatesQuitFromForceQuit() {
        let shortcuts = SwitcherShortcuts.defaults
        XCTAssertEqual(shortcuts.action(code: 12, extra: option), .quit)
        XCTAssertEqual(shortcuts.action(code: 12, extra: option.union(shift)), .forceQuit)
    }

    func testUnboundCombinationMatchesNothing() {
        XCTAssertNil(SwitcherShortcuts.defaults.action(code: 12, extra: control))
        XCTAssertNil(SwitcherShortcuts.defaults.action(code: 999, extra: option))
    }

    /// Desktop move and display move share the arrow keys and are told apart only by ⇧.
    func testArrowBindingsAreSeparatedByShift() {
        let shortcuts = SwitcherShortcuts.defaults
        XCTAssertEqual(shortcuts.action(code: 123, extra: option), .moveDesktopPrev)
        XCTAssertEqual(shortcuts.action(code: 123, extra: option.union(shift)), .moveDisplayPrev)
    }

    // MARK: - Trigger conflicts

    /// The ordinary case: ⌘ is not an action modifier, so nothing is shadowed.
    func testCommandTriggerShadowsNothing() {
        XCTAssertTrue(SwitcherShortcuts.defaults.actionsShadowed(by: .commandTab).isEmpty)
    }

    /// Every default binding is built on ⌥, so a trigger holding ⌥ makes all of them unreachable.
    func testOptionTriggerShadowsEveryDefaultAction() {
        let shadowed = SwitcherShortcuts.defaults.actionsShadowed(
            by: hotkey([.maskCommand, .maskAlternate]))
        XCTAssertEqual(Set(shadowed), Set(SwitcherAction.allCases))
    }

    /// No default binding uses ⌃, so a ⌃-based trigger is fine out of the box.
    func testControlTriggerShadowsNothingByDefault() {
        XCTAssertTrue(
            SwitcherShortcuts.defaults
                .actionsShadowed(by: hotkey([.maskCommand, .maskControl])).isEmpty)
    }

    func testFreeModifierPrefersOptionThenControl() {
        XCTAssertEqual(SwitcherShortcuts.freeModifier(under: .commandTab), option)
        XCTAssertEqual(
            SwitcherShortcuts.freeModifier(under: hotkey([.maskCommand, .maskAlternate])), control)
        XCTAssertEqual(
            SwitcherShortcuts.freeModifier(under: hotkey([.maskCommand, .maskControl])), option)
    }

    /// A trigger claiming both leaves nowhere to move the bindings, so Settings has to reject it
    /// outright rather than offer a rebind.
    func testNoFreeModifierWhenTriggerClaimsBoth() {
        XCTAssertNil(
            SwitcherShortcuts.freeModifier(under: hotkey([.maskAlternate, .maskControl])))
    }

    // MARK: - Rebinding

    func testRebindingClearsTheConflict() {
        let trigger = hotkey([.maskCommand, .maskAlternate])
        let rebound = SwitcherShortcuts.defaults.rebindingShadowed(by: trigger, to: control)
        XCTAssertTrue(rebound.actionsShadowed(by: trigger).isEmpty)
    }

    /// ⇧ has to survive the move, or ⌥Q and ⌥⇧Q both collapse onto ⌃Q and one action becomes
    /// unreachable in a different way.
    func testRebindingPreservesShiftQualifier() {
        let trigger = hotkey([.maskCommand, .maskAlternate])
        let rebound = SwitcherShortcuts.defaults.rebindingShadowed(by: trigger, to: control)

        XCTAssertEqual(rebound.bindings[.quit]?.extras, control)
        XCTAssertEqual(rebound.bindings[.forceQuit]?.extras, control.union(shift))
        XCTAssertEqual(rebound.action(code: 12, extra: control), .quit)
        XCTAssertEqual(rebound.action(code: 12, extra: control.union(shift)), .forceQuit)
    }

    func testRebindingKeepsKeyCodes() {
        let trigger = hotkey([.maskCommand, .maskAlternate])
        let rebound = SwitcherShortcuts.defaults.rebindingShadowed(by: trigger, to: control)
        for action in SwitcherAction.allCases {
            XCTAssertEqual(
                rebound.bindings[action]?.keyCode, action.defaultShortcut.keyCode,
                "\(action.title) changed key")
        }
    }

    /// Nothing shadowed means nothing touched.
    func testRebindingIsANoOpWithoutAConflict() {
        let rebound = SwitcherShortcuts.defaults.rebindingShadowed(by: .commandTab, to: control)
        XCTAssertEqual(rebound, SwitcherShortcuts.defaults)
    }

    // MARK: - Hotkey

    func testIsCommandTabIgnoresShift() {
        XCTAssertTrue(Hotkey.commandTab.isCommandTab)
        XCTAssertTrue(hotkey([.maskCommand, .maskShift]).isCommandTab)
        XCTAssertFalse(hotkey([.maskCommand, .maskAlternate]).isCommandTab)
        XCTAssertFalse(hotkey([.maskCommand], key: 49).isCommandTab)
    }

    func testHeldModifiersMasksOutShift() {
        XCTAssertEqual(hotkey([.maskCommand, .maskShift]).heldModifiers, .maskCommand)
    }
}
