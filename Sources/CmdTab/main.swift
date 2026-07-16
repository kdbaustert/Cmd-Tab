import AppKit

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
