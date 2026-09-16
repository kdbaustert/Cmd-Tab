import AppKit

/// Window-title rules: `AppRule` answers "how should this app behave", but some windows want a
/// different answer from the rest of the same app — one Zoom window that should never be tiled
/// while the meeting is up, a browser's picture-in-picture window that should never be in the
/// switcher at all. A title rule is the per-window version of that question, matched by a regular
/// expression against the window's title rather than by which app owns it.
///
/// A rule and an app rule saying the same thing are never in tension — both answer the same three
/// yes/no questions, so wherever an app rule is consulted, a title rule is unioned in beside it:
/// either one is enough to hide a window, expand it, or protect it from tiling.
enum TitleRuleAction: String, CaseIterable, Identifiable {
    /// Never list this window in the switcher, in app mode or window mode, and never show it in a
    /// hover preview or thumbnail strip.
    case hide
    /// Always list this window on its own, even when its app is not one of the apps `expandWindows`
    /// names — the per-window version of that override.
    case expand
    /// Never let a tiling chord or the drag snap move or resize this window — the per-window
    /// version of `neverTile`.
    case neverTile

    var id: String { rawValue }

    var title: String {
        switch self {
        case .hide: return "Hide from switcher"
        case .expand: return "Always list individually"
        case .neverTile: return "Never tile"
        }
    }
}

/// One title rule: an optional app to restrict it to, the pattern, and what matching does.
///
/// `bundleID == nil` reads as "any app" — a rule against a title alone, for the handful of window
/// titles (a Picture in Picture player, a screen-share overlay) that name themselves the same way
/// regardless of which app opened them.
struct TitleRule: Identifiable, Equatable {
    let id: UUID
    var bundleID: String?
    var pattern: String
    var action: TitleRuleAction

    init(id: UUID = UUID(), bundleID: String? = nil, pattern: String = "", action: TitleRuleAction = .hide) {
        self.id = id
        self.bundleID = bundleID
        self.pattern = pattern
        self.action = action
    }
}

/// A title rule with its regex compiled once, handed to every queue that has to match a window
/// against it — the switcher's Accessibility walk and the tiling chords both do this per window, per
/// pass, and re-compiling the same pattern there would be paying regex construction on the thread
/// that must never stall.
///
/// `@unchecked Sendable`: `NSRegularExpression` is not `Sendable`, but Foundation documents it as
/// immutable and safe to share across threads once built, which is exactly how this is used — built
/// once on the main actor, read-only everywhere else.
struct CompiledTitleRule: @unchecked Sendable {
    let bundleID: String?
    let action: TitleRuleAction
    /// nil when the pattern failed to compile. Treated as matching nothing rather than crashing, so
    /// a typo in a regex disables that one rule instead of the feature.
    let regex: NSRegularExpression?

    /// Whether `title` matches this rule for `action`, unioning nothing on its own — see
    /// `matches(_:bundleID:title:action:)` for the list-wide check every call site actually uses.
    fileprivate func matches(bundleID candidateBundleID: String?, title: String) -> Bool {
        guard let regex else { return false }
        guard self.bundleID == nil || self.bundleID == candidateBundleID else { return false }
        let range = NSRange(title.startIndex..<title.endIndex, in: title)
        return regex.firstMatch(in: title, options: [], range: range) != nil
    }

    /// Whether any rule in `rules` matching `action` matches this window. The check every call
    /// site that used to read a bundle-level flag now reads instead, unioned with that flag rather
    /// than replacing it.
    ///
    /// `nonisolated` and free of instance state, so the tiling queue and the Accessibility queue can
    /// call it directly on the compiled snapshot they were handed, with no actor hop.
    nonisolated static func matches(
        _ rules: [CompiledTitleRule], bundleID: String?, title: String, action: TitleRuleAction
    ) -> Bool {
        guard !rules.isEmpty else { return false }
        return rules.contains { $0.action == action && $0.matches(bundleID: bundleID, title: title) }
    }
}

@MainActor
final class TitleRulesStore: ObservableObject {
    static let shared = TitleRulesStore()

    private static let defaultsKey = "titleRules"
    static let defaultsKeys = [defaultsKey]

    @Published private(set) var rules: [TitleRule] = []
    /// Regex compiled once per rule, rebuilt whenever the list changes. Keyed by rule id so a UI
    /// row can ask whether its own pattern is valid without recompiling anything.
    private var compiledByID: [UUID: NSRegularExpression?] = [:]

    /// Fired after every change, with the freshly compiled list — the shape every consumer
    /// (`TargetProvider`, the tiling chords, the drag paths) actually stores and matches against.
    var onChange: (([CompiledTitleRule]) -> Void)?

    private init() {
        rules = Self.load()
        recompile()
    }

    /// The compiled snapshot handed to everything that matches windows against these rules.
    var compiled: [CompiledTitleRule] {
        rules.map { CompiledTitleRule(bundleID: $0.bundleID, action: $0.action, regex: compiledByID[$0.id] ?? nil) }
    }

    /// Whether this rule's own pattern compiled, for the settings row to show a red outline on.
    func isValid(_ rule: TitleRule) -> Bool {
        (compiledByID[rule.id] ?? nil) != nil
    }

    @discardableResult
    func addRule() -> UUID {
        let rule = TitleRule()
        rules.append(rule)
        persist()
        return rule.id
    }

    func update(_ id: UUID, _ mutate: (inout TitleRule) -> Void) {
        guard let index = rules.firstIndex(where: { $0.id == id }) else { return }
        mutate(&rules[index])
        persist()
    }

    func remove(_ id: UUID) {
        guard rules.contains(where: { $0.id == id }) else { return }
        rules.removeAll { $0.id == id }
        persist()
    }

    func reload() {
        rules = Self.load()
        recompile()
        onChange?(compiled)
    }

    private func recompile() {
        var map: [UUID: NSRegularExpression?] = [:]
        for rule in rules {
            map[rule.id] = try? NSRegularExpression(pattern: rule.pattern, options: [.caseInsensitive])
        }
        compiledByID = map
    }

    /// Stored as an array of `{ id, bundleID?, pattern, action }`, order preserved — unlike
    /// `AppRule`, which is deliberately sparse and keyed by bundle id, a title rule has no natural
    /// key of its own and the order is part of what the user set up (the settings list is exactly
    /// this array, top to bottom).
    private static func load() -> [TitleRule] {
        guard let raw = UserDefaults.standard.array(forKey: defaultsKey) as? [[String: Any]]
        else { return [] }
        return raw.compactMap { fields in
            guard let pattern = fields["pattern"] as? String,
                let actionRaw = fields["action"] as? String,
                let action = TitleRuleAction(rawValue: actionRaw)
            else { return nil }
            let id = (fields["id"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID()
            return TitleRule(id: id, bundleID: fields["bundleID"] as? String, pattern: pattern, action: action)
        }
    }

    private func persist() {
        recompile()
        let raw: [[String: Any]] = rules.map { rule in
            var fields: [String: Any] = [
                "id": rule.id.uuidString,
                "pattern": rule.pattern,
                "action": rule.action.rawValue,
            ]
            if let bundleID = rule.bundleID { fields["bundleID"] = bundleID }
            return fields
        }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
        onChange?(compiled)
    }
}
