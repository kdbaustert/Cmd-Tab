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

    /// An installed app offered as a launch tile, built the way
    /// `SwitcherController.updateLaunchSuggestions` builds one.
    private func launchable(_ name: String) -> SwitchTarget {
        SwitchTarget(
            id: "launch:\(name)", kind: .launch(URL(fileURLWithPath: "/Applications/\(name).app")),
            title: name, appName: name, icon: nil, isMinimized: false, isHidden: false)
    }

    // MARK: - Filtering

    /// The titles a query matches, in list order.
    ///
    /// Goes through `matchingIndices`, which is the rule the panel actually applies: it dims
    /// non-matches rather than removing them, so there is no filtered list in production to assert
    /// against. An empty match set means "no filter", which is why the two empty-query cases below
    /// ask the model instead of coming through here.
    private func matches(_ list: [SwitchTarget], query: String) -> [String] {
        SwitcherModel.matchingIndices(list, query: query).sorted().map { list[$0].title }
    }

    func testEmptyQueryKeepsEverything() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setQuery("")
        XCTAssertEqual(model.targets.count, 3)
        XCTAssertTrue(model.matchingIndices.isEmpty)  // nothing marked = nothing filtered out
    }

    /// A query of only spaces splits into no words, which must mean "no filter" rather than
    /// "match nothing".
    func testWhitespaceOnlyQueryKeepsEverything() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setQuery("   ")
        XCTAssertEqual(model.targets.count, 3)
        XCTAssertTrue(model.matchingIndices.isEmpty)
    }

    /// The space bar must not move the highlight.
    ///
    /// Space is an ordinary type-to-filter character, so it arrives as a query — and a query of one
    /// space has no words in it. `matchingIndices` had always trimmed first and answered "nothing
    /// matches"; `bestMatch` had not, and every target tied on a score of 0, so it handed back index
    /// 0. Pressing space part-way through a cycle threw the selection back to the frontmost app with
    /// nothing marked as matching to explain why.
    func testWhitespaceOnlyQueryLeavesTheSelectionAlone() {
        let model = SwitcherModel()
        model.begin(sample)
        model.selection = 2
        model.setQuery(" ")
        XCTAssertEqual(model.selection, 2)
        XCTAssertTrue(model.matchingIndices.isEmpty)
    }

    /// The other half of the same rule, from the other direction: a query that does match still
    /// moves the highlight to the best match, so the guard above did not simply disable selection.
    func testARealQueryStillMovesTheSelection() {
        let model = SwitcherModel()
        model.begin(sample)
        model.selection = 0
        model.setQuery("chrome")
        XCTAssertEqual(model.selected?.title, "Google Chrome")
    }

    func testMatchIsCaseInsensitive() {
        XCTAssertEqual(matches(sample, query: "SAFARI"), ["Safari"])
    }

    // MARK: - Running beats launchable

    /// The rule that makes it safe to show launch tiles alongside the running ones rather than only
    /// when nothing matched.
    ///
    /// "Safari" scores identically against a running Safari and an installed one, and the launch
    /// tile is a *better* match than a running "Safari Technology Preview" would be — so without
    /// this rule, widening the suggestions would have made ⌘-Tab-then-type start launching second
    /// copies of apps that were already open.
    func testARunningAppOutranksALaunchTileThatScoresHigher() {
        let list = [target("Safari Technology Preview", app: "Safari Technology Preview")]
            + [launchable("Safari")]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "safari").map { list[$0].title },
            "Safari Technology Preview")
    }

    /// Exact same name, one running and one installed: the running one still wins, whichever order
    /// they sit in.
    func testARunningAppWinsAgainstAnIdenticalLaunchTileEitherWayRound() {
        let running = target("Chess", app: "Chess")
        let installed = launchable("Chess")
        XCTAssertFalse(
            SwitcherModel.bestMatch([running, installed], query: "chess")
                .map { [running, installed][$0].isLaunchable } ?? true)
        XCTAssertFalse(
            SwitcherModel.bestMatch([installed, running], query: "chess")
                .map { [installed, running][$0].isLaunchable } ?? true)
    }

    /// And the other half: with nothing running that matches, the launch tile is selected — which is
    /// the behaviour that existed before the widening and still has to hold.
    func testALaunchTileIsSelectedWhenNothingRunningMatches() {
        let list = sample + [launchable("Numbers")]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "numbers").map { list[$0].title }, "Numbers")
    }

    /// Between two launch tiles the score decides, exactly as it does between two running apps —
    /// the rule is a preference between the groups, not a suspension of ranking inside one.
    func testBetweenTwoLaunchTilesTheScoreStillDecides() {
        let list = [launchable("Notes"), launchable("No Such App")]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "notes").map { list[$0].title }, "Notes")
    }

    /// The suggestions sit at the end of the list, so the running tiles keep every index they had —
    /// which is what ⌘-number, hit-testing and the caption all depend on.
    func testLaunchSuggestionsAreAppendedWithoutMovingTheRunningTiles() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setLaunchSuggestions([launchable("Numbers")])
        XCTAssertEqual(model.targets.count, 4)
        XCTAssertEqual(model.targets.prefix(3).map(\.title), sample.map(\.title))
        XCTAssertTrue(model.targets[3].isLaunchable)
    }

    func testMatchIsASubstringNotAPrefix() {
        XCTAssertEqual(matches(sample, query: "chrome"), ["Google Chrome"])
    }

    /// Every word has to match somewhere, but not in order and not adjacently — this is what makes
    /// "saf 2" find "Safari" window 2.
    func testAllWordsMustMatchInAnyOrder() {
        XCTAssertEqual(matches(sample, query: "chrome google"), ["Google Chrome"])
        XCTAssertTrue(matches(sample, query: "google safari").isEmpty)
    }

    func testNoMatchYieldsEmpty() {
        XCTAssertTrue(matches(sample, query: "zzz").isEmpty)
    }

    /// The window title and the app name are searched as one haystack, so a window can be found by
    /// the app that owns it.
    func testAppNameIsSearchedAlongsideTitle() {
        let windows = [target("Inbox — 3 unread", app: "Mail", pid: 4)]
        XCTAssertEqual(matches(windows, query: "mail").count, 1)
        XCTAssertEqual(matches(windows, query: "mail inbox").count, 1)
    }

    // MARK: - Model state

    func testSetQueryResetsSelectionToTopMatch() {
        let model = SwitcherModel()
        model.begin(sample)
        model.selection = 2
        // "o" matches Xcode (index 1) and Google Chrome (index 2)
        model.setQuery("o")
        XCTAssertEqual(model.selection, 1)  // first matching index
    }

    /// A query matching nothing keeps all tiles visible but matchingIndices is empty.
    func testQueryMatchingNothingKeepsTilesVisible() {
        let model = SwitcherModel()
        model.begin(sample)
        model.setQuery("zzz")
        // All tiles remain visible
        XCTAssertEqual(model.targets.count, 3)
        // But none match
        XCTAssertTrue(model.matchingIndices.isEmpty)
        // The full list still has entries
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

    // MARK: - Row navigation

    /// `count` tiles, the ones named in `matching` carrying a token `findme` picks out.
    ///
    /// The token has no letter in common with the others' names, so the match set below is exactly
    /// the one asked for rather than whatever the fuzzy matcher happens to think of "tile3".
    private func tiles(_ count: Int, matching: Set<Int> = []) -> [SwitchTarget] {
        (0..<count).map { index in
            let name = matching.contains(index) ? "tile\(index) findme" : "tile\(index)"
            return target(name, app: name, pid: pid_t(index + 1))
        }
    }

    /// A whole row at a time, which is the one direction ← and → cannot reach in fewer than
    /// `columns` presses.
    func testDownMovesOneRowInAGrid() {
        let model = SwitcherModel()
        model.begin(tiles(9))
        model.selection = 0
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 3)
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 6)
    }

    func testUpMovesOneRowBack() {
        let model = SwitcherModel()
        model.begin(tiles(9))
        model.selection = 7
        model.stepRow(-1, stride: 3)
        XCTAssertEqual(model.selection, 4)
    }

    /// Wrapping keeps the column, which is what makes a grid read as a grid: ↑ from the top row
    /// lands under the very tile it started above, and ↓ brings it straight back.
    func testWrappingKeepsTheColumn() {
        let model = SwitcherModel()
        model.begin(tiles(9))
        model.selection = 1
        model.stepRow(-1, stride: 3)
        XCTAssertEqual(model.selection, 7)
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 1)
    }

    /// The case a plain modulo over the flat index gets wrong. Eight tiles in rows of three leaves
    /// the last row one short, so wrapping the index alone would shift the column by one.
    func testARaggedLastRowDoesNotShiftTheColumn() {
        let model = SwitcherModel()
        model.begin(tiles(8))  // rows: [0 1 2] [3 4 5] [6 7]
        model.selection = 0
        model.stepRow(-1, stride: 3)
        XCTAssertEqual(model.selection, 6)
        model.selection = 1
        model.stepRow(-1, stride: 3)
        XCTAssertEqual(model.selection, 7)
    }

    /// That short row has no third column, so the nearest tile in it takes the press rather than
    /// the row being skipped — no arrow press is ever a silent no-op.
    func testAMissingCellInAShortRowTakesTheLastTile() {
        let model = SwitcherModel()
        model.begin(tiles(8))  // rows: [0 1 2] [3 4 5] [6 7]
        model.selection = 5
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 7)
    }

    /// One row means there is nowhere to go, and the press must not throw the highlight elsewhere.
    func testASingleRowStaysPut() {
        let model = SwitcherModel()
        model.begin(tiles(3))
        model.selection = 1
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 1)
    }

    /// The list layout fills each of its columns top to bottom, so one row along is one index
    /// along. The stride carries the whole of the difference between the two layouts.
    func testAStrideOfOneWalksTheListOneAtATime() {
        let model = SwitcherModel()
        model.begin(tiles(4))
        model.selection = 3
        model.stepRow(1, stride: 1)
        XCTAssertEqual(model.selection, 0)
        model.stepRow(-1, stride: 1)
        XCTAssertEqual(model.selection, 3)
    }

    /// Filtering dims tiles rather than removing them, so a row move is measured in screen
    /// positions and only then landed on a tile the filter allows. Stepping `columns` *matches*
    /// along instead — which is what `step` would do — travels several rows on a sparse list.
    func testARowMoveLandsOnTheNearestMatchInTheDirectionOfTravel() {
        let model = SwitcherModel()
        model.begin(tiles(9, matching: [0, 5]))
        model.setQuery("findme")
        XCTAssertEqual(model.matchingIndices, [0, 5])
        model.selection = 0
        // One row down from 0 is 3, which is dimmed; 5 is the next tile along that is not.
        model.stepRow(1, stride: 3)
        XCTAssertEqual(model.selection, 5)
    }

    func testARowMoveUpwardsScansBackwards() {
        let model = SwitcherModel()
        model.begin(tiles(9, matching: [1, 8]))
        model.setQuery("findme")
        model.selection = 8
        // One row up from 8 is 5, which is dimmed; scanning back reaches 1.
        model.stepRow(-1, stride: 3)
        XCTAssertEqual(model.selection, 1)
    }

    func testRowMoveOnAnEmptyListDoesNotCrash() {
        let model = SwitcherModel()
        model.begin([])
        model.stepRow(1, stride: 3)
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
