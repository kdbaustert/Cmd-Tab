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
    ///
    /// A window target defers to `focusWindow`, which additionally switches Desktops when the window
    /// lives on another one — the difference between going to a window and dragging it to you.
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
            if app.isHidden { app.unhide() }
            // Routed through `focusWindow` so the same-app cycle obeys the Desktop rule the hover
            // preview's click does — see there. Raising a window that lives on another Desktop drags
            // it onto the current one rather than taking you to it, so committing to a window on
            // Desktop 2 used to quietly pull it over and scramble a multi-Desktop layout.
            let parsed = windowID
            let wasMinimized = isMinimized
            let pid = self.pid
            Self.focusQueue.async {
                let resolved = parsed ?? TargetProvider.windowID(window)
                guard let id = resolved, id != 0, !wasMinimized else {
                    // Either no id to look a Space up with, or a minimized window — which sits in
                    // the Dock, on no Desktop at all, so there is nothing to switch to first and
                    // the direct raise is both correct and what this path has always done.
                    AXUIElementSetAttributeValue(
                        window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    AXUIElementSetAttributeValue(
                        window, kAXMainAttribute as CFString, true as CFTypeRef)
                    DispatchQueue.main.async {
                        NSRunningApplication(processIdentifier: pid)?.activate()
                    }
                    return
                }
                Self.focusWindow(id: id, pid: pid)
            }

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
            // Switching Desktops comes first, before anything touches the window over Accessibility.
            //
            // Raising, maining or focusing a window that lives on another Space does *not* take you
            // to it — macOS pulls the window onto the Space you are already on. That is what made
            // clicking one thumbnail drag the other window onto the current Desktop, and it also hid
            // the problem from this log: the raise relocated the window, so the Space lookup that
            // followed saw it on the current Space and reported nothing to switch to.
            //
            // Reading the window's Space first and moving *ourselves* there is the only order that
            // leaves the user's arrangement alone. It covers other displays too, since a Space
            // belongs to a display — `reveal` switches whichever monitor holds the target Space.
            let state = SpaceMover.spaceState(of: id)
            let switched = SpaceMover.reveal(window: id)
            Log.general.notice(
                "focus window \(id, privacy: .public): windowSpace=\(state?.windowSpace ?? 0, privacy: .public) current=\(state?.currentSpace ?? 0, privacy: .public) switch=\(switched, privacy: .public)"
            )
            // Nothing touches the app or the window until we have actually arrived on its Desktop.
            //
            // `activate()` used to run here, immediately, while the transition was still in flight —
            // and activating an app whose current window is elsewhere gathers that window to the
            // Space you are on, which relocated the window just as surely as an early raise did.
            // Both halves have to wait for the arrival, so both now live behind the same gate.
            settle(window: id, pid: pid, attempts: 14, delay: switched ? 0.15 : 0.02)
        }
    }

    /// Waits until `window` is genuinely on screen, then raises it and activates its app.
    ///
    /// `NSRunningApplication.activate()` is what relocates a window across Desktops — measured, not
    /// assumed: activating an app whose window sits on another Space gathers that window onto the
    /// Space you are looking at, while an `AXRaise` on the same window does nothing at all. So the
    /// activation is the step that must not happen until the switch has landed.
    ///
    /// The gate is on-screen membership rather than the window server's `Current Space` field,
    /// because that field flips the instant a switch is *issued* while the transition still has
    /// several hundred milliseconds to run — so it read as "arrived" during exactly the window in
    /// which activating still gathered the window. A window only joins the on-screen list once its
    /// Desktop is actually being displayed, which is the thing worth waiting for.
    ///
    /// Polled rather than given a fixed delay: the wait has two unrelated causes with no shared
    /// timescale — the transition, and an app whose accessibility tree is still waking up
    /// (Chromium, Electron). The poll stops the moment the window is reachable, which on the common
    /// case of a same-Desktop pick is the first attempt.
    private static func settle(
        window id: CGWindowID, pid: pid_t, attempts: Int, delay: TimeInterval
    ) {
        guard attempts > 0 else {
            // Deliberately gives up rather than acting anyway. Activating or raising at this point
            // would be doing it to a window still on another Desktop, which relocates it — and
            // silently scrambling a multi-Desktop layout is far worse than a pick that did nothing.
            Log.general.notice(
                "focus window \(id, privacy: .public): never reached its Space, gave up")
            return
        }
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard isOnScreen(window: id) else {
                settle(window: id, pid: pid, attempts: attempts - 1, delay: delay)
                return
            }
            // The window is genuinely in front now, so neither step below can relocate it. Order
            // matters: the raise goes first, measured to be harmless off-Space and here making the
            // clicked window the app's front one, so the activation that follows has nothing else
            // to surface.
            _ = raise(window: id, pid: pid)
            DispatchQueue.main.async {
                let app = NSRunningApplication(processIdentifier: pid)
                if app?.isHidden == true { app?.unhide() }
                app?.activate()
            }
        }
    }

    /// Whether the window is currently displayed — false while it sits on another Desktop, which is
    /// how a Desktop transition is known to have finished. Public `CGWindowList`, no private API.
    private static func isOnScreen(window: CGWindowID) -> Bool {
        guard window != 0 else { return true }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        return list.contains { ($0[kCGWindowNumber as String] as? CGWindowID) == window }
    }

    /// Unminimizes, raises and focuses the window with `id`. False when the app's Accessibility list
    /// has no such window — worth knowing, but every caller simply tries again once it is active.
    @discardableResult
    private static func raise(window id: CGWindowID, pid: pid_t) -> Bool {
        guard id != 0,
            let window = AX.windows(of: AX.application(pid))
                .first(where: { TargetProvider.windowID($0) == id })
        else { return false }
        AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        // Main is the app's own notion of its current window; focused is what actually moves the
        // keyboard there, and the two come apart when the window is on another display's Space.
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
        return true
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
