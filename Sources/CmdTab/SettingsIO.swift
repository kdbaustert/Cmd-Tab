import AppKit

/// Export, import, and reset for every preference Cmd-Tab owns. Values live in `UserDefaults`; this
/// moves the owned keys to and from a JSON file and reloads the live stores so changes take effect
/// without a relaunch.
@MainActor
enum SettingsIO {
    private static var keys: [String] { BehaviorStore.ownedDefaultsKeys }

    static func export() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Cmd-Tab Settings.json"
        panel.message = "Export Cmd-Tab settings"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let defaults = UserDefaults.standard
        var dict: [String: Any] = [:]
        for key in keys where defaults.object(forKey: key) != nil {
            dict[key] = defaults.object(forKey: key)
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
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

        let defaults = UserDefaults.standard
        let allowed = Set(keys)
        for (key, value) in dict where allowed.contains(key) {
            defaults.set(value, forKey: key)
        }
        reloadStores()
    }

    static func reset() {
        BehaviorStore.shared.resetAll()  // removes the owned keys
        reloadStores()
    }

    /// Re-reads UserDefaults into every live store so the UI and the running switcher update at once.
    private static func reloadStores() {
        BehaviorStore.shared.reload()
        AppearanceStore.shared.reload()
        ExclusionStore.shared.reload()
        FavoritesStore.shared.reload()
        SwitcherShortcutsStore.shared.reload()
    }
}
