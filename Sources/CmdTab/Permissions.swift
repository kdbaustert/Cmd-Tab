import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility ("Control your computer") is required twice over: the event tap needs it to
/// receive key events at all, and window mode needs it to enumerate and raise windows.
enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its "grant access" alert. No-op if already trusted.
    static func promptForTrust() {
        // The literal rather than `kAXTrustedCheckOptionPrompt`, which imports as a mutable C
        // global and so is not concurrency-safe to read. The constant's value is API and has been
        // this string since the option existed.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    /// Screen Recording, needed only for the hover window-preview thumbnails. Everything else in the
    /// app deliberately gets by without it.
    static var canCaptureScreen: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system's Screen Recording prompt the first time; a no-op once the user has decided.
    /// The grant only takes effect on the next launch, which is standard for this permission.
    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Called when the hover-preview setting is switched on. macOS shows the Screen Recording prompt
    /// exactly once, ever, so this splits the two cases: a first-time user gets the system prompt
    /// (which also registers the app in the Screen Recording list); a user who already answered — and
    /// was denied — is routed to System Settings instead, since no prompt will reappear and the
    /// feature would otherwise look silently broken.
    /// `@MainActor` because it puts up an `NSAlert` and runs it modally, neither of which is legal
    /// anywhere else. The only caller is the preview toggle in Settings, which is already there.
    @MainActor
    static func ensureScreenCaptureForPreview() {
        guard !canCaptureScreen else { return }
        let askedKey = "didRequestScreenCapture"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            requestScreenCapture()  // the grant only applies on the next launch
            return
        }
        let alert = NSAlert()
        alert.messageText = "Enable Screen Recording for window previews"
        alert.informativeText =
            "Cmd-Tab needs Screen Recording access to show live window previews. Enable Cmd-Tab under "
            + "System Settings → Privacy & Security → Screen Recording, then relaunch Cmd-Tab."
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            openScreenRecordingSettings()
        }
    }

    /// The one poll, and everyone waiting on it.
    ///
    /// Held here rather than in a local so a second `waitForTrust` joins the timer already running
    /// instead of starting another. Nothing has two callers today, but the untrusted case is the
    /// one where a stray timer lives longest — a user who leaves the system prompt unanswered keeps
    /// every one of them waking the main run loop for the life of the process.
    @MainActor private static var trustPoll: Timer?
    @MainActor private static var trustHandlers: [@MainActor () -> Void] = []

    /// Polls until the user flips the switch. There is no notification for this, so polling is
    /// the only option; the interval is slow enough to be free. A caller arriving while a poll is
    /// already running joins it, and `interval` is then the first caller's.
    ///
    /// `@MainActor` because the timer is scheduled on the main run loop and the handler starts the
    /// event tap. The only caller is `AppDelegate`, already on it.
    @MainActor
    static func waitForTrust(
        interval: TimeInterval = 1.0, then handler: @escaping @MainActor () -> Void
    ) {
        guard !isTrusted else { return handler() }
        trustHandlers.append(handler)
        guard trustPoll == nil else { return }
        trustPoll = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { _ in
            MainActor.assumeIsolated {
                guard isTrusted else { return }
                trustPoll?.invalidate()
                trustPoll = nil
                // Taken and cleared before any of them runs: a handler that calls back in must
                // arm a fresh poll rather than land in the list being drained.
                let handlers = trustHandlers
                trustHandlers = []
                handlers.forEach { $0() }
            }
        }
    }
}
