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
            // The answer is checked because nothing else would ever say: the panel is already down
            // by the time this runs, so a URL nothing would open was a tile that silently did
            // nothing. The scheme only, since the rest is whatever the user typed.
            guard !NSWorkspace.shared.open(url) else { return }
            Log.general.error(
                "fallback: nothing opened the \(url.scheme ?? "?", privacy: .public): URL")
        case .shellCommand(let command):
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = ["-lc", command]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.standardInput = FileHandle.nullDevice
            do {
                try process.run()
            } catch {
                // The command's output is deliberately discarded; the shell failing to *start* is
                // ours to report, or the fallback does nothing with no way to tell.
                Log.general.error(
                    "shell fallback: could not start /bin/zsh: \(error.localizedDescription, privacy: .public)")
            }
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

        /// Whether any fallback is on — and so whether a query may need the punctuation an address,
        /// a search or a command is written in. See `SwitcherController.typedCharacter`.
        var anyEnabled: Bool { offerURL || offerSearch || offerShell }
    }

    static let defaultSearchTemplate = "https://duckduckgo.com/?q=%s"

    /// The actions this query and these settings produce, in the fixed order URL, then search, then
    /// shell — the same order they are drawn in, since the highlight lands on the first one.
    ///
    /// `hasHandler` is `url(for:hasHandler:)`'s, passed through.
    static func actions(
        for query: String, settings: Settings,
        hasHandler: (URL) -> Bool = SwitcherFallbacks.handlerExists
    ) -> [FallbackAction] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return [] }
        var actions: [FallbackAction] = []
        if settings.offerURL, let url = url(for: trimmed, hasHandler: hasHandler) {
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
    /// AX behind it. `SwitcherController.launchSuggestions` is what supplies the two answers.
    static func tier(
        runningMatches: Bool, installedMatches: Bool, query: String, settings: Settings,
        hasHandler: (URL) -> Bool = SwitcherFallbacks.handlerExists
    ) -> [FallbackAction] {
        guard !runningMatches, !installedMatches else { return [] }
        return actions(for: query, settings: settings, hasHandler: hasHandler)
    }

    /// Whether `query` parses as something URL-like, and the URL it means. Anything with a space is
    /// typed prose, not an address, whichever way it parses. Otherwise, in order:
    ///
    /// * **A host and a port** — `localhost:3000`, `example.com:8080` — becomes `http://` that.
    ///   `URL`'s own parser reads the host as the *scheme*, so this was taken as a URL with scheme
    ///   `localhost`, which nothing opens: the tile the fallback exists for did nothing, silently.
    ///   `http` rather than `https` because a bare port is a development server far more often
    ///   than anything with a certificate.
    /// * **An explicit scheme** — `https://…`, `mailto:…` — is used as typed, but only when
    ///   something is registered to open it. `hasHandler` asks; without that check `note:3` or any
    ///   other `word:word` was offered as a URL and did nothing.
    /// * **A dot** turns into an `https://` address.
    ///
    /// `hasHandler` is a parameter so the refusal can be tested without depending on what this
    /// machine has installed; the switcher passes a lookup memoized per scheme, since this runs on
    /// the keystroke path.
    static func url(
        for query: String, hasHandler: (URL) -> Bool = SwitcherFallbacks.handlerExists
    ) -> URL? {
        guard !query.contains(" ") else { return nil }
        if query.range(of: hostAndPort, options: .regularExpression) != nil {
            return URL(string: "http://\(query)")
        }
        if let url = URL(string: query), url.scheme != nil {
            return hasHandler(url) ? url : nil
        }
        guard query.contains(".") else { return nil }
        return URL(string: "https://\(query)")
    }

    /// Whether anything is registered to open `url` — the default `hasHandler`. A LaunchServices
    /// lookup; the switcher memoizes it per scheme rather than paying it per keystroke.
    static func handlerExists(_ url: URL) -> Bool {
        NSWorkspace.shared.urlForApplication(toOpen: url) != nil
    }

    /// `name:digits`, optionally followed by a path — the shape `URL` misreads as a scheme.
    private static let hostAndPort = #"^[A-Za-z0-9.-]+:[0-9]+(/.*)?$"#

    /// The template with `%s` replaced by the percent-encoded query, or nil when the template has
    /// nowhere to put the query or does not parse as a URL once substituted.
    static func searchURL(for query: String, template: String) -> URL? {
        guard template.contains("%s") else { return nil }
        let encoded =
            query.addingPercentEncoding(withAllowedCharacters: queryValueAllowed) ?? query
        return URL(string: template.replacingOccurrences(of: "%s", with: encoded))
    }

    /// What may stand unescaped inside one query *value*.
    ///
    /// `urlQueryAllowed` is the set for a whole query string, so it leaves the characters that
    /// structure one alone — and a search term carrying them restructured the query instead of
    /// being part of it: `c++` arrived as `q=c++`, which a server reads as "c" and two spaces, and
    /// `AT&T` as `q=AT&T`, which ends the value at "AT" and adds a parameter named "T". `#` would
    /// end the URL outright. `/`, `?` and `;` are legal in a value, and escaping them anyway costs
    /// nothing, where leaving one to a server's reading of it can.
    private static let queryValueAllowed = CharacterSet.urlQueryAllowed
        .subtracting(CharacterSet(charactersIn: "&+=#?;/"))
}
