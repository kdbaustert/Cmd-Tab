import Foundation

/// The app was called Overtab before it was called Cmd-Tab. The rename changed the bundle
/// identifier, and `UserDefaults.standard` is keyed on that, so every tuned setting would
/// otherwise disappear the first time the renamed build launched.
///
/// This can go once nobody is upgrading from an Overtab build.
enum Migration {
    private static let oldDomain = "com.overtab.Overtab"
    private static let doneKey = "migratedFromOvertab"
    private static let keys = [
        "mode", "iconSize", "iconSpacing", "panelPadding", "titleSpacing", "excludedBundleIDs",
    ]

    /// Must run before anything reads a setting.
    static func run() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: doneKey) else { return }
        defaults.set(true, forKey: doneKey)

        guard let old = UserDefaults(suiteName: oldDomain) else { return }
        var moved: [String] = []
        for key in keys {
            // Never clobber a value the new build already has.
            guard defaults.object(forKey: key) == nil, let value = old.object(forKey: key)
            else { continue }
            defaults.set(value, forKey: key)
            moved.append(key)
        }
        guard !moved.isEmpty else { return }
        Log.general.notice("migrated from Overtab: \(moved.joined(separator: ", "))")
    }
}
