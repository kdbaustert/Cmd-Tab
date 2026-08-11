import ApplicationServices
import XCTest

@testable import CmdTab

/// The window filter, which is three special cases wearing a trench coat. Each of them was a bug:
/// Finder's desktop turning up as a switch target, every minimized window vanishing, and Finder's
/// own browser windows never appearing at all.
final class WindowClassificationTests: XCTestCase {

    private let window = kAXWindowRole as String
    private let standard = kAXStandardWindowSubrole as String
    private let dialog = kAXDialogSubrole as String
    private let floating = kAXFloatingWindowSubrole as String
    private let systemFloating = kAXSystemFloatingWindowSubrole as String

    // MARK: - The role gate

    /// Finder puts the desktop in `AXWindows` as an `AXScrollArea`. It is not a window and no
    /// amount of the checks below should rescue it.
    func testTheDesktopScrollAreaIsNotAWindow() {
        XCTAssertFalse(
            WindowClassification.isSwitchable(
                role: kAXScrollAreaRole as String,
                subrole: standard,
                isMinimized: true,
                hasMinimizeButton: true))
    }

    func testAMissingRoleIsNotAWindow() {
        XCTAssertFalse(
            WindowClassification.isSwitchable(
                role: nil, subrole: standard, isMinimized: false, hasMinimizeButton: true))
    }

    // MARK: - The ordinary case

    func testAStandardWindowIsSwitchable() {
        XCTAssertTrue(
            WindowClassification.isSwitchable(
                role: window, subrole: standard, isMinimized: false, hasMinimizeButton: true))
    }

    /// A standard window is settled by its subrole alone. The other two facts are Accessibility
    /// round trips to another process, and this is the path every window in the list takes, so
    /// paying for them here would be a per-window cost on the common case.
    func testAStandardWindowCostsNoFurtherAccessibilityReads() {
        var reads = 0
        let probe = { () -> Bool in
            reads += 1
            return false
        }
        _ = WindowClassification.isSwitchable(
            role: window, subrole: standard, isMinimized: probe(), hasMinimizeButton: probe())
        XCTAssertEqual(reads, 0)
    }

    // MARK: - Minimized windows misreport their subrole

    /// macOS flips a window's subrole to `AXDialog` while it is minimized. Filtering on
    /// `AXStandardWindow` alone therefore dropped every minimized window, silently — an empty list
    /// is indistinguishable from an app with no windows.
    func testAMinimizedWindowIsSwitchableDespiteReportingAsADialog() {
        XCTAssertTrue(
            WindowClassification.isSwitchable(
                role: window, subrole: dialog, isMinimized: true, hasMinimizeButton: false))
    }

    /// Minimized wins before the subrole is consulted at all, so a window that is in the Dock stays
    /// switchable whatever else it now calls itself.
    func testAMinimizedWindowIsSwitchableWhateverItsSubrole() {
        for subrole in [floating, systemFloating, nil] {
            XCTAssertTrue(
                WindowClassification.isSwitchable(
                    role: window, subrole: subrole, isMinimized: true, hasMinimizeButton: false),
                "minimized \(subrole ?? "nil") should still be switchable")
        }
    }

    // MARK: - Finder's browser windows

    /// Finder reports `AXDialog` for its browser windows even while they are up, which is why
    /// Finder was missing from window mode entirely. The minimize button is what tells them from a
    /// real dialog.
    func testADialogWithAMinimizeButtonIsSwitchable() {
        XCTAssertTrue(
            WindowClassification.isSwitchable(
                role: window, subrole: dialog, isMinimized: false, hasMinimizeButton: true))
    }

    /// The other side of the same rule: an alert or a Save panel has no minimize control, and
    /// switching to one is not a thing the user can meaningfully ask for.
    func testADialogWithoutAMinimizeButtonIsNotSwitchable() {
        XCTAssertFalse(
            WindowClassification.isSwitchable(
                role: window, subrole: dialog, isMinimized: false, hasMinimizeButton: false))
    }

    /// The minimize-button escape hatch is scoped to `AXDialog` on purpose. Palettes and system
    /// dialogs are what the subrole check is *for*, and a widened net that asked only "does it have
    /// a minimize button" would let them back in.
    func testTheMinimizeButtonDoesNotRescueOtherSubroles() {
        for subrole in [floating, systemFloating, kAXSystemDialogSubrole as String] {
            XCTAssertFalse(
                WindowClassification.isSwitchable(
                    role: window, subrole: subrole, isMinimized: false, hasMinimizeButton: true),
                "\(subrole) should stay out of the switcher")
        }
    }

    /// A window with no subrole at all is not a dialog, so it does not reach the button probe.
    func testAnAbsentSubroleIsNotSwitchable() {
        XCTAssertFalse(
            WindowClassification.isSwitchable(
                role: window, subrole: nil, isMinimized: false, hasMinimizeButton: true))
    }

    /// The button is only probed for the one subrole that needs it — the read is IPC and every
    /// non-standard window in the system passes through here.
    func testTheMinimizeButtonIsProbedOnlyForDialogs() {
        var probed = false
        _ = WindowClassification.isSwitchable(
            role: window, subrole: floating, isMinimized: false,
            hasMinimizeButton: { probed = true; return true }())
        XCTAssertFalse(probed)
    }
}
