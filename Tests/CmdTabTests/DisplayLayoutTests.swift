import CoreGraphics
import XCTest

@testable import CmdTab

/// `DisplayLayout` resolves a display's own tile size and column count from its visible frame and
/// backing scale, so a laptop screen and the 6K external beside it stop drawing identical panels.
/// Pure over the two inputs on purpose — a test cannot arrange a mixed desk of real `NSScreen`s.
final class DisplayLayoutTests: XCTestCase {
    // MARK: - tileScale

    func testRetinaScreensGetNoCorrection() {
        XCTAssertEqual(DisplayLayout.tileScale(backingScale: 2), 1)
        XCTAssertEqual(DisplayLayout.tileScale(backingScale: 3), 1, "denser than reference either")
    }

    func testNonRetinaExternalGrowsTiles() {
        let scale = DisplayLayout.tileScale(backingScale: 1)
        XCTAssertGreaterThan(scale, 1, "a 1x display shows more screen per point than the sliders assume")
        XCTAssertLessThanOrEqual(scale, 1.4, "clamped short of the full 2x ratio")
    }

    func testZeroOrNegativeScaleIsIgnored() {
        XCTAssertEqual(DisplayLayout.tileScale(backingScale: 0), 1)
    }

    // MARK: - metrics

    func testMetricsUnchangedOnRetina() {
        let base = Metrics.default
        XCTAssertEqual(DisplayLayout.metrics(base: base, backingScale: 2), base)
    }

    func testMetricsGrowOnANonRetinaExternal() {
        let base = Metrics.default
        let scaled = DisplayLayout.metrics(base: base, backingScale: 1)
        XCTAssertGreaterThan(scaled.iconSize, base.iconSize)
        XCTAssertGreaterThanOrEqual(scaled.iconSize, base.iconSize)
    }

    func testMetricsStayWithinTheSliderRanges() {
        // A tiny backing scale is not realistic hardware, but a hand-edited defaults plist or a
        // future display class could still hand one to `columns(for:on:cap:)`; the correction must
        // not escape the ranges `Metrics.init` already enforces.
        let scaled = DisplayLayout.metrics(base: Metrics.default, backingScale: 0.5)
        XCTAssertLessThanOrEqual(scaled.iconSize, Metrics.iconSizeRange.upperBound)
    }

    // MARK: - columns: laptop, large external, vertically stacked pair

    func testLaptopScreenFitsFewerColumnsThanALargeExternal() {
        let metrics = Metrics.default
        let laptop = DisplayLayout.columns(
            targetCount: 40, mode: .apps, layout: .grid, showsTitle: false, metrics: metrics,
            visibleSize: CGSize(width: 1440, height: 900), cap: 0)
        let external = DisplayLayout.columns(
            targetCount: 40, mode: .apps, layout: .grid, showsTitle: false, metrics: metrics,
            visibleSize: CGSize(width: 5120, height: 2880), cap: 0)
        XCTAssertGreaterThan(external, laptop, "the wider screen has room for more columns")
    }

    func testMaxColumnsCapsBothScreensAlike() {
        let metrics = Metrics.default
        let external = DisplayLayout.columns(
            targetCount: 40, mode: .apps, layout: .grid, showsTitle: false, metrics: metrics,
            visibleSize: CGSize(width: 5120, height: 2880), cap: 4)
        XCTAssertEqual(external, 4, "the user's ceiling still wins even where more would fit")
    }

    func testVerticallyStackedPairWrapsListColumnsOnHeightNotWidth() {
        let metrics = Metrics.default
        // A vertically stacked pair reports a narrow, short visible frame per screen relative to a
        // side-by-side desk — modelled here as a screen tall enough for very few list rows.
        let short = DisplayLayout.columns(
            targetCount: 30, mode: .windows, layout: .list, showsTitle: false, metrics: metrics,
            visibleSize: CGSize(width: 1200, height: 500), cap: 0)
        let tall = DisplayLayout.columns(
            targetCount: 30, mode: .windows, layout: .list, showsTitle: false, metrics: metrics,
            visibleSize: CGSize(width: 1200, height: 2000), cap: 0)
        XCTAssertGreaterThan(short, tall, "less vertical room wraps the list into more columns")
    }

    func testEmptyTargetListNeedsOneColumn() {
        XCTAssertEqual(
            DisplayLayout.columns(
                targetCount: 0, mode: .apps, layout: .grid, showsTitle: false,
                metrics: Metrics.default, visibleSize: CGSize(width: 1440, height: 900), cap: 0),
            1)
    }

    // MARK: - fitted: shrinking to the screen, since the panel does not scroll

    /// A 13" laptop's visible frame, where the overflows were measured.
    private let laptop = CGSize(width: 1470, height: 851)

