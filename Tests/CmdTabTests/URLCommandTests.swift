import CoreGraphics
import Foundation
import XCTest

@testable import CmdTab

/// The `cmdtab://` grammar.
///
/// Worth testing closely for a reason the other parsers here do not have: this one is reachable by
/// any web page the user visits, so both halves matter — that the verbs it claims to support work,
/// and that the ones it deliberately does not are not reachable by some spelling nobody thought of.
final class URLCommandTests: XCTestCase {
    private func parse(_ string: String) -> URLCommand? {
        guard let url = URL(string: string) else { return nil }
        return URLCommand.parse(url)
    }

    // MARK: - Tiling

    func testEveryArrangementIsReachableByItsRawValue() {
        for arrangement in WindowArrangement.allCases {
            XCTAssertEqual(
                parse("cmdtab://tile/\(arrangement.rawValue)"), .arrangement(arrangement),
                "\(arrangement.rawValue) is not reachable")
        }
    }

    /// The families that ship with no chord are the ones a URL is most useful for, so they had
    /// better be in the grammar — that is half the argument for the scheme existing.
    func testTheUnboundFamiliesAreReachable() {
        XCTAssertEqual(parse("cmdtab://tile/focusRight"), .arrangement(.focusRight))
        XCTAssertEqual(parse("cmdtab://tile/swapLeft"), .arrangement(.swapLeft))
        XCTAssertEqual(parse("cmdtab://tile/nudgeUp"), .arrangement(.nudgeUp))
        XCTAssertEqual(parse("cmdtab://tile/leftTwoThirds"), .arrangement(.leftTwoThirds))
    }

    func testAnUnknownArrangementIsRefused() {
        XCTAssertNil(parse("cmdtab://tile/sideways"))
        XCTAssertNil(parse("cmdtab://tile/"))
        XCTAssertNil(parse("cmdtab://tile"))
    }

    // MARK: - Activation

    /// A bundle identifier is the path, and its case is preserved. `URL` lowercases the *host*,
    /// which is why the verb and the argument cannot both live there — a lowercased bundle id
    /// resolves to nothing.
    func testABundleIdentifierKeepsItsCase() {
        XCTAssertEqual(
            parse("cmdtab://activate/com.apple.Safari"), .activate(bundleID: "com.apple.Safari"))
        XCTAssertEqual(
            parse("cmdtab://activate/com.mitchellh.ghostty"),
            .activate(bundleID: "com.mitchellh.ghostty"))
    }

    func testActivationWithNoAppIsRefused() {
        XCTAssertNil(parse("cmdtab://activate/"))
        XCTAssertNil(parse("cmdtab://activate"))
    }

    // MARK: - All windows

    func testHideAndShowAll() {
        XCTAssertEqual(parse("cmdtab://windows/hideAll"), .allWindows(.hide))
        XCTAssertEqual(parse("cmdtab://windows/showAll"), .allWindows(.show))
        XCTAssertNil(parse("cmdtab://windows/somethingElse"))
    }

    // MARK: - What is deliberately not reachable

    /// The security boundary, asserted rather than left to the comment that explains it.
    ///
    /// A URL scheme can be invoked by any page the user visits, with no prompt and no visible trace.
    /// Rearranging windows is recoverable and obvious; closing a document is neither, so the actions
    /// that end a process or a window stay behind the keyboard where a person is present. If one of
    /// these ever starts parsing, that decision has been reversed by accident.
    func testNothingDestructiveIsReachable() {
        for path in [
            "cmdtab://quit/com.apple.Safari", "cmdtab://forceQuit/com.apple.Safari",
            "cmdtab://close/com.apple.Safari", "cmdtab://action/quit", "cmdtab://action/close",
            "cmdtab://windows/quitAll", "cmdtab://windows/closeAll",
        ] {
            XCTAssertNil(parse(path), "\(path) should name nothing")
        }
    }

    /// The in-switcher actions share their spelling with nothing here, and `tile` only ever resolves
    /// against `WindowArrangement` — so an action name cannot slip through the tiling verb.
    func testSwitcherActionNamesDoNotResolveAsArrangements() {
        for action in SwitcherAction.allCases {
            guard action.arrangement == nil else { continue }
            XCTAssertNil(
                parse("cmdtab://tile/\(action.rawValue)"),
                "\(action.rawValue) should not be reachable as an arrangement")
        }
    }

    // MARK: - Shape

    func testAnotherSchemeIsRefused() {
        XCTAssertNil(parse("https://tile/leftHalf"))
        XCTAssertNil(parse("raycast://tile/leftHalf"))
    }

