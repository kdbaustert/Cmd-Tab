import XCTest

@testable import CmdTab

/// The learned search shortcuts: the pure binding store, and what a binding changes about the
/// ranking. The persistence wrapper is a thin `UserDefaults` shim over `SearchBindings` and is not
/// driven here — the shapes worth pinning down are the MRU arithmetic and the two ranking rules.
final class SearchShortcutsTests: XCTestCase {
    // MARK: - Normalization

    func testLookupIsCaseAndAccentInsensitiveAndTrimmed() {
        var bindings = SearchBindings()
        bindings.learn(query: "  Réglages ", bundleID: "com.apple.systempreferences")
        XCTAssertEqual(bindings.bundleID(for: "reglages"), "com.apple.systempreferences")
        XCTAssertEqual(bindings.bundleID(for: "REGLAGES"), "com.apple.systempreferences")
    }

    func testAnEmptyOrWhitespaceQueryNeverLearnsOrMatches() {
        var bindings = SearchBindings()
        bindings.learn(query: "   ", bundleID: "com.example.app")
        XCTAssertTrue(bindings.entries.isEmpty)
        XCTAssertNil(bindings.bundleID(for: ""))
        XCTAssertNil(bindings.bundleID(for: "  "))
    }

    // MARK: - MRU behaviour

    /// A re-learned query replaces its old answer rather than joining it — one query, one binding.
    func testRelearningAQueryReplacesItsBinding() {
        var bindings = SearchBindings()
        bindings.learn(query: "ma", bundleID: "com.apple.mail")
        bindings.learn(query: "ma", bundleID: "com.freron.MailMate")
        XCTAssertEqual(bindings.bundleID(for: "ma"), "com.freron.MailMate")
        XCTAssertEqual(bindings.entries.count, 1)
    }

    /// The cap evicts the binding least recently learned or confirmed, not an arbitrary one — the
    /// same reasoning as `RecencyList`, so the queries typed daily are the ones that stay.
    func testTheCapEvictsTheLeastRecentlyConfirmedBinding() {
        var bindings = SearchBindings()
        for index in 0..<SearchBindings.capacity {
            bindings.learn(query: "query\(index)", bundleID: "app\(index)")
        }
        // Confirm the oldest so it becomes the freshest.
        bindings.learn(query: "query0", bundleID: "app0")
        bindings.learn(query: "one more", bundleID: "app-more")
        XCTAssertEqual(bindings.entries.count, SearchBindings.capacity)
        XCTAssertEqual(bindings.bundleID(for: "query0"), "app0", "refreshed, so it survives")
        XCTAssertNil(bindings.bundleID(for: "query1"), "now the oldest, so it is the one evicted")
    }

    // MARK: - Ranking

    private func running(_ name: String, pid: pid_t, bundleID: String) -> SwitchTarget {
        SwitchTarget(
            id: "app:\(pid)", kind: .app(pid), title: name, appName: name,
            icon: nil, isMinimized: false, isHidden: false, bundleID: bundleID)
    }

    private func launchable(_ name: String, bundleID: String) -> SwitchTarget {
        SwitchTarget(
            id: "launch:\(bundleID)",
            kind: .launch(URL(fileURLWithPath: "/Applications/\(name).app")),
            title: name, appName: name, icon: nil, isMinimized: false, isHidden: false,
            bundleID: bundleID)
    }

    /// The point of the feature: the learned app wins its group whatever the letters score. "ma"
    /// prefix-scores Mail above MailMate (shorter candidates win), and the binding is what lets the
    /// user's own daily answer overrule that.
    @MainActor
    func testALearnedAppOutranksAHigherScoringUnlearnedOne() {
        let list = [
            running("MailMate", pid: 1, bundleID: "com.freron.MailMate"),
            running("Mail", pid: 2, bundleID: "com.apple.mail"),
        ]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "ma"), 1,
            "unlearned, the shorter prefix match wins")
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "ma", learned: "com.freron.MailMate"), 0,
            "learned, the binding decides")
    }

    /// The invariant the whole ranking rests on survives the boost: a learned app that is not
    /// running is still only a launch tile, and anything running still beats it.
    @MainActor
    func testALearnedLaunchTileStillLosesToAnythingRunning() {
        let list = [
            running("MailMate", pid: 1, bundleID: "com.freron.MailMate"),
            launchable("Mail", bundleID: "com.apple.mail"),
        ]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "ma", learned: "com.apple.mail"), 0,
            "running beats launchable, learned or not")
    }

    /// With nothing running answering the query, the learned launch tile is the one offered first.
    @MainActor
    func testALearnedLaunchTileWinsAmongLaunchTiles() {
        let list = [
            launchable("MailMate", bundleID: "com.freron.MailMate"),
            launchable("Mail", bundleID: "com.apple.mail"),
        ]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "ma", learned: "com.apple.mail"), 1)
    }

    /// Within the learned app, the higher score still wins — in window mode that is what picks the
    /// best-matching window rather than the app's first one.
    @MainActor
    func testWithinTheLearnedAppTheScoreStillDecides() {
        func window(_ title: String, id: String) -> SwitchTarget {
            SwitchTarget(
                id: id, kind: .app(9), title: title, appName: "Safari",
                icon: nil, isMinimized: false, isHidden: false, bundleID: "com.apple.Safari")
        }
        let list = [
            window("Release notes", id: "win:1"),
            window("Recipes", id: "win:2"),
            running("Rectangle", pid: 3, bundleID: "com.knollsoft.Rectangle"),
        ]
        XCTAssertEqual(
            SwitcherModel.bestMatch(list, query: "reci", learned: "com.apple.Safari"), 1,
            "the learned app's best-scoring tile, not merely its first")
    }
}
