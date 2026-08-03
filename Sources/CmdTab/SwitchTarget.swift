import AppKit
import ApplicationServices

/// What the switcher lists: one tile per running application, or one per open window.
///
/// Also used as a *presentation* flag inside a session — the same-app cycle shows one app's windows
/// whatever the setting says, and passes `.windows` so those tiles carry their own titles.
enum SwitcherMode: String, CaseIterable {
    case apps
    case windows

    var title: String {
        switch self {
        case .apps: return "Application Switcher"
        case .windows: return "Window Switcher"
        }
    }

    /// Short form, for a settings picker where the surrounding row already says "switch between".
    var shortTitle: String {
        switch self {
        case .apps: return "Applications"
        case .windows: return "Windows"
        }
    }

    var detail: String {
        switch self {
        case .apps:
            return "One tile per app, the way ⌘-Tab has always worked. Reach a specific window "
                + "with the app-window cycle."
        case .windows:
            return "One tile per open window, across every app, each carrying its own title."
        }
    }

    var symbol: String {
        switch self {
        case .apps: return "square.grid.2x2"
        case .windows: return "macwindow.on.rectangle"
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
            Self.focusApp(pid: pid, bundleURL: app.bundleURL)

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
                let resolved = Self.windowID(of: window, parsed: parsed, pid: pid)
                guard let id = resolved, !wasMinimized else {
                    // Either no id to look a Space up with, or a minimized window — which sits in
                    // the Dock, on no Desktop at all, so there is nothing to switch to first and
                    // the direct raise is both correct and what this path has always done.
                    Self.beginFocus()
                    Self.raise(element: window)
                    Self.activate(pid: pid)
                    return
                }
                Self.focusWindow(id: id, pid: pid)
            }

        case .launch:
            break  // handled above
        }
    }

    /// Brings an app forward. Which of four things that means depends on where its windows are, and
    /// the old single `activate(options: .activateAllWindows)` was right for only one of them.
    ///
    /// Runs off the main thread: `focus()` is reached from inside the event tap callback, and every
    /// Accessibility call below is IPC that can block on a wedged app.
    private static func focusApp(pid: pid_t, bundleURL: URL?) {
        focusQueue.async {
            // An app pick supersedes any window pick still waiting for its Desktop.
            beginFocus()

            // Something of this app's is already on the Desktop in front of us. The plain activation
            // is right, and this is the case nearly every pick takes — nothing below may slow it
            // down or change its behaviour.
            //
            // "Is anything of this app's up?" is a question for the window server, not `AXWindows`.
            // Finder keeps the desktop in its accessibility window list, and it arrives as a window
            // rather than the `AXScrollArea` this code used to filter on, so a Finder whose only
            // real window was minimized in the Dock looked like an app that already had something on
            // screen. That is the "Finder won't open" report, and it is why Finder was the app it
            // happened to: nothing else owns the desktop. `.excludeDesktopElements` drops the
            // desktop by request, minimized windows are absent from the on-screen list by
            // definition, and layer 0 keeps panels and menus from counting.
            let onScreen = onScreenWindows(pid: pid)
            guard onScreen.isEmpty else {
                // `allWindows` only when there is nothing elsewhere to drag over — see
                // `ownsWindowOnAnotherSpace`. The set is already in hand, so the check costs one
                // more window-server read on the rare app that has windows off screen and nothing
                // at all on the common path.
                activate(
                    pid: pid,
                    allWindows: !ownsWindowOnAnotherSpace(pid: pid, onScreen: onScreen))
                return
            }

            // Nothing anywhere: not minimized, not on another Desktop. `activate` cannot make a
            // window, so only a reopen produces one — see `reopen`.
            guard let front = frontOwnedWindow(pid: pid) else {
                reopen(pid: pid, bundleURL: bundleURL)
                return
            }

            // It owns a window that is off screen, which is either the Dock or another Desktop.
            // A minimized window occupies no Space at all, so a nil state here means the Dock.
            let state = SpaceMover.spaceState(of: front)
            guard let state, state.windowSpace != state.currentSpace else {
                // Minimized, or on this Desktop but not visible. Activate first — that is what makes
                // Chromium and Electron build the accessibility tree the restore needs — then raise
                // whatever comes back minimized.
                //
                // `front` being minimized says nothing about the app's *other* windows: the one in
                // the Dock is simply first in z-order, and siblings can still be sitting on Desktops
                // of their own for `allWindows` to gather. Same guard as the on-screen path.
                activate(
                    pid: pid,
                    allWindows: !ownsWindowOnAnotherSpace(pid: pid, onScreen: onScreen))
                restoreMinimized(pid: pid, attempts: 4)
                return
            }

            // On another Desktop. Activating here would *gather* the window onto the Desktop we are
            // looking at rather than taking us to it — the measured behaviour `settle` documents —
            // which is how switching to an app quietly moved its window off the Desktop the user
            // had left it on. `focusWindow` switches Spaces first and waits for the arrival, so app
            // mode reuses it rather than activating blind.
            focusWindow(id: front, pid: pid)
        }
    }

    /// Raises a minimized window of `pid`, retrying while the app's accessibility tree is empty.
    ///
    /// Chromium and Electron hosts report no windows until they are active. The caller activates
    /// first, so an empty list here means "not yet", not "none" — without the retry a minimized-only
    /// Chrome was never restored and the pick looked like it did nothing.
    private static func restoreMinimized(pid: pid_t, attempts: Int) {
        let windows = AX.windows(of: AX.application(pid)).filter(AX.isWindow)
        guard let target = windows.first(where: AX.isMinimized) else {
            guard windows.isEmpty, attempts > 1 else { return }
            focusQueue.asyncAfter(deadline: .now() + 0.1) {
                restoreMinimized(pid: pid, attempts: attempts - 1)
            }
            return
        }
        raise(element: target)
        Log.targets.notice("restored a minimized window for pid \(pid)")
        // Restoring does not reliably bring the app forward on its own.
        activate(pid: pid)
    }

    /// Asks an app that owns no window at all to make one, which is what picking its tile means.
    ///
    /// `activate()` only moves focus; it never creates a window. So an app running with nothing open
    /// — Finder after its last window is closed is the one everybody hits, but any document app left
    /// windowless behaves the same — swapped the menu bar and left the screen exactly as it was.
    ///
    /// The Dock does not have this problem because clicking a Dock tile sends a *reopen* Apple
    /// event, and an app's answer to that is to open a window. `openApplication` on an already
    /// running app is that same event, so this is the Dock's behaviour, not a new invention.
    private static func reopen(pid: pid_t, bundleURL: URL?) {
        guard let bundleURL else {
            activate(pid: pid, allWindows: true)  // Nothing to reopen with; at least come forward.
            return
        }
        Log.targets.notice("pid \(pid, privacy: .public) owns no window; reopening to make one")
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        }
    }

    /// The ordinary windows of `pid` actually displayed right now — empty when its windows are all
    /// minimized, and empty when they are all on another Space.
    private static func onScreenWindows(pid: pid_t) -> Set<CGWindowID> {
        Set(ownedWindows(pid: pid, options: [.optionOnScreenOnly, .excludeDesktopElements]))
    }

    /// Whether `pid` owns a window living on a Desktop other than the one in front.
    ///
    /// `.activateAllWindows` brings *every* window of an app forward, and the only way macOS can
    /// bring a window on another Space forward is to drag it onto the Space you are looking at. So
    /// on an app whose windows are spread across Desktops — or one the user pinned to a Desktop with
    /// the Dock's "Assign To" — the activation meant merely to surface what was already here
    /// silently gathered the rest of its windows off the Desktops they were left on. That is the
    /// "windows keep switching Desktops by themselves" report.
    ///
    /// Answering yes costs the pick nothing but the whole-window-group raise, which is only
    /// meaningful for windows that are already here; answering no keeps ⌘-Tab's traditional
    /// behaviour on the apps where it is safe.
    ///
    /// Free on the common case: an app with everything on this Desktop has no off-screen windows to
    /// look up, and only the off-screen ones are ever asked about.
    private static func ownsWindowOnAnotherSpace(pid: pid_t, onScreen: Set<CGWindowID>) -> Bool {
        let offScreen = ownedWindows(pid: pid, options: [.excludeDesktopElements])
            .filter { !onScreen.contains($0) }
        guard !offScreen.isEmpty else { return false }
        // A minimized window sits in the Dock on no Space at all, which is what a nil state means
        // here — and activation cannot drag it anywhere, so it is no reason to give up `allWindows`.
        return offScreen.contains { window in
            guard let state = SpaceMover.spaceState(of: window) else { return false }
            return state.windowSpace != state.currentSpace
        }
    }

    /// The app's frontmost window on any Desktop, minimized ones included. The window list is in
    /// z-order, so the first match is the one the app itself considers in front.
    private static func frontOwnedWindow(pid: pid_t) -> CGWindowID? {
        ownedWindows(pid: pid, options: [.excludeDesktopElements]).first
    }

    /// The ordinary windows `pid` owns, front to back.
    ///
    /// Layer 0 only, and desktop elements excluded, so Finder's desktop — which it owns for the
    /// whole session and which is never something the user switched *to* — never counts.
    private static func ownedWindows(pid: pid_t, options: CGWindowListOption) -> [CGWindowID] {
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { window in
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                (window[kCGWindowOwnerPID as String] as? pid_t) == pid
            else { return nil }
            return window[kCGWindowNumber as String] as? CGWindowID
        }
    }

    /// The `CGWindowID` for a window, by whichever of three routes answers first — each fails on a
    /// different set of apps. The AX element is the most direct; the id parsed out of a window
    /// target's `"win:<id>"` only exists for window targets; the frame match is the backstop for
    /// hosts where `_AXUIElementGetWindow` returns 0 (Electron, Catalyst). Missing the third route
    /// is how those apps used to skip the Desktop switch entirely and get dragged over instead.
    private static func windowID(of element: AXUIElement?, parsed: CGWindowID?, pid: pid_t)
        -> CGWindowID?
    {
        let id =
            element.flatMap(TargetProvider.windowID)
            ?? parsed
            ?? element.flatMap { TargetProvider.windowID(matching: $0, pid: pid) }
        return id == 0 ? nil : id
    }

    /// The AX element for the window with `id`, when the app's Accessibility list has one. Empty for
    /// apps that build that list lazily (Chromium, Electron) until they are active.
    private static func axWindow(id: CGWindowID, pid: pid_t) -> AXUIElement? {
        guard id != 0 else { return nil }
        return AX.windows(of: AX.application(pid))
            .first(where: { TargetProvider.windowID($0) == id })
    }

    /// Brings `pid` forward, unhiding it first if it is hidden. `NSRunningApplication` is
    /// main-thread work; every caller here is on `focusQueue`.
    ///
    /// `allWindows` is the app-mode pick: ⌘-Tab has always brought an app's whole window group
    /// forward, not just its front one. The window-mode paths leave it off, since there the point is
    /// to surface one specific window and dragging its siblings up with it is exactly wrong.
    private static func activate(pid: pid_t, allWindows: Bool = false) {
        DispatchQueue.main.async {
            let app = NSRunningApplication(processIdentifier: pid)
            if app?.isHidden == true { app?.unhide() }
            if allWindows {
                app?.activate(options: .activateAllWindows)
            } else {
                app?.activate()
            }
        }
    }

    /// Counts picks. A `settle` chain captures this at its start and stops the moment it no longer
    /// matches, so a pick still waiting for its Desktop to arrive cannot activate its app up to two
    /// seconds later and yank the user off whatever they picked in the meantime. Activation used to
    /// be synchronous with the pick, which made that impossible by construction; the wait for the
    /// Space transition is what opened the gap.
    ///
    /// Only ever touched from `focusQueue`, which is serial — no lock needed.
    private static var focusGeneration: UInt64 = 0

    @discardableResult
    private static func beginFocus() -> UInt64 {
        focusGeneration &+= 1
        return focusGeneration
    }

    /// Focuses a specific window of an app by its `CGWindowID` — used when a hover-preview thumbnail
    /// is clicked, so app mode can jump straight to that window. Raises and mains the matching AX
    /// window when it can be found; for apps whose AX window list is empty (Electron/Catalyst) it
    /// falls back to just activating the app.
    static func focusWindow(id: CGWindowID, pid: pid_t) {
        focusQueue.async {
            let generation = beginFocus()
            let element = axWindow(id: id, pid: pid)

            // A minimized window sits in the Dock, on no Desktop at all: there is nothing to switch
            // to first, it can never join the on-screen list the gate below waits on, and the
            // restore is the whole of the work. Not an edge case — the hover preview offers
            // minimized windows as thumbnails, so this is a path users reach by clicking one.
            if let element, AX.isMinimized(element) {
                raise(element: element)
                activate(pid: pid)
                return
            }

            // A hidden app's windows are likewise in no on-screen list, so the unhide has to happen
            // out here: inside the gate it was unreachable, because the gate could not open until it
            // had already happened. Its windows do still live on a Desktop, though, so the Space
            // logic below still applies and the poll waits for the unhide to land.
            if NSRunningApplication(processIdentifier: pid)?.isHidden == true {
                DispatchQueue.main.async {
                    NSRunningApplication(processIdentifier: pid)?.unhide()
                }
            }

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
            let reveal = SpaceMover.reveal(window: id)
            Log.general.notice(
                "focus window \(id, privacy: .public): windowSpace=\(reveal.state?.windowSpace ?? 0, privacy: .public) current=\(reveal.state?.currentSpace ?? 0, privacy: .public) switch=\(reveal.switched, privacy: .public)"
            )
            // Nothing touches the app or the window until we have actually arrived on its Desktop.
            //
            // `activate()` used to run here, immediately, while the transition was still in flight —
            // and activating an app whose current window is elsewhere gathers that window to the
            // Space you are on, which relocated the window just as surely as an early raise did.
            // Both halves have to wait for the arrival, so both now live behind the same gate.
            settle(
                window: id, pid: pid, attempts: 14, delay: reveal.switched ? 0.15 : 0.02,
                generation: generation, actWhenUnreached: !reveal.switched)
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
    ///
    /// `actWhenUnreached` says what to do if it never arrives, and is the difference between the two
    /// ways a pick can fail. See the give-up branch.
    private static func settle(
        window id: CGWindowID, pid: pid_t, attempts: Int, delay: TimeInterval,
        generation: UInt64, actWhenUnreached: Bool
    ) {
        guard generation == focusGeneration else { return }  // superseded by a later pick
        guard attempts > 0 else {
            guard actWhenUnreached else {
                // A Space switch really was issued and never landed, so the window is still on
                // another Desktop: activating or raising it now would relocate it, and silently
                // scrambling a multi-Desktop layout is far worse than a pick that did nothing.
                Log.general.notice(
                    "focus window \(id, privacy: .public): never reached its Space, gave up")
                return
            }
            // No switch was needed or one could not be issued at all, so nothing is in flight and
            // there is no Desktop to drag the window off. Whatever is keeping it out of the
            // on-screen list, acting is safe and doing nothing would make the pick a silent no-op —
            // which is what happens on a macOS where the private Space symbols have gone missing.
            Log.general.notice(
                "focus window \(id, privacy: .public): never appeared on screen, focusing anyway")
            focusAndActivate(window: id, pid: pid, generation: generation)
            return
        }
        focusQueue.asyncAfter(deadline: .now() + delay) {
            guard generation == focusGeneration else { return }
            guard isOnScreen(window: id) else {
                settle(
                    window: id, pid: pid, attempts: attempts - 1, delay: delay,
                    generation: generation, actWhenUnreached: actWhenUnreached)
                return
            }
            focusAndActivate(window: id, pid: pid, generation: generation)
        }
    }

    /// Raises the window and brings its app forward, retrying the raise once the app is up.
    ///
    /// Order matters: the raise goes first, measured to be harmless off-Space and here making the
    /// picked window the app's front one, so the activation that follows has nothing else to
    /// surface. Runs on `focusQueue`.
    private static func focusAndActivate(window id: CGWindowID, pid: pid_t, generation: UInt64) {
        let raised = raise(window: id, pid: pid)
        activate(pid: pid)
        // Apps that build their accessibility tree lazily (Chromium, Electron) report *no* windows
        // until they are active, so the raise above found nothing and the activation surfaced
        // whichever window happened to be frontmost rather than the picked one. Retry now that the
        // app is coming up — the only thing that makes the pick land for those apps.
        guard !raised else { return }
        focusQueue.asyncAfter(deadline: .now() + 0.15) {
            guard generation == focusGeneration else { return }
            raise(window: id, pid: pid)
        }
    }

    /// Whether the window is currently displayed — false while it sits on another Desktop, which is
    /// how a Desktop transition is known to have finished. Public `CGWindowList`, no private API.
    ///
    /// Asks about the one window rather than snapshotting every window on the system: this runs up
    /// to fourteen times per switch, on the latency-sensitive focus path.
    private static func isOnScreen(window: CGWindowID) -> Bool {
        guard window != 0 else { return true }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .optionIncludingWindow, .excludeDesktopElements], window)
                as? [[String: Any]]
        else { return true }
        return !list.isEmpty
    }

    /// Unminimizes, raises and focuses the window with `id`. False when the app's Accessibility list
    /// has no such window, which is worth knowing: it is how a lazily-built tree announces itself,
    /// and the caller retries once the app is active.
    @discardableResult
    private static func raise(window id: CGWindowID, pid: pid_t) -> Bool {
        guard let window = axWindow(id: id, pid: pid) else { return false }
        raise(element: window)
        return true
    }

    /// Unminimizes, raises and focuses an AX window.
    private static func raise(element window: AXUIElement) {
        AXUIElementSetAttributeValue(
            window, kAXMinimizedAttribute as CFString, false as CFTypeRef)
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, true as CFTypeRef)
        // Main is the app's own notion of its current window; focused is what actually moves the
        // keyboard there, and the two come apart when the window is on another display's Space.
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFTypeRef)
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

    /// Moves the window to the next/previous display, keeping its position relative to the display it
    /// leaves. `visibleAreas` are the displays' usable areas — menu bar and Dock already excluded —
    /// in Quartz (top-left) coordinates, resolved on the main thread by the caller since `NSScreen`
    /// is main-thread-only. `WindowTiler.visibleAreas()` is the one source for them, shared with the
    /// keyboard chords so a window thrown either way lands in the same place.
    func moveWindow(acrossDisplays delta: Int, visibleAreas frames: [CGRect]) {
        guard frames.count > 1, delta != 0 else { return }
        let kind = self.kind
        let pid = self.pid
        Self.focusQueue.async {
            guard let window = Self.resolveWindow(kind),
                let origin = AX.position(window), let size = AX.size(window)
            else { return }
            // The display the window is on, by the one rule the badge and the tiling chords also use
            // — see `WindowTiler.homeDisplay`. nil means it overlaps no usable area at all, and a
            // window on no display has no next display to be sent to.
            let frame = CGRect(origin: origin, size: size)
            guard let from = WindowTiler.homeDisplay(of: frame, in: frames) else { return }
            let to = frames[((from + delta) % frames.count + frames.count) % frames.count]
            let current = frames[from]
            // Shrink to fit before placing, exactly as `WindowTiler.apply`'s displayStep branch does
            // — the promise both sides document is that a window thrown either way lands in the same
            // place. Positioning alone left a window that filled a 4K external at 4K on a laptop
            // screen, pinned to the top-left with most of it hanging off the bottom and right.
            let fitted = CGSize(
                width: min(size.width, to.width), height: min(size.height, to.height))
            // Same fractional offset within the destination display, then clamp so it stays on it.
            let relX = current.width > 0 ? (origin.x - current.minX) / current.width : 0
            let relY = current.height > 0 ? (origin.y - current.minY) / current.height : 0
            let x = min(max(to.minX + relX * to.width, to.minX), max(to.minX, to.maxX - fitted.width))
            let y = min(
                max(to.minY + relY * to.height, to.minY), max(to.minY, to.maxY - fitted.height))
            // Size before position: a window still at its old size can be clamped back off the
            // destination by its own width, and AppKit applies each write independently.
            if fitted != size { AX.setSize(window, fitted) }
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
