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
        /// A favourited app that isn't running: picking it launches the app at this URL.
        case launch(URL)
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
    /// Which display (0-based) a window is on, set only in window mode with more than one display.
    /// nil the rest of the time, which is what suppresses the display badge.
    var displayIndex: Int? = nil
    /// Which Space (0-based) a window is on, set only in window mode with more than one Space.
    /// nil the rest of the time, which is what suppresses the Space badge.
    var spaceIndex: Int? = nil
    /// The app's Dock notification badge ("3", "•"), when it has one.
    var badge: String? = nil

    var pid: pid_t {
        switch kind {
        case .app(let pid): return pid
        case .window(let pid, _): return pid
        case .launch: return -1
        }
    }

    /// A not-yet-running favourite. Its tile launches rather than switches, and the window actions
    /// (quit/close/minimize…) don't apply — they no-op safely on its absent pid.
    var isLaunchable: Bool {
        if case .launch = kind { return true }
        return false
    }

    /// The `CGWindowID` parsed back out of a window target's id, when it carries a resolved one.
    var windowID: CGWindowID? { TargetProvider.windowID(fromTargetID: id) }
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
        // A favourite that isn't running launches instead of switching — handled before the
        // running-app guard below, which would otherwise reject its absent pid.
        if case .launch(let url) = kind {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config)
            return
        }

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

        case .launch:
            break  // handled above
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

    /// Focuses a specific window of an app by its `CGWindowID` — used when a hover-preview thumbnail
    /// is clicked, so app mode can jump straight to that window. Raises and mains the matching AX
    /// window when it can be found; for apps whose AX window list is empty (Electron/Catalyst) it
    /// falls back to just activating the app.
    static func focusWindow(id: CGWindowID, pid: pid_t) {
        focusQueue.async {
            if let window = AX.windows(of: AX.application(pid))
                .first(where: { TargetProvider.windowID($0) == id }) {
                AXUIElementSetAttributeValue(
                    window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                AXUIElementSetAttributeValue(
                    window, kAXMainAttribute as CFString, true as CFTypeRef)
            }
            DispatchQueue.main.async {
                let app = NSRunningApplication(processIdentifier: pid)
                if app?.isHidden == true { app?.unhide() }
                app?.activate()
            }
        }
    }

    func quitApp() {
        NSRunningApplication(processIdentifier: pid)?.terminate()
    }

    func hideApp() {
        NSRunningApplication(processIdentifier: pid)?.hide()
    }

    func forceQuitApp() {
        NSRunningApplication(processIdentifier: pid)?.forceTerminate()
    }

    /// The AX window this target acts on: the element itself in window mode, or the app's frontmost
    /// window in app mode.
    private static func resolveWindow(_ kind: Kind) -> AXUIElement? {
        switch kind {
        case .window(_, let element): return element
        case .app(let pid):
            let app = AX.application(pid)
            // The focused window is the one the user sees frontmost; fall back to main, then to the
            // first AX window. Reading these attributes directly is also more reliable than filtering
            // the whole `AXWindows` list, which comes back empty for some apps (Electron/Catalyst).
            return AX.copyElement(app, kAXFocusedWindowAttribute as String)
                ?? AX.copyElement(app, kAXMainWindowAttribute as String)
                ?? AX.windows(of: app).first(where: AX.isWindow)
        case .launch: return nil
        }
    }

    /// Closes the window (window mode) or the app's frontmost window (app mode) by pressing its AX
    /// close button. Runs off the main thread — the same event-tap constraint as `focus()`.
    func closeWindow() {
        let kind = self.kind
        Self.focusQueue.async {
            guard let window = Self.resolveWindow(kind) else { return }
            AX.press(window, button: kAXCloseButtonAttribute)
        }
    }

    /// Minimizes the target window into the Dock.
    func minimizeWindow() {
        let kind = self.kind
        Self.focusQueue.async {
            guard let window = Self.resolveWindow(kind) else { return }
            AX.setBool(window, kAXMinimizedAttribute, true)
        }
    }

    /// Toggles the window's zoom (the green button) — maximize / restore.
    func zoomWindow() {
        let kind = self.kind
        Self.focusQueue.async {
            guard let window = Self.resolveWindow(kind) else { return }
            AX.press(window, button: kAXZoomButtonAttribute)
        }
    }

    /// Moves the window to the next/previous Space via private SkyLight (there is no public API). In
    /// window mode the target's id carries the `CGWindowID`; in app mode we resolve the app's front
    /// switchable window. Runs off the main thread — the Accessibility lookup can block.
    func moveToSpace(_ delta: Int) {
        let kind = self.kind
        let pid = self.pid
        let parsedWindowID = windowID
        Self.focusQueue.async {
            if case .launch = kind { return }
            // Three routes, each failing on a different set of apps, and all three resolve *this*
            // window rather than guessing at the app's frontmost one. The AX element is most direct;
            // the parsed `"win:<id>"` only exists for window targets; the frame match is the backstop
            // for hosts where `_AXUIElementGetWindow` returns 0.
            let element = Self.resolveWindow(kind)
            let id = element.flatMap(TargetProvider.windowID)
                ?? parsedWindowID
                ?? element.flatMap { TargetProvider.windowID(matching: $0, pid: pid) }
            guard let id else {
                Log.general.error("space move: no window id for pid \(pid, privacy: .public)")
                return
            }
            SpaceMover.move(window: id, bySpaces: delta)
        }
    }

    /// Moves the window to the next/previous display, keeping its position relative to the display it
    /// leaves. `screenFramesCG` are the displays' visible frames in Quartz (top-left) coordinates,
    /// resolved on the main thread by the caller since `NSScreen` is main-thread-only.
    func moveWindow(acrossDisplays delta: Int, screenFramesCG frames: [CGRect]) {
        guard frames.count > 1, delta != 0 else { return }
        let kind = self.kind
        let pid = self.pid
        Self.focusQueue.async {
            guard let window = Self.resolveWindow(kind),
                let origin = AX.position(window), let size = AX.size(window)
            else { return }
            let center = CGPoint(x: origin.x + size.width / 2, y: origin.y + size.height / 2)
            let from = frames.firstIndex { $0.contains(center) } ?? 0
            let to = frames[((from + delta) % frames.count + frames.count) % frames.count]
            let current = frames[from]
            // Same fractional offset within the destination display, then clamp so it stays on it.
            let relX = current.width > 0 ? (origin.x - current.minX) / current.width : 0
            let relY = current.height > 0 ? (origin.y - current.minY) / current.height : 0
            let x = min(max(to.minX + relX * to.width, to.minX), max(to.minX, to.maxX - size.width))
            let y = min(max(to.minY + relY * to.height, to.minY), max(to.minY, to.maxY - size.height))
            AX.setPosition(window, CGPoint(x: x, y: y))
            // Bring it to the front of the destination display and focus it, rather than dropping it
            // behind whatever is already there.
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
            DispatchQueue.main.async {
                NSRunningApplication(processIdentifier: pid)?.activate()
            }
        }
    }
}
