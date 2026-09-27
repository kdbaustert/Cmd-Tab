import AppKit
import XCTest

@testable import CmdTab

/// The full-size preview's two pure rules: which thumbnail stands for a tile, and where the panel
/// lands. The capture itself is `WindowCapture`, already covered by its own collapse/veto tests.
final class QuickPreviewTests: XCTestCase {
    private func thumb(_ id: CGWindowID, title: String) -> WindowThumb {
        WindowThumb(
            id: Int(id), windowID: id, image: NSImage(), title: title, pid: 1,
            isMinimized: false, hasCapture: true, displayIndex: nil, isReachable: true)
    }

    // MARK: - Which thumbnail

    func testAWindowTileGetsItsOwnWindow() {
        let thumbs = [thumb(10, title: "front"), thumb(20, title: "mine")]
        XCTAssertEqual(QuickPreview.pick(thumbs, windowID: 20)?.title, "mine")
    }

    /// An app tile names no window, and a window whose id could not be resolved (Electron and
    /// Catalyst hosts report 0) is the same case: the frontmost capture stands in.
    func testAnAppTileAndAnUnresolvedIdBothGetTheFrontWindow() {
        let thumbs = [thumb(10, title: "front"), thumb(20, title: "behind")]
        XCTAssertEqual(QuickPreview.pick(thumbs, windowID: nil)?.title, "front")
        XCTAssertEqual(QuickPreview.pick(thumbs, windowID: 0)?.title, "front")
        XCTAssertEqual(
            QuickPreview.pick(thumbs, windowID: 99)?.title, "front",
            "an id the capture did not find falls back rather than showing nothing")
        XCTAssertNil(QuickPreview.pick([], windowID: nil))
    }

    // MARK: - Where the panel lands

    private let screen = NSRect(x: 0, y: 0, width: 1600, height: 1000)
    private let panel = NSRect(x: 500, y: 300, width: 600, height: 200)

    /// Content that fits between the switcher and the top of the screen is centred in that band,
    /// so the tiles stay visible under it.
    func testContentThatFitsSitsCentredAboveTheSwitcher() {
        let size = CGSize(width: 800, height: 300)
        let origin = QuickPreview.origin(for: size, above: panel, in: screen)
        XCTAssertEqual(origin.x, 400, "centred on the screen's width")
        // The band runs from panel.maxY + gap (512) to screen top - gap (988): 476 tall.
        XCTAssertEqual(origin.y, 512 + (476 - 300) / 2, accuracy: 0.5)
        XCTAssertGreaterThan(origin.y, panel.maxY, "clear of the switcher")
    }

    /// Content too tall for the band is centred on the screen outright — Quick Look's answer for
    /// content too big to share the stage — and never pushed off the bottom.
    func testContentTooTallForTheBandIsCentredOnTheScreen() {
        let size = CGSize(width: 800, height: 700)
        let origin = QuickPreview.origin(for: size, above: panel, in: screen)
        XCTAssertEqual(origin.y, 150, accuracy: 0.5, "centred vertically")

        let huge = CGSize(width: 800, height: 1200)
        XCTAssertEqual(
            QuickPreview.origin(for: huge, above: panel, in: screen).y, screen.minY,
            "taller than the screen still starts on it")
    }

    /// However the arithmetic falls, the panel starts on the screen horizontally.
    func testTheOriginIsClampedToTheScreenSides() {
        let wide = CGSize(width: 2000, height: 300)
        let origin = QuickPreview.origin(for: wide, above: panel, in: screen)
        XCTAssertEqual(origin.x, screen.maxX - wide.width, "pinned to the right edge, not beyond")
    }
}
