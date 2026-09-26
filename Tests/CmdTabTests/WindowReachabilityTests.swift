import CoreGraphics
import XCTest

@testable import CmdTab

/// Whether a pick can actually reach the window it names.
///
/// `SwitchTarget.canReach` exists to be asked twice — once by `focusWindow`, which declines the pick,
/// and once by the hover preview, which badges the thumbnail. The whole point is that the two answers
/// are the same answer, so the cases below are pinned rather than left to two call sites agreeing by
/// inspection. The bug they guard against is the one that prompted the split: a thumbnail that looks
/// live, takes a click, and silently does nothing.
///
/// The "app has a window on screen" input is the interesting one, and it is not a property of the
/// window being picked — it is a property of its *app*. A second display holding a single Space makes
/// it permanently true for every app with a window there, which is why this only ever showed up on a
/// multi-display desk.
final class WindowReachabilityTests: XCTestCase {
    private func state(window: UInt64, current: UInt64) -> SpaceMover.SpaceState {
        SpaceMover.SpaceState(windowSpace: window, currentSpace: current, display: "display-1")
    }

    /// In the Dock, so on no Space at all. `restoreFromDock` gets there without a Desktop change, so
    /// the app having something on screen is beside the point.
    func testAWindowOnNoSpaceIsAlwaysReachable() {
        XCTAssertTrue(SwitchTarget.canReach(state: nil, appHasWindowOnScreen: true))
        XCTAssertTrue(SwitchTarget.canReach(state: nil, appHasWindowOnScreen: false))
    }

    /// Already in front: no travel needed, so nothing can decline it.
    func testAWindowOnTheCurrentSpaceIsAlwaysReachable() {
        let showing = state(window: 4, current: 4)
        XCTAssertTrue(SwitchTarget.canReach(state: showing, appHasWindowOnScreen: true))
        XCTAssertTrue(SwitchTarget.canReach(state: showing, appHasWindowOnScreen: false))
    }

    /// The case that works: macOS travels on activation for an app with nothing on screen. Measured
    /// at ~600ms for an app one Desktop away.
    func testAnOffSpaceWindowIsReachableWhenTheAppHasNothingOnScreen() {
        XCTAssertTrue(
            SwitchTarget.canReach(state: state(window: 4, current: 1), appHasWindowOnScreen: false))
    }

    /// The reported bug. The app owns a window on the second display's only Space — so it is
    /// permanently "on screen" — and macOS will not travel for it. Measured three ways: plain
    /// activation, fronting the target window first, and minimizing the on-screen window so the app
    /// owned nothing anywhere. None moved the display.
    func testAnOffSpaceWindowIsUnreachableWhenTheAppHasAWindowOnScreen() {
        XCTAssertFalse(
            SwitchTarget.canReach(state: state(window: 4, current: 1), appHasWindowOnScreen: true))
    }

    /// The two callers must not diverge: `focusWindow` declines exactly when the strip badges.
    /// Enumerated rather than spot-checked, so a later edit to one branch shows up here.
    func testTheVerdictIsTotalOverEveryCombination() {
        for onScreen in [true, false] {
            for windowSpace: UInt64 in [1, 4] {
                let placement = state(window: windowSpace, current: 1)
                let declines = windowSpace != 1 && onScreen
                XCTAssertEqual(
                    SwitchTarget.canReach(state: placement, appHasWindowOnScreen: onScreen),
                    !declines,
                    "windowSpace=\(windowSpace) onScreen=\(onScreen)")
            }
        }
    }

    // MARK: - Finding the window in its app's Window menu

    /// The caller's title is tried first, and a match there never asks for the fresh reading —
    /// which is a round trip to the window server and, failing that, to the app.
    func testTheCallersTitleMatchesWithoutAskingForTheFreshOne() {
        var askedForFresh = false
        let match = SwitchTarget.windowMenuMatch(
            in: ["inbox", "drafts"],
            titles: [
                { "Drafts" },
                {
                    askedForFresh = true
                    return "Inbox"
                },
            ])
        XCTAssertEqual(match.index, 1)
        XCTAssertFalse(askedForFresh)
    }

    /// A tile's title is from the last refresh. When the window has moved on since — a browser
    /// on another tab — the stale one misses and the window server's current one finds it.
    func testAStaleTitleFallsBackToTheFreshOne() {
        let match = SwitchTarget.windowMenuMatch(
            in: ["new tab", "pull requests"], titles: [{ "Issues" }, { "Pull requests" }])
        XCTAssertEqual(match.index, 1)
        XCTAssertEqual(match.titlesTried, 2)
    }

    /// Normalized the way the menu's own titles are, so a status glyph the two readings disagree on
    /// does not stand between them.
    func testATitleIsNormalizedBeforeItIsCompared() {
        let match = SwitchTarget.windowMenuMatch(
            in: ["features and improvements"], titles: [{ "◐ Features and improvements" }])
        XCTAssertEqual(match.index, 0)
    }

    /// "Nothing to match with" and "matched nothing" are different lines in the log, and a title
    /// that comes back twice is one attempt, not two.
    func testNoTitleIsToldApartFromNoMatch() {
        let untitled = SwitchTarget.windowMenuMatch(in: ["a"], titles: [{ nil }, { "  " }])
        XCTAssertNil(untitled.index)
        XCTAssertEqual(untitled.titlesTried, 0)
        let missed = SwitchTarget.windowMenuMatch(in: ["a"], titles: [{ "b" }, { "B" }])
        XCTAssertNil(missed.index)
        XCTAssertEqual(missed.titlesTried, 1)
    }
}
