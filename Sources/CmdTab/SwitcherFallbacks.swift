import AppKit
import Foundation

/// The lowest tier the switcher offers: an action built straight out of the query text, reached
/// only when nothing running and nothing installed answered it — see
/// `SwitcherController.updateLaunchSuggestions`, which never builds these until the tier above it
/// has already come up empty, so a fallback can never displace a real match.
///
/// Each case is its own opt-in setting and every one of them defaults off, unlike `launchFromSearch`
/// above it: that tier only ever chooses between apps already on the machine, while this one leaves
/// it — opening a URL, running a web search, or handing a shell a string nobody vetted. A user who
/// wants the convenience turns each one on deliberately, rather than a fresh install doing any of
/// this the first time a query happens to parse as an address.
enum FallbackAction: Equatable {
    /// Opens `url`, built from the query — see `SwitcherFallbacks.url`.
    case openURL(query: String, url: URL)
    /// Opens a search engine's results page, built from the stored template.
    case search(query: String, url: URL)
    /// Runs the query as a shell command. Never reachable from `cmdtab://` — see the boundary
    /// `URLCommand` draws around its own grammar for why.
    case shellCommand(String)

    var title: String {
        switch self {
        case .openURL(let query, _): return "Open \(query)"
        case .search(let query, _): return "Search for \(query)"
        case .shellCommand(let command): return "Run \(command)"
        }
    }

    /// Carries out the action. `.openURL` and `.search` both just open a URL; `.shellCommand` is the
    /// one case that can do real damage, and it is written to leave no trace beyond what the command
    /// itself does — its output is discarded, and nothing is written to disk to run it.
    func perform() {
        switch self {
        case .openURL(_, let url), .search(_, let url):
            NSWorkspace.shared.open(url)
        case .shellCommand(let command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            try? process.run()
        }
    }
}

/// Builds the fallback tier from a query and the settings for it.
///
/// Pure and static so the ordering and the URL/template logic are testable with no switcher, no
/// panel and no running app behind them — see `FallbackActionTests`.
enum SwitcherFallbacks {
    /// Which fallbacks are on, and the template the search one fills in.
    struct Settings {
        var offerURL: Bool
        var offerSearch: Bool
        var offerShell: Bool
        var searchTemplate: String
    }

    static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"

    /// The actions this query and these settings produce, in the fixed order URL, then search, then
    /// shell — the same order they are drawn in, since the highlight lands on the first one.
    static func actions(for query: String, settings: Settings) -> [FallbackAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var actions: [FallbackAction] = []
        if settings.offerURL, let url = url(for: trimmed) {
            actions.append(.openURL(query: trimmed, url: url))
        }
        if settings.offerSearch,
            let url = searchURL(for: trimmed, template: settings.searchTemplate)
        {
            actions.append(.search(query: trimmed, url: url))
        }
        if settings.offerShell {
            actions.append(.shellCommand(trimmed))
        }
        return actions
    }

    /// The fallback tier's actions, or none — a fallback is only ever offered once the tiers above
    /// it have both come up empty, so it can never displace a real match.
    ///
    /// Pure over the two booleans rather than reading `SwitcherModel` itself, so the ordering rule
    /// — a running match suppresses fallbacks, an installed-app match suppresses fallbacks, and
    /// only an empty pair of tiers produces them — is testable with no panel, no provider and no
    /// AX behind it. `SwitcherController.updateLaunchSuggestions` is what supplies the two answers.
    static func tier(
        runningMatches: Bool, installedMatches: Bool, query: String, settings: Settings
    ) -> [FallbackAction] {
        guard !runningMatches, !installedMatches else { return [] }
        return actions(for: query, settings: settings)
    }

    /// Whether `query` parses as something URL-like: it names a scheme of its own — `URL`'s parser
    /// reads `localhost:3000` as scheme `localhost`, which is exactly the shape this is meant to
    /// catch — or it contains a dot and no spaces, which `https://` in front of turns into an
    /// address. Anything with a space is typed prose, not an address, whichever way it parses.
    static func url(for query: String) -> URL? {
        guard !query.contains(" ") else { return nil }
        if let url = URL(string: query), url.scheme != nil { return url }
        guard query.contains(".") else { return nil }
        return URL(string: "https://\(query)")
    }

    /// The template with `%s` replaced by the percent-encoded query, or nil when the template has
    /// nowhere to put the query or does not parse as a URL once substituted.
    static func searchURL(for query: String, template: String) -> URL? {
        guard template.contains("%s") else { return nil }
        let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }
}
