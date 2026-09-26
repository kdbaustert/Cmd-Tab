import AppKit
import CoreGraphics

/// Which of the app's bindings claims a keystroke when the switcher is closed, and whether the
/// keystroke is swallowed on the way.
///
/// This is the precedence the docs call load-bearing, and it was previously expressed only as
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
/// - **Key-downs only.** A key-up is not a decision: it goes wherever its own key-down went, which
///   `KeyPairing` answers. Deciding the two edges separately is what let them disagree, and an
///   unpaired edge is read by anything tracking raw key state from up/down pairs — virtualisers,
///   VNC and RDP clients, remote terminals — as a release with no press, or a press that never
///   ends.
/// - **Everything below the openers is inert while Cmd-Tab is frontmost.** Their recorders live in
///   the settings window, and a bound chord matched here would be swallowed before the recorder's
///   own monitor could see it, so no assigned combination could ever be re-recorded.
/// - **The openers stand down only while a recorder is actually listening.** Opening the switcher
///   from the settings window is long-standing, so they are not inert merely because Settings is in
///   front — but a trigger recorder asked for the chord the *other* trigger holds never saw it.
/// - **Key repeat is swallowed but not acted on.** Cycling ½ → ⅔ → ⅓ under autorepeat would strobe
///   a window through every width in a fraction of a second.
///
/// Lookups come in as closures rather than the stores themselves, which is what lets a test state a
/// binding table in a line and ask what a keystroke does.
enum TapRouting {

    /// One key-down, reduced to what this decision actually depends on.
    struct Event: Equatable {
        var keyCode: Int
        var flags: CGEventFlags
        var isAutorepeat: Bool

        /// ⇧ on a trigger means "go the other way round the list".
        var backwards: Bool { flags.contains(.maskShift) }

        init(keyCode: Int, flags: CGEventFlags, isAutorepeat: Bool = false) {
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
        /// Ours, but nothing to do — a repeat under a binding that has already fired. Swallowed, so
        /// the app in front does not receive a repeat of a press it never saw.
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
    /// - Parameter isRecording: whether one of the settings window's shortcut recorders is armed.
    ///   Only acted on while `isAppActive`: a recorder hears keys through a local monitor, so it is
    ///   listening only while this app is in front, and one left armed behind another app must not
    ///   take ⌘-Tab away from that app.
    static func idle(
        _ event: Event, bindings: Bindings, isAppActive: Bool, isRecording: Bool = false
    ) -> Decision {
        // Openers first. Not guarded by `isAppActive` alone: they are recorded by a different
        // control from everything below, and opening the switcher from the settings window is
        // long-standing behaviour. They stand down while a recorder is listening, though, or the
        // two trigger recorders could never be handed each other's chord — the main trigger would
        // swallow it before the same-app recorder's monitor saw it, and the other way round.
        if !(isAppActive && isRecording) {
            if bindings.openerMatches(event.keyCode, event.flags) {
                return .open(backwards: event.backwards)
            }
            if bindings.sameAppMatches(event.keyCode, event.flags) {
                return .openSameApp(backwards: event.backwards)
            }
        }
        // Scoped triggers are inert whenever we are frontmost, unlike the two built-ins: they are
        // recorded in the settings window, so matching one here would swallow it before its own
        // recorder could see it.
        if !isAppActive, let match = bindings.scopedMatch(event.keyCode, event.flags) {
            return .openScoped(scope: match.scope, held: match.held, backwards: event.backwards)
        }

        guard !isAppActive else {
            // Reported rather than silently dropped: "the settings window has focus so your chord is
            // deliberately inert" is the commonest confusion this app produces.
            if let arrangement = bindings.tilingMatch(event.keyCode, event.flags) {
                return .tilingInert(arrangement)
            }
            return .pass
        }

        // `acts` separates "this binding claims the event" from "this binding fires now".
        let acts = !event.isAutorepeat

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

/// Keeps a key's two edges going to the same place: a key-up is withheld exactly when the app in
/// front never saw that key go down.
///
/// The tap used to decide each key-up from the switcher's state *when the key came up*, and that
/// state has usually moved on since the press. Every way the two disagreed was a real gesture:
///
/// - ⌘ let go a moment before Tab — the ordinary end of a ⌘-Tab — commits first, so Tab's key-up
///   met an idle switcher and went to the app with no press before it.
/// - The same-app and scoped triggers swallow their press and then wait on a window list, and a
///   quick tap's key-up arrives inside that wait, which routed as idle and escaped the same way.
/// - The other direction, which is worse: a key already held when the panel opened (or pressed
///   during the show delay and let through) had its key-up swallowed, so the app — or the remote
///   machine behind a VNC or RDP client — was left with a key that never came up.
///
/// Remembering which presses were withheld answers all three without knowing any of them.
///
/// Owned by the tap path itself rather than mirrored in `TapState`: it is written and read only by
/// the handler, so it moves with the tap when the tap moves, and nothing on main ever needs it.
struct KeyPairing {
    /// Keys whose every key-down so far this press was withheld from the app in front.
    private var withheld: Set<Int> = []

    /// Records what happened to a key-down.
    ///
    /// Any key-down that reaches the app counts as the press having reached it, autorepeat
    /// included: a remote client presses the key on its first repeat, so from then on its key-up
    /// has to follow. A *withheld* repeat changes nothing — only a fresh press can start a
    /// withheld one.
    mutating func keyDown(_ code: Int, isAutorepeat: Bool, swallowed: Bool) {
        if !swallowed {
            withheld.remove(code)
        } else if !isAutorepeat {
            withheld.insert(code)
        }
    }

    /// Whether to withhold this key-up, which is whether its key-down was withheld.
    mutating func keyUp(_ code: Int) -> Bool {
        withheld.remove(code) != nil
    }
}
