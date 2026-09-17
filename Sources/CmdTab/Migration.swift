import Foundation

/// One-off rewrites of settings a user already has, from the shape an earlier release stored them
/// in to the shape this one reads. Each runs once per install, records that it ran, and can go once
/// nobody is upgrading from the release that needed it.
///
/// ## Why everything here is parameterised
///
/// This is the only code in the app that rewrites settings a user already has, it runs once per
/// install before anything reads a preference, and every way it can be wrong is silent: a guard
/// that opens when it should not clobbers a value the user chose, and one that closes when it
/// should not withholds a value they were owed. Neither shows up as anything but a preference that
/// is mysteriously not what it was.
///
/// So the domain and the reporter are arguments rather than globals. `run()` supplies the real
/// ones and is what `AppDelegate` calls; the tests drive `run(in:report:)` against a throwaway
/// suite. Nothing here reaches for `UserDefaults.standard` or `Log` on its own, which is the whole
/// of what makes the three branches below checkable.
enum Migration {
    /// Must run before anything reads a setting.
    static func run() {
        run(in: .standard)
    }

    /// The testable entry point, and the one that does the work.
    static func run(in defaults: UserDefaults, report: (String) -> Void = announce) {
        splitBadgeToggle(defaults, report)
        reviveSnapHighlightColor(defaults, report)
        dropSavedLayouts(defaults, report)
    }

    /// The production reporter. Injectable for the reason `TapStateMirror.report` documents: the
    /// tests have to run the real migrations to be worth anything, and running them writes
    /// `notice` lines into `com.cmdtab.CmdTab` from `xctest` that read exactly like an install
    /// genuinely migrating. A silent reporter keeps `log show` on this subsystem honest.
    ///
    /// `.public` because every message here is defaults key names and a colour hex. Nothing that
    /// came from a window title or a document passes through it.
    static func announce(_ message: String) {
        Log.general.notice("\(message, privacy: .public)")
    }

    /// `windowSnapHighlightColorHex` set the snap outline and landing block together, until both
    /// were fixed to grey-on-black and the key was retired. They are settings again — two of them
    /// now, one per overlay — so anyone who had chosen a colour back then gets it back.
    ///
    /// Seeded into both new keys, because the old single setting drove both overlays: splitting one
    /// value in two is what preserves the appearance the user actually had, where seeding only one
    /// would leave them with a half-recoloured gesture they never asked for.
    ///
    /// Neither key is written if the user has already set one on this build — a value chosen now is
    /// a later statement of intent than one chosen before the feature was withdrawn, and must not be
    /// overwritten by it.
    ///
    /// The old key is left on disk. It is in `retiredDefaultsKeys`, which is what clears it on the
    /// next reset, and deleting it here would make this migration unrepeatable if it ever needed
    /// fixing — the same reasoning as `splitBadgeToggle`.
    private static func reviveSnapHighlightColor(
        _ defaults: UserDefaults, _ report: (String) -> Void
    ) {
        guard !defaults.bool(forKey: snapColorRevivedKey) else { return }
        defaults.set(true, forKey: snapColorRevivedKey)
        guard let legacy = defaults.string(forKey: "windowSnapHighlightColorHex") else { return }
        var revived: [String] = []
        for key in ["windowSnapOutlineColorHex", "windowSnapLandingColorHex"]
        where defaults.object(forKey: key) == nil {
            defaults.set(legacy, forKey: key)
            revived.append(key)
        }
        guard !revived.isEmpty else { return }
        report(
            "migrated: revived the retired snap highlight colour \(legacy) into "
                + revived.joined(separator: ", "))
    }

    private static let snapColorRevivedKey = "migratedRevivedSnapHighlightColor"

    /// Saved layouts were removed, and the stored list went with the feature.
    ///
    /// Deleted outright rather than left for the next reset to sweep, which is what the retired keys
    /// get: those are settings whose *meaning* moved somewhere else, and leaving them keeps their
    /// migration repeatable. This one has nowhere to move to — no code reads `windowLayouts` any
    /// more — so it is a list of window frames sitting in the preferences of every user who ever
    /// saved one, and it can be arbitrarily large.
    private static func dropSavedLayouts(_ defaults: UserDefaults, _ report: (String) -> Void) {
        guard !defaults.bool(forKey: layoutsDroppedKey) else { return }
        defaults.set(true, forKey: layoutsDroppedKey)
        guard defaults.object(forKey: layoutsKey) != nil else { return }
        defaults.removeObject(forKey: layoutsKey)
        report("migrated: dropped the saved-layouts list, the feature is gone")
    }

    private static let layoutsDroppedKey = "migratedDroppedSavedLayouts"
    private static let layoutsKey = "windowLayouts"

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
    private static func splitBadgeToggle(_ defaults: UserDefaults, _ report: (String) -> Void) {
        guard !defaults.bool(forKey: badgeSplitKey) else { return }
        defaults.set(true, forKey: badgeSplitKey)
        guard let legacy = defaults.object(forKey: "showBadges") as? Bool, !legacy else { return }
        defaults.set(false, forKey: "showDisplayBadges")
        defaults.set(false, forKey: "showSpaceBadges")
        report("migrated: showBadges=false split across both marker settings")
    }

    private static let badgeSplitKey = "migratedBadgeSplit"
}
