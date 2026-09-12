import CoreGraphics
import XCTest

@testable import CmdTab

/// Which Spaces Bar a Desktop move aims at, and which thumbnails belong to it.
///
/// Mission Control draws a Spaces Bar per display, and the destination index counts Desktops within
/// the window's *own* display — so picking the wrong bar means the window lands on the wrong Desktop
/// entirely, on the wrong screen, with nothing in the log to say so.
///
/// The selection used to match on x alone. That is correct for displays side by side and wrong for
/// displays stacked one above the other, which share their whole x range: both bars matched and the
/// first one won. These are the cases that could not be checked without Mission Control until the
/// choice was pulled out into pure functions.
///
/// Everything here is in the window server's top-left space, which is what `CGDisplayBounds` and the
/// Accessibility frames both report.
final class DesktopMoverLayoutTests: XCTestCase {
    /// A bar sits at the top of the display it belongs to, the height of a row of thumbnails.
    private func bar(on display: CGRect) -> CGRect {
        CGRect(x: display.minX + 200, y: display.minY + 20, width: display.width - 400, height: 120)
    }

    /// The labels under one bar's thumbnails. Deliberately placed *below* the bar's own rectangle,
    /// which is what the real ones do — the whole reason a containment test cannot be used on them.
    private func buttons(under bar: CGRect, count: Int = 3) -> [CGRect] {
        (0..<count).map { index in
            CGRect(
                x: bar.minX + CGFloat(index) * (bar.width / CGFloat(count)) + 10,
                y: bar.maxY + 6, width: 60, height: 14)
        }
    }

    // MARK: - Picking the bar

