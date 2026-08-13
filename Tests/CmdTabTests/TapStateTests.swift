import CoreGraphics
import XCTest

@testable import CmdTab

/// The tap-state mirror: the value a tap running off the main run loop would decide from, and the
/// check that says whether it is telling the truth.
///
/// Worth testing on its own for the same reason `SessionRelease` is. The mirror exists to be read
/// from another thread, where being wrong is invisible — a stale flag routes one keystroke down the
/// wrong branch and leaves nothing behind. `verify` is what converts that into a log line, so
/// `verify` failing to notice is the defect that would matter most, and it is exactly what cannot be
/// caught by using the app.
final class TapStateTests: XCTestCase {

    // MARK: - Publishing

    func testAFreshMirrorHoldsDefaults() {
        XCTAssertEqual(TapStateMirror().current, TapState())
    }

    func testPublishingReplacesWhatIsRead() {
        let mirror = TapStateMirror()
        var state = TapState()
        state.isVisible = true
        state.hasQuery = true
        mirror.publish(state)
        XCTAssertEqual(mirror.current, state)
    }

    func testTheLastPublishWins() {
        let mirror = TapStateMirror()
        var first = TapState()
        first.armed = true
        var second = TapState()
        second.isVisible = true
        mirror.publish(first)
        mirror.publish(second)
        XCTAssertEqual(mirror.current, second)
    }

    // MARK: - Verification

    func testAgreementIsNotCountedAsAMismatch() {
        let mirror = TapStateMirror()
        var state = TapState()
        state.isVisible = true
        mirror.publish(state)
        mirror.verify(against: state)
        XCTAssertEqual(mirror.mismatches, 0)
    }

    func testAStalePublishIsCaught() {
        let mirror = TapStateMirror()
        mirror.publish(TapState())
        var live = TapState()
        live.isVisible = true
        mirror.verify(against: live)
        XCTAssertEqual(mirror.mismatches, 1)
    }

    func testEveryMismatchIsCounted() {
        let mirror = TapStateMirror()
        mirror.publish(TapState())
        var live = TapState()
        live.armed = true
        mirror.verify(against: live)
        mirror.verify(against: live)
        XCTAssertEqual(mirror.mismatches, 2)
    }

    /// Each field in turn. A mirror that noticed some drifts and not others would be worse than none
    /// at all — it would read as proof the publishing is complete while covering only part of it.
    func testEveryFieldIsCompared() {
        let mutations: [(String, (inout TapState) -> Void)] = [
            ("isVisible", { $0.isVisible = true }),
            ("armed", { $0.armed = true }),
            ("pendingSameApp", { $0.pendingSameApp = true }),
            ("isSticky", { $0.isSticky = true }),
            ("activeHeld", { $0.activeHeldRaw = CGEventFlags.maskAlternate.rawValue }),
            ("hotkey", { $0.hotkey = Hotkey(keyCode: 12, modifierRaw: 0) }),
            ("sameAppHotkey", { $0.sameAppHotkey = Hotkey(keyCode: 50, modifierRaw: 0) }),
            (
                "activations",
                {
                    $0.activations = DirectActivations(entries: [
                        DirectActivation(bundleID: "com.example.app", hotkey: .commandTab)
                    ])
                }
            ),
            ("actionsEnabled", { $0.actionsEnabled = true }),
            ("isAppActive", { $0.isAppActive = true }),
            ("hasQuery", { $0.hasQuery = true }),
        ]
        for (name, mutate) in mutations {
            let mirror = TapStateMirror()
            mirror.publish(TapState())
            var live = TapState()
            mutate(&live)
            mirror.verify(against: live)
            XCTAssertEqual(
                mirror.mismatches, 1,
                "a drift in \(name) went unnoticed — the mirror would be stale in silence")
        }
    }

    // MARK: - Derived values

    /// The controller derives `release` from the same two fields rather than storing it. The mirror
    /// has to derive it the same way, or a session's end-of-life rules would differ depending on
    /// which side of the tap asked.
    func testReleaseIsDerivedTheSameWayTheControllerDerivesIt() {
        var state = TapState()
        state.isSticky = true
        state.activeHeldRaw = CGEventFlags.maskAlternate.rawValue
        XCTAssertEqual(
            state.release,
            SessionRelease(isSticky: true, activeHeld: .maskAlternate))
    }

    func testActiveHeldSurvivesTheRoundTripThroughRawBits() {
        var state = TapState()
        let held: CGEventFlags = [.maskCommand, .maskShift]
        state.activeHeldRaw = held.rawValue
        XCTAssertEqual(state.activeHeld, held)
    }
}
