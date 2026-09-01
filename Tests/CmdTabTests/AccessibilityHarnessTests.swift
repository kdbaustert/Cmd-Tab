import AppKit
import ApplicationServices
import XCTest

@testable import CmdTab

/// The layer the rest of the suite cannot reach: real windows, the real Accessibility API, and the
/// real window server.
///
/// Everything else here is pure logic — 500-odd tests in a tenth of a second, no window server, no
/// grant, no running apps. That is the right shape for the arithmetic, and it leaves a hole exactly
/// where this app is most exposed: `WindowClassification` encodes a **subrole table Apple has never
/// documented** and that has already changed under it once (the `AXDialog` trap, and Finder on top of
/// it), `WindowTiler` writes frames through an API whose hosts clamp and round them in ways no unit
/// test models, and `WindowNeighbors` reads the window server's own list. A macOS point release can
/// break any of those without a single existing test going red — the symptom would be a user
/// reporting that half their windows have vanished from the switcher.
///
/// **Skipped unless asked for, twice over.** It needs the Accessibility grant, which CI cannot give
/// and which the `swift test` runner does not have by default, and it puts real windows on the
/// screen of whoever runs it. So it wants `CMDTAB_AX_HARNESS=1` *and* a trusted process, and says
/// which one is missing rather than failing:
///
/// ```sh
/// CMDTAB_AX_HARNESS=1 swift test --filter AccessibilityHarnessTests
/// ```
///
/// The grant is on the binary that runs the tests — `.build/…/CmdTabPackageTests.xctest`, or the
/// `xctest` tool that hosts it — so the first run will prompt, and the run after the grant is the
/// one that measures anything. That is a real cost and it is why this is opt-in rather than part of
/// the suite: the value is in running it against a new macOS, deliberately, not in running it a
/// hundred times a day.
@MainActor
final class AccessibilityHarnessTests: XCTestCase {
    /// Windows opened by a test, torn down whatever the test did.
    private var opened: [NSWindow] = []

    override func setUp() async throws {
        try await super.setUp()
        try XCTSkipUnless(
            ProcessInfo.processInfo.environment["CMDTAB_AX_HARNESS"] == "1",
            "set CMDTAB_AX_HARNESS=1 to run the Accessibility harness (it opens real windows)")
        try XCTSkipUnless(
            AXIsProcessTrusted(),
            "the test runner needs Accessibility: System Settings → Privacy & Security → "
                + "Accessibility, and add the binary running these tests")
        // Accessory rather than regular: this puts windows on screen without stealing the Dock or
        // the menu bar from whatever the person running it was doing.
        NSApplication.shared.setActivationPolicy(.accessory)
        // **Required, and the whole reason this file did not work at first.** AppKit installs its
        // Accessibility server as part of launching, and an XCTest bundle never calls
        // `NSApplication.run()` — so without this, every `AXWindows` read against our own pid comes
        // back `kAXErrorNotImplemented` (-25208) and the harness looks like a permissions problem
        // that no amount of granting fixes. Measured: identical probe, one line apart, -25208
        // against 0 windows and 0 against 1.
        NSApplication.shared.finishLaunching()
    }

    override func tearDown() async throws {
        for window in opened { window.orderOut(nil) }
        opened.removeAll()
        try await super.tearDown()
    }

    // MARK: - Harness

    /// Opens a real window at `frame` (Cocoa coordinates) and hands back its Accessibility element.
    ///
    /// The element is looked up by matching the frame rather than by taking the front window,
    /// because a test that opens three of them cannot tell them apart any other way — and matching
    /// on the frame is what `WindowTiler.resolve` does for the drag gestures, so this exercises that
    /// path as a side effect.
    private func openWindow(at frame: NSRect, title: String) throws -> AXUIElement {
        let window = NSWindow(
            contentRect: frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = title
        window.setFrame(frame, display: true)
        window.orderFrontRegardless()
        opened.append(window)
        let expected = axFrame(of: window)
        return try waitFor("an Accessibility element for \(title)") {
            AX.window(ofApplication: ProcessInfo.processInfo.processIdentifier, matching: expected)
        }
    }

    /// A Cocoa window frame in the top-left-origin space Accessibility and the tiler both use.
    private func axFrame(of window: NSWindow) -> CGRect {
        let primaryHeight = NSScreen.primary?.frame.height ?? 0
        let frame = window.frame
        return CGRect(
            x: frame.origin.x, y: primaryHeight - frame.origin.y - frame.height,
            width: frame.width, height: frame.height)
    }

    /// Polls `body` until it answers, pumping the run loop so AppKit and the window server can make
    /// progress. Accessibility is IPC and the window server is another process: nothing here lands
    /// synchronously, and a test that assumes it does fails intermittently, which is worse than not
    /// having the test.
    private func waitFor<T>(_ what: String, timeout: TimeInterval = 3, _ body: () -> T?) throws -> T
    {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let value = body() { return value }
            RunLoop.current.run(until: Date().addingTimeInterval(0.02))
        }
        // Thrown rather than `XCTFail`-then-skip: a timeout here is a genuine failure — the guards
        // in `setUp` already excused every reason this could legitimately not run — and reporting it
        // as both a failure and a skip made the output say two contradictory things at once.
        throw Timeout(what: what)
    }

