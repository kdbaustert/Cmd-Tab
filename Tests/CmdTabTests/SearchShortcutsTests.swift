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

    // MARK: - Insertion order

    /// A re-learned query replaces its old answer rather than joining it — one query, one binding.
    func testRelearningAQueryReplacesItsBinding() {
        var bindings = SearchBindings()
        bindings.learn(query: "ma", bundleID: "com.apple.mail")
        bindings.learn(query: "ma", bundleID: "com.freron.MailMate")
        XCTAssertEqual(bindings.bundleID(for: "ma"), "com.freron.MailMate")
        XCTAssertEqual(bindings.entries.count, 1)
    }

    /// Confirming a binding that already holds must change nothing — not even its place in the
    /// order — because any change is a write to the synced settings file on nearly every switch.
    func testConfirmingAnExistingBindingIsANoOp() {
        var bindings = SearchBindings()
        bindings.learn(query: "ma", bundleID: "com.apple.mail")
        bindings.learn(query: "sa", bundleID: "com.apple.Safari")
        let before = bindings
        bindings.learn(query: "MA", bundleID: "com.apple.mail")
        XCTAssertEqual(bindings, before)
    }

    /// The cap evicts by insertion order: the oldest new-or-changed binding goes, and confirming
    /// one does not save it.
    func testTheCapEvictsTheOldestInsertedBinding() {
        var bindings = SearchBindings()
        for index in 0..<SearchBindings.capacity {
            bindings.learn(query: "query\(index)", bundleID: "app\(index)")
        }
        bindings.learn(query: "query0", bundleID: "app0")
        bindings.learn(query: "one more", bundleID: "app-more")
        XCTAssertEqual(bindings.entries.count, SearchBindings.capacity)
        XCTAssertNil(bindings.bundleID(for: "query0"), "confirming does not refresh the order")
        XCTAssertEqual(bindings.bundleID(for: "query1"), "app1")
    }

    /// One malformed row costs that row alone.
    func testOneBadStoredRowDoesNotDropTheOthers() {
        let stored: [Any] = [
            ["ma", "com.apple.mail"], "junk", ["only-one"], [1, 2], ["sa", "com.apple.Safari"],
        ]
        let bindings = SearchBindings(stored: stored)
        XCTAssertEqual(bindings.entries.count, 2)
        XCTAssertEqual(bindings.bundleID(for: "ma"), "com.apple.mail")
        XCTAssertEqual(bindings.bundleID(for: "sa"), "com.apple.Safari")
        XCTAssertEqual(bindings.entries.first?.query, "ma", "stored order is preserved")
    }

    func testOneBadScopedTriggerRowDoesNotDropTheOthers() throws {
        let scope = try XCTUnwrap(SwitcherScope.allCases.first)
        let good: [Any] = ["id1", 12, 0, scope.rawValue]
        let stored: [Any] = [
            good, ["id2", 12, 0, "no-such-scope"], "junk", ["id3", "x", 0, scope.rawValue],
        ]
        let triggers = ScopedTriggers(stored: stored)
        XCTAssertEqual(triggers.triggers.map(\.id), ["id1"])
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
