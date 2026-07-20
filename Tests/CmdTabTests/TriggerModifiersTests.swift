import CoreGraphics
import XCTest

@testable import CmdTab

/// The trigger arithmetic that decides when a session starts and — far more importantly — when it
/// ends. While a session is open the event tap swallows every key on the machine, so `stillHeld`
/// wrongly returning true is a system-wide keyboard lockout rather than a cosmetic bug.
final class TriggerModifiersTests: XCTestCase {
    private let command: CGEventFlags = .maskCommand
    private let option: CGEventFlags = .maskAlternate
    private let control: CGEventFlags = .maskControl
    private let shift: CGEventFlags = .maskShift

    // MARK: - opens

    func testOpensOnExactModifier() {
        XCTAssertTrue(TriggerModifiers.opens(command, held: command))
    }

    /// The reason the match is exact: ⌘⌥-Tab must not also fire the ⌘-Tab trigger, or a user who
    /// binds one gets the other as well.
    func testDoesNotOpenWhenExtraPrimaryModifierIsHeld() {
        XCTAssertFalse(TriggerModifiers.opens(command.union(option), held: command))
    }

    /// Shift is the reverse-direction modifier, not part of the chord's identity, so ⇧⌘-Tab still
    /// opens a ⌘-Tab trigger.
    func testShiftIsIgnoredWhenOpening() {
        XCTAssertTrue(TriggerModifiers.opens(command.union(shift), held: command))
    }

    func testDoesNotOpenOnWrongModifier() {
        XCTAssertFalse(TriggerModifiers.opens(control, held: command))
    }

    func testMultiModifierTriggerRequiresBoth() {
        let held = command.union(option)
        XCTAssertTrue(TriggerModifiers.opens(held, held: held))
        XCTAssertFalse(TriggerModifiers.opens(command, held: held))
    }

    // MARK: - stillHeld

    func testStillHeldWhileTriggerIsDown() {
        XCTAssertTrue(TriggerModifiers.stillHeld(command, held: command))
    }

    /// Releasing the trigger is the *only* thing that ends a session, so this returning false is
    /// what lets the panel go away and the keyboard come back.
    func testNotStillHeldOnceTriggerIsReleased() {
        XCTAssertFalse(TriggerModifiers.stillHeld([], held: command))
    }

    /// Pressing another modifier mid-session — reaching for ⌥ to fire an action — must not be read
    /// as releasing the trigger, which would commit the switch out from under the user.
    func testExtraModifiersDoNotEndTheSession() {
        XCTAssertTrue(TriggerModifiers.stillHeld(command.union(option), held: command))
        XCTAssertTrue(TriggerModifiers.stillHeld(command.union(option).union(shift), held: command))
    }

    /// A multi-modifier trigger ends as soon as *either* of its modifiers comes up; requiring both
    /// to be released would leave the session open on a half-released chord.
    func testMultiModifierTriggerEndsWhenEitherIsReleased() {
        let held = command.union(option)
        XCTAssertTrue(TriggerModifiers.stillHeld(held, held: held))
        XCTAssertFalse(TriggerModifiers.stillHeld(command, held: held))
        XCTAssertFalse(TriggerModifiers.stillHeld(option, held: held))
    }

    /// The lockout scenario, stated directly: no modifiers physically down must never read as held.
    /// This is what the session watchdog polls, and it is the last line of defence when the
    /// `.flagsChanged` announcing the release never arrives.
    func testEmptyFlagsNeverCountAsHeldForAnyTrigger() {
        for held in [command, option, control, command.union(option), command.union(control)] {
            XCTAssertFalse(
                TriggerModifiers.stillHeld([], held: held),
                "empty flags must end a session opened with \(held.rawValue)")
        }
    }

    /// Shift alone is not a trigger modifier, so it cannot keep a session alive on its own.
    func testShiftAloneDoesNotKeepSessionAlive() {
        XCTAssertFalse(TriggerModifiers.stillHeld(shift, held: command))
    }
}
