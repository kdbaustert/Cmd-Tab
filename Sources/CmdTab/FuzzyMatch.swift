import Foundation

/// Subsequence matching with a score, for the switcher's type-to-filter.
///
/// The old rule was "every space-separated word must appear as a substring". That finds *Safari*
/// from "saf" but never from "sfi", and — more to the point — it has no notion of a better match, so
/// the selection landed on whichever matching tile came first in the list. Typing "chr" with Chrome
/// second and "Character Viewer" first selected the wrong one.
///
/// Pure and self-contained on purpose: this is the one part of the switcher that can be tested
/// exhaustively without a window server, an event tap or Accessibility.
enum FuzzyMatch {
    /// Scores from strongest to weakest, so the shape of a match dominates its length.
    private enum Score {
        /// The whole query is a prefix of the candidate — "saf" for Safari.
        static let prefix = 1_000
        /// The query appears intact somewhere inside it — "code" in Visual Studio Code.
        static let substring = 600
        /// A matched character starting a word: the C and the V of "Visual Studio **C**ode".
        static let wordStart = 90
        /// A matched character immediately after the previous match, rewarding runs.
        static let consecutive = 45
        /// Any other matched character.
        static let scattered = 6
        /// Charged per character skipped before the first match, so early matches win.
        static let leadingGap = 3
    }

    /// How well `candidate` matches `query`, or nil if it does not match at all.
    ///
    /// Case-insensitive. An empty query matches everything with score 0 — "no filter" is not the
    /// same as "no matches", and the switcher shows the whole list until something is typed.
    static func score(_ candidate: String, query: String) -> Int? {
        let needle = query.lowercased()
        guard !needle.isEmpty else { return 0 }
        let haystack = candidate.lowercased()
        guard !haystack.isEmpty else { return nil }

        if haystack.hasPrefix(needle) {
            // Shorter candidates win a prefix tie: typing "mail" should land on Mail, not MailMate.
            return Score.prefix - min(haystack.count, 200)
        }
        if let range = haystack.range(of: needle) {
            let offset = haystack.distance(from: haystack.startIndex, to: range.lowerBound)
            return Score.substring - offset * Score.leadingGap - min(haystack.count, 200)
        }
        return subsequenceScore(haystack, needle)
    }

    /// Whether `candidate` matches at all — the same rule `score` uses, without the arithmetic.
    static func matches(_ candidate: String, query: String) -> Bool {
        score(candidate, query: query) != nil
    }

    /// Walks the candidate once, greedily taking each needle character at its earliest position.
    ///
    /// Greedy rather than optimal: finding the best-scoring alignment is a dynamic-programming
    /// problem, and this runs against every tile on every keystroke inside a session that owns the
    /// keyboard. Greedy gets the same answer for the queries people actually type (initials, or the
    /// start of a word) at a fraction of the cost.
    private static func subsequenceScore(_ haystack: String, _ needle: String) -> Int? {
        var total = 0
        var index = haystack.startIndex
        var previousMatch: String.Index?
        var isFirstMatch = true

        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }

            if isFirstMatch {
                let offset = haystack.distance(from: haystack.startIndex, to: found)
                total -= offset * Score.leadingGap
                isFirstMatch = false
            }

            if isWordStart(haystack, at: found) {
                total += Score.wordStart
            } else if let previous = previousMatch,
                haystack.index(after: previous) == found {
                total += Score.consecutive
            } else {
                total += Score.scattered
            }

            previousMatch = found
            index = haystack.index(after: found)
        }
        // Shorter candidates win ties, as with the other two shapes.
        return total - min(haystack.count, 200)
    }

    /// True at index 0, or wherever the preceding character is a separator — so "vsc" hits the three
    /// word starts of "Visual Studio Code".
    private static func isWordStart(_ string: String, at index: String.Index) -> Bool {
        guard index != string.startIndex else { return true }
        let previous = string[string.index(before: index)]
        return previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/"
    }
}
