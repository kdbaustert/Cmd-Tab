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
        "mode", "iconSize", "iconSpacing", "titleSpacing", "excludedBundleIDs",
    ]

    /// Must run before anything reads a setting.
    static func run() {
        splitBadgeToggle()
        renameFromOvertab()
    }

    /// `showBadges` was one switch over both the display and the Space marker; it is now two.
    ///
    /// Only a value of *false* is carried across. True is the default for both new keys, so seeding
    /// it would write today's default into the user's defaults as though they had picked it — and
    /// `BehaviorStore.resetAll` depends on an unset key staying unset, or a future change to the
    /// default could never reach anyone who had ever run this build.
    ///
    /// The old key is left on disk rather than removed: it is in `retiredDefaultsKeys`, which is
    /// what clears it on the next reset, and deleting it here would make this migration
    /// unrepeatable if it ever needed fixing.
    private static func splitBadgeToggle() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: badgeSplitKey) else { return }
        defaults.set(true, forKey: badgeSplitKey)
        guard let legacy = defaults.object(forKey: "showBadges") as? Bool, !legacy else { return }
        defaults.set(false, forKey: "showDisplayBadges")
        defaults.set(false, forKey: "showSpaceBadges")
        Log.general.notice("migrated: showBadges=false split across both marker settings")
    }

    private static let badgeSplitKey = "migratedBadgeSplit"

    private static func renameFromOvertab() {
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
        Log.general.notice(
            "migrated from Overtab: \(moved.joined(separator: ", "), privacy: .public)")
    }
}
