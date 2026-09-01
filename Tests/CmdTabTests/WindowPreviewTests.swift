import CoreGraphics
import XCTest

@testable import CmdTab

/// The two rules that decide whether a window appears in the hover preview strip.
///
/// Both exist because of the same measured fact: the window server keeps a layer-0 surface — last
/// title, full-size frame, still capturable — long after a tab or window has closed, and nothing it
/// exposes separates one from a live window. Measured on Ghostty, seven such surfaces for two open
/// tabs, four of them the same dead tab, every one capturing 100% opaque pixels so the blank check
/// never rejected them.
///
/// Neither rule is reachable through `WindowCapture.thumbnails`, which needs a window server and
/// Screen Recording, so both are pure functions and this is where they are checked.
final class WindowPreviewTests: XCTestCase {
    private func answer(
        ids: Set<CGWindowID>, minimized: [(id: CGWindowID, title: String)] = [], resolved: Bool
    ) -> WindowCapture.AXWindows {
        WindowCapture.AXWindows(ids: ids, minimized: minimized, resolvedEveryWindow: resolved)
    }

    private let now = Date()

    // MARK: - Normalizing a title

    /// The menu and the window server are read a moment apart, and for a terminal that is long
    /// enough for the title to change: the same window read as `◐ Features and improvements` from
    /// one and `◑ Features and improvements` from the other, one spinner frame later.
    func testSpinnerFramesOfOneTitleNormalizeTheSame() {
        XCTAssertEqual(
            WindowCapture.normalizedTitle("◐ Features and improvements"),
            WindowCapture.normalizedTitle("◑ Features and improvements"))
    }

    /// The other prefix apps put there: an SF Symbol from the private use area, and the dot an
    /// editor shows for unsaved changes.
    func testLeadingDecorationIsDropped() {
        XCTAssertEqual(WindowCapture.normalizedTitle("\u{100000} ~/Development/cnc-claims"),
                       "development/cnc-claims")
        XCTAssertEqual(WindowCapture.normalizedTitle("● Untitled"), "untitled")
        XCTAssertEqual(WindowCapture.normalizedTitle("  Notes  "), "notes")
    }

    func testNormalizingIsCaseInsensitive() {
        XCTAssertEqual(
            WindowCapture.normalizedTitle("Safari"), WindowCapture.normalizedTitle("SAFARI"))
    }

    /// A title with nothing but decoration in it normalizes to nothing, and must never match — or
    /// every such window would claim every other.
    func testATitleOfPureDecorationNormalizesToNothing() {
        XCTAssertTrue(WindowCapture.normalizedTitle("●●●").isEmpty)
        let claim = WindowCapture.WindowClaim(ids: [], titles: [""], canVeto: true)
        XCTAssertFalse(claim.claims(id: 1, title: "◐◐"))
    }

    // MARK: - Which channel the veto acts on

    private func claim(
        fresh: WindowCapture.AXWindows, menu: Set<String> = [],
        remembered: (WindowCapture.AXWindows, Date)? = nil, lifetime: TimeInterval = 120
    ) -> WindowCapture.WindowClaim {
        WindowCapture.claim(
            fresh: fresh, menuTitles: menu, remembered: remembered.map { ($0.0, $0.1) }, now: now,
            lifetime: lifetime)
    }

    /// Accessibility's window list is exact where it works, and it is the only channel that yields
    /// ids at all.
    func testAUsableWindowListIsUsed() {
        let out = claim(fresh: answer(ids: [1, 2], resolved: true))
        XCTAssertTrue(out.canVeto)
        XCTAssertTrue(out.claims(id: 1, title: "anything"))
        XCTAssertFalse(out.claims(id: 9, title: "anything"))
    }

    /// **Unioned, never ranked.** Each current channel under-reports in a way the other does not:
    /// Accessibility publishes one tab of a tabbed window, the menu names them all. Ghostty is the
    /// case that needs it — the window list named one tab and the menu named both.
    func testTheWindowListAndTheMenuAreUnioned() {
        let out = claim(fresh: answer(ids: [1], resolved: true), menu: ["second tab"])
        XCTAssertTrue(out.claims(id: 1, title: "first tab"), "named by the window list")
        XCTAssertTrue(out.claims(id: 2, title: "Second Tab"), "named by the menu")
        XCTAssertFalse(out.claims(id: 3, title: "a tab that closed"))
    }

