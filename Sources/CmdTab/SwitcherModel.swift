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
    /// All targets to display. Filtering dims non-matches but keeps them visible.
    @Published private(set) var targets: [SwitchTarget] = []
    @Published var selection: Int = 0
    /// The live type-to-filter query. Empty means "show everything".
    @Published private(set) var query: String = ""
    /// Indices into `targets` that match the current query. Empty when no query.
    @Published private(set) var matchingIndices: Set<Int> = []
    @Published var mode: SwitcherMode = .apps
    /// Grid of icons, or one target per row.
    @Published var layout: SwitcherLayout = .grid
    /// Every panel dimension; see `Metrics`.
    @Published var metrics: Metrics = .default
    /// Tint of the selected tile's highlight.
    @Published var highlightColor: Color = .accentColor
    /// Show the ⌘-number badge on the first ten tiles.
    @Published var showNumbers: Bool = true
    /// Show the display and Space badges on window tiles.
    @Published var showBadges: Bool = true
    /// The frosted material behind the tiles.
    @Published var material: PanelMaterial = .hud
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

    /// Whether the current query matched anything at all. Empty query counts as matching — there is
    /// no filter to fail.
    var matchesAnything: Bool { query.isEmpty || !matchingIndices.isEmpty }

    /// Whether the full list has anything in it, regardless of the current filter. Distinguishes
    /// "this app has no windows" from "the query matched nothing" — the panel stays up for the latter.
    var hasAnyTarget: Bool { !allTargets.isEmpty }


    private var allTargets: [SwitchTarget] = []
    /// Installed apps offered because the query matched nothing running. Appended after the real
    /// targets, so every existing index — hit-testing, ⌘-number, the caption — keeps its meaning.
    private var suggestions: [SwitchTarget] = []

    /// What the panel actually shows.
    private var composed: [SwitchTarget] { allTargets + suggestions }

    /// Replaces the launch suggestions, keeping the current query and selection sensible.
    ///
    /// Cleared by `begin` and by any query change that finds matches, so a stale suggestion from a
    /// previous keystroke can never sit at the end of the list.
    func setLaunchSuggestions(_ new: [SwitchTarget]) {
        guard new.map(\.id) != suggestions.map(\.id) else { return }
        suggestions = new
        reapply(anchor: selected?.id)
    }

    func step(_ delta: Int) {
        guard !targets.isEmpty else { return }
        // When filtering, only step through matching indices
        if matchingIndices.isEmpty {
            selection = (selection + delta + targets.count) % targets.count
        } else {
            let sorted = matchingIndices.sorted()
            if let current = sorted.firstIndex(of: selection) {
                let next = (current + delta + sorted.count) % sorted.count
                selection = sorted[next]
            } else {
                selection = sorted.first ?? 0
            }
        }
    }

    /// Starts a fresh session: replaces the whole list and clears any previous query. The caller
    /// sets `selection` afterward.
    func begin(_ new: [SwitchTarget]) {
        query = ""
        allTargets = new
        suggestions = []
        targets = new
        matchingIndices = []
    }

    /// Keeps the highlight on the same target across a background refresh, so the tile the user
    /// is looking at does not slide out from under them. Honours the active query.
    func update(targets new: [SwitchTarget]) {
        allTargets = new
        reapply(anchor: selected?.id)
    }

    /// Sets the filter query and highlights the first match. All tiles remain visible; selection
    /// cycles only through matches.
    func setQuery(_ new: String) {
        query = new
        // Keep all targets visible, track which indices match
        targets = composed
        matchingIndices = Self.matchingIndices(targets, query: query)
        // The *best* match, not the first one in list order — see `bestMatch`.
        if let best = Self.bestMatch(targets, query: query) {
            selection = best
        }
    }

    /// Drops matching targets from the *full* list (not just the filtered view), so removing the
    /// acted-on tile during a search doesn't discard the apps the query is hiding.
    func remove(where predicate: (SwitchTarget) -> Bool) {
        let anchor = selected?.id
        allTargets.removeAll(where: predicate)
        reapply(anchor: anchor)
    }

    private func reapply(anchor: String?) {
        targets = composed
        matchingIndices = Self.matchingIndices(targets, query: query)
        if let anchor, let index = targets.firstIndex(where: { $0.id == anchor }),
           (matchingIndices.isEmpty || matchingIndices.contains(index)) {
            selection = index
        } else if let best = Self.bestMatch(targets, query: query) {
            selection = best
        } else {
            selection = targets.isEmpty ? 0 : min(selection, targets.count - 1)
        }
    }

    /// Fuzzy match against the tile's title and app name. See `FuzzyMatch`.
    ///
    /// A query with several space-separated words requires every word to match, so "saf 2" still
    /// finds Safari's second window — but each word now matches as a subsequence rather than a
    /// substring, so "vsc" finds Visual Studio Code.
    static func filtered(_ list: [SwitchTarget], query: String) -> [SwitchTarget] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return list }
        return list.filter { score($0, query: query) != nil }
    }

    /// Returns indices of targets matching the query.
    static func matchingIndices(_ list: [SwitchTarget], query: String) -> Set<Int> {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        return Set(list.indices.filter { score(list[$0], query: query) != nil })
    }

    /// The best index to select for a query: the highest-scoring match rather than the first one in
    /// list order.
    ///
    /// This is the point of scoring. Selection used to land on `matchingIndices.min()`, so typing
    /// "chr" with Character Viewer ahead of Chrome in the list highlighted the wrong one and the
    /// user had to arrow past it — which is exactly the work filtering is supposed to save.
    /// Ties break towards the earlier index, which for the default sort is the more recently used.
    static func bestMatch(_ list: [SwitchTarget], query: String) -> Int? {
        var best: (index: Int, score: Int)?
        for index in list.indices {
            guard let score = score(list[index], query: query) else { continue }
            if best == nil || score > best!.score { best = (index, score) }
        }
        return best?.index
    }

    /// A target's score for a query: every word must match, and the total is their sum.
    ///
    /// Both fields are scored and the better taken, rather than concatenating them: a query matching
    /// the *title* strongly should not be diluted by the app name trailing after it.
    private static func score(_ target: SwitchTarget, query: String) -> Int? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return 0 }
        var total = 0
        for word in words {
            let title = FuzzyMatch.score(target.title, query: word)
            let app = FuzzyMatch.score(target.appName, query: word)
            guard let best = [title, app].compactMap({ $0 }).max() else { return nil }
            total += best
        }
        return total
    }
}
