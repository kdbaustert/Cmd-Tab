import CoreGraphics
import Foundation

/// How a switcher session begins.
///
/// The sibling of `SessionRelease`, extracted for the same reason and against the same class of bug.
/// Every rule here is a disagreement between three or four booleans, every one of them has already
/// been wrong at least once in a way the comments in `SwitcherController` record, and none was
/// reachable from a test while it lived inside an `@MainActor` controller behind a `CGEvent`-driven
/// entry point:
///
/// * session state assigned *before* the empty-list bail-out left `isSticky` latched true after a
///   press that opened nothing, so the next session — from any hotkey — silently came up sticky;
/// * an armed sticky session started a watchdog that could never act, waking the main run loop five
///   times a second for the life of the panel;
/// * a window list landing after the user had moved on acted on the session that replaced it,
///   stopping *its* watchdog and deleting the failsafe between a missed modifier-release and a
///   machine-wide keyboard lockout.
///
/// Value types over the flags, with no dependency on the event tap, the panel, or Accessibility.
enum SessionOpen {

    /// What a trigger press should do.
    enum Plan: Equatable {
        /// Nothing to show. The press is not swallowed — it belongs to whatever is in front.
        case decline
        /// Draw nothing yet; wait out the show-delay. `watchdog` is whether the release poll runs.
        case arm(watchdog: Bool)
        /// Draw now.
        case show
    }

    /// Decides a press without touching any session state, which is the half that was wrong: the
    /// bail-out has to come before anything is assigned, and a function that returns the decision
    /// rather than performing it cannot get that order wrong.
    ///
    /// The watchdog is the failsafe for a `flagsChanged` that never arrives, so it is wanted for
    /// every session that ends on release — and only those. A sticky session does not end on release
    /// at all, so its poll would return at its first guard on every tick for as long as the panel
    /// stood.
    static func plan(hasTargets: Bool, showDelay: TimeInterval, isSticky: Bool) -> Plan {
        guard hasTargets else { return .decline }
        guard showDelay > 0 else { return .show }
        return .arm(watchdog: !isSticky)
    }
}

/// A session whose window list is fetched asynchronously — the same-app cycle and the scoped
/// openers.
///
/// Both fetch through Accessibility against an app that may be wedged, so both always swallow the
/// chord (there is no way to know yet whether there is anything to show, and letting it through
/// would fire the shortcut in the app behind us a moment later) and both have to survive a result
/// landing after the user gave up.
enum AsyncSession {

    /// Whether the chord may start a cycle at all.
    ///
    /// Three ways to already be busy, and starting a second cycle over any of them would strand the
    /// first one's token, deadline and watchdog with nothing left to clear them.
    static func canOpen(pendingSameApp: Bool, isVisible: Bool, armed: Bool) -> Bool {
        !pendingSameApp && !isVisible && !armed
    }

    /// What to do with a list that has landed.
    enum Outcome: Equatable {
        /// Superseded, or already handled. Touch nothing — the session that replaced this one owns
        /// the watchdog now.
        case stale
        /// Nothing worth cycling between. End quietly, without drawing.
        case abandon
        /// Draw the panel; the trigger is still held.
        case show
        /// Tapped and released before the list landed: switch straight to this index, never drawing.
        case focus(index: Int)
    }

    /// `minimum` is what makes a list worth acting on, and it differs by caller: the same-app cycle
    /// needs two windows, since one window is nothing to cycle *between*, while a scoped opener acts
    /// on a single hit — narrowing to "minimized windows" and finding exactly one is a successful
    /// search, not an empty one.
    ///
    /// The index is one rule rather than the two the callers used to spell out separately. Forwards
    /// wants the *next* window, which is index 1 — except in a one-item list, where the only window
    /// is index 0 and reaching for 1 would trap. Backwards wants the last. `min(1, count - 1)` is
    /// both, and it is identical to the bare `1` the same-app path used, because `minimum` of 2
    /// means `count - 1` is never below 1 there.
    static func outcome(
        isCurrent: Bool, count: Int, atLeast minimum: Int, wasReleased: Bool, backwards: Bool
    ) -> Outcome {
        guard isCurrent else { return .stale }
        guard count >= minimum, count > 0 else { return .abandon }
        guard wasReleased else { return .show }
        return .focus(index: backwards ? count - 1 : min(1, count - 1))
    }
}
