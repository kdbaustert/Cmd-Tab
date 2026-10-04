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

    /// Whether this session is a Desktops overview: the targets arrive sorted by Desktop and the
    /// grid draws a header per Desktop. Set per session by the controller — see the
    /// `.desktopsOverview` scoped trigger.
    @Published var groupsByDesktop = false

    /// A contiguous run of overview targets on one Desktop — what one header stands over.
    struct DesktopSection: Equatable {
        /// The 0-based Desktop, or nil for the trailing group that is on none: minimized windows,
        /// and anything the window server could not place.
        let spaceIndex: Int?
        /// Indices into `targets`, so tile identity — hit-testing, ⌘-digits, the frame map — is
        /// untouched by the grouping.
        let range: Range<Int>
    }

    /// Splits a Desktop-sorted list into its sections. Pure over the one ordering
    /// `SwitcherController.groupedByDesktop` produces; a list where no target carries a Desktop —
    /// a single-Desktop machine, or a failed placement read — comes back as one section, which is
    /// what suppresses the headers entirely rather than drawing one header over everything.
    static func desktopSections(_ targets: [SwitchTarget]) -> [DesktopSection] {
        var sections: [DesktopSection] = []
        var start = 0
        for index in targets.indices {
            let next = index + 1
            if next == targets.count || targets[next].spaceIndex != targets[index].spaceIndex {
                sections.append(
                    DesktopSection(spaceIndex: targets[index].spaceIndex, range: start..<next))
                start = next
            }
        }
        return sections
    }

    /// The marked set, by target id. Session-scoped — the controller clears it in `hide()`, which
    /// every dismissal path (commit, cancel, an emptied list) already funnels through, so there is
    /// one place that has to remember to do it rather than one per exit.
    @Published private(set) var markedIDs: Set<String> = []

    /// Toggles tile `index` in or out of the marked set. Out of range is a silent no-op, the same
    /// tolerance `jump(to:)` gives a stray keypress.
    ///
    /// A launch or fallback tile is refused, and here rather than at each caller. Every one of them
    /// shares the -1 pid sentinel, so a marked set carrying one hands every set-capable action a
    /// target that matches all of them: ⌥Q asked to "Quit 2 apps?" and then dropped every launch
    /// tile from the list. The keyboard route was already guarded (`SwitcherController.perform`
    /// refuses a launch selection); ⌥-click was not, and the model is the one place both reach.
    func toggleMark(at index: Int) {
        guard targets.indices.contains(index), !targets[index].isLaunchable else { return }
        let id = targets[index].id
        if markedIDs.contains(id) { markedIDs.remove(id) } else { markedIDs.insert(id) }
    }

    func clearMarks() { markedIDs.removeAll() }

    func isMarked(at index: Int) -> Bool {
        targets.indices.contains(index) && markedIDs.contains(targets[index].id)
    }

    /// The marked tiles, in list order — which is also left-to-right tiling order for `tileMarked`.
    var markedTargets: [SwitchTarget] { targets.filter { markedIDs.contains($0.id) } }

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
    /// near is a button nobody meant to aim at. And the tile has to be something the close action
    /// will act on: a not-running favourite is an offer to launch, with nothing there to close, and
    /// a tab tile is refused outright — see `SwitchTarget.canClose` for what its ✕ used to close.
    ///
    /// On the model rather than in the view so it can be tested — a click that closes the wrong
    /// window is the most expensive mistake in this file, and "which tile is this button on" is the
    /// question that would cause it.
    func showsClose(at index: Int) -> Bool {
        guard showsCloseButton, hoverIndex == index, targets.indices.contains(index) else {
            return false
        }
        return targets[index].canClose
    }

    /// Tiles carry a title only when they represent windows — the same-app cycle. App tiles show
    /// their name in the caption instead, so repeating it under every icon was pure noise.
    var showsTitle: Bool { mode == .windows }

    var selected: SwitchTarget? {
        targets.indices.contains(selection) ? targets[selection] : nil
    }

    /// Whether the current query matched anything at all. An empty or whitespace-only query counts
    /// as matching — there is no filter to fail, which is also why `matches` answers it with none.
    var matchesAnything: Bool {
        query.trimmingCharacters(in: .whitespaces).isEmpty || !matchingIndices.isEmpty
    }

    /// Whether the full list has anything in it, regardless of the current filter. Distinguishes
    /// "this app has no windows" from "the query matched nothing" — the panel stays up for the latter.
    var hasAnyTarget: Bool { !allTargets.isEmpty }


    private var allTargets: [SwitchTarget] = []
    /// Installed apps offered because the query matched nothing running. Appended after the real
    /// targets, so every existing index — hit-testing, ⌘-number, the caption — keeps its meaning.
    private var suggestions: [SwitchTarget] = []
    /// The app the current query has learned, looked up by the controller and handed in with the
    /// query — see `SearchShortcutsStore`. Kept so a background refresh (`reapply`) re-ranks under
    /// the same binding the keystroke did. nil when the query has learned nothing, or learning is
    /// off.
    private var learnedBundleID: String?

    /// What the panel actually shows.
    private var composed: [SwitchTarget] { allTargets + suggestions }

    /// The ids of the tiles the provider built — `targets` without the launch suggestions.
    ///
    /// For deduplicating a fresh set of suggestions. `targets` is the wrong list to check against:
    /// it still carries the *previous* keystroke's suggestions, whose ids are exactly the ones a
    /// suggestion for the same app builds again, so every app that stayed a match was filtered out
    /// on alternate keystrokes.
    var providerTargetIDs: Set<String> { Set(allTargets.map(\.id)) }

    /// Whether anything the provider built — not a launch suggestion, not a fallback — answers
    /// `query`. What the fallback tier is gated on.
    ///
    /// Stops at the first hit rather than scoring the whole list, because it is asked on the
    /// keystroke path and only the yes/no is wanted.
    func hasRunningMatch(for query: String) -> Bool {
        let words = Self.words(of: query)
        guard !words.isEmpty else { return false }
        return allTargets.contains { !$0.isLaunchable && Self.score($0, words: words) != nil }
    }

    func step(_ delta: Int) {
        guard !targets.isEmpty else { return }
        // A true modulo, not `(x + delta + n) % n`: Swift's `%` keeps the sign, so that idiom only
        // wraps while |delta| ≤ n. The keyboard sends ±1, but a scroll is accelerated into several
        // tiles per event (`PanelGroup.handleScroll`), and under a two-match filter a step of −3
        // indexed `sorted[-1]`.
        // When filtering, only step through matching indices
        if matchingIndices.isEmpty {
            let count = targets.count
            selection = ((selection + delta) % count + count) % count
        } else {
            let sorted = matchingIndices.sorted()
            if let current = sorted.firstIndex(of: selection) {
                let count = sorted.count
                selection = sorted[((current + delta) % count + count) % count]
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
    ///
    /// In the Desktops overview the grid is one per Desktop, each starting on a fresh row, so "the
    /// row below" is measured inside the Desktop and only the last row spills into the next one —
    /// landing at the same column, or the last tile if that row is shorter. Stepping the whole list
    /// as one grid skipped past whole Desktops, because a short last row in one section is not a
    /// short row in the flat list.
    func stepRow(_ delta: Int, stride: Int) {
        guard !targets.isEmpty, delta != 0 else { return }
        let count = targets.count
        let columns = max(stride, 1)
        let sections = groupsByDesktop ? Self.desktopSections(targets).map(\.range) : [0..<count]
        // Clamped rather than trusted: `selection` is assigned from several places and only
        // `selected` guards it, so a stale one out of range would make the arithmetic nonsense.
        var target = min(max(selection, 0), count - 1)
        for _ in 0..<abs(delta) {
            target = Self.rowStep(from: target, down: delta > 0, columns: columns, sections: sections)
        }
        selection = nearestSelectable(from: target, direction: delta < 0 ? -1 : 1)
    }

    /// One row up or down over `sections` — contiguous index ranges that each draw as their own
    /// grid of `columns` — wrapping past the last section's end back to the first. Column and
    /// short-row clamping are as `stepRow` describes.
    static func rowStep(
        from index: Int, down: Bool, columns: Int, sections: [Range<Int>]
    ) -> Int {
        guard let at = sections.firstIndex(where: { $0.contains(index) }) else { return index }
        let section = sections[at]
        let local = index - section.lowerBound
        let column = local % columns
        let row = local / columns
        let rows = Int((Double(section.count) / Double(columns)).rounded(.up))
        var destination = section
        var destinationRow = row + (down ? 1 : -1)
        if destinationRow < 0 || destinationRow >= rows {
            let next = (at + (down ? 1 : -1) + sections.count) % sections.count
            destination = sections[next]
            let destinationRows = Int((Double(destination.count) / Double(columns)).rounded(.up))
            destinationRow = down ? 0 : destinationRows - 1
        }
        let offset = min(destinationRow * columns + column, destination.count - 1)
        return destination.lowerBound + offset
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
        markedIDs = []
        learnedBundleID = nil
    }

    /// Keeps the highlight on the same target across a background refresh, so the tile the user
    /// is looking at does not slide out from under them. Honours the active query.
    func update(targets new: [SwitchTarget]) {
        allTargets = new
        reapply(anchor: selected?.id)
    }

    /// Sets the filter query and highlights the best match. All tiles remain visible; selection
    /// cycles only through matches.
    ///
    /// `suggestions` replaces the launch and fallback tiles in the same pass; nil keeps the ones
    /// there are. Taking them here rather than through a setter of their own is what keeps a
    /// keystroke to one scoring pass: the setter re-scored the list to settle the highlight, and
    /// the query had to be applied again afterwards so the new tiles were matched — the list fuzzy-
    /// matched up to four times per key, on the path the tap callback waits on. It also means a
    /// fallback tile, whose id names its slot rather than its query, is always replaced by the
    /// keystroke's own: "Search for wikip" can no longer outlive the `wikipedia` typed after it.
    ///
    /// With no match the highlight stays on the tile it was on, found again by id since the
    /// suggestions may have moved under it, and clamps only when that tile is gone.
    ///
    /// `learned` is the app the query's stored binding names, or nil for a query that has learned
    /// nothing — see `bestMatch` for what it changes.
    func setQuery(
        _ new: String, suggestions newSuggestions: [SwitchTarget]? = nil, learned: String? = nil
    ) {
        let anchor = selected?.id
        query = new
        learnedBundleID = learned
        if let newSuggestions { suggestions = newSuggestions }
        // Keep all targets visible, track which indices match
        targets = composed
        let matches = Self.matches(targets, query: query, learned: learnedBundleID)
        matchingIndices = Self.matchingIndices(matches)
        // The *best* match, not the first one in list order — see `bestMatch`.
        if let best = Self.bestMatch(matches) {
            selection = best
        } else if let anchor, let index = targets.firstIndex(where: { $0.id == anchor }) {
            selection = index
        } else {
            selection = targets.isEmpty ? 0 : min(selection, targets.count - 1)
        }
    }

    /// Swaps in suggestion tiles that differ from the current ones only in artwork — a launch icon
    /// that has just been resolved — without touching the query, the ranking or the highlight, all
    /// of which `setQuery` would recompute (and would snap the highlight back to the best match).
    /// A set with different ids or order is not that, and is ignored.
    func refreshSuggestionIcons(_ fresh: [SwitchTarget]) {
        guard fresh.map(\.id) == suggestions.map(\.id) else { return }
        suggestions = fresh
        targets = composed
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
        let matches = Self.matches(targets, query: query, learned: learnedBundleID)
        matchingIndices = Self.matchingIndices(matches)
        if let anchor, let index = targets.firstIndex(where: { $0.id == anchor }),
           (matchingIndices.isEmpty || matchingIndices.contains(index)) {
            selection = index
        } else if let best = Self.bestMatch(matches) {
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
        matchingIndices(matches(list, query: query))
    }

    private static func matchingIndices(_ matches: [Match]) -> Set<Int> {
        Set(matches.map(\.index))
    }

    /// A target that answers the query, and what it scored.
    ///
    /// One pass feeds both `matchingIndices` and `bestMatch`. Each used to score the whole list for
    /// itself, and a keystroke asks for both — so type-to-filter fuzzy-matched every target twice
    /// per key, on the path the tap callback is waiting on.
    private struct Match {
        let index: Int
        let score: Int
        let running: Bool
        /// Whether the target belongs to the app the query has learned — see `bestMatch`.
        let learned: Bool
    }

    private static func matches(
        _ list: [SwitchTarget], query: String, learned: String? = nil
    ) -> [Match] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }
        // Folded and split once for the whole list rather than once per tile.
        let words = words(of: query)
        return list.indices.compactMap { index in
            // A fallback tile is built *from* the query, so scoring its title against it fuzzily
            // would be a coincidence rather than a signal — and the whole point of the tier is that
            // it always matches, being the last resort rather than a competing answer. Ties within
            // the group break towards the earlier index, which is what keeps the highlight on the
            // first fallback (URL, then search, then shell) whenever more than one is offered.
            if list[index].isFallback {
                return Match(index: index, score: 0, running: false, learned: false)
            }
            return score(list[index], words: words).map {
                Match(
                    index: index, score: $0, running: !list[index].isLaunchable,
                    learned: learned != nil && list[index].bundleID == learned)
            }
        }
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
    ///
    /// **A learned app wins its group, whatever it scores.** `learned` is the app the query's
    /// stored binding names (see `SearchShortcutsStore`): a query committed to Mail every day
    /// should land on Mail however the letters score against MailMate. Only *within* the group —
    /// the running-beats-launchable rule stands above it, so a remembered app that is not running
    /// is still only a launch tile, taken when nothing running answers. Within the learned app,
    /// the higher score still wins, which in window mode is what picks its best-matching window.
    static func bestMatch(_ list: [SwitchTarget], query: String, learned: String? = nil) -> Int? {
        bestMatch(matches(list, query: query, learned: learned))
    }

    private static func bestMatch(_ matches: [Match]) -> Int? {
        var best: Match?
        for match in matches {
            guard let current = best else {
                best = match
                continue
            }
            // Running beats launchable outright; within a group, learned beats unlearned, then the
            // higher score wins and ties break towards the earlier index.
            if match.running != current.running {
                if match.running { best = match }
            } else if match.learned != current.learned {
                if match.learned { best = match }
            } else if match.score > current.score {
                best = match
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
    private static func score(_ target: SwitchTarget, words: [String]) -> Int? {
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

    /// The query as `score` takes it: lowercased, split on spaces.
    private static func words(of query: String) -> [String] {
        query.lowercased().split(separator: " ").map(String.init)
    }
}
