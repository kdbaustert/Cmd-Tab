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
    /// The tile the cursor is over, or nil when it is over none of them.
    ///
    /// Distinct from `selection`, which the cursor also moves: the two agree while the pointer is on
    /// a tile and diverge the moment it leaves, and it is the *leaving* that matters — the close
    /// button belongs to the tile under the pointer and must go away with the pointer, where the
    /// highlight stays where it was left. Driven by `PanelGroup`'s cursor poll, because the panel
    /// never becomes key and SwiftUI's own hover tracking never runs.
    @Published var hoverIndex: Int?
    /// Whether a hovered tile offers a close button. Mirrors the in-switcher actions switch: the
    /// button is the same action ⌥W performs, so it appears exactly when that key would work.
    @Published var showsCloseButton: Bool = false
    /// Show the display badge on window tiles.
    @Published var showDisplayBadges: Bool = true
    /// Show the Space (Desktop) badge on window tiles.
    @Published var showSpaceBadges: Bool = true
    /// The frosted material behind the tiles.
    @Published var material: PanelMaterial = .hud
    /// Blur radius override for the glass, or nil to use the material's built-in blur.
    @Published var blurRadius: Double?
    /// Corner radius of a tile's highlight.
    @Published var tileCorner: CGFloat = 12
    /// Live window thumbnails drawn as the tile artwork in window mode, keyed by window id.
    ///
    /// Owned by `TileThumbnails` and republished here so a tile can read it without every tile
    /// observing a second object. Empty when the feature is off, which is the default — see
    /// `TileThumbnails` for why it is opt-in.
    @Published var thumbnails: [CGWindowID: CGImage] = [:]
    /// Point size of tile titles.
    @Published var titleFontSize: CGFloat = 10
    /// Font family for tile titles and the caption. Empty means the system font.
    @Published var titleFontName: String = ""

    /// The title font at `size`. See `TitleFont.resolve`.
    func titleFont(size: CGFloat) -> Font { TitleFont.resolve(titleFontName, size: size) }

    /// The digit that jumps to this target, or nil where there is none.
    ///
    /// The ⌘-number jump is disabled while filtering (digits type into the query), so the badges
    /// come off too. The tenth target is labelled 0, because 0 is the key that selects it — there is
    /// no ⌘-10 to press.
    ///
    /// On the model rather than in the view because the announcement wants the same answer: what
    /// VoiceOver says about a tile has to match what is drawn on it, and two copies of this
    /// expression is how that stops being true.
    func number(for index: Int) -> Int? {
        showNumbers && query.isEmpty && index < 10 ? (index + 1) % 10 : nil
    }

    /// Whether tile `index` draws a close button right now.
    ///
    /// Three conditions, and each is load-bearing. The in-switcher actions have to be on, because
    /// the button performs exactly what ⌥W performs and an affordance for a disabled action is a
    /// lie. The cursor has to be on *this* tile, because a button on a tile the pointer is nowhere
    /// near is a button nobody meant to aim at. And the tile has to be something with a window: a
    /// not-running favourite is an offer to launch, and there is nothing there to close.
    ///
    /// On the model rather than in the view so it can be tested — a click that closes the wrong
    /// window is the most expensive mistake in this file, and "which tile is this button on" is the
    /// question that would cause it.
    func showsClose(at index: Int) -> Bool {
        guard showsCloseButton, hoverIndex == index, targets.indices.contains(index) else {
            return false
        }
        return !targets[index].isLaunchable
    }

    /// Tiles carry a title only when they represent windows — the same-app cycle. App tiles show
    /// their name in the caption instead, so repeating it under every icon was pure noise.
    var showsTitle: Bool { mode == .windows }

    var selected: SwitchTarget? {
        targets.indices.contains(selection) ? targets[selection] : nil
    }

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

    /// Moves the highlight one row, for the up and down arrows.
    ///
    /// `stride` is how many indices a row is worth in the layout on screen — see
    /// `SwitcherPanel.rowStride`, which is where it comes from. One formula covers both layouts: at
    /// a stride of 1 the arithmetic below degenerates to a plain ±1 step, which is exactly what one
    /// row means in a list whose columns are vertical runs.
    ///
    /// Deliberately **not** `step(_:)` with a larger delta, and that is the whole reason this
    /// exists. `step` walks the *match* list, so under a filter a delta of `columns` moves that many
    /// matches along rather than one row down — several rows at once on a sparsely-matching list.
    /// Filtering does not remove tiles: non-matches are dimmed and stay exactly where they were, so
    /// a row move has to be measured in screen positions first and only then landed on a tile the
    /// filter allows.
    ///
    /// The column survives the wrap, which a plain modulo over the flat index does not manage: the
    /// last row is usually short, so wrapping the index shifts the column by however many tiles that
    /// row is missing. A target cell past the end of a short row takes the last tile in it — the way
    /// an icon grid does — rather than being skipped, so no key press is ever a silent no-op.
    func stepRow(_ delta: Int, stride: Int) {
        guard !targets.isEmpty, delta != 0 else { return }
        let count = targets.count
        let columns = max(stride, 1)
        let rows = Int((Double(count) / Double(columns)).rounded(.up))
        // Clamped rather than trusted: `selection` is assigned from several places and only
        // `selected` guards it, so a stale one out of range would make the division below nonsense.
        let current = min(max(selection, 0), count - 1)
        let wrapped = ((current / columns + delta) % rows + rows) % rows
        let target = min(wrapped * columns + current % columns, count - 1)
        selection = nearestSelectable(from: target, direction: delta < 0 ? -1 : 1)
    }

    /// `index` when the current filter allows it, else the next tile along `direction` that does.
    ///
    /// The identity whenever nothing is filtered — an empty `matchingIndices` means "no filter", so
    /// every index is selectable and the common path pays one `isEmpty` check. Bounded by the list
    /// length so it terminates on any input, though it cannot actually run out: it is only reached
    /// with a non-empty match set.
    private func nearestSelectable(from index: Int, direction: Int) -> Int {
        guard !matchingIndices.isEmpty else { return index }
        let count = targets.count
        var candidate = index
        for _ in 0..<count {
            if matchingIndices.contains(candidate) { return candidate }
            candidate = ((candidate + direction) % count + count) % count
        }
        return index
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

    /// Returns indices of targets matching the query.
    ///
    /// Fuzzy match against the tile's title and app name — see `FuzzyMatch`. A query with several
    /// space-separated words requires every word to match, so "saf 2" still finds Safari's second
    /// window, and each word matches as a subsequence rather than a substring, so "vsc" finds Visual
    /// Studio Code.
    ///
    /// Indices rather than a filtered list, because the panel dims non-matches instead of removing
    /// them: every existing index — hit-testing, ⌘-number, the caption — has to keep its meaning.
    /// An empty set is how "no filter" is spelled, which is why an empty or whitespace-only query
    /// answers with one rather than with everything.
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
    ///
    /// **Something running always outranks something launchable, whatever they score.** The launch
    /// tiles are shown alongside the real ones now rather than only when nothing matched, and that
    /// widening is only safe because of this rule: a query that reaches anything already open must
    /// still land on it, or the switcher would have started launching second copies of things in
    /// answer to the gesture that has always meant "go to the one I have". The suggestion is still
    /// *there* — one arrow key away, and selected the moment nothing running answers the query —
    /// which is the whole difference between offering a launcher and displacing the switcher.
    static func bestMatch(_ list: [SwitchTarget], query: String) -> Int? {
        var best: (index: Int, score: Int, running: Bool)?
        for index in list.indices {
            guard let score = score(list[index], query: query) else { continue }
            let running = !list[index].isLaunchable
            guard let current = best else {
                best = (index, score, running)
                continue
            }
            // Running beats launchable outright; within a group, the higher score wins and ties
            // break towards the earlier index.
            if running != current.running {
                if running { best = (index, score, running) }
            } else if score > current.score {
                best = (index, score, running)
            }
        }
        return best?.index
    }

    /// A target's score for a query: every word must match, and the total is their sum.
    ///
    /// Both fields are scored and the better taken, rather than concatenating them: a query matching
    /// the *title* strongly should not be diluted by the app name trailing after it.
    ///
    /// A query with no words in it — the space bar, which type-to-filter accepts as an ordinary
    /// character — is **no match**, not a free one. It used to score 0, which every target tied on,
    /// so `bestMatch` handed back index 0 and a tap of the space bar threw the highlight back to the
    /// frontmost app in the middle of cycling. `matchingIndices` had always guarded this by
    /// trimming first; `bestMatch` did not, and the two disagreeing is what made the bug invisible —
    /// nothing was marked as matching while the selection had already moved.
    private static func score(_ target: SwitchTarget, query: String) -> Int? {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return nil }
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
