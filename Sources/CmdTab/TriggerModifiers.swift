import CoreGraphics

/// The modifier arithmetic behind the switcher's trigger chord.
///
/// Pulled out of `SwitcherController` deliberately. This is the crux of the session state machine:
/// while the panel is up the event tap swallows every key on the machine, and `stillHeld` returning
/// the wrong answer is what leaves it up with no way out. As free functions over a value type it can
/// be exercised without an event tap, a panel, or Accessibility permission — which is the difference
/// between this logic being tested and not.
enum TriggerModifiers {
    /// The three modifiers that identify a chord. Shift is excluded throughout: it only ever means
    /// "go backwards", never part of the trigger's identity.
    static let primary: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl]

    /// Exact match — whether a keypress *opens* the switcher. Exact so that ⌘-Tab opens on ⌘ alone
    /// and stays out of the way of ⌘⌥-Tab.
    static func opens(_ flags: CGEventFlags, held: CGEventFlags) -> Bool {
        flags.intersection(primary) == held
    }

    /// Whether the opening modifier is *still down*, tolerating extra modifiers added mid-session.
    /// A session ends when the trigger modifier itself is released, not when another one is pressed.
    static func stillHeld(_ flags: CGEventFlags, held: CGEventFlags) -> Bool {
        flags.intersection(primary).isSuperset(of: held)
    }
}
