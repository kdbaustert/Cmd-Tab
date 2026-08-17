import CoreGraphics
import XCTest

@testable import CmdTab

/// Which of an app's window ids an app pick acts on.
///
/// `CGWindowList` is not a list of an app's windows and never was — it also carries the menu-bar
/// backing windows and the helper surfaces apps leave beside the real thing. The Space check that
/// used to be the whole filter does not separate them: a helper is layer 0, on screen, and placed on
/// a Space exactly like a real window, so the front-most one in z-order won the pick.
///
/// Measured on Alfred Preferences, which owns a 500×500 surface and one 2056×39 menu-bar backing per
/// display alongside its single real window. Picking it fronted a 720×520 surface that Accessibility
/// had never heard of: `_SLPSSetFrontProcessWithOptions` took the id and marked the process front —
/// menu bar swapped, `frontmostApplication` agreed — while ordering no window at all, leaving the
/// real window buried under the app the user was switching away from. The log signature is
/// `fronted=true raised=false`, `raised` being false for the same reason the pick failed: the id
/// named nothing in the Accessibility tree.
///
/// So Accessibility is the third input, and the cases below pin what it is allowed to decide —
/// including the one it must not, since Chromium and Electron hosts publish no windows at all until
/// they are active and an empty set has to mean "no opinion" rather than "no windows".
final class FrontWindowSelectionTests: XCTestCase {
    private func state(window: UInt64, current: UInt64) -> SpaceMover.SpaceState {
        SpaceMover.SpaceState(windowSpace: window, currentSpace: current, display: "display-1")
    }

    /// The reported bug: the phantom sorts ahead of the real window, and both are on the Desktop in
    /// front of the user. Accessibility is the only thing that tells them apart.
    func testAHelperSurfaceAheadOfTheRealWindowIsSkipped() {
        let phantom: CGWindowID = 28691
        let real: CGWindowID = 28680
        let placement = [phantom: state(window: 1, current: 1), real: state(window: 1, current: 1)]
        XCTAssertEqual(
            SwitchTarget.frontWindow(
                onScreen: [phantom, real], placement: placement, real: [real]),
            real)
    }

    /// Without the Accessibility set there is nothing to go on, and the old answer stands. This is
    /// the Chromium/Electron case, not a fallback worth improving: an app that publishes no windows
    /// until it is active must not be read as an app with none.
    func testAnEmptyAccessibilitySetLeavesEveryCandidateStanding() {
        let phantom: CGWindowID = 28691
        let real: CGWindowID = 28680
        let placement = [phantom: state(window: 1, current: 1), real: state(window: 1, current: 1)]
        XCTAssertEqual(
            SwitchTarget.frontWindow(onScreen: [phantom, real], placement: placement, real: []),
            phantom)
    }

    /// The Space check still does its own job: a real window on another Desktop is not "in front of
    /// the user", however far up the z-order it sits.
    func testAWindowOnAnotherDesktopIsNotHere() {
        let elsewhere: CGWindowID = 10
        let here: CGWindowID = 11
        let placement = [
            elsewhere: state(window: 4, current: 1), here: state(window: 1, current: 1),
        ]
        XCTAssertEqual(
            SwitchTarget.frontWindow(
                onScreen: [elsewhere, here], placement: placement, real: [elsewhere, here]),
            here)
    }

    /// An app whose only on-screen surface is a phantom has nothing in front of the user, and saying
    /// so is what sends the pick on to the Dock search — the branch that restores a minimized window.
    func testAnAppShowingOnlyAHelperSurfaceHasNothingHere() {
        let phantom: CGWindowID = 28691
        XCTAssertNil(
            SwitchTarget.frontWindow(
                onScreen: [phantom], placement: [phantom: state(window: 1, current: 1)],
                real: [28680]))
    }

    /// An unreadable placement map is the one case on-screen membership answers alone — but it is
    /// still no reason to front something that is not a window.
    func testAnUnreadablePlacementMapStillSkipsHelperSurfaces() {
        let phantom: CGWindowID = 28691
        let real: CGWindowID = 28680
        XCTAssertEqual(
            SwitchTarget.frontWindow(onScreen: [phantom, real], placement: [:], real: [real]),
            real)
    }

    /// The same rule on the other branch, which asks where an app's windows are rather than whether
    /// any is here: a phantom on some Desktop must not become a Desktop the pick travels to.
    func testThePlacedFrontWindowSkipsHelperSurfacesToo() {
        let phantom: CGWindowID = 28691
        let real: CGWindowID = 28680
        let placement = [phantom: state(window: 1, current: 1), real: state(window: 4, current: 1)]
        XCTAssertEqual(
            SwitchTarget.placedWindow(owned: [phantom, real], placement: placement, real: [real]),
            real)
    }

    /// Minimized windows are on no Space, so a nil here means the Dock is the last place to look —
    /// the distinction `restoreMinimized` is reached by.
    func testAnAppWhoseRealWindowsAreAllInTheDockPlacesNothing() {
        let phantom: CGWindowID = 28691
        let real: CGWindowID = 28680
        XCTAssertNil(
            SwitchTarget.placedWindow(
                owned: [phantom, real], placement: [phantom: state(window: 1, current: 1)],
                real: [real]))
    }
}
