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
