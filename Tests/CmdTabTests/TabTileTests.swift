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

    /// Close is refused on a tab: the button in reach is the whole window's.
    func testATabTileCannotBeClosed() {
        XCTAssertFalse(tabTarget(title: "Inbox", appName: "Safari").canClose)
    }

    /// A tab tile and a window tile over the same window name the same window, so closing the
    /// window takes both out of the list; another app's window is left alone.
    func testATabSharesItsWindowWithThatWindowsTile() {
        let tab = tabTarget(pid: 4242, title: "Inbox", appName: "Safari")
        let sameWindow = SwitchTarget(
            id: "win:1", kind: .window(4242, AX.application(4242)), title: "Safari",
            appName: "Safari", icon: nil, isMinimized: false, isHidden: false)
        let otherWindow = SwitchTarget(
            id: "win:2", kind: .window(4243, AX.application(4243)), title: "Mail",
            appName: "Mail", icon: nil, isMinimized: false, isHidden: false)
        guard let a = tab.windowElement, let b = sameWindow.windowElement,
            let c = otherWindow.windowElement
        else { return XCTFail("both kinds should name a window") }
        XCTAssertTrue(CFEqual(a, b))
        XCTAssertFalse(CFEqual(a, c))
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
