/// A bounded most-recently-used list.
///
/// `TargetProvider` keeps two of these — one of pids for cross-app order, one of window ids for
/// per-app order — and both were the same four lines written twice inside methods that also did
/// Accessibility IPC, workspace notification handling and generation bookkeeping. That made the
/// ordering rule, which is the part users actually see, the one part with nothing asserting it.
///
/// The rule has two halves that are easy to get subtly wrong:
///
/// - **Re-touching moves rather than duplicates.** Insert-without-remove leaves the same id at two
///   ranks; the older one then wins every `min`-uniqued lookup built from this list, so an app
///   would sort by the position it held several switches ago.
/// - **The cap drops the oldest, not the newest.** Trimming the head would evict the app the user
///   is looking at right now.
///
/// The cap exists because both lists otherwise grow by one entry for every app or window ever
/// focused and never shrink — a rank table rebuilt on every refresh, and a session that has been up
/// for a week has thousands of dead entries in it.
struct RecencyList<Element: Hashable> {
    private(set) var entries: [Element] = []
    let limit: Int

    init(limit: Int) {
        self.limit = limit
    }

    /// Moves `element` to the front, dropping the oldest entries if that puts the list over its cap.
    mutating func touch(_ element: Element) {
        entries.removeAll { $0 == element }
        entries.insert(element, at: 0)
        if entries.count > limit { entries.removeLast(entries.count - limit) }
    }

    mutating func remove(_ element: Element) {
        entries.removeAll { $0 == element }
    }

    /// Rank by recency, 0 being most recent.
    ///
    /// `uniquingKeysWith: min` rather than the strict initializer: a duplicate should be impossible
    /// given `touch` above, but the strict one traps on it, and trapping inside the switcher would
    /// take the whole app down mid-⌘-Tab. `min` also picks the answer a caller would want if one
    /// ever did appear — the more recent of the two positions.
    func ranks() -> [Element: Int] {
        Dictionary(entries.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
    }
}
