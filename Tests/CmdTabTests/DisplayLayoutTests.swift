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
}
