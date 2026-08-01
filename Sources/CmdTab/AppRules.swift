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

    var isDefault: Bool { self == AppRule() }
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

    /// Stored as `{ bundleID: ["expandWindows": Bool, "neverTile": Bool] }`, which is plist-safe and
    /// stays readable in a hand-edited `config.json`.
    private static func load() -> [String: AppRule] {
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return [:] }
        var out: [String: AppRule] = [:]
        for (bundleID, value) in raw {
            guard let fields = value as? [String: Bool] else { continue }
            let rule = AppRule(
                expandWindows: fields["expandWindows"] ?? false,
                neverTile: fields["neverTile"] ?? false)
            if !rule.isDefault { out[bundleID] = rule }
        }
        return out
    }

    private func persist() {
        var raw: [String: [String: Bool]] = [:]
        for (bundleID, rule) in rules {
            raw[bundleID] = ["expandWindows": rule.expandWindows, "neverTile": rule.neverTile]
        }
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
        onChange?(rules)
    }
}
