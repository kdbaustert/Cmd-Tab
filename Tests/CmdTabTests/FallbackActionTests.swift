import Foundation
import XCTest

@testable import CmdTab

/// The fallback tier: URL detection, template substitution, and the ordering rule that keeps a
/// fallback from ever displacing a real match.
final class FallbackActionTests: XCTestCase {
    private let allOn = SwitcherFallbacks.Settings(
        offerURL: true, offerSearch: true, offerShell: true,
        searchTemplate: SwitcherFallbacks.defaultSearchTemplate)

    // MARK: - URL detection

    func testADottedHostWithNoSchemeIsURLLike() {
        XCTAssertEqual(SwitcherFallbacks.url(for: "example.com")?.absoluteString, "https://example.com")
    }

    func testAURLWithAnExplicitSchemeIsUsedAsIs() {
        XCTAssertEqual(SwitcherFallbacks.url(for: "https://x.y")?.absoluteString, "https://x.y")
    }

    /// Plain prose is not an address whichever way it parses.
    func testTwoWordsIsNotURLLike() {
        XCTAssertNil(SwitcherFallbacks.url(for: "hello world"))
    }

    /// `URL`'s own parser reads `host:port` as scheme `host`, which is exactly the shape this is
    /// meant to catch even though there is no dot in it anywhere.
    func testAHostAndPortWithNoDotIsStillURLLike() {
        XCTAssertEqual(SwitcherFallbacks.url(for: "localhost:3000")?.absoluteString, "localhost:3000")
    }

    func testABareWordWithNoDotAndNoSchemeIsNotURLLike() {
        XCTAssertNil(SwitcherFallbacks.url(for: "chrome"))
    }

    // MARK: - Search template

    func testTheTemplatePlaceholderIsReplacedWithThePercentEncodedQuery() {
        let url = SwitcherFallbacks.searchURL(for: "swift concurrency", template: "https://duckduckgo.com/?q=%s")
        XCTAssertEqual(url?.absoluteString, "https://duckduckgo.com/?q=swift%20concurrency")
    }

    func testATemplateWithNoPlaceholderIsRefused() {
        XCTAssertNil(SwitcherFallbacks.searchURL(for: "anything", template: "https://example.com/search"))
    }

    // MARK: - Ordering

    func testAllThreeAppearInFixedOrderWhenEnabled() {
        let actions = SwitcherFallbacks.actions(for: "example.com", settings: allOn)
        XCTAssertEqual(actions.count, 3)
        guard case .openURL = actions[0] else { return XCTFail("expected .openURL first") }
        guard case .search = actions[1] else { return XCTFail("expected .search second") }
        guard case .shellCommand = actions[2] else { return XCTFail("expected .shellCommand third") }
    }

    /// A query with no dot and no scheme never offers the URL action, whatever the setting says.
    func testTheURLActionIsAbsentWhenTheQueryDoesNotLookLikeOne() {
        let actions = SwitcherFallbacks.actions(for: "hello world", settings: allOn)
        XCTAssertTrue(actions.allSatisfy { if case .openURL = $0 { return false } else { return true } })
    }

    func testEachFallbackIsIndividuallySwitchable() {
        var settings = allOn
        settings.offerURL = false
        settings.offerShell = false
        let actions = SwitcherFallbacks.actions(for: "example.com", settings: settings)
        XCTAssertEqual(actions.count, 1)
        guard case .search = actions[0] else { return XCTFail("expected only .search") }
    }

    func testAnEmptyQueryOffersNothing() {
        XCTAssertTrue(SwitcherFallbacks.actions(for: "   ", settings: allOn).isEmpty)
    }

    // MARK: - Tier suppression

    /// A running match suppresses the fallback tier outright.
    func testARunningMatchSuppressesFallbacks() {
        let tier = SwitcherFallbacks.tier(
            runningMatches: true, installedMatches: false, query: "example.com", settings: allOn)
        XCTAssertTrue(tier.isEmpty)
    }

    /// So does an installed-app match — the two tiers above are each enough on their own.
    func testAnInstalledAppMatchSuppressesFallbacks() {
        let tier = SwitcherFallbacks.tier(
            runningMatches: false, installedMatches: true, query: "example.com", settings: allOn)
        XCTAssertTrue(tier.isEmpty)
    }

    /// Only when both tiers above are empty does the fallback tier produce anything, and it does so
    /// in the fixed order.
    func testEmptyTiersProduceFallbacksInOrder() {
        let tier = SwitcherFallbacks.tier(
            runningMatches: false, installedMatches: false, query: "example.com", settings: allOn)
        XCTAssertEqual(tier.count, 3)
        guard case .openURL = tier[0] else { return XCTFail("expected .openURL first") }
    }

    // MARK: - The `cmdtab://` boundary

    /// The one fallback that can do real damage must never be reachable by a URL, which any web
    /// page can send with no prompt — see `URLCommand`'s own header for the argument. Mirrors
    /// `URLCommandTests.testNothingDestructiveIsReachable`.
    func testShellCommandFallbackIsNotReachableFromURLCommand() {
        for path in [
            "cmdtab://run/ls", "cmdtab://shell/ls", "cmdtab://exec/ls", "cmdtab://command/ls",
            "cmdtab://fallback/shellCommand",
        ] {
            XCTAssertNil(
                URL(string: path).flatMap(URLCommand.parse), "\(path) should name nothing")
        }
    }

    /// `URLCommand` has no case that carries a `FallbackAction` at all — asserted at the type level
    /// rather than just by trying spellings, so a future verb added to the grammar cannot smuggle
    /// one in under a name this test did not think to try.
    func testURLCommandHasNoCaseCarryingAFallbackAction() {
        func carriesFallback(_ command: URLCommand) -> Bool {
            switch command {
            case .arrangement, .activate, .allWindows: return false
            }
        }
        // The switch above is exhaustive over `URLCommand` today; if a case is ever added without
        // updating this function, this line stops compiling rather than this test silently passing.
        XCTAssertFalse(carriesFallback(.allWindows(.hide)))
    }
}
