import AppKit

// Recovery path for a takeover that outlived the process that made it. `SystemSwitcher` disables
// the Dock's ⌘-Tab in the window server's memory and restores it on every ordinary exit — quit,
// SIGTERM, SIGINT, SIGHUP — but SIGKILL and hard crashes run no cleanup, and
// `CGSGetSymbolicHotKeyEnabled` is gone on current macOS, so nothing can even ask whether the
// takeover is still in force. That left logging out as the only way back.
//
// This flag is the way back that does not cost a session: the symbolic hot keys are global window
// server state, so a fresh process can hand them over on behalf of the dead one. Handled before
// `NSApplication` exists, since it needs no app, no delegate and no Accessibility grant.
if CommandLine.arguments.contains("--restore-system-switcher") {
    guard SystemSwitcher.isAvailable else {
        FileHandle.standardError.write(Data(
            "Cmd-Tab: CGSSetSymbolicHotKeyEnabled is unavailable on this macOS; log out to restore ⌘-Tab.\n"
                .utf8))
        exit(1)
    }
    // Unconditional rather than `restoreNativeIfNeeded()`: this process never disabled anything, so
    // its own bookkeeping says there is nothing to undo. Re-enabling an already-enabled hot key is
    // a no-op in the window server, which is what makes calling it blind safe.
    guard SystemSwitcher.setNativeEnabled(true) else {
        FileHandle.standardError.write(Data(
            "Cmd-Tab: the window server refused to re-enable ⌘-Tab; log out to restore it.\n".utf8))
        exit(1)
    }
    print("Cmd-Tab: restored the system ⌘-Tab switcher.")
    exit(0)
}

// Top-level code is not implicitly main-actor-isolated here, but it does run on the main
// thread, which is what the annotation is really asserting.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    // Accessory: menu bar only, no Dock tile, and crucially never steals activation.
    app.setActivationPolicy(.accessory)
    // Held for the process lifetime; NSApplication only keeps a weak delegate reference.
    objc_setAssociatedObject(app, "cmdtab.delegate", delegate, .OBJC_ASSOCIATION_RETAIN)
    app.run()
}
