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

    /// Moves a favourite into the slot another one holds — what dropping a row onto another row in
    /// settings means. Positions are resolved against the whole list rather than against what the
    /// pane is showing, so a drag past an excluded favourite (whose star is masked, so it has no
    /// row) still lands where the user aimed.
    func move(_ bundleID: String, toPositionOf target: String) {
        let reordered = Self.reordered(favorites, moving: bundleID, toPositionOf: target)
        guard reordered != favorites else { return }
        favorites = reordered
        persist()
    }

    /// The reorder itself, kept out of the store so it can be tested without `UserDefaults`.
    ///
    /// The moved app *takes* the target's index — dragging the last row onto the first makes it
    /// first, and dragging the first onto the last makes it last — rather than being inserted
    /// before or after depending on the direction of travel.
    nonisolated static func reordered(
        _ list: [String], moving bundleID: String, toPositionOf target: String
    ) -> [String] {
        guard bundleID != target,
              let from = list.firstIndex(of: bundleID),
              let to = list.firstIndex(of: target) else { return list }
        var moved = list
        moved.remove(at: from)
        moved.insert(bundleID, at: to)
        return moved
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
