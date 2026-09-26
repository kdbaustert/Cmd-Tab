import XCTest

@testable import CmdTab

/// The pure matching logic behind title rules — regex compilation, the any-app/any-window
/// wildcards, and the union with a bundle-level rule. `TitleRulesStore` itself reads
/// `UserDefaults.standard`, which no test here touches; these compile `CompiledTitleRule` by hand
/// the way the store does internally.
final class TitleRuleTests: XCTestCase {

    private func compile(bundleID: String?, pattern: String, action: TitleRuleAction) -> CompiledTitleRule {
        CompiledTitleRule(
            bundleID: bundleID, action: action,
            regex: try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]))
    }

    // MARK: - Matching

    func testMatchIsCaseInsensitive() {
        let rules = [compile(bundleID: nil, pattern: "zoom", action: .hide)]
        XCTAssertTrue(
            CompiledTitleRule.matches(rules, bundleID: "com.zoom.xos", title: "ZOOM Meeting", action: .hide))
    }

    /// Anchoring is left entirely to the pattern: `^Zoom` only matches a title that *starts* with
    /// it, where a bare `Zoom` matches the word anywhere in the title.
    func testAnchoringIsThePatternsJob() {
        let anchored = [compile(bundleID: nil, pattern: "^Zoom", action: .hide)]
        let unanchored = [compile(bundleID: nil, pattern: "Zoom", action: .hide)]

        XCTAssertFalse(
            CompiledTitleRule.matches(anchored, bundleID: nil, title: "Screen Share (Zoom)", action: .hide))
        XCTAssertTrue(
            CompiledTitleRule.matches(unanchored, bundleID: nil, title: "Screen Share (Zoom)", action: .hide))
        XCTAssertTrue(
            CompiledTitleRule.matches(anchored, bundleID: nil, title: "Zoom Meeting", action: .hide))
    }

    func testANilBundleIDMatchesAnyApp() {
        let rules = [compile(bundleID: nil, pattern: "Picture in Picture", action: .hide)]
        XCTAssertTrue(
            CompiledTitleRule.matches(rules, bundleID: "com.apple.Safari", title: "Picture in Picture", action: .hide))
        XCTAssertTrue(
            CompiledTitleRule.matches(rules, bundleID: nil, title: "Picture in Picture", action: .hide))
    }

    func testABundleScopedRuleIgnoresEveryOtherApp() {
        let rules = [compile(bundleID: "us.zoom.xos", pattern: "Meeting", action: .neverTile)]
        XCTAssertTrue(
            CompiledTitleRule.matches(rules, bundleID: "us.zoom.xos", title: "Zoom Meeting", action: .neverTile))
        XCTAssertFalse(
            CompiledTitleRule.matches(rules, bundleID: "com.apple.Safari", title: "Zoom Meeting", action: .neverTile))
    }

    /// A rule for `.hide` never answers `.expand` or `.neverTile`, however well its pattern matches
    /// — the action is part of the question, not a filter applied afterwards.
    func testARuleOnlyAnswersItsOwnAction() {
        let rules = [compile(bundleID: nil, pattern: "Zoom", action: .hide)]
        XCTAssertFalse(CompiledTitleRule.matches(rules, bundleID: nil, title: "Zoom", action: .expand))
        XCTAssertFalse(CompiledTitleRule.matches(rules, bundleID: nil, title: "Zoom", action: .neverTile))
    }

    // MARK: - Invalid patterns

    /// An unbalanced group is an invalid regex. It has to be stored rather than rejected — the
    /// settings row saves as the user types — and it must match nothing rather than crash the
    /// switcher or the tiler that asks it on every window, every pass.
    func testAnInvalidPatternCompilesToNilAndMatchesNothing() {
        let rule = compile(bundleID: nil, pattern: "(unclosed", action: .hide)
        XCTAssertNil(rule.regex)
        XCTAssertFalse(CompiledTitleRule.matches([rule], bundleID: nil, title: "anything at all", action: .hide))
    }

    // MARK: - Union with an app rule

    /// Neither call site replaces the other's answer — see every place `AppRule.neverTile` is
    /// checked, which now also asks this. A window rule and an app rule are unioned: either one
    /// protecting a window is enough, and clearing one must not clear the other.
    func testATitleRuleAndABundleRuleAreUnionedNotExclusive() {
        var appRule = AppRule()
        appRule.neverTile = false
        let titleRules = [compile(bundleID: nil, pattern: "Meeting", action: .neverTile)]

        let blockedByTitle = appRule.neverTile
            || CompiledTitleRule.matches(titleRules, bundleID: "us.zoom.xos", title: "Zoom Meeting", action: .neverTile)
        XCTAssertTrue(blockedByTitle)

        appRule.neverTile = true
        let blockedByEither = appRule.neverTile
            || CompiledTitleRule.matches(titleRules, bundleID: "us.zoom.xos", title: "Something else", action: .neverTile)
        XCTAssertTrue(blockedByEither)
    }

    // MARK: - Round trip through the config serialisation

    /// `TitleRulesStore` persists as `[{ id, bundleID?, pattern, action }]` — the same shape
    /// `SettingsIO`/`ConfigFile` mirror to `config.json`. Exercised as a plist-safe dictionary
    /// round trip through `TitleRulesStore.decode` rather than through `UserDefaults`, which no
    /// test here touches.
    func testRoundTripsThroughThePlistSafeShape() {
        let rules = [
            TitleRule(bundleID: "us.zoom.xos", pattern: "^Zoom", action: .neverTile),
            TitleRule(bundleID: nil, pattern: "Picture in Picture", action: .hide),
        ]

        let encoded: [[String: Any]] = rules.map { rule in
            var fields: [String: Any] = [
                "id": rule.id.uuidString, "pattern": rule.pattern, "action": rule.action.rawValue,
            ]
            if let bundleID = rule.bundleID { fields["bundleID"] = bundleID }
            return fields
        }

        let decoded = TitleRulesStore.decode(encoded)

        XCTAssertEqual(decoded.rules, rules)
        XCTAssertTrue(decoded.unreadable.isEmpty)
    }

    /// A malformed entry — an action a newer build added, say — is skipped rather than crashing
    /// the whole load, the same contract `AppRulesStore.load` keeps for a field it does not
    /// recognise. And kept: `persist` writes it back, so an older build does not erase it.
    func testAMalformedEntryIsSkippedAndKept() {
        let encoded: [[String: Any]] = [
            ["pattern": "Zoom", "action": "hide"],
            ["pattern": "Zoom", "action": "notARealAction"],
            ["action": "hide"],
        ]
        let decoded = TitleRulesStore.decode(encoded)
        XCTAssertEqual(decoded.rules.count, 1)
        XCTAssertEqual(decoded.rules.first?.pattern, "Zoom")
        XCTAssertEqual(decoded.unreadable.count, 2)
    }

    /// The regression. The list used to be cast whole, and one element that is not a dictionary
    /// failed the cast for all of them — every rule gone, nothing logged.
    func testOneEntryThatIsNotADictionaryCostsOnlyItself() {
        let raw: [Any] = [
            ["pattern": "Zoom", "action": "neverTile"],
            "Picture in Picture",
            ["pattern": "^PiP", "action": "hide"],
        ]
        let decoded = TitleRulesStore.decode(raw)
        XCTAssertEqual(decoded.rules.map(\.pattern), ["Zoom", "^PiP"])
        XCTAssertEqual(decoded.unreadable.first as? String, "Picture in Picture")
    }

    func testAStoredValueThatIsNotAListDecodesAsNoRules() {
        let decoded = TitleRulesStore.decode("Zoom")
        XCTAssertTrue(decoded.rules.isEmpty)
        XCTAssertTrue(decoded.unreadable.isEmpty)
        XCTAssertTrue(TitleRulesStore.decode(nil).rules.isEmpty)
    }

    // MARK: - Which apps the expand walk visits

    /// The refresh only reads window titles for apps an expand rule could apply to: one naming the
    /// app, or one naming none. Other actions do not count.
    func testOnlyAppsAnExpandRuleNamesAreWalked() {
        let scoped = [
            compile(bundleID: "com.apple.Safari", pattern: "PiP", action: .expand),
            compile(bundleID: nil, pattern: "x", action: .hide),
        ]
        XCTAssertTrue(TargetProvider.mayExpand(scoped, bundleID: "com.apple.Safari"))
        XCTAssertFalse(TargetProvider.mayExpand(scoped, bundleID: "com.apple.mail"))
        XCTAssertFalse(TargetProvider.mayExpand(scoped, bundleID: nil))
        let anyApp = [compile(bundleID: nil, pattern: "PiP", action: .expand)]
        XCTAssertTrue(TargetProvider.mayExpand(anyApp, bundleID: "com.apple.mail"))
    }
}
