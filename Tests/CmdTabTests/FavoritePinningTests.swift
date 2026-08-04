import AppKit
import XCTest

@testable import CmdTab

/// Pinned favourites: the front of the app list is the favourites in the user's order, running or
/// not, and a plain ⌘-Tab tap still finds the previous app behind them.
final class FavoritePinningTests: XCTestCase {

    private func appTarget(_ pid: pid_t, _ name: String) -> SwitchTarget {
        SwitchTarget(
            id: "app:\(pid)", kind: .app(pid), title: name, appName: name, icon: nil,
            isMinimized: false, isHidden: false)
    }

    private func windowTarget(_ pid: pid_t, _ name: String, _ title: String) -> SwitchTarget {
        SwitchTarget(
            id: "window:\(pid):\(title)", kind: .app(pid), title: title, appName: name, icon: nil,
            isMinimized: false, isHidden: false)
    }

    private func launchTile(_ bundleID: String, _ name: String) -> SwitchTarget {
        SwitchTarget(
            id: "launch:\(bundleID)", kind: .launch(URL(fileURLWithPath: "/Applications/\(name).app")),
            title: name, appName: name, icon: nil, isMinimized: false, isHidden: false)
    }

    // MARK: - Order

    func testFavouritesLeadTheListInTheUsersOrder() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Finder"), appTarget(3, "Code")]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: ["com.apple.finder", "com.microsoft.VSCode"],
            bundleIDs: [1: "com.apple.Safari", 2: "com.apple.finder", 3: "com.microsoft.VSCode"],
            launchTiles: [:])
        XCTAssertEqual(pinned.map(\.title), ["Finder", "Code", "Safari"])
    }

    /// The slot is the point: whether the app is running decides which *kind* of tile fills the
    /// position, never where the position is.
    func testAFavouriteThatIsNotRunningHoldsItsSlotWithALaunchTile() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Finder")]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: ["com.apple.finder", "md.obsidian", "com.apple.Safari"],
            bundleIDs: [1: "com.apple.Safari", 2: "com.apple.finder"],
            launchTiles: ["md.obsidian": launchTile("md.obsidian", "Obsidian")])
        XCTAssertEqual(pinned.map(\.title), ["Finder", "Obsidian", "Safari"])
        XCTAssertTrue(pinned[1].isLaunchable)
    }

    /// An app whose rule expands it window-by-window contributes several tiles. They travel
    /// together to the favourite's slot rather than being scattered or partly left behind.
    func testAnExpandedFavouriteBringsAllOfItsWindows() {
        let targets = [
            appTarget(1, "Safari"),
            windowTarget(2, "Code", "one.swift"),
            windowTarget(2, "Code", "two.swift"),
        ]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: ["com.microsoft.VSCode"],
            bundleIDs: [1: "com.apple.Safari", 2: "com.microsoft.VSCode"], launchTiles: [:])
        XCTAssertEqual(pinned.map(\.title), ["one.swift", "two.swift", "Safari"])
    }

    /// A favourite that is neither running nor resolvable — uninstalled, or excluded, so no launch
    /// tile was built for it — contributes nothing and must not leave a gap or drop the ones after.
    func testAFavouriteWithNoTileAtAllIsSkipped() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Finder")]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: ["com.gone.App", "com.apple.finder"],
            bundleIDs: [1: "com.apple.Safari", 2: "com.apple.finder"], launchTiles: [:])
        XCTAssertEqual(pinned.map(\.title), ["Finder", "Safari"])
    }

    func testNonFavouritesKeepTheOrderTheSortGaveThem() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Mail"), appTarget(3, "Finder")]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: ["com.apple.finder"],
            bundleIDs: [1: "com.apple.Safari", 2: "com.apple.mail", 3: "com.apple.finder"],
            launchTiles: [:])
        XCTAssertEqual(pinned.map(\.title), ["Finder", "Safari", "Mail"])
    }

    func testNoFavouritesLeavesTheListAlone() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Mail")]
        let pinned = TargetProvider.pinningFavorites(
            targets, order: [], bundleIDs: [1: "com.apple.Safari", 2: "com.apple.mail"],
            launchTiles: [:])
        XCTAssertEqual(pinned.map(\.title), ["Safari", "Mail"])
    }

    // MARK: - Where a tap lands

    /// The habit pinning must not cost: tap ⌘-Tab and you are back in the app you just left, even
    /// though it is no longer the second tile.
    func testATapFindsThePreviousAppBehindThePinnedBlock() {
        // Front is Safari (pid 1), before it Mail (pid 2) — both pushed down by two favourites.
        let targets = [
            appTarget(3, "Finder"), appTarget(4, "Code"), appTarget(1, "Safari"),
            appTarget(2, "Mail"),
        ]
        XCTAssertEqual(TargetProvider.previousAppIndex(in: targets, mru: [1, 2, 4, 3]), 3)
    }

    /// With nothing pinned the MRU walk has to agree with the plain arithmetic it replaces,
    /// otherwise turning the setting on and off would move the tap around.
    func testWithoutPinningTheAnswerIsStillTheSecondTile() {
        let targets = [appTarget(1, "Safari"), appTarget(2, "Mail"), appTarget(3, "Finder")]
        XCTAssertEqual(TargetProvider.previousAppIndex(in: targets, mru: [1, 2, 3]), 1)
    }

    /// The front app can be missing from the list — excluded, or hidden as empty. The tap then goes
    /// to the one behind the most recent app that *is* listed, which is what an unpinned list does.
    func testAFrontAppThatIsNotListedDoesNotShiftTheAnswer() {
        let targets = [appTarget(2, "Mail"), appTarget(3, "Finder")]
        XCTAssertEqual(TargetProvider.previousAppIndex(in: targets, mru: [1, 2, 3]), 1)
    }

    /// Launch tiles share a placeholder pid and represent apps that are not running, so they can
    /// never be "the app you were just in" — a stale MRU entry must not select one.
    func testLaunchTilesAreNeverTheTapTarget() {
        let targets = [
            launchTile("md.obsidian", "Obsidian"), appTarget(1, "Safari"), appTarget(2, "Mail"),
        ]
        let index = TargetProvider.previousAppIndex(in: targets, mru: [1, 2])
        XCTAssertEqual(index, 2)
    }

    /// One app in the list, or an MRU too stale to name a second listed app: there is no previous
    /// app, and the caller falls back to its own arithmetic rather than being handed an index.
    func testNoSecondListedAppReportsNothing() {
        XCTAssertNil(TargetProvider.previousAppIndex(in: [appTarget(1, "Safari")], mru: [1, 2, 3]))
        XCTAssertNil(TargetProvider.previousAppIndex(in: [], mru: [1]))
    }
}
