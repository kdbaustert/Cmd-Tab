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
    /// round trip rather than through `UserDefaults`, which no test here touches.
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

        let decoded: [TitleRule] = encoded.compactMap { fields in
            guard let pattern = fields["pattern"] as? String,
                let actionRaw = fields["action"] as? String,
                let action = TitleRuleAction(rawValue: actionRaw)
            else { return nil }
            let id = (fields["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return TitleRule(id: id, bundleID: fields["bundleID"] as? String, pattern: pattern, action: action)
        }

        XCTAssertEqual(decoded, rules)
    }

    /// A malformed entry — an action a newer build removed, say — is skipped rather than crashing
    /// the whole load, the same contract `AppRulesStore.load` keeps for a field it does not
    /// recognise.
    func testAMalformedEntryIsSkippedNotCrashed() {
        let encoded: [[String: Any]] = [
            ["pattern": "Zoom", "action": "hide"],
            ["pattern": "Zoom", "action": "notARealAction"],
            ["action": "hide"],
        ]
        let decoded: [TitleRule] = encoded.compactMap { fields in
            guard let pattern = fields["pattern"] as? String,
                let actionRaw = fields["action"] as? String,
                let action = TitleRuleAction(rawValue: actionRaw)
            else { return nil }
            return TitleRule(bundleID: fields["bundleID"] as? String, pattern: pattern, action: action)
        }
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.pattern, "Zoom")
    }
}
