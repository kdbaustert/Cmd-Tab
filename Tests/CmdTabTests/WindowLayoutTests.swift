import CoreGraphics
import XCTest

@testable import CmdTab

/// Saved layouts: turning absolute frames into display-relative ones and back, and re-identifying a
/// saved window among the live ones. Both are the parts that have to survive the desk changing.
final class WindowLayoutTests: XCTestCase {
    /// The built-in display, carrying the menu bar — so this is the one a window whose own display
    /// is gone falls back to.
    private let laptop = WindowTiler.DisplayArea(
        id: "laptop", area: CGRect(x: 0, y: 0, width: 1440, height: 900), isPrimary: true)
    private let external = WindowTiler.DisplayArea(
        id: "external", area: CGRect(x: 1440, y: 0, width: 2560, height: 1440))
    /// The same physical monitor at a lower resolution — same id, different size.
    private let externalSmaller = WindowTiler.DisplayArea(
        id: "external", area: CGRect(x: 1440, y: 0, width: 1920, height: 1080))

    private func saved(
        _ title: String, index: Int = 0, app: String = "com.example.App",
        display: String? = "laptop", frame: CGRect
    ) -> LayoutWindow {
        LayoutWindow(
            bundleID: app, title: title, index: index, displayID: display, relativeFrame: frame)
    }

    private let rightHalf = CGRect(x: 0.5, y: 0, width: 0.5, height: 1)

    // MARK: - Capture geometry

    func testAbsoluteFrameBecomesAFractionOfItsDisplay() {
        let frame = CGRect(x: 720, y: 0, width: 720, height: 900)  // right half of the laptop
        let placed = LayoutGeometry.relative(frame, displays: [laptop, external])
        XCTAssertEqual(placed?.displayID, "laptop")
        XCTAssertEqual(placed?.relativeFrame, rightHalf)
    }

    /// A window on the second display must be recorded against *that* display, with coordinates
    /// local to it — not as a global x of 2720.
    func testFrameOnASecondDisplayIsRelativeToThatDisplay() {
        let frame = CGRect(x: 2720, y: 0, width: 1280, height: 1440)  // right half of the external
        let placed = LayoutGeometry.relative(frame, displays: [laptop, external])
        XCTAssertEqual(placed?.displayID, "external")
        XCTAssertEqual(placed?.relativeFrame, rightHalf)
    }

    /// A window straddling two monitors belongs to the one it is mostly on, the same rule the tiler
    /// uses to pick a screen.
    func testStraddlingWindowBelongsToTheDisplayItIsMostlyOn() {
        let frame = CGRect(x: 1340, y: 0, width: 400, height: 500)  // 100pt on laptop, 300 external
        XCTAssertEqual(
            LayoutGeometry.relative(frame, displays: [laptop, external])?.displayID, "external")
    }

    // MARK: - Restore geometry

    func testFractionBecomesAbsoluteOnTheSameDisplay() {
        let entry = saved("Notes", display: "external", frame: rightHalf)
        let frame = LayoutGeometry.absolute(entry, displays: [laptop, external])
        XCTAssertEqual(frame, CGRect(x: 2720, y: 0, width: 1280, height: 1440))
    }

    /// The point of storing fractions. The same monitor at a lower resolution puts the window in the
    /// same *place*, where an absolute frame would have left it in the wrong one while still looking
    /// plausible enough to pass an on-screen check.
    func testSameDisplayAtALowerResolutionKeepsTheRelativePlace() {
        let entry = saved("Notes", display: "external", frame: rightHalf)
        let frame = LayoutGeometry.absolute(entry, displays: [laptop, externalSmaller])
        XCTAssertEqual(frame, CGRect(x: 2400, y: 0, width: 960, height: 1080))
    }