    /// The case the menu exists for: the app's window list says nothing, and its menu still names
    /// every window it has.
    func testTheMenuAnswersWhenTheWindowListDoesNot() {
        let out = claim(fresh: answer(ids: [], resolved: false), menu: ["features and improvements"])
        XCTAssertTrue(out.canVeto)
        XCTAssertTrue(out.claims(id: 99, title: "◑ Features and improvements"))
    }

    /// Last resort, and only when neither current channel says anything — a remembered answer is
    /// stale by definition, and the menu is not.
    func testTheRememberedAnswerIsUsedOnlyWhenNothingCurrentAnswers() {
        let remembered = answer(ids: [7], resolved: true)
        let withMenu = claim(
            fresh: answer(ids: [], resolved: false), menu: ["live window"],
            remembered: (remembered, now))
        XCTAssertFalse(
            withMenu.claims(id: 7, title: "x"), "a current answer supersedes a remembered one")

        let without = claim(
            fresh: answer(ids: [], resolved: false), remembered: (remembered, now))
        XCTAssertTrue(without.canVeto)
        XCTAssertTrue(without.claims(id: 7, title: "x"))
    }

    /// Bounded, because a remembered list is dangerous as it ages: a window opened since the
    /// snapshot is not in it.
    func testAnExpiredRememberedAnswerIsNotUsed() {
        let out = claim(
            fresh: answer(ids: [], resolved: false),
            remembered: (answer(ids: [7], resolved: true), now.addingTimeInterval(-121)))
        XCTAssertFalse(out.canVeto)
    }

    /// An app that says nothing through any channel keeps every tile it has. This is Spotify, whose
    /// window list is empty and whose menu names no windows at all.
    func testAnAppThatSaysNothingVetoesNothing() {
        let out = claim(fresh: answer(ids: [], resolved: false))
        XCTAssertFalse(out.canVeto)
        XCTAssertTrue(out.vetoing(candidates: [(id: 1, title: "x", unverified: true)]).isEmpty)
    }

    // MARK: - What the claim removes

    /// The measured Ghostty state: seven surfaces at one frame, two of them live tabs the menu
    /// names, four the same closed tab, one a window that has gone. Only the five unnamed go.
    func testTheMeasuredGhosttyStateLeavesExactlyTheLiveTabs() {
        let out = claim(
            fresh: answer(ids: [], resolved: false),
            menu: ["features and improvements", "claimcenter claim personnel view profile menu"])
        let candidates: [(id: CGWindowID, title: String, unverified: Bool)] = [
            (57130, "\u{100000} ~/Development/cnc-claims", true),
            (56624, "\u{100000} ~/Development/cnc-claims", true),
            (55567, "✳ ClaimCenter claim personnel view profile menu", true),
            (55884, "\u{100000} ~/Development/cnc-claims", true),
            (57673, "◐ Features and improvements", true),
            (60793, "\u{10001B} ghostty", true),
            (57668, "\u{100000} ~/Development/cnc-claims", true),
        ]
        XCTAssertEqual(
            out.vetoing(candidates: candidates), [57130, 56624, 55884, 60793, 57668])
    }

    /// A window on a Space or on screen is never a candidate, so nothing the user is looking at can
    /// be removed however badly the channels disagree.
    func testAVerifiableWindowIsNeverRemoved() {
        let out = claim(fresh: answer(ids: [1], resolved: true))
        XCTAssertTrue(
            out.vetoing(candidates: [
                (id: 1, title: "claimed", unverified: false),
                (id: 2, title: "unclaimed but on a Space", unverified: false),
            ]).isEmpty)
    }

    /// **Nothing is dropped unless something was kept.** An answer that accounts for none of the
    /// windows in front of us is not describing this app's windows, and emptying the strip on the
    /// strength of it is how a working preview becomes a blank one.
    func testAnAnswerThatMatchesNothingRemovesNothing() {
        let out = claim(fresh: answer(ids: [], resolved: false), menu: ["something else entirely"])
        XCTAssertTrue(out.canVeto)
        XCTAssertTrue(
            out.vetoing(candidates: [
                (id: 1, title: "a real window", unverified: true),
                (id: 2, title: "another real window", unverified: true),
            ]).isEmpty)
    }

    /// One corroborating match is enough to show the two lists are talking about the same app.
    func testOneMatchIsEnoughToAuthoriseTheRest() {
        let out = claim(fresh: answer(ids: [], resolved: false), menu: ["kept"])
        XCTAssertEqual(
            out.vetoing(candidates: [
                (id: 1, title: "Kept", unverified: true),
                (id: 2, title: "dead surface", unverified: true),
            ]), [2])
    }

