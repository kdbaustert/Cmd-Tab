import CoreGraphics
import XCTest

@testable import CmdTab

/// The end-of-session rules. Every case here corresponds to a defect a review pass actually found —
/// the panel swallows every keystroke on the machine while it is up, so "when does it close" is the
/// single most consequential decision in the app, and it has regressed four passes running.
final class SessionReleaseTests: XCTestCase {
    private let command: CGEventFlags = .maskCommand
    private let option: CGEventFlags = .maskAlternate
    private let shift: CGEventFlags = .maskShift
    private let none: CGEventFlags = []

    private func session(
        sticky: Bool = false, cycled: Bool = false, held: CGEventFlags = .maskCommand
    ) -> SessionRelease {
        SessionRelease(isSticky: sticky, cycledWithTab: cycled, activeHeld: held)
    }

    // MARK: - Ordinary sessions

    func testHoldingTheTriggerKeepsTheSessionOpen() {
        XCTAssertFalse(session().shouldCommit(flags: command, isKeyUp: false))
    }

    func testReleasingTheTriggerCommits() {
        XCTAssertTrue(session().shouldCommit(flags: none, isKeyUp: false))
    }

    /// The only event-driven recovery when another head-inserted tap swallows the `flagsChanged`.
    /// Losing it left the panel holding the keyboard until the next 200 ms watchdog poll.
    func testANonStickySessionCommitsOnAReleaseSeenViaKeyUp() {
        XCTAssertTrue(session().shouldCommit(flags: none, isKeyUp: true))
    }

    /// Reaching for another modifier mid-session is not letting go of the trigger.
    func testExtraModifiersDoNotEndTheSession() {
        XCTAssertFalse(session().shouldCommit(flags: command.union(option), isKeyUp: false))
        XCTAssertFalse(session().shouldCommit(flags: command.union(shift), isKeyUp: false))
    }

    // MARK: - Stay open

    func testStickySessionStaysOpenOnRelease() {
        let sticky = session(sticky: true)
        XCTAssertTrue(sticky.staysOpenOnRelease)
        XCTAssertFalse(sticky.shouldCommit(flags: none, isKeyUp: false))
    }

    /// Tab-cycling opts back into the classic gesture: let go and you land on the app.
    func testTabCyclingReArmsCommitOnRelease() {
        let cycled = session(sticky: true, cycled: true)
        XCTAssertFalse(cycled.staysOpenOnRelease)
        XCTAssertTrue(cycled.shouldCommit(flags: none, isKeyUp: false))
    }

    /// The regression that made Stay open unusable: with the modifier already up, the key-up of the
    /// very Tab that armed cycling satisfied the release check and closed the panel after one step.
    /// A sticky session must never treat a keyUp as a release.
    func testStickySessionNeverCommitsOnAKeyUp() {
        XCTAssertFalse(session(sticky: true).shouldCommit(flags: none, isKeyUp: true))
        XCTAssertFalse(session(sticky: true, cycled: true).shouldCommit(flags: none, isKeyUp: true))
    }

    // MARK: - Menu-bar sessions

    /// Opened with no chord, so there is nothing to release. Every event looks like a release and
    /// none of them may close it — it ends on a click, Return or Escape.
    func testMenuBarSessionNeverCommitsOnRelease() {
        let menuBar = session(sticky: true, held: [])
        XCTAssertFalse(menuBar.shouldCommit(flags: none, isKeyUp: false))
        XCTAssertFalse(menuBar.shouldCommit(flags: none, isKeyUp: true))
    }

    /// Guards the same hole for a session that somehow reaches `cycledWithTab` without a chord:
    /// `staysOpenOnRelease` would be false, so only the empty-`activeHeld` check prevents a commit.
    func testMenuBarSessionSurvivesEvenIfCyclingIsSomehowArmed() {
        XCTAssertFalse(
            session(sticky: true, cycled: true, held: []).shouldCommit(flags: none, isKeyUp: false))
    }

    // MARK: - Arming

    func testTabArmsCyclingWhileTheChordIsHeld() {
        XCTAssertTrue(session(sticky: true).armsCycling(flags: command))
    }

    /// Tabbing after the chord is already up is navigation inside a stay-open session, not cycling.
    /// Arming there is what made the panel close on that key's own key-up.
    func testTabDoesNotArmCyclingOnceTheChordIsReleased() {
        XCTAssertFalse(session(sticky: true).armsCycling(flags: none))
    }

    func testMenuBarSessionNeverArmsCycling() {
        XCTAssertFalse(session(sticky: true, held: []).armsCycling(flags: none))
    }

    func testArmingToleratesExtraModifiers() {
        XCTAssertTrue(session(sticky: true).armsCycling(flags: command.union(shift)))
    }

    // MARK: - Multi-modifier triggers

    func testMultiModifierTriggerCommitsWhenEitherModifierIsReleased() {
        let held = command.union(option)
        let s = session(held: held)
        XCTAssertFalse(s.shouldCommit(flags: held, isKeyUp: false))
        XCTAssertTrue(s.shouldCommit(flags: command, isKeyUp: false))
        XCTAssertTrue(s.shouldCommit(flags: option, isKeyUp: false))
    }
}
