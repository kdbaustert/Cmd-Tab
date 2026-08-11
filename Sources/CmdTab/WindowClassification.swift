import ApplicationServices

/// Decides whether an Accessibility window belongs in the switcher.
///
/// Split out of `AX` so it can be tested: every input here is a plain value, where the same
/// question asked of a live `AXUIElement` needs a running app, a granted permission and a window
/// in a particular state. The three rules below were each paid for by a bug, and a subrole table
/// that shifts under us on the next macOS is exactly the kind of thing that should be pinned down
/// by tests rather than re-derived by hand.
enum WindowClassification {

    /// The role-only check: a window as opposed to the other things that turn up in `AXWindows`.
    /// Finder puts the desktop in there as an `AXScrollArea`.
    static func isWindow(role: String?) -> Bool {
        role == (kAXWindowRole as String)
    }

    /// A real window the user could switch to, as opposed to a palette, sheet or alert.
    ///
    /// This cannot be a subrole check alone, for two separate reasons.
    ///
    /// **Minimized windows lie about their subrole.** macOS reports a window as `AXDialog` while it
    /// is minimized: the same window flips `AXStandardWindow` → `AXDialog` on minimize and back on
    /// restore (verified on macOS 26.5 with TextEdit). Filtering on `AXStandardWindow` therefore
    /// drops every minimized window on the floor — silently, since an empty list looks exactly like
    /// an app with no windows.
    ///
    /// **Some apps lie about it all the time.** Finder's browser windows report `AXDialog` even
    /// while up, so the minimized escape hatch above does not reach them and Finder — one of the
    /// most-switched-to apps on the machine — was missing from window mode entirely.
    ///
    /// The discriminator for that second case is the **minimize button**. A window the user can
    /// send to the Dock is a window they can switch back to, which is the same question this
    /// function is asking; an alert, a modal or a Save panel has no such control. Deliberately
    /// narrowed to `AXDialog` rather than "any non-standard subrole", so floating palettes
    /// (`AXFloatingWindow`), sheets (`AXSheet`) and system dialogs stay out however they are
    /// decorated — the bug was about one subrole, and widening the net past it would readmit the
    /// things the subrole check exists to exclude.
    static func isSwitchable(
        role: String?,
        subrole: String?,
        isMinimized: @autoclosure () -> Bool,
        hasMinimizeButton: @autoclosure () -> Bool
    ) -> Bool {
        guard isWindow(role: role) else { return false }
        if subrole == (kAXStandardWindowSubrole as String) { return true }
        // Minimized: it is sitting in the Dock and is switchable whatever it now calls itself.
        if isMinimized() { return true }
        guard subrole == (kAXDialogSubrole as String) else { return false }
        return hasMinimizeButton()
    }
}
