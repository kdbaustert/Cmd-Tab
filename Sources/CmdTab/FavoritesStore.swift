import AppKit
import SwiftUI

/// Apps the user has pinned as favourites. When a favourite isn't running it still appears in the
/// switcher (app mode) as a launchable tile, so ⌘-Tab doubles as a launcher for the handful of apps
/// you always want one keystroke away.
///
/// Keyed by bundle identifier, like exclusions, so a pin survives the app quitting and relaunching.
@MainActor
final class FavoritesStore: ObservableObject {
    static let shared = FavoritesStore()

    private static let defaultsKey = "favoriteBundleIDs"

    @Published private(set) var favorites: [String] = []

    /// Fired after every change so the switcher can rebuild its list with the launchable tiles.
    var onChange: (([String]) -> Void)?

    private init() {
        favorites = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
    }

    func isFavorite(_ bundleID: String) -> Bool { favorites.contains(bundleID) }

    func add(_ bundleID: String) {
        guard bundleID != Bundle.main.bundleIdentifier, !favorites.contains(bundleID) else { return }
        favorites.append(bundleID)
        persist()
    }

    func remove(_ bundleID: String) {
        guard let index = favorites.firstIndex(of: bundleID) else { return }
        favorites.remove(at: index)
        persist()
    }

    func removeAll() {
        guard !favorites.isEmpty else { return }
        favorites.removeAll()
        persist()
    }

    /// Re-reads the set after an import or reset and notifies so the switcher rebuilds.
    func reload() {
        favorites = UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? []
        onChange?(favorites)
    }

    /// Resolves a favourite's app URL, display name and icon. Nil when the app can no longer be found
    /// on disk (uninstalled). `nonisolated` so the provider can call it while resolving launch tiles.
    nonisolated static func appInfo(for bundleID: String) -> (url: URL, name: String, icon: NSImage)?
    {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        let name = FileManager.default.displayName(atPath: url.path)
            .replacingOccurrences(of: ".app", with: "")
        return (url, name, NSWorkspace.shared.icon(forFile: url.path))
    }

    private func persist() {
        UserDefaults.standard.set(favorites, forKey: Self.defaultsKey)
        onChange?(favorites)
    }
}
