import AppKit
import CoreGraphics

// `cmdtab://` — every global thing this app does, reachable without a chord.
//
// Chords are the scarce resource here. Almost every row in the Windows tab apologises for taking a
// combination away from whatever app is in front, three families ship unbound because there is no
// arrow left to give them, and the Overview exists because it is genuinely hard to keep track of
// what is claimed. A URL scheme is the way out of that: Raycast, Alfred, Shortcuts, Keyboard Maestro,
// a Stream Deck key and a line of `open` in a shell script can all reach the whole feature set
// without a single global hotkey being spent.
//
// It costs one `CFBundleURLTypes` entry and this file, because the work was already done — every
// action is a case of an enum with a stable `rawValue`, and those raw values *are* the URL grammar.
//
// **What is deliberately not here.** Nothing that quits an app, force-quits one, or closes a window.
// A URL scheme can be invoked by any web page the user visits, with no prompt and no visible trace,
// and the difference between "a page rearranged my windows" and "a page closed my unsaved document"
// is the difference between a curiosity and a bug report. Rearranging is recoverable and visible;
// the in-switcher actions that are not stay behind the keyboard, where a person is present. That
// line is the whole security argument for this feature and it is worth keeping obvious: if a verb
// ever needs adding below, ask what an arbitrary web page could do with it.

/// One parsed `cmdtab://` request.
enum URLCommand: Equatable {
    /// Apply a window arrangement — every case of `WindowArrangement`, including focus and swap.
    case arrangement(WindowArrangement)
    /// Bring an app forward, launching it if it is not running.
    case activate(bundleID: String)
    /// Hide or show every app.
    case allWindows(AllWindowsAction)

    /// Parses a `cmdtab://` URL, or nil if it names nothing.
    ///
    /// The grammar is `cmdtab://<verb>/<argument>`, and the arguments are the raw values already on
    /// disk in everyone's settings file — `cmdtab://tile/leftHalf`, `cmdtab://tile/focusRight`,
    /// `cmdtab://activate/com.apple.Safari`, `cmdtab://windows/hideAll`. Nothing new is invented to
    /// name them, so the URL for an action is discoverable by reading the settings file, and adding
    /// an arrangement adds its URL for free.
    ///
    /// A bundle identifier is taken from the *path* rather than a query parameter because it is the
    /// argument, and `cmdtab://activate/com.apple.Safari` reads as what it does. `URL` puts the first
    /// component in `host` and the rest in `path`, and it lowercases the host — which is why the
    /// verb is matched case-insensitively and the argument, which may be a bundle id, is not.
    static func parse(_ url: URL) -> URLCommand? {
        guard url.scheme?.lowercased() == "cmdtab" else { return nil }
        let verb = (url.host ?? "").lowercased()
        let argument = url.path.split(separator: "/").first.map(String.init) ?? ""
        switch verb {
        case "tile":
            return WindowArrangement(rawValue: argument).map(URLCommand.arrangement)
        case "activate":
            // Empty would mean "activate nothing", which `GlobalActions.activate` would carry all
            // the way to a LaunchServices lookup before failing.
            return argument.isEmpty ? nil : .activate(bundleID: argument)
        case "windows":
            switch argument {
            case "hideAll": return .allWindows(.hide)
            case "showAll": return .allWindows(.show)
            default: return nil
            }
        default:
            return nil
        }
    }
}