    private func fitted(
        _ count: Int, _ mode: SwitcherMode, _ layout: SwitcherLayout, base: Metrics = .default,
        cap: Int = 0
    ) -> Metrics {
        DisplayLayout.fitted(
            base, targetCount: count, mode: mode, layout: layout, showsTitle: mode == .windows,
            visibleSize: laptop, cap: cap)
    }

    private func fits(
        _ metrics: Metrics, _ count: Int, _ mode: SwitcherMode, _ layout: SwitcherLayout,
        cap: Int = 0
    ) -> Bool {
        DisplayLayout.fits(
            metrics, targetCount: count, mode: mode, layout: layout,
            showsTitle: mode == .windows, visibleSize: laptop, cap: cap)
    }

    /// The ordinary session is left exactly as the user set it.
    func testAListThatAlreadyFitsIsNotShrunk() {
        XCTAssertEqual(fitted(12, .apps, .grid), .default)
        XCTAssertEqual(fitted(12, .windows, .list), .default)
    }

    /// The grid only ever wrapped on width, so its rows ran off the bottom of the screen.
    func testAGridTooTallForTheScreenShrinksUntilItFits() {
        XCTAssertFalse(fits(.default, 120, .windows, .grid), "precondition: it overflowed")
        let metrics = fitted(120, .windows, .grid)
        XCTAssertLessThan(metrics.iconSize, Metrics.default.iconSize)
        XCTAssertTrue(fits(metrics, 120, .windows, .grid))
    }

    /// The list only ever wrapped on height, so its columns ran off the side.
    func testAListTooWideForTheScreenShrinksUntilItFits() {
        let large = Metrics(iconSize: 128, iconSpacing: 2, titleSpacing: 2)
        XCTAssertFalse(fits(large, 40, .windows, .list), "precondition: it overflowed")
        XCTAssertTrue(fits(fitted(40, .windows, .list, base: large), 40, .windows, .list))
    }

    /// The column ceiling forces rows the screen may not have — for either layout.
    func testAColumnCapIsHonouredByShrinkingRatherThanOverflowing() {
        for layout in [SwitcherLayout.grid, .list] {
            let metrics = fitted(30, .apps, layout, cap: 3)
            XCTAssertTrue(fits(metrics, 30, .apps, layout, cap: 3), "\(layout)")
            XCTAssertEqual(
                DisplayLayout.columns(
                    targetCount: 30, mode: .apps, layout: layout, showsTitle: false,
                    metrics: metrics, visibleSize: laptop, cap: 3),
                3, "the cap itself still holds")
        }
    }

    /// Past the slider's floor there is nothing left to give: it stops there rather than spinning,
    /// and the remainder overflows.
    func testAnImpossibleCountStopsAtTheSmallestIcon() {
        let metrics = fitted(5000, .windows, .grid)
        XCTAssertEqual(metrics.iconSize, Metrics.iconSizeRange.lowerBound)
        XCTAssertFalse(fits(metrics, 5000, .windows, .grid))
    }

    /// Three Desktops of 23 windows: 69 tiles fit the laptop as one grid, but each Desktop wraps
    /// onto its own third row and carries a header, so drawn as an overview it ran off the bottom.
    func testAnOverviewThatFitsByTileCountButNotByRowsAndHeadersIsShrunk() {
        let sizes = [23, 23, 23]
        func fits(_ metrics: Metrics, sections: [Int]?) -> Bool {
            DisplayLayout.fits(
                metrics, targetCount: 69, mode: .windows, layout: .grid, showsTitle: true,
                visibleSize: laptop, cap: 0, sectionSizes: sections)
        }
        XCTAssertTrue(fits(.default, sections: nil), "precondition: fits as one grid")
        XCTAssertFalse(fits(.default, sections: sizes), "precondition: overflows sectioned")

        let shrunk = DisplayLayout.fitted(
            .default, targetCount: 69, mode: .windows, layout: .grid, showsTitle: true,
            visibleSize: laptop, cap: 0, sectionSizes: sizes)
        XCTAssertLessThan(shrunk.iconSize, Metrics.default.iconSize)
        XCTAssertTrue(fits(shrunk, sections: sizes))
    }

    /// One section draws no headers, so it is the plain grid — the answer must not change.
    func testASingleSectionIsTheFlatGrid() {
        XCTAssertEqual(
            DisplayLayout.fits(
                .default, targetCount: 69, mode: .windows, layout: .grid, showsTitle: true,
                visibleSize: laptop, cap: 0, sectionSizes: [69]),
            DisplayLayout.fits(
                .default, targetCount: 69, mode: .windows, layout: .grid, showsTitle: true,
                visibleSize: laptop, cap: 0))
    }
}
