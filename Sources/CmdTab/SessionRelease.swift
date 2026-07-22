import CoreGraphics

/// When a switcher session ends.
///
/// Extracted for exactly the reason `TriggerModifiers` was. These rules decide whether the panel —
/// which swallows every keystroke on the machine while it is up — closes or stays, and four review
/// passes running have found regressions in them: the keyUp of a Tab closing the panel after one
/// step, the release recovery being lost when that was fixed, sticky sessions that could never end,
/// sessions that ended when they should have stayed. Every one of those was a disagreement between a
/// handful of booleans, and none was reachable from a test while the logic lived inside an
/// `@MainActor` controller behind a `CGEvent`-driven entry point.
///
/// A value type over the flags, with no dependency on the event tap, the panel, or Accessibility.
struct SessionRelease: Equatable {
    /// Whether this session is allowed to outlive the trigger being released.
    let isSticky: Bool
    /// Modifiers of whichever hotkey opened the session. Empty for a menu-bar session, which has no
    /// modifier to release at all.
    let activeHeld: CGEventFlags

    /// Whether releasing the trigger leaves the panel up rather than committing.
    ///
    /// Unconditional for a sticky session, Tab-cycling included. It used to carve Tab out — pressing
    /// Tab with the chord still held re-armed the classic "let go and you land on the app" — but that
    /// carve-out was the one thing standing between Stay open and the gesture it exists for: the
    /// obvious way to use the switcher is ⌘-Tab, Tab, and re-arming there closed the panel the moment
    /// ⌘ came up, so a bare Tab afterwards never had a session left to cycle. A stay-open session now
    /// commits the way the rest of its keys already read: Return, a click, or a digit.
    var staysOpenOnRelease: Bool { isSticky }

    /// Whether a press of the trigger key should switch rather than move the highlight.
    ///
    /// The chord decides. Still held, this is the classic ⌘-Tab cycle and Tab steps along the list —
    /// letting go is what takes you there. Already up, there is no release left to commit on: a
    /// stay-open session, or one opened from the menu bar with no chord at all, would otherwise leave
    /// Tab as a key that can only ever shuffle the highlight. So it becomes the go key, and the
    /// highlight moves with the arrows, scroll or the mouse.
    ///
    /// Shift is the exception at both ends. ⇧-Tab means "step backwards" here, in the native switcher
    /// and everywhere else people bring the gesture from; promoting it to the go key along with plain
    /// Tab left a released session with no keyboard way to reverse-cycle at all — you had to overshoot
    /// and come round the list. `stillHeld` deliberately ignores Shift when reading the chord, so this
    /// has to be checked before it.
    func tabCommits(flags: CGEventFlags) -> Bool {
        guard !flags.contains(.maskShift) else { return false }
        // Nothing to hold, so nothing can be "still held" — `stillHeld` says yes to an empty chord.
        guard !activeHeld.isEmpty else { return true }
        return !TriggerModifiers.stillHeld(flags, held: activeHeld)
    }

    /// Whether an event carrying `flags` should end the session and switch.
    ///
    /// Read off any event, key-up included, and not just `flagsChanged`: when another head-inserted
    /// tap ahead of ours consumes the modifier event, a later key-up seeing the modifier already gone
    /// is the only event-driven recovery there is.
    func shouldCommit(flags: CGEventFlags) -> Bool {
        guard !TriggerModifiers.stillHeld(flags, held: activeHeld) else { return false }
        // No modifier to release: a menu-bar session ends by clicking, Return or Escape, never here.
        guard !activeHeld.isEmpty else { return false }
        // A sticky session's modifier is legitimately already up, so every event that follows looks
        // like a release. None of them may commit — that is the whole of Stay open.
        return !staysOpenOnRelease
    }
}