    private struct Timeout: Error, CustomStringConvertible {
        let what: String
        var description: String { "timed out waiting for \(what)" }
    }

    /// The usable area of the display the window is on, which is what every arrangement measures
    /// itself against.
    private func homeArea(of window: AXUIElement) throws -> CGRect {
        let areas = WindowTiler.visibleAreas()
        let frame = try XCTUnwrap(AX.frame(window))
        let index = try XCTUnwrap(
            WindowTiler.homeDisplay(of: frame, in: areas), "the window is on no display")
        return areas[index]
    }

    /// Two points of slack. Hosts round frames, and a display with a fractional backing scale can
    /// land a half-point off; anything larger than this is the tiler being wrong rather than the
    /// window server being itself.
    private let tolerance: CGFloat = 2

    private func assertFrame(
        _ actual: CGRect?, _ expected: CGRect, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        guard let actual else {
            return XCTFail("no frame at all. \(message)", file: file, line: line)
        }
        XCTAssertEqual(actual.minX, expected.minX, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(actual.minY, expected.minY, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(
            actual.width, expected.width, accuracy: tolerance, message, file: file, line: line)
        XCTAssertEqual(
            actual.height, expected.height, accuracy: tolerance, message, file: file, line: line)
    }

    // MARK: - Classification

    /// The baseline the whole switcher rests on: an ordinary window is switchable, and says so
    /// through the four facts `WindowClassification` asks about.
    func testAnOrdinaryWindowIsSwitchable() throws {
        let window = try openWindow(
            at: NSRect(x: 200, y: 200, width: 600, height: 400), title: "Harness")
        XCTAssertEqual(AX.copyString(window, kAXRoleAttribute as String), kAXWindowRole as String)
        XCTAssertEqual(
            AX.copyString(window, kAXSubroleAttribute as String),
            kAXStandardWindowSubrole as String)
        XCTAssertFalse(AX.isMinimized(window))
        XCTAssertTrue(AX.isSwitchableWindow(window))
    }

    /// **The AXDialog trap, measured rather than remembered.**
    ///
    /// macOS reports a window's subrole as `AXDialog` while it is minimized — the same window flips
    /// `AXStandardWindow` → `AXDialog` on minimize and back on restore. That is the single fact
    /// `WindowClassification` exists for, it is undocumented, and the README's table of it was
    /// established by hand against TextEdit on one OS version. This is that table, re-derived on
    /// whatever macOS is running now, against a window this process owns.
    ///
    /// If this fails on a future macOS, the fix is not to make the test pass: it is to re-read
    /// `WindowClassification.isSwitchable` and decide what the new truth means for the filter.
    func testMinimizingFlipsTheSubroleAndTheWindowStaysSwitchable() throws {
        let window = try openWindow(
            at: NSRect(x: 240, y: 240, width: 500, height: 360), title: "Minimize me")
        let native = try XCTUnwrap(opened.last)

        native.miniaturize(nil)
        _ = try waitFor("the window to reach the Dock") { AX.isMinimized(window) ? true : nil }

        let subrole = AX.copyString(window, kAXSubroleAttribute as String)
        XCTAssertEqual(
            subrole, kAXDialogSubrole as String,
            "the AXDialog trap no longer holds — re-read WindowClassification before changing this")
        XCTAssertTrue(
            AX.isSwitchableWindow(window),
            "a minimized window is in the Dock and switchable whatever it calls itself")
        // And the filter that used to drop it silently would have.
        XCTAssertNotEqual(subrole, kAXStandardWindowSubrole as String)

        native.deminiaturize(nil)
        _ = try waitFor("the window to come back") { AX.isMinimized(window) ? nil : true }
        XCTAssertEqual(
            AX.copyString(window, kAXSubroleAttribute as String),
            kAXStandardWindowSubrole as String, "restoring should put the subrole back")
    }

    /// The minimize button is the discriminator that readmits Finder's browser windows, which report
    /// `AXDialog` even while up. A window with one is switchable; the check has to find it.
    func testAResizableWindowAdvertisesItsMinimizeButton() throws {
        let window = try openWindow(
            at: NSRect(x: 300, y: 300, width: 480, height: 320), title: "Buttons")
        XCTAssertNotNil(
            AX.copyElement(window, kAXMinimizeButtonAttribute as String),
            "a titled, miniaturizable window has a minimize button")
        XCTAssertTrue(
            WindowClassification.isSwitchable(
                role: kAXWindowRole as String, subrole: kAXDialogSubrole as String,
                isMinimized: false,
                hasMinimizeButton: AX.copyElement(
                    window, kAXMinimizeButtonAttribute as String) != nil),
            "the Finder case: AXDialog, up, and switchable because it can be minimized")
    }

    // MARK: - Tiling

    /// The arithmetic is unit-tested; this is the half that is not — that a computed frame survives
    /// being written through Accessibility to a real window and comes back the same.
    func testTilingToTheLeftHalfLandsWhereTheGeometrySays() throws {
        let window = try openWindow(
            at: NSRect(x: 150, y: 150, width: 700, height: 500), title: "Tile me")
        let area = try homeArea(of: window)
        let expected = try XCTUnwrap(
            WindowArrangement.leftHalf.frame(
                in: area, current: try XCTUnwrap(AX.frame(window)), fraction: 0.5))

        WindowTiler.apply(
            .leftHalf, pid: ProcessInfo.processInfo.processIdentifier, areas: [area],
            cycleWidths: false, target: .element(window))

        let landed = try waitFor("the tile to land") { () -> CGRect? in
            guard let frame = AX.frame(window),
                abs(frame.minX - expected.minX) <= tolerance,
                abs(frame.width - expected.width) <= tolerance
            else { return nil }
            return frame
        }
        assertFrame(landed, expected, "left half")
    }

    /// The position → size → position dance exists because hosts clamp one against the other. A
    /// window that has to both move and grow is the case that catches a host doing it.
    func testAWindowThatMustMoveAndGrowLandsInOneGo() throws {
        let window = try openWindow(
            at: NSRect(x: 60, y: 60, width: 320, height: 240), title: "Grow me")
        let area = try homeArea(of: window)

        WindowTiler.apply(
            .maximize, pid: ProcessInfo.processInfo.processIdentifier, areas: [area],
            cycleWidths: false, target: .element(window))

        let landed = try waitFor("maximize to land") { () -> CGRect? in
            guard let frame = AX.frame(window), abs(frame.width - area.width) <= tolerance
            else { return nil }
            return frame
        }
        assertFrame(landed, area, "maximize fills the usable area")
    }

    /// A gap is applied to the finished tile, and the promise is that two neighbours end up exactly
    /// one gap apart. Checked against a real window rather than against the arithmetic, because the
    /// arithmetic is not what the user sees.
    func testAGapSurvivesTheRoundTripToARealWindow() throws {
        let window = try openWindow(
            at: NSRect(x: 120, y: 120, width: 640, height: 480), title: "Gapped")
        let area = try homeArea(of: window)
        let gap: CGFloat = 20
        let plain = try XCTUnwrap(
            WindowArrangement.rightHalf.frame(
                in: area, current: try XCTUnwrap(AX.frame(window)), fraction: 0.5))
        let expected = TilingGap.inset(plain, in: area, gap: gap)

        WindowTiler.apply(
            .rightHalf, pid: ProcessInfo.processInfo.processIdentifier, areas: [area],
            cycleWidths: false, gap: gap, target: .element(window))

        let landed = try waitFor("the gapped tile to land") { () -> CGRect? in
            guard let frame = AX.frame(window), abs(frame.width - expected.width) <= tolerance
            else { return nil }
            return frame
        }
        assertFrame(landed, expected, "right half with a \(Int(gap))px gap")
        XCTAssertEqual(area.maxX - landed.maxX, gap, accuracy: tolerance, "full gap at the screen edge")
    }

    /// The per-edge resize, end to end: one edge moves, the other three do not. On a real window,
    /// where a host that clamped the resize against its old origin would move all four.
    func testGrowingOneEdgeLeavesTheOtherThreeAlone() throws {
        let window = try openWindow(
            at: NSRect(x: 400, y: 300, width: 500, height: 400), title: "One edge")
        let area = try homeArea(of: window)
        let before = try XCTUnwrap(AX.frame(window))
        let expected = try XCTUnwrap(
            WindowArrangement.growRight.frame(in: area, current: before, fraction: 0.5))

        WindowTiler.apply(
            .growRight, pid: ProcessInfo.processInfo.processIdentifier, areas: [area],
            cycleWidths: false, target: .element(window))

        let landed = try waitFor("the edge to move") { () -> CGRect? in
            guard let frame = AX.frame(window), abs(frame.width - expected.width) <= tolerance
            else { return nil }
            return frame
        }
        XCTAssertEqual(landed.minX, before.minX, accuracy: tolerance, "the left edge stayed")
        XCTAssertEqual(landed.minY, before.minY, accuracy: tolerance, "the top edge stayed")
        XCTAssertEqual(landed.maxY, before.maxY, accuracy: tolerance, "the bottom edge stayed")
        XCTAssertGreaterThan(landed.maxX, before.maxX, "the right edge moved out")
    }

    /// Restore's promise is the exact rectangle back, and it is kept across a real write.
    func testRestorePutsAWindowBackWhereItWas() throws {
        let window = try openWindow(
            at: NSRect(x: 260, y: 260, width: 560, height: 420), title: "Restore me")
        let area = try homeArea(of: window)
        let original = try XCTUnwrap(AX.frame(window))
        let pid = ProcessInfo.processInfo.processIdentifier

        WindowTiler.apply(
            .topLeft, pid: pid, areas: [area], cycleWidths: false, target: .element(window))
        _ = try waitFor("the tile to land") { () -> CGRect? in
            guard let frame = AX.frame(window), abs(frame.width - area.width / 2) <= tolerance
            else { return nil }
            return frame
        }

        WindowTiler.apply(
            .restore, pid: pid, areas: [area], cycleWidths: false, target: .element(window))
        let back = try waitFor("the restore to land") { () -> CGRect? in
            guard let frame = AX.frame(window), abs(frame.width - original.width) <= tolerance
            else { return nil }
            return frame
        }
        assertFrame(back, original, "restore returns the frame the window started with")
    }

    // MARK: - Navigation

    /// Directional focus against the window server's own list, which is where it gets its answers.
    ///
    /// Three real windows in a row: the middle one's right-hand neighbour has to be the right-hand
    /// one, and its left-hand neighbour the left-hand one. Unit tests cover the picking rules
    /// against synthetic rectangles; this covers the half those cannot — that `onScreen()` actually
    /// finds our windows, in the coordinate space `pick` assumes.
    func testTheWindowServerListPlacesRealWindowsWhereNavigationExpects() throws {
        let screen = try XCTUnwrap(NSScreen.main)
        let visible = screen.visibleFrame
        let width = min(320.0, visible.width / 4)
        let y = visible.minY + visible.height / 2 - 120

        let left = try openWindow(
            at: NSRect(x: visible.minX + 20, y: y, width: width, height: 240), title: "Left")
        let middle = try openWindow(
            at: NSRect(x: visible.minX + 40 + width, y: y, width: width, height: 240),
            title: "Middle")
        let right = try openWindow(
            at: NSRect(x: visible.minX + 60 + width * 2, y: y, width: width, height: 240),
            title: "Right")

        let frames = [left, middle, right].map { AX.frame($0) }
        let origin = try XCTUnwrap(frames[1])
        let candidates = [try XCTUnwrap(frames[0]), try XCTUnwrap(frames[2])]

        XCTAssertEqual(
            WindowNeighbors.pick(from: origin, among: candidates, direction: .right), 1,
            "the window to the right of the middle one is the right-hand one")
        XCTAssertEqual(
            WindowNeighbors.pick(from: origin, among: candidates, direction: .left), 0,
            "and to its left, the left-hand one")

        // The window server can see them, in the same space. This is the assertion that would catch
        // `onScreen()` filtering our windows out — the failure that makes directional focus silently
        // reach nothing.
        let listed = WindowNavigator.onScreen()
        let mine = listed.filter { $0.pid == ProcessInfo.processInfo.processIdentifier }
        XCTAssertGreaterThanOrEqual(
            mine.count, 3, "the window server should list the three windows just opened")
    }
}
