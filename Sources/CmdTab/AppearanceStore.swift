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

    /// Fired after every change so the panel can resize itself.
    var onChange: ((Metrics) -> Void)?

    @Published var iconSize: CGFloat = Metrics.default.iconSize {
        didSet { store(iconSize, was: oldValue, at: Key.iconSize) }
    }
    @Published var iconSpacing: CGFloat = Metrics.default.iconSpacing {
        didSet { store(iconSpacing, was: oldValue, at: Key.iconSpacing) }
    }
    @Published var titleSpacing: CGFloat = Metrics.default.titleSpacing {
        didSet { store(titleSpacing, was: oldValue, at: Key.titleSpacing) }
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
        let defaults = UserDefaults.standard
        func read(_ key: String, _ fallback: CGFloat) -> CGFloat {
            // `double(forKey:)` reports 0 for a missing key, which is indistinguishable from a
            // real stored zero — and zero is a legal value for three of these four.
            defaults.object(forKey: key) != nil
                ? CGFloat(defaults.double(forKey: key)) : fallback
        }
        iconSize = read(Key.iconSize, Metrics.default.iconSize)
        iconSpacing = read(Key.iconSpacing, Metrics.default.iconSpacing)
        titleSpacing = read(Key.titleSpacing, Metrics.default.titleSpacing)
    }

    func reset() {
        iconSize = Metrics.default.iconSize
        iconSpacing = Metrics.default.iconSpacing
        titleSpacing = Metrics.default.titleSpacing
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
        let defaults = UserDefaults.standard
        func read(_ key: String, _ fallback: CGFloat) -> CGFloat {
            defaults.object(forKey: key) != nil
                ? CGFloat(defaults.double(forKey: key)) : fallback
        }
        isReloading = true
        iconSize = read(Key.iconSize, Metrics.default.iconSize)
        iconSpacing = read(Key.iconSpacing, Metrics.default.iconSpacing)
        titleSpacing = read(Key.titleSpacing, Metrics.default.titleSpacing)
        isReloading = false
        // Once, at the end: the panel still has to resize, and the per-field calls were suppressed.
        onChange?(metrics)
    }

    private func store(_ new: CGFloat, was old: CGFloat, at key: String) {
        guard new != old, !isReloading else { return }
        UserDefaults.standard.set(Double(new), forKey: key)
        onChange?(metrics)
    }
}