    func testASingleBarIsTakenWhateverTheDisplay() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(DesktopMover.barIndex(in: [bar(on: display)], on: display), 0)
    }

    func testNoDisplayFallsBackToTheFirstBar() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        XCTAssertEqual(
            DesktopMover.barIndex(in: [bar(on: left), bar(on: right)], on: nil), 0)
    }

    func testSideBySideDisplaysPickTheirOwnBar() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let bars = [bar(on: left), bar(on: right)]
        XCTAssertEqual(DesktopMover.barIndex(in: bars, on: left), 0)
        XCTAssertEqual(DesktopMover.barIndex(in: bars, on: right), 1)
    }

    /// The case the old x-only rule got wrong: two displays one above the other share every x, so
    /// only the y separates their bars.
    func testVerticallyStackedDisplaysPickTheirOwnBar() {
        let top = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bottom = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let bars = [bar(on: top), bar(on: bottom)]
        XCTAssertEqual(DesktopMover.barIndex(in: bars, on: top), 0)
        XCTAssertEqual(
            DesktopMover.barIndex(in: bars, on: bottom), 1,
            "the lower display's bar is the one below it, not the first one in the tree")
    }

    /// An external at the origin with a laptop below and to the right of it — the layout the old
    /// comment named as the one that dropped a window nowhere at all.
    func testAnOffsetStackPicksTheRightBar() {
        let external = CGRect(x: 0, y: 0, width: 2560, height: 1440)
        let laptop = CGRect(x: 640, y: 1440, width: 1512, height: 982)
        let bars = [bar(on: external), bar(on: laptop)]
        XCTAssertEqual(DesktopMover.barIndex(in: bars, on: external), 0)
        XCTAssertEqual(DesktopMover.barIndex(in: bars, on: laptop), 1)
    }

    /// A bar reported somewhere no display contains still yields a bar rather than nothing: a wrong
    /// bar is a move to the wrong Desktop, where no bar is a window that does not move at all.
    func testABarOnNoDisplayFallsBackRatherThanFailing() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let stray = CGRect(x: 9000, y: 9000, width: 400, height: 120)
        XCTAssertEqual(DesktopMover.barIndex(in: [stray], on: display), 0)
    }

    func testNoBarsAtAllIsNil() {
        XCTAssertNil(DesktopMover.barIndex(in: [], on: CGRect(x: 0, y: 0, width: 100, height: 100)))
    }

    // MARK: - Picking the thumbnails

    func testButtonsAreScopedToTheirOwnBarWhenDisplaysAreStacked() {
        let top = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let bottom = CGRect(x: 0, y: 1080, width: 1920, height: 1080)
        let topBar = bar(on: top)
        let bottomBar = bar(on: bottom)
        let frames = buttons(under: topBar) + buttons(under: bottomBar)

        let lower = DesktopMover.buttonIndices(of: frames, on: bottom, bar: bottomBar)
        XCTAssertEqual(lower, [3, 4, 5])
        let upper = DesktopMover.buttonIndices(of: frames, on: top, bar: topBar)
        XCTAssertEqual(upper, [0, 1, 2])
    }

    /// Side by side, the x filter and the bar filter agree — which is why the bug stayed hidden.
    func testButtonsAreScopedToTheirOwnBarWhenDisplaysAreSideBySide() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let frames = buttons(under: bar(on: left)) + buttons(under: bar(on: right))
        XCTAssertEqual(DesktopMover.buttonIndices(of: frames, on: right, bar: bar(on: right)), [3, 4, 5])
    }

    /// Order is preserved, because the index into this list *is* the Desktop number.
    func testScopingKeepsTheThumbnailsInOrder() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let frames = buttons(under: bar(on: display), count: 4)
        let kept = DesktopMover.buttonIndices(of: frames, on: display, bar: bar(on: display))
        XCTAssertEqual(kept, [0, 1, 2, 3])
        XCTAssertEqual(kept, kept.sorted())
    }

    /// With no bar to scope by, the display's x range is the fallback — what shipped before.
    func testWithoutABarTheDisplayXRangeStillScopes() {
        let left = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let right = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
        let frames = buttons(under: bar(on: left)) + buttons(under: bar(on: right))
        XCTAssertEqual(DesktopMover.buttonIndices(of: frames, on: right, bar: nil), [3, 4, 5])
    }

    /// Every filter missing degrades to the whole list rather than to no move.
    func testAFilterThatMatchesNothingKeepsEveryThumbnail() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let elsewhere = CGRect(x: 5000, y: 5000, width: 400, height: 120)
        let frames = buttons(under: bar(on: display))
        XCTAssertEqual(
            DesktopMover.buttonIndices(of: frames, on: elsewhere, bar: elsewhere),
            Array(frames.indices))
    }

    /// A single display reaches the same list by every route, which is what makes this change a
    /// no-op for the setup it was not written for.
    func testASingleDisplayIsUnaffectedByTheScoping() {
        let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let only = bar(on: display)
        let frames = buttons(under: only, count: 5)
        let all = Array(frames.indices)
        XCTAssertEqual(DesktopMover.buttonIndices(of: frames, on: display, bar: only), all)
        XCTAssertEqual(DesktopMover.buttonIndices(of: frames, on: display, bar: nil), all)
        XCTAssertEqual(DesktopMover.buttonIndices(of: frames, on: nil, bar: nil), all)
    }

    // MARK: - Aiming at a thumbnail

    /// The measured macOS 27 case: frames whose left edges sit on the thumbnail centres, so the
    /// row as a whole is half a frame right of centre. Centring it puts each aim on `minX`.
    func testFramesOffsetByHalfTheirWidthAreAimedAtTheirLeftEdge() {
        let bar = CGRect(x: 0, y: 0, width: 2056, height: 194)
        let xs: [CGFloat] = [599, 771, 942, 1113, 1284, 1456]
        let frames = xs.map { CGRect(x: $0, y: 125, width: 169, height: 129) }
        let centres = DesktopMover.thumbnailCentres(of: frames, in: bar)
        for (centre, x) in zip(centres, xs) {
            XCTAssertEqual(centre, x, accuracy: 2)
        }
    }

    /// Label frames already centred on the bar — what earlier macOS reported — are left alone, so
    /// the midpoint that shipped stays the answer there.
    func testFramesAlreadyCentredKeepTheirMidpoints() {
        let bar = CGRect(x: 0, y: 0, width: 2000, height: 78)
        let frames = [800, 940, 1080].map { CGRect(x: $0, y: 84, width: 120, height: 14) }
        XCTAssertEqual(
            DesktopMover.thumbnailCentres(of: frames, in: bar), frames.map(\.midX))
    }

    /// A bar on a second display corrects against that bar, not the first one's.
    func testCentringUsesTheBarItWasGiven() {
        let bar = CGRect(x: 2056, y: 0, width: 1440, height: 194)
        let frames = [2600, 2770].map { CGRect(x: $0, y: 125, width: 169, height: 129) }
        let centres = DesktopMover.thumbnailCentres(of: frames, in: bar)
        XCTAssertEqual((centres[0] + centres[1]) / 2, bar.midX, accuracy: 0.001)
        XCTAssertEqual(centres[1] - centres[0], 170)
    }

    func testNoFramesGiveNoCentres() {
        XCTAssertEqual(DesktopMover.thumbnailCentres(of: [], in: .zero), [])
    }

    // MARK: - Taking hold

    /// The midpoint leads, because it is what shipped and it is the title bar in every native
    /// window; the rest sit either side of a centred control, all on the same title-bar row.
    func testGrabPointsLeadWithTheMidpointAndStayOnTheTitleBar() {
        let bounds = CGRect(x: 100, y: 50, width: 1200, height: 800)
        let points = DesktopMover.grabPoints(for: bounds)
        XCTAssertEqual(points.first?.x, bounds.midX)
        XCTAssertEqual(points.count, 4)
        XCTAssertEqual(Set(points.map(\.y)).count, 1)
        XCTAssertTrue(points.allSatisfy { $0.y > bounds.minY && $0.y < bounds.minY + 30 })
        XCTAssertTrue(points.allSatisfy { $0.x > bounds.minX && $0.x < bounds.maxX })
        XCTAssertEqual(Set(points.map(\.x)).count, points.count, "no point is tried twice")
    }

    /// A window too narrow to hold a point loses it rather than getting a clamped duplicate.
    func testGrabPointsANarrowWindowCannotHoldAreDropped() {
        let narrow = CGRect(x: 0, y: 0, width: 80, height: 300)
        let points = DesktopMover.grabPoints(for: narrow)
        XCTAssertEqual(points.count, 3)
        XCTAssertTrue(points.allSatisfy { $0.x > narrow.minX && $0.x < narrow.maxX })
    }
}
