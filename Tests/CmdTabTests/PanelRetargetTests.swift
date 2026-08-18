import CoreGraphics
import XCTest

@testable import CmdTab

/// Which screen-parameter notifications the switcher's panels have to answer.
///
/// `didChangeScreenParametersNotification` fires for the Dock sliding in and the menu bar hiding as
/// readily as for a monitor being unplugged, so the predicate filtering them apart decides two
/// things at once: whether an open panel is moved out from under the user's selection, and whether
/// the display badges — numbered against `NSScreen.screens` when each target was built — ever get
/// renumbered.
///
/// Pure over the readings on purpose. The case that matters most is a second display arriving, and a
/// test cannot arrange one.
final class PanelRetargetTests: XCTestCase {
    private let laptop: CGDirectDisplayID = 1
    private let external: CGDirectDisplayID = 2

    private func retarget(
        _ screens: PanelScreens, desk: [CGDirectDisplayID?], primary: CGDirectDisplayID?,
        lastDesk: [CGDirectDisplayID?], lastAim: [CGDirectDisplayID?]
    ) -> Bool {
        PanelGroup.shouldRetarget(
            screens, desk: desk, primary: primary, lastDesk: lastDesk, lastAim: lastAim)
    }

    // MARK: - The Dock and the menu bar, which move no display

    /// The reason the guard exists: acting on these moves an unpinned panel onto whatever display
    /// the cursor is on, mid-selection.
    func testNothingMovedIsIgnoredUnderEverySetting() {
        for screens in PanelScreens.allCases {
            let aim: [CGDirectDisplayID?] = screens == .allDisplays
                ? [laptop, external] : (screens == .mainDisplay ? [laptop] : [nil])
            XCTAssertFalse(
                retarget(
                    screens, desk: [laptop, external], primary: laptop,
                    lastDesk: [laptop, external], lastAim: aim),
                "\(screens) reacted to a notification that changed nothing")
        }
    }

    // MARK: - The desk moved

    /// The regression, and it is the *default* setting. `.automatic` aims at `[nil]` whatever the
    /// desk does, so a check on the aim alone can never fire here — the panel stayed at coordinates
    /// nothing covered and the display badges were never renumbered.
    func testAutomaticNoticesADisplayGoingAway() {
        XCTAssertTrue(
            retarget(
                .automatic, desk: [laptop], primary: laptop,
                lastDesk: [laptop, external], lastAim: [nil]))
    }

    func testAutomaticNoticesADisplayArriving() {
        XCTAssertTrue(
            retarget(
                .automatic, desk: [laptop, external], primary: laptop,
                lastDesk: [laptop], lastAim: [nil]))
    }

    /// Membership is unchanged and the badges are still stale: they are numbered by *position* in
    /// `NSScreen.screens`, so swapping two monitors renumbers every one of them.
    func testRearrangingTheSameDisplaysCounts() {
        XCTAssertTrue(
            retarget(
                .automatic, desk: [external, laptop], primary: external,
                lastDesk: [laptop, external], lastAim: [nil]))
    }

    func testAllDisplaysNoticesADisplayArriving() {
        XCTAssertTrue(
            retarget(
                .allDisplays, desk: [laptop, external], primary: laptop,
                lastDesk: [laptop], lastAim: [laptop]))
    }

    // MARK: - The aim moved

    /// Dragging the menu bar to the other monitor in Displays settings: the same displays are
    /// attached, but `.mainDisplay` now points at a different one. A desk-only check would leave the
    /// panel pinned to the display that is no longer primary.
    func testMainDisplayNoticesThePrimaryMoving() {
        XCTAssertTrue(
            retarget(
                .mainDisplay, desk: [laptop, external], primary: external,
                lastDesk: [laptop, external], lastAim: [laptop]))
    }

    /// The same move under `.automatic` aims at nothing in particular, so there is nothing to
    /// re-pin — and the desk is untouched, so this is one to sit out.
    func testAutomaticIgnoresThePrimaryMoving() {
        XCTAssertFalse(
            retarget(
                .automatic, desk: [laptop, external], primary: external,
                lastDesk: [laptop, external], lastAim: [nil]))
    }

    // MARK: - Degenerate desks

    /// Every display asleep. Not a state to keep panels aimed at whatever they were aimed at before.
    func testAnEmptyDeskCounts() {
        XCTAssertTrue(
            retarget(.automatic, desk: [], primary: nil, lastDesk: [laptop], lastAim: [nil]))
    }

    /// A display whose `NSScreenNumber` cannot be read arrives as a nil id. It is still a display,
    /// and its arrival is still a change.
    func testAnUnreadableDisplayIsStillADisplay() {
        XCTAssertTrue(
            retarget(
                .allDisplays, desk: [laptop, nil], primary: laptop,
                lastDesk: [laptop], lastAim: [laptop]))
    }

    /// A fresh group has stamped nothing yet, so the first notification is always worth answering.
    func testAnUnstampedSessionAlwaysRetargets() {
        XCTAssertTrue(
            retarget(.automatic, desk: [laptop], primary: laptop, lastDesk: [], lastAim: []))
    }
}
