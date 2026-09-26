import XCTest

@testable import CmdTab

/// `TabEnumeration`'s search over an accessibility tree, exercised against a fake tree rather than
/// a real one — a real `AXUIElement` only exists inside a trusted, running process, and the search
/// itself (role-path matching, depth bounds, the active-tab rule) is pure logic that does not need
/// one. `AccessibilityHarnessTests` covers the real walk, opt-in, against Safari.
final class TabEnumerationTests: XCTestCase {
    /// A fake node, built by hand rather than adapted from anything live.
    private struct FakeNode: TabEnumeration.Node {
        var role: String?
        var children: [FakeNode] = []
        var title: String?
        var isSelected: Bool?
        var axValue: Int?
    }

    private func radioButton(_ title: String, selected: Bool? = nil, value: Int? = nil) -> FakeNode {
        FakeNode(role: "AXRadioButton", title: title, isSelected: selected, axValue: value)
    }

    // MARK: - Depth-bounded search

    /// Ghostty's shape: the tab group is the window's direct child, and its own children are the
    /// radio buttons — no nesting to search through at all.
    func testFindsATabGroupOneLevelDown() {
        let group = FakeNode(
            role: "AXTabGroup",
            children: [radioButton("main", value: 1), radioButton("logs", value: 0)])
        let window = FakeNode(role: "AXWindow", children: [group])

        let tabs = TabEnumeration.findTabs(in: window)
        XCTAssertEqual(tabs?.map(\.title), ["main", "logs"])
    }

    /// Safari's shape: the tab group's own children are groups, and the radio buttons sit three
    /// levels further down — the collection step has to look past the tab group's direct children,
    /// not just at them.
    func testFindsRadioButtonsNestedSeveralLevelsBelowTheTabGroup() {
        let opaque = FakeNode(role: "AXOpaqueProviderGroup", children: [radioButton("Safari tab", value: 1)])
        let innerGroup = FakeNode(role: "AXGroup", children: [opaque])
        let group = FakeNode(role: "AXTabGroup", children: [
            innerGroup,
            FakeNode(role: "AXGroup", children: [
                FakeNode(role: "AXOpaqueProviderGroup", children: [radioButton("Other tab", value: 0)]),
            ]),
        ])
        let splitGroup = FakeNode(role: "AXSplitGroup", children: [group])
        let window = FakeNode(role: "AXWindow", children: [splitGroup])

        let tabs = TabEnumeration.findTabs(in: window)
        XCTAssertEqual(tabs?.map(\.title), ["Safari tab", "Other tab"])
    }

    /// A Chromium-style shape: several anonymous groups between the window and the tab group. Six
    /// deep is the measured case, and it must still be found within the default depth bound.
    func testFindsATabGroupSixAnonymousGroupsDown() {
        var node = FakeNode(
            role: "AXTabGroup",
            children: [radioButton("one", selected: true), radioButton("two", selected: false)])
        for _ in 0..<6 { node = FakeNode(role: "AXGroup", children: [node]) }
        let window = FakeNode(role: "AXWindow", children: [node])

        let tabs = TabEnumeration.findTabs(in: window)
        XCTAssertEqual(tabs?.map(\.title), ["one", "two"])
    }

    /// A tab group past the search depth bound is not found — the bound exists precisely so one
    /// pathological app cannot make every tabs-scoped session pay for an unbounded walk.
    func testATabGroupPastTheDepthBoundIsNotFound() {
        var node = FakeNode(
            role: "AXTabGroup",
            children: [radioButton("one"), radioButton("two")])
        for _ in 0..<20 { node = FakeNode(role: "AXGroup", children: [node]) }
        let window = FakeNode(role: "AXWindow", children: [node])

        XCTAssertNil(TabEnumeration.findTabs(in: window, maxSearchDepth: 12))
    }

    // MARK: - The >=2 AXRadioButton rule

    /// A segmented control or similar with only one radio-button child does not qualify — the rule
    /// this file leans on instead of a denylist.
    func testATabGroupWithOnlyOneRadioButtonIsNotTreatedAsTabs() {
        let group = FakeNode(role: "AXTabGroup", children: [radioButton("only one")])
        let window = FakeNode(role: "AXWindow", children: [group])
        XCTAssertNil(TabEnumeration.findTabs(in: window))
    }

    /// An app with no `AXTabGroup` anywhere in its window answers nil, not an empty array — the
    /// caller (`TabEnumeration.tabs`) turns both into "no tabs", but the search itself should say
    /// plainly that it found nothing to look inside.
    func testAWindowWithNoTabGroupFindsNothing() {
        let window = FakeNode(role: "AXWindow", children: [FakeNode(role: "AXToolbar")])
        XCTAssertNil(TabEnumeration.findTabs(in: window))
    }

    // MARK: - The time budget

