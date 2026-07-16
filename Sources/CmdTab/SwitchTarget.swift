import AppKit
import ApplicationServices

enum SwitcherMode: String {
    case apps
    case windows

    var title: String {
        switch self {
        case .apps: return "Application Switcher"
        case .windows: return "Window Switcher"
        }
    }
}

/// One tile in the switcher: either a whole app or a single window.
struct SwitchTarget: Identifiable {
    enum Kind {
        case app(pid_t)
        case window(pid_t, AXUIElement)
    }

    let id: String
    let kind: Kind
    /// The window title in window mode, the app name in app mode.
    let title: String
    /// The app name, shown alongside the window title in window mode.
    let appName: String
    let icon: NSImage?
    let isMinimized: Bool
    let isHidden: Bool

    var pid: pid_t {
        switch kind {
        case .app(let pid): return pid
        case .window(let pid, _): return pid
        }
    }
}

extension SwitchTarget {
    /// Accessibility work kicked off by a switch. Deliberately not `TargetProvider`'s queue: that
    /// one can be busy enumerating every window on the system, and a restore stuck behind a full
    /// refresh would land visibly late.
    private static let focusQueue = DispatchQueue(
        label: "com.cmdtab.focus", qos: .userInitiated)

    /// Brings the target forward. Unminimizing has to happen before the raise, and the app
    /// activation has to happen after it, or the window comes up behind its own app.
    func focus() {
        guard let app = NSRunningApplication(processIdentifier: pid) else { return }

        switch kind {
        case .app:
            if app.isHidden { app.unhide() }
            app.activate(options: .activateAllWindows)
            Self.restoreWindowIfAllMinimized(pid: pid)

        case .window(_, let window):
            if isMinimized {
                AXUIElementSetAttributeValue(
                    window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            }
            if app.isHidden { app.unhide() }
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(
                window, kAXMainAttribute as CFString, true as CFTypeRef)
            app.activate()
        }
    }

    /// Activating an app whose windows are *all* minimized leaves you looking at its menu bar and
    /// an empty desktop, so restore one. Window mode does not need this — there the specific
    /// window is unminimized by name above.
    ///
    /// Runs off the main thread: `focus()` is called from inside the event tap callback, and
    /// every Accessibility call here is IPC that can block on a wedged app.
    private static func restoreWindowIfAllMinimized(pid: pid_t) {
        focusQueue.async {
            // Every window, not just the switchable ones: an app showing only a dialog still has
            // something on screen, and restoring a minimized window over it would be wrong. The
            // role check is what keeps Finder's desktop (an AXScrollArea) out.
            let windows = AX.windows(of: AX.application(pid)).filter(AX.isWindow)
            guard !windows.isEmpty else { return }
            // Something is already up — leave the user's arrangement alone.
            guard !windows.contains(where: { !AX.isMinimized($0) }) else { return }
            guard let target = windows.first else { return }

            AXUIElementSetAttributeValue(
                target, kAXMinimizedAttribute as CFString, false as CFTypeRef)
            AXUIElementPerformAction(target, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(target, kAXMainAttribute as CFString, true as CFTypeRef)

            Log.targets.notice("restored a minimized window for pid \(pid)")

            // Restoring does not reliably bring the app forward on its own, and by now our own
            // activation has already happened.
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }

    func quitApp() {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }
}
