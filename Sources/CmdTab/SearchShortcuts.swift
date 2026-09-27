import Foundation

// Learned search shortcuts: the first time a typed query is committed to a particular app, that
// query→app binding is remembered, and the same query then ranks that app first.
//
// The fuzzy matcher re-derives its ranking from scratch on every keystroke, which is right for a
// query it has never seen and wasteful for one typed every day: "ma" scores Mail and MailMate on
// their letters alone, however many hundred times the user has answered that question the same way.
// The binding records the answer. It sits *on top* of the scoring — a learned tile wins its group —
// rather than replacing it, so an unlearned query behaves exactly as before, and the one invariant
// the ranking is built on is untouched: something running always outranks something launchable,
// learned or not. A remembered app that is not running is still only a launch tile, selected only
// when nothing running answers.
//
// Keyed by bundle identifier, like the favourites and exclusions, so a binding survives the app
// quitting and relaunching under a new pid. Deliberately *not* keyed to one window: a window's
// title changes under it (a browser per page, a terminal per directory), so a per-window binding
// would go stale within the hour, and the per-app one still lands the highlight on the app's
// best-scoring window in window mode.

/// The bindings themselves — pure, so the MRU insertion, the lookup and the cap can be tested
/// without `UserDefaults`.
struct SearchBindings: Equatable {
    struct Entry: Equatable {
        let query: String
        let bundleID: String
    }

    /// Most recently learned or confirmed first — the order eviction reads from the back of.
    private(set) var entries: [Entry] = []

    /// Bounded like `RecencyList`, and for the same reason: an unbounded store of every query ever
    /// committed grows for the life of the install, and the bindings past the first few dozen are
    /// ones nobody has typed in months. Re-learning an evicted one costs a single commit.
    static let capacity = 64

    /// The form queries are stored and compared in: lowercased, accents dropped, outer whitespace
    /// trimmed — the same folding `FuzzyMatch` applies, so the query that matched is the query that
    /// learns.
    static func normalized(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespaces)
            .lowercased()
            .folding(options: .diacriticInsensitive, locale: nil)
    }

    /// Records `query` → `bundleID`, replacing what the query previously learned and refreshing its
    /// place in the eviction order. An empty query records nothing — there is nothing to bind.
    mutating func learn(query: String, bundleID: String) {
        let key = Self.normalized(query)
        guard !key.isEmpty else { return }
        entries.removeAll { $0.query == key }
        entries.insert(Entry(query: key, bundleID: bundleID), at: 0)
        if entries.count > Self.capacity { entries.removeLast(entries.count - Self.capacity) }
    }

    /// The app `query` has learned, or nil for a query never committed. Exact on the normalized
    /// query rather than fuzzy — the binding is "this exact habit", and a prefix of it is a
    /// different question the scoring already answers.
    func bundleID(for query: String) -> String? {
        let key = Self.normalized(query)
        guard !key.isEmpty else { return nil }
        return entries.first { $0.query == key }?.bundleID
    }
}

/// Persists the learned bindings, keyed like every other bundle-identifier store.
@MainActor
final class SearchShortcutsStore: ObservableObject {
    static let shared = SearchShortcutsStore()

    private static let defaultsKey = "searchShortcuts"

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [defaultsKey]

    @Published private(set) var bindings = SearchBindings()

    private init() { load() }

    func bundleID(for query: String) -> String? { bindings.bundleID(for: query) }

    func learn(query: String, bundleID: String) {
        let before = bindings
        bindings.learn(query: query, bundleID: bundleID)
        guard bindings != before else { return }
        persist()
    }

    /// Forgets every binding — the whole of the undo this feature needs. A single wrong binding is
    /// corrected the cheaper way, by committing the query to the right app once.
    func removeAll() {
        guard !bindings.entries.isEmpty else { return }
        bindings = SearchBindings()
        persist()
    }

    /// Re-reads the set after an import or reset.
    func reload() { load() }

    /// Stored as an ordered array of `[query, bundleID]` pairs, most recent first — the same
    /// row-of-strings shape `scopedTriggers` uses, read defensively for the same reason: a
    /// hand-edited config can put anything here, and one bad row must cost that row alone.
    private func load() {
        var loaded = SearchBindings()
        if let raw = UserDefaults.standard.array(forKey: Self.defaultsKey) as? [[Any]] {
            // Learned oldest-first so the insertion order rebuilds the stored order.
            for row in raw.reversed() {
                guard row.count == 2, let query = row[0] as? String,
                    let bundleID = row[1] as? String
                else { continue }
                loaded.learn(query: query, bundleID: bundleID)
            }
        }
        bindings = loaded
    }

    private func persist() {
        UserDefaults.standard.set(
            bindings.entries.map { [$0.query, $0.bundleID] }, forKey: Self.defaultsKey)
    }
}
