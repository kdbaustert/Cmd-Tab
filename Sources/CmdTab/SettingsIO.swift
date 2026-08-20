import AppKit

/// Export, import, and reset for every preference Cmd-Tab owns. Values live in `UserDefaults`; this
/// moves the owned keys to and from a JSON file and reloads the live stores so changes take effect
/// without a relaunch.
@MainActor
enum SettingsIO {
    private static var keys: [String] { BehaviorStore.ownedDefaultsKeys }

    /// Every owned preference that has actually been set, as a plist-safe dictionary.
    ///
    /// Shared with `ConfigFile`, which writes the same payload to disk continuously rather than on
    /// demand — the two must agree on what "your settings" means, or a config file would carry a
    /// different set from an exported one.
    static func currentPayload() -> [String: Any] {
        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for key in keys where defaults.object(forKey: key) != nil {
            dict[key] = defaults.object(forKey: key)
        }
        return dict
    }

    /// Writes an incoming payload into `UserDefaults`, ignoring anything not ours, and republishes
    /// every store. Keys absent from `payload` are left alone rather than reset: a hand-edited
    /// config that mentions three settings means "change these three".
    static func apply(_ payload: [String: Any]) {
        let rejected = apply(payload, to: .standard)
        if !rejected.isEmpty {
            // `.public` because these are key names matched against our own allow-list, so nothing
            // that came from the file's *values* passes through here.
            Log.general.error(
                """
                config: ignored \(rejected.sorted().joined(separator: ", "), privacy: .public) \
                — not a property list
                """)
        }
        reloadStores()
    }

    /// The testable half, and the one that does the work.
    ///
    /// Split for the reason `Migration.run(in:migratingFrom:report:)` is: this rewrites settings a
    /// user already has, against a file they are explicitly invited to edit by hand, so what it does
    /// with a value it did not expect is part of the contract rather than an implementation detail.
    /// `reloadStores` stays with the caller because it drives the live UI.
    ///
    /// - Returns: the keys it refused, so the caller can say so. Nothing else reports them — a
    ///   silently dropped setting is the failure this whole guard exists to make visible.
    @discardableResult
    static func apply(_ payload: [String: Any], to defaults: UserDefaults) -> [String] {
        let allowed = Set(keys)
        var rejected: [String] = []
        for (key, value) in payload where allowed.contains(key) {
            // JSON has no way to spell "unset", so `null` is what a hand-edited config reaches for,
            // and removing the key is exactly what it should mean: an absent key is how "use the
            // default" is written everywhere else in this app, and `resetAll` depends on that.
            if value is NSNull {
                defaults.removeObject(forKey: key)
                continue
            }
            // Everything else has to be a property list *before* it reaches `set(_:forKey:)`, which
            // raises rather than returning on a value that is not one. A `null` anywhere in the file
            // — bare, or nested inside an array — therefore aborted the process, and because
            // `ConfigFile` re-reads and re-applies the same file at every launch, it did so again on
            // the next one, with no way out of it from inside the app.
            //
            // One recursive check rather than a hand-rolled walk over arrays and dictionaries:
            // `NSNull` is the only invalid value `JSONSerialization` can produce today, but this
            // should not have to be revisited if that ever stops being true.
            guard PropertyListSerialization.propertyList(value, isValidFor: .binary) else {
                rejected.append(key)
                continue
            }
            defaults.set(value, forKey: key)
        }
        return rejected
    }

    /// Serialised the one way, so a byte comparison between what we wrote and what is on disk is
    /// meaningful. Sorted keys also keep the file diff-friendly, which is the point of putting it
    /// in a dotfiles repo.
    static func encode(_ payload: [String: Any]) -> Data? {
        try? JSONSerialization.data(
            withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
    }

    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Cmd-Tab Settings.json"
        panel.message = "Export Cmd-Tab settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        guard let data = encode(currentPayload()) else { return }
        try? data.write(to: url)
    }

    static func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import Cmd-Tab settings"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        apply(dict)
    }

    static func reset() {
        BehaviorStore.shared.resetAll()  // removes the owned keys
        reloadStores()
    }

    /// Re-reads UserDefaults into every live store so the UI and the running switcher update at once.
    static func reloadStores() {
        BehaviorStore.shared.reload()
        AppearanceStore.shared.reload()
        ExclusionStore.shared.reload()
        FavoritesStore.shared.reload()
        WindowTilingStore.shared.reload()
        GlobalActionsStore.shared.reload()
        ScopedTriggersStore.shared.reload()
        AppRulesStore.shared.reload()
        SwitcherShortcutsStore.shared.reload()
        // Last: an import or reset can flip the config-file switch itself, and this re-reads it
        // rather than leaving a watcher running against a preference that has since changed.
        ConfigFile.shared.reload()
    }
}