    /// The scheme itself is matched case-insensitively, because that is what the URL machinery and
    /// the people typing them both do.
    func testTheSchemeAndVerbAreCaseInsensitive() {
        XCTAssertEqual(parse("CMDTAB://TILE/leftHalf"), .arrangement(.leftHalf))
    }

    /// Trailing components are ignored rather than making the whole request fail: a URL pasted with
    /// a stray slash still means what it says.
    func testTrailingPathComponentsAreIgnored() {
        XCTAssertEqual(parse("cmdtab://tile/leftHalf/"), .arrangement(.leftHalf))
        XCTAssertEqual(parse("cmdtab://tile/leftHalf/extra"), .arrangement(.leftHalf))
    }

    func testAnUnknownVerbIsRefused() {
        XCTAssertNil(parse("cmdtab://something/leftHalf"))
        XCTAssertNil(parse("cmdtab://"))
    }
}

/// The two pure halves of the display-layout restore.
///
/// Internal rather than private for the reason `WindowTiler.reachable` gives for the same choice:
/// the cases that matter are the ones where the desk has changed under a stored frame, and no test
/// can arrange a second monitor to unplug.
final class DisplayLayoutGeometryTests: XCTestCase {
    private let laptop = CGRect(x: 0, y: 25, width: 1512, height: 945)
    private let external = CGRect(x: 1512, y: 0, width: 2560, height: 1415)

    /// A frame stored on one display and read back on the same one is the frame it started as.
    func testTheRoundTripIsLossless() {
        let window = CGRect(x: 100, y: 200, width: 700, height: 500)
        let stored = DisplayLayouts.fraction(of: window, in: laptop)
        let back = DisplayLayouts.absolute(stored, in: laptop)
        XCTAssertEqual(back.minX, window.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, window.minY, accuracy: 0.001)
        XCTAssertEqual(back.width, window.width, accuracy: 0.001)
        XCTAssertEqual(back.height, window.height, accuracy: 0.001)
    }

    /// The whole reason frames are stored as fractions: the same monitor at a different resolution,
    /// or a different monitor entirely, still puts the window in the same relative place. Stored as
    /// absolute coordinates, the right half of a 2560-wide display is off the edge of a 1512-wide
    /// one — and looks perfectly plausible while being wrong.
    func testARightHalfIsStillARightHalfOnADifferentDisplay() {
        let rightHalf = CGRect(
            x: external.midX, y: external.minY, width: external.width / 2, height: external.height)
        let stored = DisplayLayouts.fraction(of: rightHalf, in: external)
        XCTAssertEqual(stored.minX, 0.5, accuracy: 0.0001)
        XCTAssertEqual(stored.width, 0.5, accuracy: 0.0001)
        let onLaptop = DisplayLayouts.absolute(stored, in: laptop)
        XCTAssertEqual(onLaptop.minX, laptop.midX, accuracy: 0.001)
        XCTAssertEqual(onLaptop.width, laptop.width / 2, accuracy: 0.001)
        XCTAssertEqual(onLaptop.maxX, laptop.maxX, accuracy: 0.001)
    }

    /// A display's visible area does not start at the origin — the menu bar sees to that — so the
    /// fraction has to be measured from the area's own origin rather than the screen's.
    func testFractionsAreMeasuredFromTheAreaNotTheOrigin() {
        let atTop = CGRect(x: laptop.minX, y: laptop.minY, width: 400, height: 300)
        let stored = DisplayLayouts.fraction(of: atTop, in: laptop)
        XCTAssertEqual(stored.minX, 0, accuracy: 0.0001)
        XCTAssertEqual(stored.minY, 0, accuracy: 0.0001)
    }

    /// A zero-sized area cannot be divided by, and a display can report one transiently while the
    /// desk is being reconfigured — which is exactly when this code runs.
    func testAZeroSizedAreaDoesNotDivideByZero() {
        let stored = DisplayLayouts.fraction(of: laptop, in: .zero)
        XCTAssertEqual(stored, .zero)
    }

    /// Windows already where they belong are left alone, so a desk change does not rewrite every
    /// frame on the machine — and the tolerance is what stops the lossy round trip above from
    /// nudging a window by half a pixel forever.
    func testAWindowAlreadyInPlaceIsLeftAlone() {
        let window = CGRect(x: 100, y: 200, width: 700, height: 500)
        XCTAssertTrue(DisplayLayouts.matches(window, window))
        XCTAssertTrue(
            DisplayLayouts.matches(window, window.offsetBy(dx: 0.5, dy: -0.5)),
            "a sub-pixel difference is not a move")
        XCTAssertFalse(DisplayLayouts.matches(window, window.offsetBy(dx: 40, dy: 0)))
    }
}
