import ApplicationServices
import XCTest

@testable import CmdTab

/// The `.tab` tile shape: a `SwitchTarget` built from a `TabEnumeration.TabRef`, matched by the
/// switcher's existing fuzzy filter over its title and app name — no new matching logic, which is
/// the point of routing it through `title`/`appName` like every other tile.
@MainActor
final class TabTileTests: XCTestCase {
    /// A `TabRef` carries live `AXUIElement`s, which only make sense pointed at a real process —
    /// but constructing one costs no IPC, so a harmless pid stands in for the app a real tab would
    /// belong to.
    private func tabTarget(pid: pid_t = 4242, title: String, appName: String) -> SwitchTarget {
        let element = AX.application(pid)
        let ref = TabEnumeration.TabRef(
            pid: pid, window: element, element: element, title: title, isActive: false)
        return SwitchTarget(
            id: "tab:\(pid):\(title)", kind: .tab(ref), title: title, appName: appName,
            icon: nil, isMinimized: false, isHidden: false)
    }

    func testATabTileIsNotLaunchable() {
        XCTAssertFalse(tabTarget(title: "Inbox", appName: "Safari").isLaunchable)
    }

    func testATabTilesPidIsTheOwningApps() {
        XCTAssertEqual(tabTarget(pid: 99, title: "Inbox", appName: "Safari").pid, 99)
    }

    /// Matches on the tab's own title, exactly like a window tile matches on its window title.
    func testMatchesOnTabTitle() {
        let targets = [tabTarget(title: "Pull Request #42", appName: "Safari")]
        let hits = SwitcherModel.matchingIndices(targets, query: "pull")
        XCTAssertEqual(hits, [0])
    }

    /// Matches on the owning app's name too, exactly like a window tile matches on its app name —
    /// so typing "safari" finds a tab whose title shares nothing with the query.
    func testMatchesOnOwningAppName() {
        let targets = [tabTarget(title: "Pull Request #42", appName: "Safari")]
        let hits = SwitcherModel.matchingIndices(targets, query: "saf")
        XCTAssertEqual(hits, [0])
    }

    /// A query matching neither the tab's title nor its app's name is not a hit.
    func testNoMatchWhenNeitherTitleNorAppNameMatch() {
        let targets = [tabTarget(title: "Pull Request #42", appName: "Safari")]
        XCTAssertTrue(SwitcherModel.matchingIndices(targets, query: "zzz").isEmpty)
    }

    /// Two tabs, one from each app: the query picks out only the one whose app matches.
    func testAppNameMatchingDistinguishesTabsOfDifferentApps() {
        let targets = [
            tabTarget(pid: 1, title: "Inbox", appName: "Ghostty"),
            tabTarget(pid: 2, title: "Inbox", appName: "Safari"),
        ]
        XCTAssertEqual(SwitcherModel.matchingIndices(targets, query: "ghostty"), [0])
    }
}
