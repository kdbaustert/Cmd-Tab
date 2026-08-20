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
        // The *original* candidate, not the lowercased one: the subsequence walk scores word starts,
        // and on a Mac an internal capital is a word start far more often than a space is. See
        // `isWordStart`. The two shapes above are pure substring tests and have no such need.
        return subsequenceScore(candidate, needle)
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
    ///
    /// `candidate` arrives in its original case — unlike the `haystack` its caller matches the other
    /// two shapes against — and `needle` already lowercased; the comparison below is what bridges
    /// them. Walking a lowercased copy instead would be simpler by one call and would throw away the
    /// capitals `isWordStart` needs, and the case cannot be recovered afterwards by index, since a
    /// single character can lowercase to several.
    ///
    /// Flattened to an array first. The walk steps back one position to find a word boundary, which
    /// on a `String` means `index(before:)` and its own scan, and it does that once per matched
    /// character on every tile on every keystroke.
    private static func subsequenceScore(_ candidate: String, _ needle: String) -> Int? {
        let characters = Array(candidate)
        var total = 0
        var index = 0
        var previousMatch: Int?
        var isFirstMatch = true

        for character in needle {
            // The equality first: `needle` is already lowercased, so most candidate characters match
            // outright and never pay for the `String` that `Character.lowercased()` returns.
            guard
                let found = characters[index...].firstIndex(where: {
                    $0 == character || $0.lowercased() == String(character)
                })
            else { return nil }

            if isFirstMatch {
                total -= found * Score.leadingGap
                isFirstMatch = false
            }

            if isWordStart(characters, at: found) {
                total += Score.wordStart
            } else if let previous = previousMatch, previous + 1 == found {
                total += Score.consecutive
            } else {
                total += Score.scattered
            }

            previousMatch = found
            index = found + 1
        }
        // Shorter candidates win ties, as with the other two shapes.
        return total - min(characters.count, 200)
    }

    /// True at index 0, wherever the preceding character is a separator, and at a camelCase seam —
    /// so "vsc" hits the three word starts of "Visual Studio Code" *and* of "VisualStudioCode".
    ///
    /// The seam matters more than the separator on this platform. Mac app names run words together
    /// far more readily than they space them — OmniGraffle, BetterTouchTool, TextEdit, iTerm — and
    /// typing initials is the case fuzzy matching exists to serve. Without this the capitals carried
    /// no weight at all: "og" scored 85 against OmniGraffle where the same name written with a space
    /// scored 168, so the run-together form, which is the common one, matched half as well.
    ///
    /// A run of capitals is deliberately not split. "HTTPServer" would need the extra rule that a
    /// capital followed by a lowercase ends an acronym, and app names that would gain by it are rare
    /// enough not to pay for a third condition here.
    private static func isWordStart(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0 else { return true }
        let previous = characters[index - 1]
        if previous == " " || previous == "-" || previous == "_" || previous == "." || previous == "/" {
            return true
        }
        return !previous.isUppercase && characters[index].isUppercase
    }
}
