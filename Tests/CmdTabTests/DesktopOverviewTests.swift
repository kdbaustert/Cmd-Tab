import XCTest

@testable import CmdTab

/// The Desktops overview's two pure halves: the Desktop-sorted order the scope produces, and the
/// sections the view draws headers over.
@MainActor
final class DesktopOverviewTests: XCTestCase {
    private func window(_ title: String, space: Int?) -> SwitchTarget {
        var target = SwitchTarget(
            id: "win:\(title)", kind: .app(1), title: title, appName: "App",
            icon: nil, isMinimized: false, isHidden: false)
        target.spaceIndex = space
        return target
    }

    // MARK: - Ordering

    /// Stable by Desktop, with the placeless windows one group at the very end — minimized windows
    /// occupy no Space, and scattering them through the list would put "somewhere" tiles between
    /// every Desktop's runs.
    func testWindowsSortByDesktopKeepingOrderWithinOneAndPlacelessLast() {
        let sorted = SwitcherController.groupedByDesktop([
            window("b1", space: 1),
            window("dockA", space: nil),
            window("a1", space: 0),
            window("b2", space: 1),
            window("a2", space: 0),
        ])
        XCTAssertEqual(sorted.map(\.title), ["a1", "a2", "b1", "b2", "dockA"])
    }

    /// A single-Desktop machine tags nothing with a Space, so the overview is the list untouched —
    /// the identity, not a reshuffle.
    func testAListWithNoDesktopsKeepsItsOrder() {
        let list = [window("one", space: nil), window("two", space: nil)]
        XCTAssertEqual(
            SwitcherController.groupedByDesktop(list).map(\.title), ["one", "two"])
    }

    // MARK: - Sections

    func testSectionsAreTheContiguousDesktopRuns() {
        let targets = SwitcherController.groupedByDesktop([
            window("a1", space: 0), window("a2", space: 0),
            window("c1", space: 2),
            window("dock", space: nil),
        ])
        let sections = SwitcherModel.desktopSections(targets)
        XCTAssertEqual(sections.count, 3)
        XCTAssertEqual(sections[0], .init(spaceIndex: 0, range: 0..<2))
        XCTAssertEqual(sections[1], .init(spaceIndex: 2, range: 2..<3))
        XCTAssertEqual(sections[2], .init(spaceIndex: nil, range: 3..<4), "the placeless group")
    }

    /// One section means no headers — the view's rule — and that is exactly what a list with no
    /// Desktop information collapses to.
    func testAListWithNoDesktopsIsOneSection() {
        let sections = SwitcherModel.desktopSections([
            window("one", space: nil), window("two", space: nil),
        ])
        XCTAssertEqual(sections, [.init(spaceIndex: nil, range: 0..<2)])
    }

    func testAnEmptyListHasNoSections() {
        XCTAssertEqual(SwitcherModel.desktopSections([]), [])
    }

    // MARK: - Opening highlight

    /// MRU A (Desktop 3, front), B (Desktop 1), C (Desktop 1): the tap means "the window used before
    /// this one", which is B. The sorted list is B, C, A — where index 1 is C.
    func testTapPicksTheMRUNeighbourNotTheSortedOne() {
        let mru = [window("A", space: 2), window("B", space: 0), window("C", space: 0)]
        let grouped = SwitcherController.groupedByDesktop(mru)
        XCTAssertEqual(grouped.map(\.title), ["B", "C", "A"])
        let tap = TargetProvider.tapIndex(in: mru, pinned: false, mru: [])
        XCTAssertEqual(SwitcherController.indexInGrouped(tap, mruOrder: mru, grouped: grouped), 0)
        // Backwards is the oldest window, which is C, not whatever the sort put last.
        XCTAssertEqual(
            SwitcherController.indexInGrouped(mru.count - 1, mruOrder: mru, grouped: grouped), 1)
    }

    func testAnUnsortedListMapsToItself() {
        let list = [window("a", space: nil), window("b", space: nil)]
        XCTAssertEqual(SwitcherController.indexInGrouped(1, mruOrder: list, grouped: list), 1)
        XCTAssertEqual(SwitcherController.indexInGrouped(0, mruOrder: [], grouped: []), 0)
    }

    /// A narrowing scope (minimized, this display, this Desktop) is a subset, not a reordering:
    /// the index already counts the subset, so mapping it through the full list would name a tile
    /// the filter removed — or run past the end of the shorter list.
    func testAFilteredSubsetIsNotRemapped() {
        let all = [
            window("a", space: nil), window("b", space: nil), window("c", space: nil),
            window("d", space: nil),
        ]
        let subset = [all[1], all[3]]
        XCTAssertEqual(SwitcherController.indexInGrouped(1, mruOrder: all, grouped: subset), 1)
        XCTAssertEqual(SwitcherController.indexInGrouped(3, mruOrder: all, grouped: subset), 3)
    }

    // MARK: - Row stepping

    /// Desktops of 2, 3 and 4 windows at 6 columns: each is a single short row, so ↓ goes to the
    /// next Desktop at the same column (clamped), never past it.
    func testDownStepsThroughEachDesktopInTurn() {
        let model = SwitcherModel()
        model.groupsByDesktop = true
        model.begin(
            (0..<2).map { window("a\($0)", space: 0) } + (0..<3).map { window("b\($0)", space: 1) }
                + (0..<4).map { window("c\($0)", space: 2) })
        model.selection = 0
        model.stepRow(1, stride: 6)
        XCTAssertEqual(model.selection, 2, "Desktop 2, same column")
        model.selection = 1
        model.stepRow(1, stride: 6)
        XCTAssertEqual(model.selection, 3)
        model.selection = 4
        model.stepRow(1, stride: 6)
        XCTAssertEqual(model.selection, 7, "column 2 of Desktop 3")
        model.stepRow(1, stride: 6)
        XCTAssertEqual(model.selection, 1, "wraps to the first Desktop, clamped to its last tile")
    }

    func testUpMirrorsDownAcrossDesktops() {
        let model = SwitcherModel()
        model.groupsByDesktop = true
        // Two columns: Desktop 1 has 3 windows (two rows), Desktop 2 has 1.
        model.begin(
            (0..<3).map { window("a\($0)", space: 0) } + [window("b0", space: 1)])
        model.selection = 3
        model.stepRow(-1, stride: 2)
        XCTAssertEqual(model.selection, 2, "last row of Desktop 1, column 0")
        model.stepRow(-1, stride: 2)
        XCTAssertEqual(model.selection, 0)
        model.stepRow(-1, stride: 2)
        XCTAssertEqual(model.selection, 3, "wraps to the last Desktop")
    }
}