    /// A walk the budget has already run out on finds nothing, even with a tab strip right there —
    /// a partial answer is not offered as a whole one.
    func testAnExpiredBudgetFindsNothing() {
        let group = FakeNode(role: "AXTabGroup", children: [radioButton("a"), radioButton("b")])
        let window = FakeNode(role: "AXWindow", children: [group])
        XCTAssertNil(TabEnumeration.findTabs(in: window, isExpired: { true }))
    }

    /// The budget is checked as the walk goes, not only between apps: a window a thousand rows
    /// wide stops within a few nodes of running out, rather than visiting every row — each of which
    /// is a round trip against a real app.
    func testTheWalkStopsSoonAfterTheBudgetRunsOut() {
        let wide = FakeNode(
            role: "AXWindow", children: Array(repeating: FakeNode(role: "AXRow"), count: 1_000))
        var checks = 0
        let tabs = TabEnumeration.findTabs(
            in: wide,
            isExpired: {
                checks += 1
                return checks > 10
            })
        XCTAssertNil(tabs)
        XCTAssertLessThan(checks, 20, "the walk kept going after the budget ran out")
    }

    /// The same budget, unexpired, changes nothing about what is found.
    func testAnUnexpiredBudgetFindsTheSameTabs() {
        let group = FakeNode(role: "AXTabGroup", children: [radioButton("a"), radioButton("b")])
        let window = FakeNode(role: "AXWindow", children: [group])
        XCTAssertEqual(
            TabEnumeration.findTabs(in: window, isExpired: { false })?.map(\.title), ["a", "b"])
    }

    // MARK: - Active-tab detection

    /// Chromium/Ghostty style: `AXSelected` decides it, and a present-but-false value is honoured
    /// rather than falling through to `AXValue`.
    func testAXSelectedTrueIsActive() {
        XCTAssertTrue(TabEnumeration.isActive(radioButton("t", selected: true, value: 0)))
    }

    func testAXSelectedFalseIsNotActiveEvenIfAXValueSaysOtherwise() {
        XCTAssertFalse(TabEnumeration.isActive(radioButton("t", selected: false, value: 1)))
    }

    /// Safari style: no `AXSelected` at all, so `AXValue == 1` decides it.
    func testAXValueOneIsActiveWhenAXSelectedIsAbsent() {
        XCTAssertTrue(TabEnumeration.isActive(radioButton("t", value: 1)))
        XCTAssertFalse(TabEnumeration.isActive(radioButton("t", value: 0)))
    }

    /// Neither attribute present: not active, rather than crashing or guessing.
    func testNeitherAttributePresentIsNotActive() {
        XCTAssertFalse(TabEnumeration.isActive(radioButton("t")))
    }

    /// The active tab sorts first among a Safari-shaped app's tabs, which is what
    /// `TabEnumeration.tabs` promises callers so the switcher can list it ahead of its siblings
    /// without a separate badge.
    func testFindTabsDoesNotItselfReorderAndTheRealEntryPointDoesActiveTabFirst() {
        // The pure search preserves document order — ordering is `TabEnumeration.tabs`'s job, once
        // it knows which pid and window the nodes came from, so this pins that boundary.
        let group = FakeNode(role: "AXTabGroup", children: [
            radioButton("first", value: 0),
            radioButton("second", value: 1),
        ])
        let tabs = TabEnumeration.findTabs(in: FakeNode(role: "AXWindow", children: [group]))
        XCTAssertEqual(tabs?.map(\.title), ["first", "second"])
    }

    // MARK: - Sharing the budget

    /// Each app gets an even share of what is left, so one wide tree cannot spend it all.
    func testEachAppGetsAShareOfTheTimeLeft() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = now + .milliseconds(150)
        XCTAssertEqual(
            TabEnumeration.slice(now: now, deadline: deadline, appsLeft: 3),
            now + .milliseconds(50))
    }

    /// With many apps open the even share is a sliver; the floor keeps the apps at the front of
    /// the MRU order — the ones walked first — a usable walk.
    func testManyAppsStillGiveEachAUsableSlice() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = now + .milliseconds(150)
        XCTAssertEqual(
            TabEnumeration.slice(now: now, deadline: deadline, appsLeft: 20),
            now + .milliseconds(30))
    }

    /// The last app — and a lone one — gets everything left; nothing is ever given past the
    /// overall deadline.
    func testTheLastAppGetsWhateverIsLeft() {
        let now = DispatchTime(uptimeNanoseconds: 1_000_000_000)
        let deadline = now + .milliseconds(150)
        XCTAssertEqual(TabEnumeration.slice(now: now, deadline: deadline, appsLeft: 1), deadline)
        XCTAssertEqual(
            TabEnumeration.slice(now: deadline + .milliseconds(5), deadline: deadline, appsLeft: 4),
            deadline)
    }
}
