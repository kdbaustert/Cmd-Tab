import XCTest

@testable import CmdTab

/// Type-to-filter's ranking, which decides what the Return key lands on.
///
/// `FuzzyMatch` describes itself as the one part of the switcher testable exhaustively without a
/// window server, an event tap or Accessibility, and it was the only such part with no tests at all.
/// It is also the part whose failures are least likely to be reported: a mis-ranked query does not
/// crash or log, it switches to the wrong app, and the user assumes they typed too few letters.
///
/// The assertions below are mostly *comparisons* rather than exact scores. The constants in `Score`
/// are tuning, and a test that pinned them would fail on every retune while proving nothing; what
/// must hold across a retune is the ordering — that a prefix beats a substring, that a word start
/// beats a scattered hit, that the shorter of two equally-good candidates wins. Where an exact
/// number is asserted it is because the number is the contract: the empty query scores 0.
final class FuzzyMatchTests: XCTestCase {

    /// Unwraps a score that must exist, so a nil turns into one clear failure rather than a
    /// cascade of optional comparisons that silently pass.
    private func score(
        _ candidate: String, _ query: String, file: StaticString = #filePath, line: UInt = #line
    ) throws -> Int {
        try XCTUnwrap(
            FuzzyMatch.score(candidate, query: query),
            "expected \"\(query)\" to match \"\(candidate)\"", file: file, line: line)
    }

    // MARK: - The empty and impossible cases

    /// "No filter" is not "no matches". The switcher shows the whole list until something is typed,
    /// and it does that by every target scoring rather than by a special case at the call site — so
    /// a nil here would empty the panel the moment the query was cleared.
    func testAnEmptyQueryMatchesEverythingAtZero() {
        XCTAssertEqual(FuzzyMatch.score("Safari", query: ""), 0)
        XCTAssertEqual(FuzzyMatch.score("", query: ""), 0)
    }

    /// Zero, specifically, and not merely "some score": `SwitcherModel.bestMatch` compares these
    /// across targets, so an empty query has to leave every candidate tied rather than ranked.
    func testAnEmptyQueryLeavesEveryCandidateTied() {
        XCTAssertEqual(FuzzyMatch.score("Safari", query: ""), FuzzyMatch.score("MailMate", query: ""))
    }

    func testAnEmptyCandidateNeverMatchesARealQuery() {
        XCTAssertNil(FuzzyMatch.score("", query: "x"))
    }

    /// A query whose characters are not all present, in order, is not a match at any score.
    func testACandidateMissingACharacterDoesNotMatch() {
        XCTAssertNil(FuzzyMatch.score("Safari", query: "zzz"))
        // Present, but out of order — subsequence matching is ordered, and "ifs" is not a
        // reordering Safari should answer to.
        XCTAssertNil(FuzzyMatch.score("Safari", query: "ifs"))
    }

    /// `matches` exists so a caller can ask without the arithmetic; the two disagreeing would mean a
    /// target shown as matching but never selectable, or the reverse.
    func testMatchesAgreesWithScore() {
        for query in ["", "saf", "sfi", "zzz", "SAFARI"] {
            XCTAssertEqual(
                FuzzyMatch.matches("Safari", query: query),
                FuzzyMatch.score("Safari", query: query) != nil,
                "disagreement on \"\(query)\"")
        }
    }

    // MARK: - Case

    /// Nobody holds shift to filter. Asserted in both directions because the fix for camelCase word
    /// starts stopped lowercasing the candidate before the walk, which is exactly where a
    /// case-sensitivity regression would enter.
    func testMatchingIsCaseInsensitiveInBothDirections() throws {
        let plain = try score("Safari", "saf")
        XCTAssertEqual(try score("Safari", "SAF"), plain)
        XCTAssertEqual(try score("SAFARI", "saf"), plain)
        XCTAssertEqual(try score("sAfArI", "SaF"), plain)
    }

    /// The subsequence walk, not the prefix shortcut — a different code path, and the one that now
    /// reads the candidate in its original case.
    ///
    /// What must not vary is the *query's* case. The candidate's case now genuinely does change the
    /// score, which is the point of the camelCase rule below and not a case-sensitivity bug: a name
    /// written all in lowercase has no word starts to find.
    func testTheSubsequenceWalkIgnoresTheCaseOfTheQuery() throws {
        let mixed = try score("VisualStudioCode", "vsc")
        XCTAssertEqual(try score("VisualStudioCode", "VSC"), mixed)
        XCTAssertEqual(try score("VisualStudioCode", "vSc"), mixed)

        let flat = try score("visualstudiocode", "vsc")
        XCTAssertEqual(try score("visualstudiocode", "VSC"), flat)
    }

    // MARK: - Shape beats length

    /// The ordering the `Score` constants exist to produce. Typing "code" should reach Code as a
    /// prefix before it reaches "Visual Studio Code" as a substring, and both before anything that
    /// merely contains c, o, d and e in order.
    func testAPrefixOutranksASubstringOutranksAScatteredMatch() throws {
        let prefix = try score("Code", "code")
        let substring = try score("Visual Studio Code", "code")
        let scattered = try score("Cyberduck Open Directory Explorer", "code")
        XCTAssertGreaterThan(prefix, substring)
        XCTAssertGreaterThan(substring, scattered)
    }

