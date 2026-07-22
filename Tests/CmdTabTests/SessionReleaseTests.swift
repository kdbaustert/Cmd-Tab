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
        sticky: Bool = false, held: CGEventFlags = .maskCommand
    ) -> SessionRelease {
        SessionRelease(isSticky: sticky, activeHeld: held)
    }

    // MARK: - Ordinary sessions

    func testHoldingTheTriggerKeepsTheSessionOpen() {
        XCTAssertFalse(session().shouldCommit(flags: command))
    }

    func testReleasingTheTriggerCommits() {
        XCTAssertTrue(session().shouldCommit(flags: none))
    }

    /// Reaching for another modifier mid-session is not letting go of the trigger.
    func testExtraModifiersDoNotEndTheSession() {
        XCTAssertFalse(session().shouldCommit(flags: command.union(option)))
        XCTAssertFalse(session().shouldCommit(flags: command.union(shift)))
    }

    // MARK: - Stay open

    func testStickySessionStaysOpenOnRelease() {
        let sticky = session(sticky: true)
        XCTAssertTrue(sticky.staysOpenOnRelease)
        XCTAssertFalse(sticky.shouldCommit(flags: none))
    }

    /// The point of the whole file. Tab-cycling used to re-arm commit-on-release, so ⌘-Tab, Tab,
    /// release — the way anyone actually uses a switcher — closed the panel and left nothing for a
    /// bare Tab to cycle. Stay open now means stay open, whatever was pressed on the way there.
    func testTabCyclingDoesNotEndAStayOpenSession() {
        let sticky = session(sticky: true)
        // ⌘-Tab: chord down, so Tab is the cycle and nothing commits.
        XCTAssertFalse(sticky.tabCommits(flags: command))
        XCTAssertFalse(sticky.shouldCommit(flags: command))
        // Tab again, still held. This is the press that used to re-arm commit-on-release.
        XCTAssertFalse(sticky.tabCommits(flags: command))
        // ⌘ up. Every event from here looks like a release, since the modifier really is up, and none
        // of them may close the session — that is the whole of Stay open.
        XCTAssertFalse(sticky.shouldCommit(flags: none))
        XCTAssertFalse(sticky.shouldCommit(flags: none))
        // The session survived, so a bare Tab still has something to act on: now the go key.
        XCTAssertTrue(sticky.tabCommits(flags: none))
    }

    // MARK: - Tab

    /// Held chord: Tab is the cycle, exactly as the native switcher behaves.
    func testTabCyclesWhileTheChordIsHeld() {
        XCTAssertFalse(session(sticky: true).tabCommits(flags: command))
        XCTAssertFalse(session(sticky: true).tabCommits(flags: command.union(shift)))
    }

    /// Chord up: nothing is left to release, so Tab is what takes you to the app.
    func testTabCommitsOnceTheChordIsReleased() {
        XCTAssertTrue(session(sticky: true).tabCommits(flags: none))
    }

    /// No chord to hold at all — `stillHeld` says an empty chord is always held, so this needs its
    /// own answer or Tab would be inert for the whole session.
    func testTabCommitsInAMenuBarSession() {
        XCTAssertTrue(session(sticky: true, held: []).tabCommits(flags: none))
        XCTAssertTrue(session(sticky: true, held: []).tabCommits(flags: command))
    }

    /// ⇧-Tab steps backwards everywhere else, and it is the *only* keyboard way to reverse-cycle once
    /// the chord is up. Promoting it to the go key along with plain Tab left an overshoot with no way
    /// back, in exactly the sessions that stay up long enough to overshoot.
    func testShiftTabNeverCommits() {
        XCTAssertFalse(session(sticky: true).tabCommits(flags: shift))
        XCTAssertFalse(session(sticky: true).tabCommits(flags: command.union(shift)))
        // Even with no chord to release at all.
        XCTAssertFalse(session(sticky: true, held: []).tabCommits(flags: shift))
    }

    // MARK: - Menu-bar sessions

    /// Opened with no chord, so there is nothing to release. Every event looks like a release and
    /// none of them may close it — it ends on a click, Return or Escape.
    func testMenuBarSessionNeverCommitsOnRelease() {
        XCTAssertFalse(session(sticky: true, held: []).shouldCommit(flags: none))
        // Even were it somehow non-sticky, the empty chord is what has to save it.
        XCTAssertFalse(session(held: []).shouldCommit(flags: none))
    }

    // MARK: - Multi-modifier triggers

    func testMultiModifierTriggerCommitsWhenEitherModifierIsReleased() {
        let held = command.union(option)
        let s = session(held: held)
        XCTAssertFalse(s.shouldCommit(flags: held))
        XCTAssertTrue(s.shouldCommit(flags: command))
        XCTAssertTrue(s.shouldCommit(flags: option))
    }
}
