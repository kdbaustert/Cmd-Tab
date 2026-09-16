import XCTest

@testable import CmdTab

/// The marked set: toggling it, clearing it on close, which targets a set-capable action reaches,
/// and the arrangement ⌥T assigns to it.
///
/// All pure model/logic — no Accessibility calls and no window-server interaction. `SwitcherModel`
/// is exercised directly, the same way `FilteringAndMetricsTests` and `SwitcherTileTests` do; the
/// controller's own dispatch (`actionTargets`, `tileMarkedWindows`) is not reachable from a test that
/// may not open an event tap, so its two load-bearing pieces of logic are tested at the seam each is
/// pulled out to: `SwitcherModel.markedTargets` for target resolution, `MarkedTiling.arrangements`
/// for the tiling assignment.
@MainActor
final class MarkedTilesTests: XCTestCase {
    private func app(_ name: String, pid: pid_t) -> SwitchTarget {
        SwitchTarget(
            id: "\(pid):\(name)", kind: .app(pid), title: name, appName: name,
            icon: nil, isMinimized: false, isHidden: false)
    }

    /// A window tile. `AXUIElementCreateApplication` builds an inert CF handle — it talks to no
    /// process and needs no Accessibility permission, since nothing here ever reads an attribute off
    /// it. Good enough to satisfy `SwitchTarget.Kind.window`'s associated value for a test that only
    /// cares which case it is.
    private func window(_ name: String, pid: pid_t) -> SwitchTarget {
        SwitchTarget(
            id: "w\(pid):\(name)", kind: .window(pid, AXUIElementCreateApplication(pid)),
            title: name, appName: name, icon: nil, isMinimized: false, isHidden: false)
    }

    private func model(with targets: [SwitchTarget]) -> SwitcherModel {
        let model = SwitcherModel()
        model.begin(targets)
        return model
    }

    // MARK: - Toggling

    func testTogglingAtAnIndexMarksAndUnmarksThatTile() {
        let model = model(with: [app("Safari", pid: 1), app("Mail", pid: 2)])
        XCTAssertFalse(model.isMarked(at: 0))
        model.toggleMark(at: 0)
        XCTAssertTrue(model.isMarked(at: 0))
        XCTAssertFalse(model.isMarked(at: 1))
        model.toggleMark(at: 0)
        XCTAssertFalse(model.isMarked(at: 0))
    }

    func testTogglingPastTheEndOfTheListIsANoOp() {
        let model = model(with: [app("Safari", pid: 1)])
        model.toggleMark(at: 5)
        XCTAssertTrue(model.markedIDs.isEmpty)
    }

    func testMarkingSeveralTilesBuildsTheMarkedSet() {
        let model = model(with: [app("Safari", pid: 1), app("Mail", pid: 2), app("Notes", pid: 3)])
        model.toggleMark(at: 0)
        model.toggleMark(at: 2)
        XCTAssertEqual(Set(model.markedTargets.map(\.title)), ["Safari", "Notes"])
    }

    /// A fresh session (`begin`) is a hard reset of everything else on the model, and the marked set
    /// is no exception — the controller also clears it explicitly in `hide()`, but a session that
    /// starts with yesterday's marks still on it would be its own bug.
    func testANewSessionStartsWithNoMarks() {
        let model = model(with: [app("Safari", pid: 1)])
        model.toggleMark(at: 0)
        XCTAssertFalse(model.markedIDs.isEmpty)
        model.begin([app("Mail", pid: 2)])
        XCTAssertTrue(model.markedIDs.isEmpty)
    }

    func testClearMarksEmptiesTheSet() {
        let model = model(with: [app("Safari", pid: 1), app("Mail", pid: 2)])
        model.toggleMark(at: 0)
        model.toggleMark(at: 1)
        model.clearMarks()
        XCTAssertTrue(model.markedIDs.isEmpty)
        XCTAssertTrue(model.markedTargets.isEmpty)
    }

    // MARK: - Target resolution

    /// With nothing marked, a set-capable action's target is the highlighted tile alone — the same
    /// resolution `SwitcherController.actionTargets()` performs by falling back to `model.selected`.
    func testNoMarksMeansTheHighlightedTileIsTheOnlyTarget() {
        let model = model(with: [app("Safari", pid: 1), app("Mail", pid: 2)])
        model.selection = 1
        XCTAssertTrue(model.markedTargets.isEmpty)
        let resolved = model.markedTargets.isEmpty ? [model.selected].compactMap { $0 } : model.markedTargets
        XCTAssertEqual(resolved.map(\.title), ["Mail"])
    }

    /// Marks present means the marked set is the target, regardless of which tile is highlighted.
    func testMarksPresentMeansTheMarkedSetIsTheTarget() {
        let model = model(with: [app("Safari", pid: 1), app("Mail", pid: 2), app("Notes", pid: 3)])
        model.selection = 2
        model.toggleMark(at: 0)
        model.toggleMark(at: 1)
        let resolved = model.markedTargets.isEmpty ? [model.selected].compactMap { $0 } : model.markedTargets
        XCTAssertEqual(Set(resolved.map(\.title)), ["Safari", "Mail"])
    }

    // MARK: - ⌥T arrangement assignment

    func testTwoMarkedWindowsGetLeftAndRightHalves() {
        XCTAssertEqual(MarkedTiling.arrangements(for: 2), [.leftHalf, .rightHalf])
    }

    func testThreeMarkedWindowsGetTheThreeThirdsLeftToRight() {
        XCTAssertEqual(MarkedTiling.arrangements(for: 3), [.leftThird, .centerThird, .rightThird])
    }

    func testFourMarkedWindowsGetTheFourQuartersInReadingOrder() {
        XCTAssertEqual(
            MarkedTiling.arrangements(for: 4), [.topLeft, .topRight, .bottomLeft, .bottomRight])
    }

    /// One marked tile has nothing to sit beside, and five or more has no slot shape defined for
    /// it — both refuse rather than guess.
    func testOneOrFiveMarkedWindowsRefuse() {
        XCTAssertNil(MarkedTiling.arrangements(for: 1))
        XCTAssertNil(MarkedTiling.arrangements(for: 5))
        XCTAssertNil(MarkedTiling.arrangements(for: 0))
    }

    /// An app tile in the marked set has no single window to put in a slot, which is the guard
    /// `SwitcherController.tileMarkedWindows()` adds on top of the count check above — exercised
    /// here at the same seam, against the `Kind` check directly.
    func testAnAppTileAmongTheMarkedSetIsNotAllWindows() {
        let marked = [window("Safari", pid: 1), app("Mail", pid: 2)]
        XCTAssertFalse(marked.allSatisfy { if case .window = $0.kind { true } else { false } })
    }

    func testAllWindowTilesInTheMarkedSetPassTheWindowOnlyGuard() {
        let marked = [window("Safari", pid: 1), window("Xcode", pid: 2)]
        XCTAssertTrue(marked.allSatisfy { if case .window = $0.kind { true } else { false } })
    }
}
