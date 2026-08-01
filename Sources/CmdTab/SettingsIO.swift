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
        let defaults = UserDefaults.standard
        let allowed = Set(keys)
        for (key, value) in payload where allowed.contains(key) {
            defaults.set(value, forKey: key)
        }
        reloadStores()
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
        SwitcherShortcutsStore.shared.reload()
        WindowTilingStore.shared.reload()
        GlobalActionsStore.shared.reload()
        ScopedTriggersStore.shared.reload()
        // Last: an import or reset can flip the config-file switch itself, and this re-reads it
        // rather than leaving a watcher running against a preference that has since changed.
        ConfigFile.shared.reload()
    }
}