    // MARK: - Collapsing identical surfaces

    private struct Surface {
        let id: Int
        let title: String
        let frame: CGRect
        let verified: Bool
    }

    private func collapse(_ surfaces: [Surface]) -> [Int] {
        WindowCapture.collapsingDuplicates(
            surfaces, unverified: { !$0.verified },
            key: { WindowCapture.SurfaceKey(title: $0.title, frame: $0.frame) }
        ).map(\.id)
    }

    private let frame = CGRect(x: 16, y: 55, width: 2024, height: 1258)

    /// The measured case: four surfaces, one title, one frame, none of them verifiable. The frontmost
    /// is kept — the list arrives front to back, so it is the likeliest to be the live one.
    func testIdenticalUnverifiedSurfacesCollapseToTheFrontmost() {
        let out = collapse([
            Surface(id: 1, title: "~/Development/cnc-claims", frame: frame, verified: false),
            Surface(id: 2, title: "~/Development/cnc-claims", frame: frame, verified: false),
            Surface(id: 3, title: "~/Development/cnc-claims", frame: frame, verified: false),
            Surface(id: 4, title: "~/Development/cnc-claims", frame: frame, verified: false),
        ])
        XCTAssertEqual(out, [1])
    }

    /// The guard that makes it safe. Two live windows may legitimately share a title and a frame —
    /// two empty terminals in one directory — and taking one off the strip would lose a window the
    /// user has open.
    func testVerifiedWindowsAreNeverCollapsed() {
        let out = collapse([
            Surface(id: 1, title: "Untitled", frame: frame, verified: true),
            Surface(id: 2, title: "Untitled", frame: frame, verified: true),
            Surface(id: 3, title: "Untitled", frame: frame, verified: true),
        ])
        XCTAssertEqual(out, [1, 2, 3])
    }

    /// A verified window is not even a *candidate*, so it neither collapses nor absorbs an
    /// unverified twin's slot — the two sets are considered separately.
    func testAVerifiedWindowDoesNotSuppressAnUnverifiedTwin() {
        let out = collapse([
            Surface(id: 1, title: "Same", frame: frame, verified: true),
            Surface(id: 2, title: "Same", frame: frame, verified: false),
            Surface(id: 3, title: "Same", frame: frame, verified: false),
        ])
        XCTAssertEqual(out, [1, 2], "the verified one stays, and one unverified copy stands for the rest")
    }

    /// The title is the discriminator, and it is the reason the live tabs survive: on Ghostty every
    /// window sits at the identical frame, so a frame-only rule would collapse the whole app to one.
    func testDistinctTitlesAtOneFrameAllSurvive() {
        let out = collapse([
            Surface(id: 1, title: "ClaimCenter", frame: frame, verified: false),
            Surface(id: 2, title: "Features and improvements", frame: frame, verified: false),
            Surface(id: 3, title: "ghostty", frame: frame, verified: false),
        ])
        XCTAssertEqual(out, [1, 2, 3])
    }

    func testOneTitleAtDifferentFramesSurvives() {
        let out = collapse([
            Surface(id: 1, title: "Notes", frame: frame, verified: false),
            Surface(id: 2, title: "Notes", frame: frame.offsetBy(dx: 40, dy: 0), verified: false),
        ])
        XCTAssertEqual(out, [1, 2])
    }

    /// Order is the strip's reading order, so collapsing must not disturb what it leaves behind.
    func testTheSurvivingOrderIsUnchanged() {
        let out = collapse([
            Surface(id: 1, title: "A", frame: frame, verified: false),
            Surface(id: 2, title: "B", frame: frame, verified: true),
            Surface(id: 3, title: "A", frame: frame, verified: false),
            Surface(id: 4, title: "C", frame: frame, verified: false),
        ])
        XCTAssertEqual(out, [1, 2, 4])
    }

    /// A surface kept from before a resolution change can sit a sub-pixel off, and two tiles a
    /// fraction of a point apart are the same tile to anyone looking at them.
    func testASubPixelDifferenceStillCounts() {
        let out = collapse([
            Surface(id: 1, title: "Same", frame: frame, verified: false),
            Surface(
                id: 2, title: "Same", frame: frame.offsetBy(dx: 0.2, dy: -0.1), verified: false),
        ])
        XCTAssertEqual(out, [1])
    }

    func testAnEmptyListIsEmpty() {
        XCTAssertEqual(collapse([]), [])
    }
}
