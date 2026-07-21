import AppKit
import SwiftUI

/// Resolves the user's chosen title font family.
///
/// Shared so the switcher and the Settings preview agree — a preview that renders in a different
/// font than the thing it is previewing is worse than no preview.
enum TitleFont {
    /// Falls back to the system font when the family can't be resolved, not only when none is set:
    /// a font can be uninstalled between launches, and `Font.custom` with an unknown name silently
    /// substitutes something arbitrary rather than failing, so the check has to happen here.
    static func resolve(_ family: String, size: CGFloat) -> Font {
        guard !family.isEmpty, NSFont(name: family, size: size) != nil else {
            return .system(size: size)
        }
        return .custom(family, size: size)
    }
}

@MainActor
final class SwitcherModel: ObservableObject {
    /// The visible list — `allTargets` narrowed by `query`. Everything downstream (tiles, hover,
    /// jump, columns) works off this, so filtering "just works" once the query is applied here.
    @Published private(set) var targets: [SwitchTarget] = []
    @Published var selection: Int = 0
    /// The live type-to-filter query. Empty means "show everything".
    @Published private(set) var query: String = ""
    @Published var mode: SwitcherMode = .apps
    /// Every panel dimension; see `Metrics`.
    @Published var metrics: Metrics = .default
    /// Tint of the selected tile's highlight.
    @Published var highlightColor: Color = .accentColor
    /// Show the ⌘-number badge on the first nine tiles.
    @Published var showNumbers: Bool = true
    /// The frosted material behind the tiles.
    @Published var material: PanelMaterial = .hud
    /// Panel translucency, 0.3–1.0.
    @Published var opacity: Double = 1.0
    /// Blur radius override for the glass, or nil to use the material's built-in blur.
    @Published var blurRadius: Double?
    /// Corner radius of a tile's highlight.
    @Published var tileCorner: CGFloat = 12
    /// Point size of tile titles.
    @Published var titleFontSize: CGFloat = 10
    /// Font family for tile titles and the caption. Empty means the system font.
    @Published var titleFontName: String = ""

    /// The title font at `size`. See `TitleFont.resolve`.
    func titleFont(size: CGFloat) -> Font { TitleFont.resolve(titleFontName, size: size) }

    /// Tiles carry a title only when they represent windows — the same-app cycle. App tiles show
    /// their name in the caption instead, so repeating it under every icon was pure noise.
    var showsTitle: Bool { mode == .windows }

    var selected: SwitchTarget? {
        targets.indices.contains(selection) ? targets[selection] : nil
    }

    var isEmpty: Bool { targets.isEmpty }

    /// Whether the full list has anything in it, regardless of the current filter. Distinguishes
    /// "this app has no windows" from "the query matched nothing" — the panel stays up for the latter.
    var hasAnyTarget: Bool { !allTargets.isEmpty }

    private var allTargets: [SwitchTarget] = []

    func step(_ delta: Int) {
        guard !targets.isEmpty else { return }
        selection = (selection + delta + targets.count) % targets.count
    }

    /// Starts a fresh session: replaces the whole list and clears any previous query. The caller
    /// sets `selection` afterward.
    func begin(_ new: [SwitchTarget]) {
        query = ""
        allTargets = new
        targets = new
    }

    /// Keeps the highlight on the same target across a background refresh, so the tile the user
    /// is looking at does not slide out from under them. Honours the active query.
    func update(targets new: [SwitchTarget]) {
        allTargets = new
        reapply(anchor: selected?.id)
    }

    /// Sets the filter query, reslices the list, and highlights the top match — like a search field,
    /// where each keystroke re-ranks from the top rather than clinging to the previous selection.
    func setQuery(_ new: String) {
        query = new
        targets = Self.filtered(allTargets, query: query)
        selection = 0
    }

    /// Drops matching targets from the *full* list (not just the filtered view), so removing the
    /// acted-on tile during a search doesn't discard the apps the query is hiding.
    func remove(where predicate: (SwitchTarget) -> Bool) {
        let anchor = selected?.id
        allTargets.removeAll(where: predicate)
        reapply(anchor: anchor)
    }

    private func reapply(anchor: String?) {
        targets = Self.filtered(allTargets, query: query)
        if let anchor, let index = targets.firstIndex(where: { $0.id == anchor }) {
            selection = index
        } else {
            selection = targets.isEmpty ? 0 : min(selection, targets.count - 1)
        }
    }

    /// Case-insensitive substring match against the tile's title and app name. A query with several
    /// space-separated words requires every word to match somewhere, so "saf 2" finds "Safari" window 2.
    static func filtered(_ list: [SwitchTarget], query: String) -> [SwitchTarget] {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return list }
        return list.filter { target in
            let hay = (target.title + " " + target.appName).lowercased()
            return words.allSatisfy(hay.contains)
        }
    }
}