    /// Undocking. The old design dropped these windows; this one puts them somewhere the user can
    /// actually see, in the place they held on the monitor that is gone.
    func testMissingDisplayFallsBackToThePrimaryOne() {
        let entry = saved("Notes", display: "external", frame: rightHalf)
        let frame = LayoutGeometry.absolute(entry, displays: [laptop])
        XCTAssertEqual(frame, CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    /// "Primary" means the display with the menu bar, not the first one in the list. The list is in
    /// `NSScreen.screens` order so that callers pairing it with a screen index stay aligned, and a
    /// desk can perfectly well report an external monitor first — where taking index 0 would drop
    /// the window onto exactly the monitor the user has just unplugged the *other* one to avoid.
    func testMissingDisplayFallsBackToTheMenuBarDisplayNotTheFirstOne() {
        let secondExternal = WindowTiler.DisplayArea(
            id: "second", area: CGRect(x: -1920, y: 0, width: 1920, height: 1080))
        let entry = saved("Notes", display: "external", frame: rightHalf)
        let frame = LayoutGeometry.absolute(entry, displays: [secondExternal, laptop])
        XCTAssertEqual(frame, CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    /// A window whose display had no readable UUID when it was captured is stored with no display at
    /// all, which cannot be told apart from one whose display has since gone. It takes the same
    /// fallback rather than landing wherever the list happens to start.
    func testAWindowSavedWithNoDisplayTakesTheSameFallback() {
        let entry = saved("Notes", display: nil, frame: rightHalf)
        let frame = LayoutGeometry.absolute(entry, displays: [external, laptop])
        XCTAssertEqual(frame, CGRect(x: 720, y: 0, width: 720, height: 900))
    }

    /// A window captured hanging off the edge would come back proportionally further off a smaller
    /// screen, which is how a restore loses a window on a laptop.
    func testAnOversizedFractionIsClampedOntoTheDisplay() {
        let entry = saved("Wide", frame: CGRect(x: 0.8, y: 0, width: 0.5, height: 1))
        let frame = LayoutGeometry.absolute(entry, displays: [laptop])
        XCTAssertEqual(frame?.maxX, 1440)
        XCTAssertEqual(frame?.width, 720)
    }

    func testAFrameBiggerThanTheDisplayIsShrunkToFit() {
        let entry = saved("Huge", frame: CGRect(x: 0, y: 0, width: 2, height: 2))
        XCTAssertEqual(LayoutGeometry.absolute(entry, displays: [laptop])?.size,
                       CGSize(width: 1440, height: 900))
    }

    func testNoDisplaysPlacesNothing() {
        XCTAssertNil(LayoutGeometry.absolute(saved("A", frame: rightHalf), displays: []))
    }

    // MARK: - Matching

    private func live(_ title: String, _ frame: CGRect = .zero) -> LiveWindow {
        LiveWindow(title: title, frame: frame)
    }

    func testTitleBeatsPositionAndOrder() {
        let entry = saved("Notes", index: 0, frame: rightHalf)
        let assignment = LayoutMatcher.assign(
            saved: [entry],
            live: [live("Inbox", CGRect(x: 0, y: 0, width: 100, height: 100)), live("Notes")],
            expected: [0: CGRect(x: 0, y: 0, width: 100, height: 100)])
        XCTAssertEqual(assignment[0], 1)
    }

    /// Position is the signal the old first-fit design threw away. A window that has not moved since
    /// capture is very likely the same window, even when its title has changed.
    func testPositionMatchesWhenTitlesHaveChanged() {
        let entry = saved("Old name", index: 5, frame: rightHalf)
        let here = CGRect(x: 720, y: 0, width: 720, height: 900)
        let assignment = LayoutMatcher.assign(
            saved: [entry],
            live: [live("Something else", CGRect(x: 0, y: 0, width: 720, height: 900)),
                   live("New name", here)],
            expected: [0: here])
        XCTAssertEqual(assignment[0], 1)
    }

    /// The order slot still carries a match on its own, which is what keeps a layout working for an
    /// app that reopened with every title and position changed.
    func testOrderAloneStillMatches() {
        let entry = saved("Gone", index: 1, frame: rightHalf)
        let assignment = LayoutMatcher.assign(
            saved: [entry], live: [live("A"), live("B"), live("C")], expected: [:])
        XCTAssertEqual(assignment[0], 1)
    }

    /// Nothing in common is not a match. Pairing two unrelated windows because both are unclaimed
    /// moves a window the user never asked to move.
    func testNoSignalIsNotAMatch() {
        let entry = saved("Gone", index: 9, frame: rightHalf)
        let assignment = LayoutMatcher.assign(
            saved: [entry], live: [live("A"), live("B")], expected: [:])
        XCTAssertNil(assignment[0])
    }

    /// One live window cannot satisfy two saved entries — a browser with three "New Tab"s would
    /// otherwise stack all three saved frames onto one window.
    func testEachLiveWindowIsUsedOnce() {
        let first = saved("New Tab", index: 0, frame: rightHalf)
        let second = saved("New Tab", index: 1, frame: rightHalf)
        let assignment = LayoutMatcher.assign(
            saved: [first, second], live: [live("New Tab"), live("New Tab")], expected: [:])
        XCTAssertEqual(Set([assignment[0], assignment[1]].compactMap { $0 }).count, 2)
    }

    /// The reason this is a global assignment rather than a walk down the saved list.
    ///
    /// Entry 0 has the stronger claim on window 0 by position and order, and would take it under
    /// first-fit — leaving entry 1, which matches that window *exactly* by title, with nothing. The
    /// scorer settles the strongest pair first and pushes entry 0 onto its second choice.
    func testAWeakEarlyClaimDoesNotStealAnExactLaterMatch() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        let narrow = CGRect(x: 0, y: 0, width: 50, height: 100)
        let weak = saved("Untitled", index: 0, frame: rightHalf)
        let exact = saved("Report.pdf", index: 7, frame: rightHalf)

        let assignment = LayoutMatcher.assign(
            saved: [weak, exact],
            live: [live("Report.pdf", big), live("Something", narrow)],
            // Entry 0 sits exactly where window 0 is, and half-overlaps window 1.
            expected: [0: big])

        XCTAssertEqual(assignment[1], 0, "the exact title match should win the window")
        XCTAssertEqual(assignment[0], 1, "the weaker claim should be pushed onto its second choice")
    }

    /// An empty saved title means the window had no title when captured, not that it should match
    /// the first untitled window found.
    func testEmptySavedTitleDoesNotMatchOnTitle() {
        let entry = saved("", index: 2, frame: rightHalf)
        let assignment = LayoutMatcher.assign(
            saved: [entry], live: [live(""), live("")], expected: [:])
        XCTAssertNil(assignment[0], "index 2 does not exist and the empty title must not match")
    }

    func testNoLiveWindowsMatchesNothing() {
        let assignment = LayoutMatcher.assign(
            saved: [saved("A", frame: rightHalf)], live: [], expected: [:])
        XCTAssertTrue(assignment.isEmpty)
    }

    // MARK: - Overlap

    func testOverlapIsIntersectionOverUnion() {
        let a = CGRect(x: 0, y: 0, width: 100, height: 100)
        XCTAssertEqual(LayoutMatcher.overlap(a, a), 1.0, accuracy: 0.001)
        XCTAssertEqual(
            LayoutMatcher.overlap(a, CGRect(x: 200, y: 0, width: 100, height: 100)), 0,
            accuracy: 0.001)
    }

    /// Intersection over *union*, so a small window sitting inside a large one does not read as a
    /// near-perfect match the way intersection-over-self would.
    func testASmallWindowInsideALargeOneIsNotANearPerfectMatch() {
        let big = CGRect(x: 0, y: 0, width: 100, height: 100)
        let small = CGRect(x: 0, y: 0, width: 10, height: 10)
        XCTAssertEqual(LayoutMatcher.overlap(big, small), 0.01, accuracy: 0.001)
    }

    // MARK: - Chord matching

    func testLayoutChordMatchesOnExactModifiers() {
        let hotkey = Hotkey(keyCode: 18, modifierRaw: CGEventFlags.maskControl.rawValue)
        let shortcuts = LayoutShortcuts(entries: [(id: "work", hotkey: hotkey)])

        XCTAssertEqual(shortcuts.layoutID(code: 18, flags: .maskControl), "work")
        XCTAssertNil(shortcuts.layoutID(code: 18, flags: [.maskControl, .maskCommand]))
        XCTAssertNil(shortcuts.layoutID(code: 19, flags: .maskControl))
    }

    /// Two layouts on one chord resolve to the same one every time rather than by dictionary order.
    func testDuplicateChordResolvesToTheFirstLayout() {
        let hotkey = Hotkey(keyCode: 18, modifierRaw: CGEventFlags.maskControl.rawValue)
        let shortcuts = LayoutShortcuts(
            entries: [(id: "first", hotkey: hotkey), (id: "second", hotkey: hotkey)])
        XCTAssertEqual(shortcuts.layoutID(code: 18, flags: .maskControl), "first")
    }

    func testUnboundLayoutsMatchNothing() {
        XCTAssertNil(LayoutShortcuts().layoutID(code: 18, flags: .maskControl))
    }
}
