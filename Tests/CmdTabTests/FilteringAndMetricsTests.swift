import SwiftUI
import XCTest

@testable import CmdTab

/// Type-to-filter matching, panel sizing, and the settings round-trip for the highlight colour.
@MainActor
final class FilteringAndMetricsTests: XCTestCase {
    private func target(_ title: String, app: String, pid: pid_t = 1) -> SwitchTarget {
        SwitchTarget(
            id: "\(pid):\(title)", kind: .app(pid), title: title, appName: app,
            icon: nil, isMinimized: false, isHidden: false)
    }

    private var sample: [SwitchTarget] {
        [
            target("Safari", app: "Safari"),
            target("Xcode", app: "Xcode", pid: 2),
            target("Google Chrome", app: "Google Chrome", pid: 3),
        ]
    }

    // MARK: - Filtering

    func testEmptyQueryKeepsEverything() {
        XCTAssertEqual(SwitcherModel.filtered(sample, query: "").count, 3)
    }

    /// A query of only spaces splits into no words, which must mean "no filter" rather than
    /// "match nothing".
    func testWhitespaceOnlyQueryKeepsEverything() {
        XCTAssertEqual(SwitcherModel.filtered(sample, query: "   ").count, 3)
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(SwitcherModel.filtered(sample, query: "SAFARI").map(\.title), ["Safari"])
    }

    func testMatchIsASubstringNotAPrefix() {
        XCTAssertEqual(SwitcherModel.filtered(sample, query: "chrome").map(\.title), ["Google Chrome"])
    }

    /// Every word has to match somewhere, but not in order and not adjacently — this is what makes
    /// "saf 2" find "Safari" window 2.
    func testAllWordsMustMatchInAnyOrder() {
        XCTAssertEqual(
            SwitcherModel.filtered(sample, query: "chrome google").map(\.title), ["Google Chrome"])
        XCTAssertTrue(SwitcherModel.filtered(sample, query: "google safari").isEmpty)
    }

    func testNoMatchYieldsEmpty() {
        XCTAssertTrue(SwitcherModel.filtered(sample, query: "zzz").isEmpty)
    }

    /// The window title and the app name are searched as one haystack, so a window can be found by
    /// the app that owns it.
    func testAppNameIsSearchedAlongsideTitle() {
        let windows = [target("Inbox — 3 unread", app: "Mail", pid: 4)]
        XCTAssertEqual(SwitcherModel.filtered(windows, query: "mail").count, 1)
        XCTAssertEqual(SwitcherModel.filtered(windows, query: "mail inbox").count, 1)
    }

    // MARK: - Model state

    func testSetQueryResetsSelectionToTopMatch() {
        let model = SwitcherModel()
        model.begin(sample)
        model.selection = 2
        model.setQuery("o")
        XCTAssertEqual(model.selection, 0)
    }

    /// A query matching nothing must not leave the panel claiming it has a selection — `selected`
    /// backs the caption and the window actions.
    func testSelectedIsNilWhenQueryMatchesNothing() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setQuery("zzz")
        XCTAssertTrue(model.isEmpty)
        XCTAssertNil(model.selected)
        // The full list still has entries, which is what keeps the panel up to be backspaced.
        XCTAssertTrue(model.hasAnyTarget)
    }

    /// `begin` starts a fresh session, so a query left over from the previous one must not silently
    /// narrow the new list.
    func testBeginClearsPreviousQuery() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setQuery("safari")
        model.begin(sample)
        XCTAssertEqual(model.query, "")
        XCTAssertEqual(model.targets.count, 3)
    }

    func testStepWrapsInBothDirections() {
        let model = SwitcherModel()
        model.begin(sample)
        model.selection = 2
        model.step(1)
        XCTAssertEqual(model.selection, 0)
        model.step(-1)
        XCTAssertEqual(model.selection, 2)
    }

    func testStepOnEmptyListDoesNotCrash() {
        let model = SwitcherModel()
        model.begin([])
        model.step(1)
        XCTAssertEqual(model.selection, 0)
    }

    // MARK: - Metrics

    /// Values can arrive from a hand-edited defaults plist, so the initialiser clamps rather than
    /// trusts — an unclamped icon size would size the panel off the screen.
    func testMetricsClampOutOfRangeValues() {
        let tiny = Metrics(iconSize: -100, iconSpacing: -5, titleSpacing: -1)
        XCTAssertEqual(tiny.iconSize, Metrics.iconSizeRange.lowerBound)
        XCTAssertEqual(tiny.iconSpacing, Metrics.iconSpacingRange.lowerBound)
        XCTAssertEqual(tiny.titleSpacing, Metrics.titleSpacingRange.lowerBound)

        let huge = Metrics(iconSize: 9999, iconSpacing: 9999, titleSpacing: 9999)
        XCTAssertEqual(huge.iconSize, Metrics.iconSizeRange.upperBound)
        XCTAssertEqual(huge.iconSpacing, Metrics.iconSpacingRange.upperBound)
        XCTAssertEqual(huge.titleSpacing, Metrics.titleSpacingRange.upperBound)
    }

    /// A titled app tile has to be paid for in both axes, or the title renders outside the tile the
    /// hit-test reports.
    func testTitledAppTileIsLargerThanUntitled() {
        let metrics = Metrics.default
        let plain = metrics.tile(for: .apps, showsTitle: false)
        let titled = metrics.tile(for: .apps, showsTitle: true)
        XCTAssertGreaterThan(titled.width, plain.width)
        XCTAssertGreaterThan(titled.height, plain.height)
    }

    /// Window mode always carries a title, so `showsTitle` cannot shrink it.
    func testWindowTileIgnoresShowsTitle() {
        let metrics = Metrics.default
        XCTAssertEqual(
            metrics.tile(for: .windows, showsTitle: false),
            metrics.tile(for: .windows, showsTitle: true))
    }

    // MARK: - Colour round-trip

    /// The highlight colour is persisted as a hex string, so a lossy round-trip would drift the
    /// user's colour every time settings are saved.
    func testColorHexRoundTrips() {
        for hex in ["#FF0000", "#00FF00", "#0000FF", "#123456", "#FFFFFF", "#000000"] {
            guard let color = Color(hex: hex) else {
                return XCTFail("failed to parse \(hex)")
            }
            XCTAssertEqual(color.hexString, hex)
        }
    }

    func testColorHexAcceptsMissingHash() {
        XCTAssertEqual(Color(hex: "FF0000")?.hexString, "#FF0000")
    }

    func testColorHexRejectsMalformedInput() {
        XCTAssertNil(Color(hex: "#FFF"))
        XCTAssertNil(Color(hex: "#GGGGGG"))
        XCTAssertNil(Color(hex: ""))
    }
}
