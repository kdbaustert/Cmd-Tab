import AppKit
import CoreGraphics

/// Which of the app's bindings claims a keystroke when the switcher is closed, and whether the
/// keystroke is swallowed on the way.
///
/// This is the precedence the README calls load-bearing, and it was previously expressed only as
/// the order of a run of `if` statements inside `SwitcherController.handle` — a function that can
/// only be reached through a live `CGEventTap`, which means it could only be checked by pressing
/// keys and watching. The rules it encodes are not obvious and each one was paid for:
///
/// - **Openers win.** Nothing a user (or a hand-edited `config.json`) binds can take ⌘-Tab away
///   from the switcher itself. The recorders refuse a chord a trigger already claims, but a config
///   file is not a recorder, and a settings file that quietly disabled the app's whole reason for
///   existing would be very hard to diagnose.
/// - **The main trigger beats the same-app trigger beats scoped triggers.** Binding two of them to
///   one chord is allowed; the one that wins is defined rather than incidental.
/// - **Openers are keydown-only; global actions match both edges.** Swallowing only the keydown
///   left an unpaired key-up heading for the frontmost app, which anything tracking raw key state
///   from up/down pairs — virtualisers, VNC and RDP clients, remote terminals — reads as a release
///   with no press.
/// - **Everything below the openers is inert while Cmd-Tab is frontmost.** Their recorders live in
///   the settings window, and a bound chord matched here would be swallowed before the recorder's
///   own monitor could see it, so no assigned combination could ever be re-recorded.
/// - **Key repeat is swallowed but not acted on.** Cycling ½ → ⅔ → ⅓ under autorepeat would strobe
///   a window through every width in a fraction of a second.
///
/// Lookups come in as closures rather than the stores themselves, which is what lets a test state a
/// binding table in a line and ask what a keystroke does.
enum TapRouting {

    /// One keystroke, reduced to what this decision actually depends on.
    struct Event: Equatable {
        var type: CGEventType
        var keyCode: Int
        var flags: CGEventFlags
        var isAutorepeat: Bool

        var isKeyDown: Bool { type == .keyDown }
        /// ⇧ on a trigger means "go the other way round the list".
        var backwards: Bool { flags.contains(.maskShift) }

        init(type: CGEventType, keyCode: Int, flags: CGEventFlags, isAutorepeat: Bool = false) {
            self.type = type
            self.keyCode = keyCode
            self.flags = flags
            self.isAutorepeat = isAutorepeat
        }
    }

    /// The bindings a keystroke is matched against. Every one is a lookup that answers for a
    /// (code, flags) pair, which is the only thing the routing needs to know about any of them.
    struct Bindings {
        var openerMatches: (Int, CGEventFlags) -> Bool
        var sameAppMatches: (Int, CGEventFlags) -> Bool
        var scopedMatch: (Int, CGEventFlags) -> (scope: SwitcherScope, held: CGEventFlags)?
        var activationMatch: (Int, CGEventFlags) -> String?
        var allWindowsMatch: (Int, CGEventFlags) -> AllWindowsAction?
        var tilingMatch: (Int, CGEventFlags) -> WindowArrangement?

        init(
            openerMatches: @escaping (Int, CGEventFlags) -> Bool = { _, _ in false },
            sameAppMatches: @escaping (Int, CGEventFlags) -> Bool = { _, _ in false },
            scopedMatch: @escaping (Int, CGEventFlags) -> (scope: SwitcherScope, held: CGEventFlags)? = { _, _ in nil },
            activationMatch: @escaping (Int, CGEventFlags) -> String? = { _, _ in nil },
            allWindowsMatch: @escaping (Int, CGEventFlags) -> AllWindowsAction? = { _, _ in nil },
            tilingMatch: @escaping (Int, CGEventFlags) -> WindowArrangement? = { _, _ in nil }
        ) {
            self.openerMatches = openerMatches
            self.sameAppMatches = sameAppMatches
            self.scopedMatch = scopedMatch
            self.activationMatch = activationMatch
            self.allWindowsMatch = allWindowsMatch
            self.tilingMatch = tilingMatch
        }
    }

    /// What the controller should do. `swallows` is carried on the case rather than derived by the
    /// caller, because the two were the thing most likely to drift: a branch added to `handle` that
    /// returned the wrong `Bool` produced an unpaired key edge, which is invisible locally and
    /// breaks remote-desktop clients.
    enum Decision: Equatable {
        /// Not ours. Passes through untouched.
        case pass
        /// Ours, but nothing to do on this edge — a key-up, or a repeat under a binding that has
        /// already fired. Swallowed so the other half of the pair does not escape.
        case consume
        case open(backwards: Bool)
        case openSameApp(backwards: Bool)
        case openScoped(scope: SwitcherScope, held: CGEventFlags, backwards: Bool)
        case activate(bundleID: String)
        case allWindows(AllWindowsAction)
        case tile(WindowArrangement)
        /// A tiling chord pressed while Cmd-Tab itself is frontmost. Deliberately *not* `.consume`:
        /// the settings window's shortcut recorder has to be able to see it. Carried as its own case
        /// so the controller can log the commonest "my shortcut does nothing".
        case tilingInert(WindowArrangement)

        /// Whether the event is withheld from the app in front.
        var swallows: Bool {
            switch self {
            case .pass, .tilingInert: return false
            case .consume, .open, .openSameApp, .openScoped, .activate, .allWindows, .tile:
                return true
            }
        }
    }

    /// The idle path: no panel up, nothing armed.
    ///
    /// - Parameter isAppActive: whether Cmd-Tab itself is frontmost, which is what makes everything
    ///   below the openers inert.
    static func idle(_ event: Event, bindings: Bindings, isAppActive: Bool) -> Decision {
        // Openers first, and only on a fresh press. Not guarded by `isAppActive`: they are recorded
        // by a different control from everything below, and opening the switcher from the settings
        // window is long-standing behaviour.
        if event.isKeyDown {
            if bindings.openerMatches(event.keyCode, event.flags) {
                return .open(backwards: event.backwards)
            }
            if bindings.sameAppMatches(event.keyCode, event.flags) {
                return .openSameApp(backwards: event.backwards)
            }
            // Scoped triggers are inert while we are frontmost, unlike the two built-ins: they are
            // recorded in the settings window, so matching one here would swallow it before its own
            // recorder could see it.
            if !isAppActive, let match = bindings.scopedMatch(event.keyCode, event.flags) {
                return .openScoped(
                    scope: match.scope, held: match.held, backwards: event.backwards)
            }
        }

        guard !isAppActive else {
            // Reported rather than silently dropped: "the settings window has focus so your chord is
            // deliberately inert" is the commonest confusion this app produces.
            if event.isKeyDown, let arrangement = bindings.tilingMatch(event.keyCode, event.flags) {
                return .tilingInert(arrangement)
            }
            return .pass
        }

        // Both edges match from here down, so the key-up is consumed alongside the press. `acts`
        // separates "this binding claims the event" from "this binding fires now".
        let acts = event.isKeyDown && !event.isAutorepeat

        if let bundleID = bindings.activationMatch(event.keyCode, event.flags) {
            return acts ? .activate(bundleID: bundleID) : .consume
        }
        if let action = bindings.allWindowsMatch(event.keyCode, event.flags) {
            return acts ? .allWindows(action) : .consume
        }
        if let arrangement = bindings.tilingMatch(event.keyCode, event.flags) {
            return acts ? .tile(arrangement) : .consume
        }
        return .pass
    }
}
