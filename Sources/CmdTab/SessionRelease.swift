import CoreGraphics

/// When a switcher session ends, and when Tab-cycling arms it to end on release.
///
/// Extracted for exactly the reason `TriggerModifiers` was. These rules decide whether the panel —
/// which swallows every keystroke on the machine while it is up — closes or stays, and four review
/// passes running have found regressions in them: the keyUp of the Tab that armed cycling closing
/// the panel after one step, the release recovery being lost when that was fixed, sticky sessions
/// that could never end, sessions that ended when they should have stayed. Every one of those was a
/// disagreement between a handful of booleans, and none was reachable from a test while the logic
/// lived inside an `@MainActor` controller behind a `CGEvent`-driven entry point.
///
/// A value type over the flags, with no dependency on the event tap, the panel, or Accessibility.
struct SessionRelease: Equatable {
    /// Whether this session is allowed to outlive the trigger being released.
    let isSticky: Bool
    /// Whether Tab has been pressed with the panel up *and the chord still held*.
    let cycledWithTab: Bool
    /// Modifiers of whichever hotkey opened the session. Empty for a menu-bar session, which has no
    /// modifier to release at all.
    let activeHeld: CGEventFlags

    /// Whether releasing the trigger leaves the panel up rather than committing.
    ///
    /// Tab-cycling opts back in: reaching for Tab is the classic ⌘-Tab gesture and carries the
    /// classic expectation that letting go takes you there.
    var staysOpenOnRelease: Bool { isSticky && !cycledWithTab }

    /// Whether an event carrying `flags` should end the session and switch.
    ///
    /// `isKeyUp` is load-bearing and not cosmetic. A sticky session's modifier is *legitimately*
    /// already up, so every subsequent event looks like a release; treating a keyUp as one closed
    /// the panel on the key-up of the very Tab that armed cycling, one step into browsing. A
    /// non-sticky session has the opposite need: reading the release off a keyUp is the only
    /// event-driven recovery when another head-inserted tap consumes the `flagsChanged`.
    func shouldCommit(flags: CGEventFlags, isKeyUp: Bool) -> Bool {
        guard !TriggerModifiers.stillHeld(flags, held: activeHeld) else { return false }
        // No modifier to release: a menu-bar session ends by clicking, Return or Escape, never here.
        guard !activeHeld.isEmpty else { return false }
        if !isSticky { return true }
        if isKeyUp { return false }
        return !staysOpenOnRelease
    }

    /// Whether a Tab press should arm commit-on-release.
    ///
    /// Only while the chord is still down. "Tab to cycle, release to go" presupposes something left
    /// to release; tabbing in an already-released stay-open session is plain navigation.
    func armsCycling(flags: CGEventFlags) -> Bool {
        !activeHeld.isEmpty && TriggerModifiers.stillHeld(flags, held: activeHeld)
    }
}
