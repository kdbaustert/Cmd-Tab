import AppKit

/// Per-app overrides of settings that are otherwise global.
///
/// Favourite and exclude answer "should this app be in the switcher at all". These answer the
/// questions that only became askable once the switcher grew a global apps/windows mode and a window
/// tiler: *this* app should always be listed window-by-window, and *that* app's windows should never
/// be resized by a tiling chord.
///
/// Deliberately sparse — only apps with a non-default rule are stored — so the common case costs
/// nothing and an app the user has never heard of never appears in their settings file.
struct AppRule: Equatable {
    /// Always list this app's windows individually, even when the switcher is in app mode.
    var expandWindows = false
    /// Never let a tiling chord move or resize this app's windows.
    var neverTile = false
    /// Switching to this app while it is *already* frontmost hides it instead, so one chord toggles
    /// it away and back. Off everywhere by default: the switcher's job is to switch, and an app that
    /// vanished when you picked it would be astonishing anywhere it was not asked for.
    var hideWhenFrontmost = false
    /// Replaces the name on this app's tiles. Empty means "use the app's own".
    ///
    /// Exists for the hosts that report a name nobody would search for — Electron and Catalyst apps
    /// that call themselves after their framework, and the several distinct tools that all report
    /// "Console". Only the label changes; the app is still keyed by bundle identifier everywhere.
    var displayName = ""
    /// Snap this app's windows here as they open. Nil leaves them wherever the app puts them.
    var launchArrangement: WindowArrangement?

    var isDefault: Bool { self == AppRule() }

    /// The name to show for an app whose own name is `fallback`.
    func label(or fallback: String) -> String {
        displayName.isEmpty ? fallback : displayName
    }
}

@MainActor
final class AppRulesStore: ObservableObject {
    static let shared = AppRulesStore()

    private static let defaultsKey = "appRules"
    static let defaultsKeys = [defaultsKey]

    @Published private(set) var rules: [String: AppRule] = [:]

    var onChange: (([String: AppRule]) -> Void)?

    private init() { rules = Self.load() }

    func rule(for bundleID: String) -> AppRule { rules[bundleID] ?? AppRule() }

    /// Apps carrying a non-default rule, in a stable order for the settings list.
    var configured: [String] { rules.keys.sorted() }

    func setExpandWindows(_ value: Bool, for bundleID: String) {
        var rule = self.rule(for: bundleID)
        rule.expandWindows = value
        set(rule, for: bundleID)
    }

    func setNeverTile(_ value: Bool, for bundleID: String) {
        var rule = self.rule(for: bundleID)
        rule.neverTile = value
        set(rule, for: bundleID)
    }

    func setHideWhenFrontmost(_ value: Bool, for bundleID: String) {
        var rule = self.rule(for: bundleID)
        rule.hideWhenFrontmost = value
        set(rule, for: bundleID)
    }

    /// Whitespace-trimmed, so a name of only spaces reads as "no override" rather than blanking the
    /// tile — the field is a text box and an accidental space is easy to leave behind.
    func setDisplayName(_ value: String, for bundleID: String) {
        var rule = self.rule(for: bundleID)
        rule.displayName = value.trimmingCharacters(in: .whitespacesAndNewlines)
        set(rule, for: bundleID)
    }

    func setLaunchArrangement(_ value: WindowArrangement?, for bundleID: String) {
        var rule = self.rule(for: bundleID)
        rule.launchArrangement = value
        set(rule, for: bundleID)
    }

    func remove(_ bundleID: String) {
        guard rules[bundleID] != nil else { return }
        rules[bundleID] = nil
        persist()
    }

    /// Storing a rule that says nothing would grow the file forever with entries that change no
    /// behaviour, so a rule reset to its defaults deletes itself.
    private func set(_ rule: AppRule, for bundleID: String) {
        if rule.isDefault {
            remove(bundleID)
            return
        }
        guard rules[bundleID] != rule else { return }
        rules[bundleID] = rule
        persist()
    }

    func reload() {
        rules = Self.load()
        onChange?(rules)
    }

    /// Stored as `{ bundleID: { field: value } }`, which is plist-safe and stays readable in a
    /// hand-edited `config.json`.
    ///
    /// The value type is `Any` rather than `Bool`: this held two booleans once, and the cast that
    /// enforced that (`value as? [String: Bool]`) would now reject a whole app's entry outright the
    /// moment one string field appeared in it — silently discarding the booleans alongside it. Each
    /// field is cast on its own instead, so an unreadable one costs only itself.
    ///
    /// Only *written* fields are stored, and a field written by a newer build is ignored rather
    /// than dropped: `persist` rewrites the whole dictionary, so anything not read here is lost on
    /// the next write. That is the accepted cost of a flat plist, and the reason a downgrade is a
    /// one-way trip for settings this build does not know about.
    private static func load() -> [String: AppRule] {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return [:] }
        var out: [String: AppRule] = [:]
        for (bundleID, value) in raw {
            guard let fields = value as? [String: Any] else { continue }
            var rule = AppRule()
            rule.expandWindows = fields["expandWindows"] as? Bool ?? false
            rule.neverTile = fields["neverTile"] as? Bool ?? false
            rule.hideWhenFrontmost = fields["hideWhenFrontmost"] as? Bool ?? false
            rule.displayName = fields["displayName"] as? String ?? ""
            // An arrangement retired between builds reads back as nil, which is the same as never
            // having set one — the app simply opens where it opens.
            rule.launchArrangement = (fields["launchArrangement"] as? String)
                .flatMap(WindowArrangement.init(rawValue:))
            if !rule.isDefault { out[bundleID] = rule }
        }
        return out
    }

    private func persist() {
        var raw: [String: [String: Any]] = [:]
        for (bundleID, rule) in rules {
            // Sparse per field as well as per app: writing every field would put five entries in
            // the file for an app the user set one switch on, and make a hand-edited config.json
            // much harder to read than the thing it is describing.
            var fields: [String: Any] = [:]
            if rule.expandWindows { fields["expandWindows"] = true }
            if rule.neverTile { fields["neverTile"] = true }
            if rule.hideWhenFrontmost { fields["hideWhenFrontmost"] = true }
            if !rule.displayName.isEmpty { fields["displayName"] = rule.displayName }
            if let arrangement = rule.launchArrangement {
                fields["launchArrangement"] = arrangement.rawValue
            }
            raw[bundleID] = fields
        }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
        onChange?(rules)
    }
}
