import AppKit
import SwiftUI

/// How the switcher looks. Each value is one slider in Settings → Appearance, and together they
/// make up the `Metrics` the panel lays itself out from.
@MainActor
final class AppearanceStore: ObservableObject {
    static let shared = AppearanceStore()

    private enum Key {
        static let iconSize = "iconSize"
        static let iconSpacing = "iconSpacing"
        static let titleSpacing = "titleSpacing"
    }

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [Key.iconSize, Key.iconSpacing, Key.titleSpacing]

    /// Fired after every change so the panel can resize itself.
    var onChange: ((Metrics) -> Void)?

    // Each value is held inside its slider's range as it is assigned, not only when `Metrics` is
    // built from it. The sliders read these properties directly, and a theme apply writes two of
    // them from a file nobody here wrote — `Theme.init(from:)` leaves them unclamped on the
    // understanding that `Metrics` covers them, which it does for the panel and did not for the
    // Settings window: `"iconSpacing": 1e19` reached `SettingsSlider` and trapped converting it to
    // an `Int`. Reassigning inside `didSet` does not re-enter it.
    @Published var iconSize: CGFloat = Metrics.default.iconSize {
        didSet {
            let held = Self.held(
                iconSize, in: Metrics.iconSizeRange, default: Metrics.default.iconSize)
            if held != iconSize { iconSize = held }
            store(iconSize, was: oldValue, at: Key.iconSize, default: Metrics.default.iconSize)
        }
    }
    @Published var iconSpacing: CGFloat = Metrics.default.iconSpacing {
        didSet {
            let held = Self.held(
                iconSpacing, in: Metrics.iconSpacingRange, default: Metrics.default.iconSpacing)
            if held != iconSpacing { iconSpacing = held }
            store(
                iconSpacing, was: oldValue, at: Key.iconSpacing,
                default: Metrics.default.iconSpacing)
        }
    }
    @Published var titleSpacing: CGFloat = Metrics.default.titleSpacing {
        didSet {
            let held = Self.held(
                titleSpacing, in: Metrics.titleSpacingRange, default: Metrics.default.titleSpacing)
            if held != titleSpacing { titleSpacing = held }
            store(
                titleSpacing, was: oldValue, at: Key.titleSpacing,
                default: Metrics.default.titleSpacing)
        }
    }

    /// `raw` inside `range`, or `fallback` for a NaN, which `min`/`max` pass straight through and a
    /// property list can hold. The same rule as `BehaviorStore.clamp`.
    nonisolated static func held(
        _ raw: CGFloat, in range: ClosedRange<CGFloat>, default fallback: CGFloat
    ) -> CGFloat {
        raw.isNaN ? fallback : Swift.min(Swift.max(raw, range.lowerBound), range.upperBound)
    }

    /// A stored value read back inside its slider's range; the default when the key is absent.
    ///
    /// `double(forKey:)` reports 0 for a missing key, which is indistinguishable from a real stored
    /// zero — and zero is a legal value for two of these three. Clamped on read and not written
    /// back, like `BehaviorStore.clamped`: config.json or an import checks a number's type only.
    private static func read(
        _ key: String, _ fallback: CGFloat, in range: ClosedRange<CGFloat>
    ) -> CGFloat {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: key) != nil else { return fallback }
        return held(CGFloat(defaults.double(forKey: key)), in: range, default: fallback)
    }

    var metrics: Metrics {
        Metrics(
            iconSize: iconSize,
            iconSpacing: iconSpacing,
            titleSpacing: titleSpacing)
    }

    var isDefault: Bool { metrics == .default }

    private init() {
        // Assignment inside init does not fire didSet, so this loads without writing back.
        let d = Metrics.default
        iconSize = Self.read(Key.iconSize, d.iconSize, in: Metrics.iconSizeRange)
        iconSpacing = Self.read(Key.iconSpacing, d.iconSpacing, in: Metrics.iconSpacingRange)
        titleSpacing = Self.read(Key.titleSpacing, d.titleSpacing, in: Metrics.titleSpacingRange)
    }

    /// "Reset sliders". Removes the three keys rather than writing today's numbers into them, for
    /// the reason `isReloading` below gives: a stored default is a default no later build can move.
    /// `reload` then republishes the built-in values and resizes the panel once.
    func reset() {
        for key in Self.defaultsKeys { UserDefaults.standard.removeObject(forKey: key) }
        reload()
    }

    /// Suppresses the *write* half of the `didSet` handlers during `reload()`, exactly as
    /// `BehaviorStore.isReloading` does and for the same reason.
    ///
    /// `init` is safe without it — Swift skips observers for assignments written inside `init`
    /// itself — but `reload()` is an ordinary method, so every assignment there fires its observer.
    /// Each value was just read out of its key, so re-persisting it is a no-op where the key
    /// existed. Where it did *not*, the read falls through to this build's default and the write
    /// stores it as though the user had chosen it: `resetAll()` followed by `reload()` re-creates
    /// the three keys holding today's numbers, and no future default change can ever reach that
    /// install again. A hand-edited `"iconSize": null` — which `SettingsIO` treats as "use the
    /// default" — comes back written out as `88` within the config file's next write.
    private var isReloading = false

    /// Re-reads the sliders from `UserDefaults` after an import or reset.
    func reload() {
        let d = Metrics.default
        isReloading = true
        iconSize = Self.read(Key.iconSize, d.iconSize, in: Metrics.iconSizeRange)
        iconSpacing = Self.read(Key.iconSpacing, d.iconSpacing, in: Metrics.iconSpacingRange)
        titleSpacing = Self.read(Key.titleSpacing, d.titleSpacing, in: Metrics.titleSpacingRange)
        isReloading = false
        // Once, at the end: the panel still has to resize, and the per-field calls were suppressed.
        onChange?(metrics)
    }

    /// Writes a changed value, or removes its key when the value is the built-in default — the
    /// rule `BehaviorStore.persist` follows, for the reason `isReloading` gives: applying the Glass
    /// theme, or dragging a slider back to where it started, otherwise pinned today's number as
    /// though the user had chosen it.
    private func store(
        _ new: CGFloat, was old: CGFloat, at key: String, default fallback: CGFloat
    ) {
        guard new != old, !isReloading else { return }
        if new == fallback {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(Double(new), forKey: key)
        }
        onChange?(metrics)
    }
}
