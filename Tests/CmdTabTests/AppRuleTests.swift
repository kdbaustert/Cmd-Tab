import XCTest

@testable import CmdTab

/// The per-app rule value type. The store around it reads `UserDefaults.standard`, which no test
/// here touches, so this covers the parts that decide behaviour rather than the plist round-trip.
final class AppRuleTests: XCTestCase {

    /// A rule saying nothing deletes itself rather than growing the settings file forever, so every
    /// new field has to leave `isDefault` true when it is unset.
    func testAnUntouchedRuleIsDefault() {
        XCTAssertTrue(AppRule().isDefault)
    }

    func testEachFieldOnItsOwnMakesTheRuleNonDefault() {
        var expand = AppRule()
        expand.expandWindows = true
        XCTAssertFalse(expand.isDefault)

        var tile = AppRule()
        tile.neverTile = true
        XCTAssertFalse(tile.isDefault)

        var hide = AppRule()
        hide.hideWhenFrontmost = true
        XCTAssertFalse(hide.isDefault)

        var named = AppRule()
        named.displayName = "Slack"
        XCTAssertFalse(named.isDefault)

        var arranged = AppRule()
        arranged.launchArrangement = .rightHalf
        XCTAssertFalse(arranged.isDefault)
    }

    // MARK: - Display name

    func testLabelFallsBackToTheAppsOwnName() {
        XCTAssertEqual(AppRule().label(or: "Code"), "Code")
    }

    func testLabelPrefersTheOverride() {
        var rule = AppRule()
        rule.displayName = "Editor"
        XCTAssertEqual(rule.label(or: "Code"), "Editor")
    }

    /// The store trims before storing, so an all-whitespace name never reaches here as an override —
    /// but an imported or hand-edited config can carry one, and a blank tile label is worse than the
    /// app's own name.
    func testEmptyOverrideIsIgnored() {
        var rule = AppRule()
        rule.displayName = ""
        XCTAssertEqual(rule.label(or: "Code"), "Code")
    }

    // MARK: - Launch arrangements

    /// A relative move means nothing for a window that has only just appeared.
    func testLaunchableExcludesTheDisplayMoves() {
        XCTAssertFalse(WindowArrangement.launchable.contains { $0.isMove })
    }

    /// `.restore` goes back to the frame a window had before it was first tiled. A window on its
    /// first frame has no such history, so offering it here would be a silent no-op.
    func testLaunchableExcludesRestore() {
        XCTAssertFalse(WindowArrangement.launchable.contains(.restore))
    }

    /// Everything that actually places a window at an absolute frame should be offered.
    func testLaunchableKeepsTheRealPlacements() {
        for arrangement in [
            WindowArrangement.leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .leftThird, .centerThird, .rightThird,
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .maximize, .center,
        ] {
            XCTAssertTrue(
                WindowArrangement.launchable.contains(arrangement),
                "\(arrangement.title) should be offered as a launch arrangement")
        }
    }
}
