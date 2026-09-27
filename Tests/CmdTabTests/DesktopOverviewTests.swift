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
}
