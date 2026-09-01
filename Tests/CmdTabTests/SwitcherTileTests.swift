import XCTest

@testable import CmdTab

/// What a tile says and what it offers: the sentence VoiceOver reads, the digit drawn in its corner,
/// and whether the pointer gets a close button on it.
///
/// All three used to live inside the view, where nothing could check them and the only way to find a
/// mistake was to look at the panel — which, for the VoiceOver sentence, means listening to it.
@MainActor
final class SwitcherTileTests: XCTestCase {
    private func app(
        _ name: String, pid: pid_t = 1, appName: String? = nil, minimized: Bool = false,
        hidden: Bool = false
    ) -> SwitchTarget {
        SwitchTarget(
            id: "\(pid):\(name)", kind: .app(pid), title: name, appName: appName ?? name,
            icon: nil, isMinimized: minimized, isHidden: hidden)
    }

    private func launchable(_ name: String) -> SwitchTarget {
        SwitchTarget(
            id: "launch:\(name)", kind: .launch(URL(fileURLWithPath: "/Applications/\(name).app")),
            title: name, appName: name, icon: nil, isMinimized: false, isHidden: false)
    }

    private func describe(_ target: SwitchTarget, number: Int? = nil) -> String {
        TileDescription.text(
            for: target, number: number, showsDisplayBadges: true, showsSpaceBadges: true)
    }

    // MARK: - What a tile announces

    func testAPlainAppIsJustItsName() {
        XCTAssertEqual(describe(app("Safari")), "Safari")
    }

    /// In window mode the title is the window's and the app name is the other half of the identity —
    /// but an app tile, where the two are equal, must not say its name twice.
    func testAWindowCarriesItsAppNameAndAnAppDoesNotRepeatItself() {
        XCTAssertEqual(describe(app("Inbox", appName: "Mail")), "Inbox, Mail")
        XCTAssertEqual(describe(app("Mail")), "Mail")
    }

    /// Every state that is carried by a dimmed icon or a badge glyph and by nothing else.
    func testTheVisualBadgesAllReachTheSentence() {
        XCTAssertTrue(describe(app("Notes", minimized: true)).contains("minimized"))
        XCTAssertTrue(describe(app("Notes", hidden: true)).contains("hidden"))
        XCTAssertTrue(describe(launchable("Numbers")).contains("not running"))

        var badged = app("Mail")
        badged.badge = "12"
        XCTAssertTrue(describe(badged).contains("12 notifications"))

        var placed = app("Safari")
        placed.displayIndex = 1
        placed.spaceIndex = 2
        XCTAssertTrue(describe(placed).contains("display 2"))
        XCTAssertTrue(describe(placed).contains("desktop 3"))
    }

    /// The badges can be switched off, and then they must not be spoken either — an announcement
    /// describing a marker that is not drawn is describing a different panel.
    func testSwitchedOffBadgesAreNotAnnounced() {
        var target = app("Safari")
        target.displayIndex = 1
        target.spaceIndex = 2
        let text = TileDescription.text(
            for: target, number: nil, showsDisplayBadges: false, showsSpaceBadges: false)
        XCTAssertFalse(text.contains("display"))
        XCTAssertFalse(text.contains("desktop"))
    }

    /// The tenth tile is reached with 0, so the sentence has to name the *key* rather than the
    /// position — which is the one place the number drawn on the tile and its index disagree.
    func testTheTenthTileAnnouncesTheKeyNotThePosition() {
        XCTAssertTrue(describe(app("Safari"), number: 1).contains("press 1 to switch"))
        XCTAssertTrue(describe(app("Safari"), number: 10).contains("press 0 to switch"))
    }

    // MARK: - The number on a tile

    func testTheFirstTenTilesAreNumberedAndTheTenthIsZero() {
        let model = SwitcherModel()
        model.begin((0..<12).map { app("App \($0)", pid: pid_t($0 + 1)) })
        XCTAssertEqual(model.number(for: 0), 1)
        XCTAssertEqual(model.number(for: 8), 9)
        XCTAssertEqual(model.number(for: 9), 0)
        XCTAssertNil(model.number(for: 10))
    }

    /// The jump is off while filtering — digits type into the query — so the badges come off too,
    /// and the announcement must stop offering a key that would no longer work.
    func testFilteringTakesTheNumbersAway() {
        let model = SwitcherModel()
        model.begin([app("Safari"), app("Xcode", pid: 2)])
        XCTAssertEqual(model.number(for: 0), 1)
        model.setQuery("saf")
        XCTAssertNil(model.number(for: 0))
    }

    // MARK: - The close button

    func testNoCloseButtonUntilTheActionsAreEnabled() {
        let model = SwitcherModel()
        model.begin([app("Safari")])
        model.hoverIndex = 0
        XCTAssertFalse(model.showsClose(at: 0))
        model.showsCloseButton = true
        XCTAssertTrue(model.showsClose(at: 0))
    }

    /// It belongs to the tile the cursor is on, and to no other — the whole point of tracking the
    /// hovered tile separately from the selected one.
    func testTheCloseButtonIsOnlyOnTheHoveredTile() {
        let model = SwitcherModel()
        model.begin([app("Safari"), app("Xcode", pid: 2)])
        model.showsCloseButton = true
        model.hoverIndex = 1
        XCTAssertFalse(model.showsClose(at: 0))
        XCTAssertTrue(model.showsClose(at: 1))
        // Selection is not hover: the keyboard moving the highlight must not move the button.
        model.selection = 0
        XCTAssertFalse(model.showsClose(at: 0))
    }

    func testNoCloseButtonWhenTheCursorIsOffTheTiles() {
        let model = SwitcherModel()
        model.begin([app("Safari")])
        model.showsCloseButton = true
        model.hoverIndex = nil
        XCTAssertFalse(model.showsClose(at: 0))
    }

    /// A launch tile is an offer to start an app; there is no window behind it to close.
    func testALaunchTileNeverOffersToClose() {
        let model = SwitcherModel()
        model.begin([launchable("Numbers")])
        model.showsCloseButton = true
        model.hoverIndex = 0
        XCTAssertFalse(model.showsClose(at: 0))
    }

    /// A hover index left over from a longer list must not answer for a tile that no longer exists.
    func testAnOutOfRangeHoverIsRefused() {
        let model = SwitcherModel()
        model.begin([app("Safari")])
        model.showsCloseButton = true
        model.hoverIndex = 7
        XCTAssertFalse(model.showsClose(at: 7))
    }
}