    /// The bug this file's subject was written for: selection used to land on the first matching
    /// tile in list order, so "chr" with Character Viewer ahead of Chrome highlighted the wrong one.
    /// Chrome wins on shape — "chr" is inside "Chrome" intact — regardless of list position.
    func testChromeOutranksCharacterViewerForChr() throws {
        XCTAssertGreaterThan(try score("Google Chrome", "chr"), try score("Character Viewer", "chr"))
    }

    /// Two candidates matching in the same shape are separated by length, so the more specific name
    /// does not bury the plain one.
    func testTheShorterCandidateWinsAPrefixTie() throws {
        XCTAssertGreaterThan(try score("Mail", "mail"), try score("MailMate", "mail"))
    }

    /// `leadingGap` in the substring shape: the same word found earlier is the better match.
    func testAnEarlierSubstringOutranksALaterOne() throws {
        XCTAssertGreaterThan(try score("Code Runner", "code"), try score("Visual Studio Code", "code"))
    }

    // MARK: - Word starts

    /// Initials are what people actually type, and the reward for hitting word starts is what makes
    /// them work — "vsc" has to beat a candidate that merely contains v, s and c scattered through it.
    func testInitialsOutrankAScatteredMatchOfTheSameLetters() throws {
        XCTAssertGreaterThan(
            try score("Visual Studio Code", "vsc"), try score("Vivisector", "vsc"))
    }

    /// The fix this file was added alongside. `score` lowercased the candidate before the walk, so
    /// an internal capital carried no weight at all and the run-together form of a name matched
    /// about half as well as the spaced one — measured at 85 against 168 for "og" on OmniGraffle.
    /// Mac app names run words together far more often than they space them, so that was the common
    /// case losing to the rare one.
    ///
    /// Asserted as near-parity rather than equality: the two differ by the length tiebreak, which is
    /// correct — the shorter name is the better match, by exactly the margin its missing spaces are
    /// worth.
    func testACamelCaseSeamCountsAsAWordStart() throws {
        for (joined, spaced, query) in [
            ("OmniGraffle", "Omni Graffle", "og"),
            ("VisualStudioCode", "Visual Studio Code", "vsc"),
            ("TextEdit", "Text Edit", "te"),
        ] {
            let run = try score(joined, query)
            let apart = try score(spaced, query)
            XCTAssertEqual(
                run, apart + (spaced.count - joined.count),
                "\"\(query)\" should score \(joined) and \(spaced) alike but for length")
        }
    }

    /// The seam has to be worth more than a bare scattered hit, or the change above is decoration.
    func testACamelCaseSeamOutranksTheSameLettersMidWord() throws {
        // The G of Graffle is a seam; the g of "orange" is in the middle of a word.
        XCTAssertGreaterThan(try score("OmniGraffle", "og"), try score("Orange", "og"))
    }

    /// Every separator the switcher meets in a real name, so removing one from the list is a test
    /// failure rather than a quiet ranking change.
    ///
    /// The letters are spread out on purpose. A candidate as tidy as "Aabb" contains "ab" outright
    /// and is scored by the substring shape, which never consults `isWordStart` at all — so the
    /// obvious fixture tests nothing and passes whatever this rule says.
    func testEachSeparatorCountsAsAWordStart() throws {
        let midWord = try score("Axxbxx", "ab")
        for separator in [" ", "-", "_", ".", "/"] {
            XCTAssertGreaterThan(
                try score("Axx\(separator)bxx", "ab"), midWord,
                "\"\(separator)\" should start a word")
        }
    }

    /// A run of capitals is deliberately *not* split — "HTTPServer" is one word to this matcher.
    /// Asserted so the omission stays a decision rather than becoming an accident: someone adding
    /// the acronym rule later should see this fail and delete it on purpose.
    func testARunOfCapitalsIsNotSplit() throws {
        XCTAssertEqual(try score("HTTPServer", "hs"), try score("httpserver", "hs"))
    }

    // MARK: - Runs

    /// Consecutive matched characters beat the same characters spread out, which is what keeps a
    /// half-typed word ranked above a coincidence.
    func testAConsecutiveRunOutranksAScatteredMatch() throws {
        XCTAssertGreaterThan(try score("Xanadu", "ana"), try score("Xaonadu", "ana"))
    }

    /// The greedy walk takes each character at its earliest position rather than its best one, which
    /// is a deliberate trade — finding the optimal alignment is dynamic programming, and this runs
    /// against every tile on every keystroke inside a session that owns the keyboard.
    ///
    /// Pinned because it is a known limit rather than a hidden one, and stated as the property that
    /// causes it: an earlier mid-word occurrence *costs* a match, because the walk spends the needle
    /// character on it and never reaches the word start further along. Adding a letter to the
    /// candidate makes it match worse.
    ///
    /// If this ever starts failing, greedy has been replaced by something that looks ahead, and the
    /// paragraph in `subsequenceScore` explaining why it does not should go with it.
    func testAnEarlierMidWordHitCostsTheWordStartFurtherAlong() throws {
        XCTAssertLessThan(try score("Axxb Bxx", "ab"), try score("Axxx Bxx", "ab"))
    }

    /// The consequence for a name people really do type initials at: "btt" spends both t's inside
    /// "Better" and never reaches Touch or Tool, so the run-together name scores as a near-scattered
    /// match rather than as three word starts.
    func testGreedyMatchingUnderratesInitialsAcrossRepeatedLetters() throws {
        XCTAssertLessThan(try score("BetterTouchTool", "btt"), try score("Bxx Txx Txx", "btt"))
    }
}
