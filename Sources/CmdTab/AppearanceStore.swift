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

    private func store(_ new: CGFloat, was old: CGFloat, at key: String) {
        guard new != old else { return }
        UserDefaults.standard.set(Double(new), forKey: key)
        onChange?(metrics)
    }
}
