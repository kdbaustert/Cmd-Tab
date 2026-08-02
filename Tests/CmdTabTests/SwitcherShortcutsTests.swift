import CoreGraphics
import XCTest

@testable import CmdTab

/// Action bindings, and the trigger/action modifier collision that used to disable every action
/// silently while misrouting their keys into type-to-filter.
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

    /// The arrows carry the display move now that the Space move is gone (it could not work — see
    /// `SpaceMover`), so plain ⌥←/→ is free for it and the ⇧ qualifier binds nothing.
    func testArrowsAreBoundToTheDisplayMoveWithoutShift() {
        let shortcuts = SwitcherShortcuts.defaults
        XCTAssertEqual(shortcuts.action(code: 123, extra: option), .moveDisplayPrev)
        XCTAssertEqual(shortcuts.action(code: 124, extra: option), .moveDisplayNext)
        XCTAssertNil(shortcuts.action(code: 123, extra: option.union(shift)))
    }

    /// An arrow with no extra modifier must fall through to the navigation keys, or the panel
    /// loses ←/→ selection movement to a binding that was never pressed.
    func testBareArrowMatchesNoAction() {
        XCTAssertNil(SwitcherShortcuts.defaults.action(code: 123, extra: []))
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

    // MARK: - Defaults

    /// Every action has a binding out of the box; a nil here would show as a blank recorder button.
    func testEveryActionHasADefaultBinding() {
        for action in SwitcherAction.allCases {
            XCTAssertNotNil(SwitcherShortcuts.defaults.bindings[action], "\(action.title) unbound")
        }
    }

    /// Two actions on one chord means the later one can never fire. `action(code:extra:)` resolves
    /// it deterministically, but the shipped defaults should not need that tiebreak at all.
    func testDefaultBindingsDoNotCollide() {
        var seen: Set<String> = []
        for action in SwitcherAction.allCases {
            let binding = action.defaultShortcut
            let key = "\(binding.keyCode):\(binding.extras.rawValue)"
            XCTAssertTrue(seen.insert(key).inserted, "\(action.title) collides with an earlier default")
        }
    }

    /// The Space moves cannot work from an ordinary process (see `SpaceMover`) and shipped once
    /// anyway, logging success on every press. This is the guard against them coming back.
    func testNoSpaceMoveActionExists() {
        XCTAssertFalse(SwitcherAction.allCases.contains { $0.rawValue.contains("Desktop") })
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
