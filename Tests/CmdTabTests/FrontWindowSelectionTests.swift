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

    // MARK: - Which apps own a window at all

    /// One row of the window server's list, carrying only what `windowOwners` reads. Small by
    /// default, so a test that is not about size is not decided by it.
    private func row(
        pid: pid_t, id: CGWindowID, layer: Int = 0, onScreen: Bool = false,
        frame: CGRect = CGRect(x: 0, y: 829, width: 64, height: 64)
    ) -> [String: Any] {
        var row: [String: Any] = [
            kCGWindowOwnerPID as String: pid, kCGWindowNumber as String: id,
            kCGWindowLayer as String: layer,
            kCGWindowBounds as String: [
                "X": frame.minX, "Y": frame.minY, "Width": frame.width, "Height": frame.height,
            ],
        ]
        // Absent rather than false when off screen, which is how the window server reports it.
        if onScreen { row[kCGWindowIsOnscreen as String] = true }
        return row
    }

    /// A menu-bar backing window as measured: full width, 39pt tall, at the top of the display.
    private let menuBarBacking = CGRect(x: 0, y: 0, width: 2056, height: 39)

    /// A Ghostty window as measured: the full visible area of a 2056×1329 display.
    private let ghosttyWindow = CGRect(x: 16, y: 55, width: 2024, height: 1258)

    /// The measured case behind "hide apps with no windows" hiding nothing: a Finder with every
    /// window closed still owns four menu-bar backings and a 64×64 surface, all layer 0. None is on
    /// screen, on a Space, or window-sized, so none makes Finder an owner.
    func testAnAppOwningOnlyPhantomsOwnsNoWindow() {
        let finder: pid_t = 400
        let backings = (56...59).map {
            row(pid: finder, id: CGWindowID($0), frame: menuBarBacking)
        }
        let info = backings + [row(pid: finder, id: 67)]
        XCTAssertEqual(TargetProvider.windowOwners(in: info, placed: []), [])
    }

    /// On screen is enough, and so is placed on a Space the user is not looking at — the second is
    /// what keeps an app whose windows are all on another Desktop in the list. A small window that
    /// is neither does not count.
    func testAWindowOnScreenOrOnAnotherDesktopMakesItsAppAnOwner() {
        let info = [
            row(pid: 1, id: 10, onScreen: true),
            row(pid: 2, id: 20),
            row(pid: 3, id: 30),
        ]
        XCTAssertEqual(TargetProvider.windowOwners(in: info, placed: [20]), [1, 2])
    }

    /// The measured Ghostty: one real window placed on Desktop 1, and a second at the same frame
    /// that the Space query placed nowhere — off screen, not minimized, named in its Window menu.
    /// The second on its own still has to keep Ghostty in the list, since it is what is left when
    /// the placed one closes; its size is what vouches for it. Its menu-bar backings do not.
    func testAnUnplacedWindowSizedWindowStillMakesItsAppAnOwner() {
        let ghostty: pid_t = 2657
        let info = [row(pid: ghostty, id: 146, frame: ghosttyWindow)]
            + (142...145).map { row(pid: ghostty, id: CGWindowID($0), frame: menuBarBacking) }
        XCTAssertEqual(TargetProvider.windowOwners(in: info, placed: []), [ghostty])
    }

    /// The floor is the drag minimum on each axis, inclusive: exactly that size counts, a point
    /// short on either axis does not.
    func testTheSizeFloorIsTheDragMinimum() {
        let floor = MouseDragGeometry.minimumSize
        let exact = CGRect(x: 0, y: 0, width: floor.width, height: floor.height)
        XCTAssertEqual(
            TargetProvider.windowOwners(in: [row(pid: 1, id: 1, frame: exact)], placed: []), [1])
        let short = [
            row(pid: 2, id: 2, frame: CGRect(x: 0, y: 0, width: floor.width - 1, height: 500)),
            row(pid: 3, id: 3, frame: CGRect(x: 0, y: 0, width: 500, height: floor.height - 1)),
        ]
        XCTAssertEqual(TargetProvider.windowOwners(in: short, placed: []), [])
    }

    /// Only layer 0 counts: a panel or menu on screen is not a window the app can be switched to.
    func testAWindowAboveLayerZeroDoesNotCount() {
        let info = [row(pid: 1, id: 10, layer: 3, onScreen: true, frame: ghosttyWindow)]
        XCTAssertEqual(TargetProvider.windowOwners(in: info, placed: [10]), [])
    }
}
