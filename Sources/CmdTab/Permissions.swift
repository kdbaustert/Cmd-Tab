import AppKit
import ApplicationServices
import CoreGraphics

/// Accessibility ("Control your computer") is required twice over: the event tap needs it to
/// receive key events at all, and window mode needs it to enumerate and raise windows.
enum Permissions {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Asks the system to show its "grant access" alert. No-op if already trusted.
    static func promptForTrust() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true]
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

    /// Shows the system's Screen Recording prompt the first time; a no-op once decided. The grant
    /// only takes effect on the next launch, which is standard for this permission.
    @discardableResult
    static func requestScreenCapture() -> Bool { CGRequestScreenCaptureAccess() }

    static func openScreenRecordingSettings() {
        let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        NSWorkspace.shared.open(url)
    }

    /// Called when the hover-preview setting is switched on. macOS only shows the Screen Recording
    /// prompt once ever, so this distinguishes the two cases: a first-time user gets the system
    /// prompt (and the app is registered in the Screen Recording list); a user who already
    /// decided — and was denied — is instead routed to System Settings, since no prompt will
    /// reappear and the feature would otherwise look silently broken.
    static func ensureScreenCaptureForPreview() {
        guard !canCaptureScreen else { return }
        let askedKey = "didRequestScreenCapture"
        if !UserDefaults.standard.bool(forKey: askedKey) {
            UserDefaults.standard.set(true, forKey: askedKey)
            requestScreenCapture()  // grant only applies on next launch
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

    /// Polls until the user flips the switch. There is no notification for this, so polling is
    /// the only option; the interval is slow enough to be free.
    static func waitForTrust(interval: TimeInterval = 1.0, then handler: @escaping () -> Void) {
        guard !isTrusted else { return handler() }
        Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { timer in
            guard isTrusted else { return }
            timer.invalidate()
            handler()
        }
    }
}
