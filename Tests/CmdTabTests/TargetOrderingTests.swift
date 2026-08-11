import AppKit
import XCTest

@testable import CmdTab

/// How the app list is ordered before it becomes tiles — the sort behind the "Order" setting.
///
/// `TargetProvider.sorted` is the one piece of the refresh that decides what the user sees and does
/// no Accessibility IPC to decide it, so it is the piece worth testing directly. Everything around
/// it enumerates live processes and reads windows out of other apps.
final class TargetOrderingTests: XCTestCase {

    private func app(_ pid: pid_t, _ name: String) -> TargetProvider.AppInfo {
        TargetProvider.AppInfo(pid: pid, name: name, bundleID: nil, icon: nil, isHidden: false)
    }

    // MARK: - Alphabetical

    func testAlphabeticalIgnoresTheRecencyOrder() {
        let apps = [app(1, "Safari"), app(2, "Ghostty"), app(3, "Xcode")]
        let sorted = TargetProvider.sorted(apps, by: [3, 1, 2], sortOrder: .alphabetical)
        XCTAssertEqual(sorted.map(\.name), ["Ghostty", "Safari", "Xcode"])
    }

    /// `localizedCaseInsensitiveCompare`, so "iTerm" does not sort after "Xcode" the way a raw
    /// Unicode comparison would put every lowercase letter after every uppercase one.
    func testAlphabeticalIsCaseInsensitive() {
        let apps = [app(1, "Xcode"), app(2, "iTerm"), app(3, "Alfred")]
        let sorted = TargetProvider.sorted(apps, by: [], sortOrder: .alphabetical)
        XCTAssertEqual(sorted.map(\.name), ["Alfred", "iTerm", "Xcode"])
    }

    // MARK: - Recently used

    func testRecentlyUsedFollowsTheMRUOrder() {
        let apps = [app(1, "Safari"), app(2, "Ghostty"), app(3, "Xcode")]
        let sorted = TargetProvider.sorted(apps, by: [3, 1, 2], sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Xcode", "Safari", "Ghostty"])
    }

    /// An app the MRU has never seen ranks `Int.max` and lands after everything it has, rather than
    /// jumping to the front on a missing lookup.
    func testAppsMissingFromTheMRUSortLast() {
        let apps = [app(1, "Safari"), app(2, "Ghostty"), app(3, "Xcode")]
        let sorted = TargetProvider.sorted(apps, by: [3], sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Xcode", "Safari", "Ghostty"])
    }

    /// Among equally-unranked apps the workspace's own ordering is preserved, so the list does not
    /// reshuffle itself between refreshes that learned nothing new.
    func testUnrankedAppsKeepTheirIncomingOrder() {
        let apps = [app(5, "Eagle"), app(6, "Falcon"), app(7, "Grouse")]
        let sorted = TargetProvider.sorted(apps, by: [], sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Eagle", "Falcon", "Grouse"])
    }

    /// A duplicate pid in the MRU should be impossible, but the sort must not trap on one —
    /// trapping inside the switcher would take the app down mid-⌘-Tab. The more recent position
    /// wins.
    func testADuplicateInTheMRUDoesNotTrapAndTakesTheEarlierRank() {
        let apps = [app(1, "Safari"), app(2, "Ghostty")]
        let sorted = TargetProvider.sorted(apps, by: [2, 1, 2], sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Ghostty", "Safari"])
    }

    func testAnEmptyAppListStaysEmpty() {
        XCTAssertTrue(TargetProvider.sorted([], by: [1, 2], sortOrder: .recentlyUsed).isEmpty)
        XCTAssertTrue(TargetProvider.sorted([], by: [1, 2], sortOrder: .alphabetical).isEmpty)
    }

    // MARK: - The two together

    /// The MRU list is maintained by `RecencyList` and consumed by `sorted`, and the contract
    /// between them is that entry order *is* rank order. Worth asserting end to end, since the two
    /// live in different files and nothing else connects them.
    func testARecencyListDrivesTheSortDirectly() {
        var mru = RecencyList<pid_t>(limit: 10)
        mru.touch(1)  // Safari
        mru.touch(2)  // Ghostty
        mru.touch(3)  // Xcode
        mru.touch(1)  // back to Safari

        let apps = [app(1, "Safari"), app(2, "Ghostty"), app(3, "Xcode")]
        let sorted = TargetProvider.sorted(apps, by: mru.entries, sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Safari", "Xcode", "Ghostty"])
    }

    /// A terminated app leaves the MRU and stops influencing the order of the ones still running.
    func testATerminatedAppLeavesTheOrderIntact() {
        var mru = RecencyList<pid_t>(limit: 10)
        mru.touch(1)
        mru.touch(2)
        mru.touch(3)
        mru.remove(3)

        let apps = [app(1, "Safari"), app(2, "Ghostty")]
        let sorted = TargetProvider.sorted(apps, by: mru.entries, sortOrder: .recentlyUsed)
        XCTAssertEqual(sorted.map(\.name), ["Ghostty", "Safari"])
    }
}
