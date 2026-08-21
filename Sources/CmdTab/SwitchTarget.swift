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
/// `@unchecked Sendable` rather than genuinely `Sendable`, because two of the fields cannot be
/// checked: `NSImage` is not `Sendable`, and `AXUIElement` is an opaque CF handle. Both are safe
/// here for the same reason, which is worth stating rather than assuming.
///
/// A target is **built once and never mutated after it is handed off**. `TargetProvider` constructs
/// the whole list on `axQueue` and passes it to the main thread, which only reads it; nothing
/// writes to a target after construction. The `NSImage`s are app icons obtained from
/// `NSWorkspace`/`NSRunningApplication` and are only ever drawn, and `AXUIElement` is a thread-safe
/// opaque reference whose whole purpose is to be messaged from whichever queue the caller is on —
/// this app already does exactly that, deliberately, all over `AX`.
///
/// The alternative is threading the list back as a `sending` value, which says the same thing with
/// more ceremony and none of the explanation.
extension SwitchTarget: @unchecked Sendable {}

struct SwitchTarget: Identifiable {
    /// `@unchecked Sendable` for the same reason as `SwitchTarget` itself, and it has to be stated
    /// separately because the associated value is what makes it unclear: `AXUIElement` is an opaque
    /// CF handle that this app messages from `focusQueue` on purpose. See the note on the extension
    /// below.
    enum Kind: @unchecked Sendable {
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

    /// Counts completed Desktop transitions, so a pick that issued one can wait for it to *land*.
    ///
    /// `NSWorkspace.activeSpaceDidChangeNotification` is the only signal here that means the switch
    /// is finished rather than merely begun. Both of the cheaper tests lie during the animation: the
    /// window server's `Current Space` field flips the instant a switch is issued, and — measured,
    /// which is what this counter exists to fix — so does on-screen membership, because the incoming
    /// Space's windows start compositing as the transition opens. Activating an app in that gap
    /// gathers its window onto the Desktop being left, which is how picking a window on Desktop 1
    /// from Desktop 4 quietly moved it to Desktop 4 instead of taking the user to it.
    private static let spaceChanges = SpaceChangeCounter()

    /// Registers the observer from the main thread at launch instead of leaving it to whichever pick
    /// touches `spaceChanges` first — that would be `focusQueue`, and `NSWorkspace.shared`'s own
    /// first initialisation is not background work to be doing in the middle of a pick.
    ///
    /// Only decides *when*: the `static let` is what registers, so a pick that somehow beats this
    /// call still gets an observer, and one that follows it does not get a second.
    static func warmSpaceTracking() {
        _ = spaceChanges.value
    }

    /// Registered once and never removed — it lives as long as the process, which is why the
    /// observer token is not kept. Its own tiny type so the lock around the count stays next to it;
    /// the increment lands on the main thread and the read comes from `focusQueue`.
    private final class SpaceChangeCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count: UInt64 = 0

        init() {
            // `queue: nil` runs the block synchronously on the thread that posts, rather than hopping
            // it onto a queue: a transition that has landed has to be visible to the very next poll
            // on `focusQueue`, not one hop later.
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil
            ) { [weak self] _ in
                guard let self else { return }
                self.lock.withLock { self.count &+= 1 }
            }
        }

        var value: UInt64 { lock.withLock { count } }
    }

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
            // `nonisolated(unsafe)` rather than relying on `Kind`'s conformance: the element is
            // bound out of the pattern match above, so it arrives as a bare `AXUIElement` with no
            // `Sendable` of its own. Crossing onto `focusQueue` is the point — every Accessibility
            // call in this app is IPC that must not run on the thread servicing the event tap.
            nonisolated(unsafe) let window = window
            Self.focusQueue.async {
                let resolved = Self.windowID(of: window, parsed: parsed, pid: pid)
                guard let id = resolved, !wasMinimized else {
                    // Either no id to look a Space up with, or a minimized window — which sits in
                    // the Dock, on no Desktop at all, so there is nothing to switch to first and
                    // the direct raise is both correct and what this path has always done.
                    //
                    // The no-id half of that is *not* safe in the same way: a raise with no Space
                    // check drags an off-Desktop window onto the current one. The two say different
                    // things in the log despite sharing a branch, because only one of them is a
                    // suspect when a window turns up on the wrong Desktop.
                    if wasMinimized {
                        Log.general.notice(
                            "window pick: unminimizing pid \(pid, privacy: .public) (id=\(resolved ?? 0, privacy: .public))"
                        )
                    } else {
                        Log.general.notice(
                            "window pick: raising pid \(pid, privacy: .public) blind — no window id, Space unchecked"
                        )
                    }
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
    ///
    /// Not private, because a tile pick is not the only way to ask for an app: the direct-activation
    /// shortcuts in `GlobalActions` mean the same thing and used to spell it `activate(options:
    /// .activateAllWindows)`, which is precisely the call that rearranges Desktops.
    static func focusApp(pid: pid_t, bundleURL: URL?) {
        focusQueue.async {
            // An app pick supersedes any window pick still waiting for its Desktop.
            let generation = beginFocus()

            // One placement read, shared by every question below. Each of them used to take its own
            // — and the whole-window-group check took one *per window* — where a read walks every
            // Space on every display at a window-server round-trip each. Measured on a six-Space
            // machine: thirty-six round-trips to answer a single pick, all of them on the queue the
            // switch is waiting on.
            let placement = SpaceMover.windowSpaces()

            // The ids Accessibility vouches for, shared by the same questions. See `realWindows`:
            // the window list alone cannot tell an app's window from the helper surfaces it leaves
            // beside it, and picking one of those is a pick that fronts the app and raises nothing.
            let real = realWindows(pid: pid)

            // Something of this app's is already in front of us, which is the case nearly every pick
            // takes. What it does *not* license is `activate`: that call is app-level, and an app
            // whose front window lives on another Desktop has that window dragged onto this one as
            // its side effect — see `FrontProcess`. So an app with one window here and one on
            // Desktop 1 had the Desktop 1 window hauled over every time it was picked from
            // elsewhere, which is the "Ghostty and VS Code follow me between Desktops" report: the
            // window came over, and macOS put it back the next time its own Desktop came up.
            //
            // Fronting the window that is already here, by id, is the same outcome for the user with
            // no app-level activation to have that effect. Its siblings stay where they were left.
            //
            // "Is anything of this app's up?" is a question for the window server, not `AXWindows`.
            // Finder keeps the desktop in its accessibility window list, and it arrives as a window
            // rather than the `AXScrollArea` this code used to filter on, so a Finder whose only
            // real window was minimized in the Dock looked like an app that already had something on
            // screen. That is the "Finder won't open" report, and it is why Finder was the app it
            // happened to: nothing else owns the desktop. `.excludeDesktopElements` drops the
            // desktop by request, minimized windows are absent from the on-screen list by
            // definition, and layer 0 keeps panels and menus from counting.
            if let here = frontWindowHere(pid: pid, placement: placement, real: real) {
                Log.general.notice(
                    """
                    app pick: pid \(pid, privacy: .public) fronting window \
                    \(here, privacy: .public), already on this Desktop
                    """)
                // The siblings first, so the app arrives as a group rather than as one window with
                // the rest still buried — see `raiseGroupHere`. Ordered before the pick's own front
                // so the picked window finishes on top of them.
                raiseGroupHere(pid: pid, except: here, placement: placement, real: real)
                focusAndActivate(window: here, pid: pid, generation: generation)
                return
            }

            // Nothing on this Desktop and nothing on any other: its windows are in the Dock, or it
            // owns none at all. `restoreMinimized` tells those two apart — the Dock is the only
            // place left to look — and reopens when there turns out to be nothing to restore.
            //
            // The window list cannot answer this on its own, which is what the old
            // `frontOwnedWindow` here assumed it could: see `placedFrontWindow` for the five
            // phantoms a windowless Finder owns. Trusting them meant `reopen` was unreachable for
            // the one app whose name is on the bug it exists to fix.
            guard let front = placedFrontWindow(pid: pid, placement: placement, real: real) else {
                Log.general.notice(
                    "app pick: pid \(pid, privacy: .public) has nothing on any Desktop")
                activate(pid: pid)
                restoreMinimized(
                    pid: pid, attempts: 4, bundleURL: bundleURL, generation: generation)
                return
            }

            // Either on another Desktop, or on this one but hidden or wholly covered. Both are
            // `focusWindow`'s job: it switches Spaces when there is one to switch to, unhides when
            // that is what is in the way, and waits for the arrival before it touches the window.
            //
            // Activating here instead would *gather* an off-Desktop window onto the Desktop we are
            // looking at rather than taking us to it — the measured behaviour `settle` documents —
            // which is how switching to an app quietly moved its window off the Desktop the user had
            // left it on.
            let state = placement[front]
            Log.general.notice(
                """
                app pick: pid \(pid, privacy: .public) has nothing on this Desktop, going to \
                front=\(front, privacy: .public) on space \(state?.windowSpace ?? 0, privacy: .public) \
                (current \(state?.currentSpace ?? 0, privacy: .public))
                """)
            // With the placement already in hand: `placedFrontWindow` picked `front` *because* the
            // map places it, so re-reading it there could only lose the answer, never improve it.
            // The whole map goes down rather than `state` alone — `focusWindow` needs this app's
            // other windows to tell a Desktop switch from a gather.
            focusWindow(id: front, pid: pid, placement: placement)
        }
    }

    /// Raises a minimized window of `pid`, retrying while the app's accessibility tree is empty, and
    /// reopens the app when the retries prove it has no window anywhere.
    ///
    /// Chromium and Electron hosts report no windows until they are active. The caller activates
    /// first, so an empty list here means "not yet", not "none" — without the retry a minimized-only
    /// Chrome was never restored and the pick looked like it did nothing.
    ///
    /// Reached only once the window server has said the app has nothing on any Desktop, so the Dock
    /// is the last place a window could be. Running out of retries therefore settles the question
    /// the caller could not: the app owns none, and a pick that lands here has to *make* one or it
    /// does nothing at all. That silent nothing was the "Finder won't open" report — Finder's
    /// accessibility list holds only the desktop, an `AXScrollArea` that `isWindow` drops, so the
    /// list is empty forever and every retry expired against a `return`.
    ///
    /// `generation` for the same reason every other deferred step in this file carries one: the
    /// retry chain is up to four tenths of a second long and ends in an activation, so without it a
    /// pick the user had already replaced could still haul them back to a Dock window they had moved
    /// on from.
    private static func restoreMinimized(
        pid: pid_t, attempts: Int, bundleURL: URL?, generation: UInt64
    ) {
        guard generation == focusGeneration else { return }
        let windows = AX.windows(of: AX.application(pid)).filter(AX.isWindow)
        guard let target = windows.first(where: AX.isMinimized) else {
            // It has windows, just none in the Dock. Nothing to restore, and nothing to reopen for
            // either — the activation the caller already issued is the whole of the answer.
            guard windows.isEmpty else { return }
            guard attempts > 1 else {
                reopen(pid: pid, bundleURL: bundleURL)
                return
            }
            focusQueue.asyncAfter(deadline: .now() + 0.1) {
                restoreMinimized(
                    pid: pid, attempts: attempts - 1, bundleURL: bundleURL, generation: generation)
            }
            return
        }
        raise(element: target)
        Log.targets.notice("restored a minimized window for pid \(pid)")
        // Restoring does not reliably bring the app forward on its own — and until now a bare
        // `activate` was the whole of the answer here, which made this the one pick path that never
        // checked its own outcome. It is also the path most likely to need one: a day of logs has
        // five picks that reached it and not one `after activation` line among them, while the user
        // re-pressed ⌘-Tab at the same app three times in twelve seconds around two of them.
        //
        // `focusAndActivate` is the same verification every other path gets, and it is safe here for
        // the reason its own `FrontProcess` note gives: it names the window by id rather than
        // activating the app, and this branch was reached *because* the app has nothing on any
        // Desktop, so there is nothing left elsewhere for its activation fallback to gather.
        guard let id = windowID(of: target, parsed: nil, pid: pid) else {
            activate(pid: pid)
            return
        }
        focusAndActivate(window: id, pid: pid, generation: generation)
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
            activate(pid: pid, allWindows: mayRaiseWholeWindowGroup)  // Nothing to reopen with; at least come forward.
            return
        }
        Log.targets.notice("pid \(pid, privacy: .public) owns no window; reopening to make one")
        DispatchQueue.main.async {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: bundleURL, configuration: config)
        }
    }

    /// The app's frontmost window that is genuinely in front of the user right now: displayed, and
    /// on the Space its display is currently showing. nil when everything it owns is minimized,
    /// hidden, or on another Desktop.
    ///
    /// Both halves are needed, and the Space one is what this bug turned on. `.optionOnScreenOnly`
    /// answers "is this window composited", which is *not* the same question: an incoming Desktop's
    /// windows begin compositing as a transition opens — the measured behaviour `spaceChanges`
    /// documents — so a pick that lands in that gap sees a window as on screen while it still
    /// belongs to the Desktop being left. Acting on that reading is what pulled the window over.
    /// Asking the window server which Space actually holds it settles it either way.
    ///
    /// Returns the on-screen list's first entry when the placement map could not be read at all: it
    /// is then the only evidence there is, and on-screen membership on its own is still enough to
    /// say the window is here. Unlike the whole-window-group raise this replaces, a blind answer
    /// costs nothing — the window fronted is one specific window of the app's, never its siblings on
    /// Desktops the user is not looking at.
    ///
    /// `real` is a third half neither of those two covers: both ask *where* a window is, and neither
    /// asks whether it is a window at all. See `realWindows` — an app's helper surfaces pass the
    /// on-screen test and the Space test alike, and fronting one is a pick that does nothing.
    private static func frontWindowHere(
        pid: pid_t, placement: [CGWindowID: SpaceMover.SpaceState], real: Set<CGWindowID>
    ) -> CGWindowID? {
        // In z-order, so the first match is the one the app considers in front.
        frontWindow(
            onScreen: ownedWindows(
                pid: pid, options: [.optionOnScreenOnly, .excludeDesktopElements]),
            placement: placement, real: real)
    }

    /// The rule above, over values rather than the window server, so the three inputs that decide it
    /// can be pinned by a test. `onScreen` is front-to-back.
    static func frontWindow(
        onScreen: [CGWindowID], placement: [CGWindowID: SpaceMover.SpaceState],
        real: Set<CGWindowID>
    ) -> CGWindowID? {
        let candidates = onScreen.filter { isReal($0, real) }
        guard !placement.isEmpty else { return candidates.first }
        return candidates.first { window in
            guard let state = placement[window] else { return false }
            return state.windowSpace == state.currentSpace
        }
    }

    /// The window ids Accessibility will vouch for as real windows of `pid`.
    ///
    /// `CGWindowList` is not a list of an app's windows, and the Space check the callers already
    /// apply is not enough to make it one: an app's helper surfaces are layer 0, on screen, and
    /// placed on a Space exactly like its real windows. Measured on Alfred Preferences, which owns a
    /// 500×500 surface and one 2056×39 menu-bar backing per display alongside its one real window;
    /// when one of those sorts ahead of the real window in z-order, `frontWindowHere` returns it and
    /// the pick fronts a window that does not exist. `_SLPSSetFrontProcessWithOptions` accepts the id
    /// and marks the process front — the menu bar swaps, `frontmostApplication` reports success —
    /// while ordering nothing, so the app's real window stays buried under whatever the user was
    /// looking at. That is the "picked it and the window didn't come forward" report, and its
    /// signature in the log is `fronted=true raised=false`: `raised` is false precisely because the
    /// id names no Accessibility window.
    ///
    /// Empty means "no opinion", not "no windows": Chromium and Electron hosts publish nothing until
    /// they are active, so every caller degrades to the unfiltered list rather than concluding an app
    /// has nothing on screen. One Accessibility round trip per pick, on `focusQueue` — next to the
    /// per-Space window-server walk `focusApp` already pays for, it does not register.
    private static func realWindows(pid: pid_t) -> Set<CGWindowID> {
        Set(TargetProvider.switchableWindowIDs(for: pid))
    }

    /// See `realWindows`: an empty set is no opinion, so everything passes.
    private static func isReal(_ window: CGWindowID, _ real: Set<CGWindowID>) -> Bool {
        real.isEmpty || real.contains(window)
    }

    /// Raises the app's *other* windows that are already on the Desktop in front of the user, so an
    /// app pick surfaces the whole group the way ⌘-Tab always has.
    ///
    /// Fronting one window was right about Spaces and wrong about what picking an app means: an app
    /// with two windows on this Desktop, one of them covered by something else, came forward with
    /// the covered one still covered. The app was "in front" and half of it was not.
    ///
    /// This is the group raise `mayRaiseWholeWindowGroup` describes and declines to do with
    /// `.activateAllWindows`, and the reason it is safe here is that it never asks for a *group*.
    /// `.activateAllWindows` hands the window server a process and lets it decide what to gather,
    /// which is how windows got hauled off Desktops nobody was looking at. This names specific
    /// windows, one at a time, and names only those the placement map already puts on the current
    /// Space — so a window on another Desktop is not merely unlikely to move, it is never mentioned.
    /// An unreadable placement map means an empty list and no group raise at all, which degrades to
    /// exactly the previous behaviour.
    ///
    /// Back to front, so the app's own stacking survives: each call puts one window on top, so
    /// replaying them in reverse z-order rebuilds the same order above everything else. `except` is
    /// the picked window, left out because `focusAndActivate` fronts it immediately afterwards and
    /// it has to finish on top.
    private static func raiseGroupHere(
        pid: pid_t, except target: CGWindowID, placement: [CGWindowID: SpaceMover.SpaceState],
        real: Set<CGWindowID>
    ) {
        let siblings = ownedWindows(
            pid: pid, options: [.optionOnScreenOnly, .excludeDesktopElements]
        )
        .filter { window in
            guard window != target, isReal(window, real), let state = placement[window] else {
                return false
            }
            return state.windowSpace == state.currentSpace
        }
        guard !siblings.isEmpty else { return }
        for window in siblings.reversed() {
            FrontProcess.raise(window: window, pid: pid)
        }
        Log.general.notice(
            """
            app pick: pid \(pid, privacy: .public) raised \(siblings.count, privacy: .public) \
            sibling window(s) already on this Desktop
            """)
    }

    /// The app's frontmost window that the window server actually places on a Desktop.
    ///
    /// The raw window list is not a list of an app's windows. Every app that draws a menu bar owns
    /// one full-width menu-bar backing window per display, and apps leave 1×1, 64×64 and 500×500
    /// helper surfaces behind them; all are layer 0, all survive `.excludeDesktopElements`, and none
    /// is anything the user could switch to. Closed windows linger in the list too, after the app
    /// itself has forgotten them. Measured on a Finder with no windows open: five entries, every one
    /// of them a phantom — which is why the old `frontOwnedWindow` never returned nil for Finder and
    /// `reopen` was unreachable for the very app whose name is on the bug it exists to fix.
    ///
    /// Placement was the first cut and is not enough on its own: the `0x2` query behind this map was
    /// taken to return exactly the real windows, and Alfred Preferences disproves it — its helper
    /// surfaces are placed on a Space like everything else. So `real` runs alongside it; see
    /// `realWindows`. Minimized windows are on no Space and so are absent from the map, which is why
    /// the caller goes on to search the Dock through the accessibility tree rather than concluding
    /// anything from a nil.
    ///
    /// The list is in z-order, so the first match is the one the app considers in front.
    private static func placedFrontWindow(
        pid: pid_t, placement: [CGWindowID: SpaceMover.SpaceState], real: Set<CGWindowID>
    ) -> CGWindowID? {
        placedWindow(
            owned: ownedWindows(pid: pid, options: [.excludeDesktopElements]),
            placement: placement, real: real)
    }

    /// The rule above, over values. `owned` is front-to-back.
    static func placedWindow(
        owned: [CGWindowID], placement: [CGWindowID: SpaceMover.SpaceState], real: Set<CGWindowID>
    ) -> CGWindowID? {
        owned.first { isReal($0, real) && placement[$0] != nil }
    }

    /// Whether a pick of the window at `state` can actually get the user there.
    ///
    /// The one place the "macOS will not travel for this app" verdict is written down, because two
    /// callers have to agree on it exactly: `focusWindow`, which declines the pick, and the hover
    /// preview, which badges the thumbnail so the click is not offered as if it would work. Split
    /// apart they would drift, and the failure mode of drift here is the worst one available — a
    /// thumbnail that looks live and does nothing, which is the bug this whole path exists around.
    ///
    /// A window on no Space is reachable: it is in the Dock, and `restoreFromDock` handles it
    /// without a Desktop change. A window on the Space already in front is trivially reachable.
    /// Anything else needs macOS to travel, and macOS only travels for an app with nothing on
    /// screen — see the measurements in `focusWindow`.
    ///
    /// `appHasWindowOnScreen` is passed in rather than read here, and autoclosed rather than taken
    /// as a plain `Bool`, because the two callers want opposite things from it. `hasWindowOnScreen`
    /// walks the whole system window list: the strip asks this once per thumbnail and so hands over
    /// an answer it computed once for the app, while `focusWindow` is on the pick path and must not
    /// pay for it at all on the common same-Desktop pick, which the two cheap guards above settle.
    static func canReach(
        state: SpaceMover.SpaceState?, appHasWindowOnScreen: @autoclosure () -> Bool
    ) -> Bool {
        guard let state else { return true }
        guard state.windowSpace != state.currentSpace else { return true }
        return !appHasWindowOnScreen()
    }

    /// Whether `pid` already has a window on a Space that is currently being displayed.
    ///
    /// The question activation's behaviour turns on: an app with something on screen is one macOS
    /// will not travel for, so activating it can only bring it forward where the user is standing —
    /// gathering whatever it owns elsewhere. See `canReach`, which is what turns this into a verdict.
    ///
    /// `currentSpace` is per display in this map, which is what makes the answer right on a
    /// multi-monitor setup: a window on the second display's visible Space counts as on screen even
    /// though it is nowhere near the Desktop the pick came from. That is precisely the case this
    /// exists for, and a single-display reading of "is it on the current Desktop" would miss it.
    ///
    /// Takes the map rather than reading one, so the caller's single enumeration answers both this
    /// and the placement — see `windowSpaces`, which costs a round trip per Space.
    static func hasWindowOnScreen(
        pid: pid_t, placement: [CGWindowID: SpaceMover.SpaceState]
    ) -> Bool {
        ownedWindows(pid: pid, options: [.excludeDesktopElements]).contains { window in
            guard let state = placement[window] else { return false }
            return state.windowSpace == state.currentSpace
        }
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

    /// Whether an app pick may raise the app's *whole* window group rather than just bringing it
    /// forward.
    ///
    /// ⌘-Tab has traditionally done this, and `.activateAllWindows` is the only call that does — but
    /// it is also the loudest of the calls in this file that can pull a window off the Desktop it
    /// lives on, and no amount of gating made that trade-off worth defending: a check on where the
    /// app's windows are cannot make the underlying call safe, because what the window server does
    /// with a pinned or reassigned window is not ours to predict.
    ///
    /// So it is off, and the picks that used to weigh it now front one specific window instead. The
    /// group raise is a nicety — it surfaces siblings that were already on the Desktop in front of
    /// you — while gathering rearranges Desktops the user was not even looking at. Set to `true` to
    /// restore the traditional behaviour on the one path that still consults it.
    private static let mayRaiseWholeWindowGroup = false

    /// Brings `pid` forward by naming one of its windows, rather than by activating the app.
    ///
    /// The difference is the whole subject of `FrontProcess`: an app-level activation gathers the
    /// app's windows from other Desktops onto the one in front of you, and naming a window does not.
    /// Callers that have *not* established the window is on the current Desktop must use this one.
    ///
    /// Falls back to activation when the private symbols are gone — wrong about Spaces, but a pick
    /// that does nothing at all is worse, and it is the same trade `focusAndActivate` makes.
    private static func front(window id: CGWindowID, pid: pid_t) {
        guard FrontProcess.focus(window: id, pid: pid) else {
            Log.general.notice(
                """
                focus window \(id, privacy: .public): cannot front a single window, \
                activating pid \(pid, privacy: .public) instead
                """)
            activate(pid: pid)
            return
        }
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
            // `allWindows` is the one call here that can drag a window off the Desktop it lives on,
            // so every use of it is on the record: a window that turns up on the wrong Desktop was
            // either gathered by this line or by nothing this app did.
            Log.general.notice(
                """
                activate pid \(pid, privacy: .public) \
                (\(app?.localizedName ?? "?", privacy: .public)) allWindows=\(allWindows, privacy: .public)
                """)
            if app?.isHidden == true { app?.unhide() }
            if allWindows {
                app?.activate(options: .activateAllWindows)
            } else {
                app?.activate()
            }
        }
    }

    /// `activate`, held until `deadline` when that is still ahead of us.
    ///
    /// The one call in this file that can gather an app's windows onto the Desktop in front of the
    /// user is `activate`, and the one time it does so unbidden is while a Desktop transition is
    /// still running. Callers that may be inside one hand over the moment it is certainly finished;
    /// everyone else passes a deadline already in the past and goes straight through, which is why
    /// this is not simply an `asyncAfter` — a same-Desktop pick must not pick up a queue hop it has
    /// no reason to wait for.
    ///
    /// Deferring rather than dropping: this is a fallback path, reached only once fronting a single
    /// window has already failed, so skipping it would leave the pick dead. Late is the trade.
    private static func activate(pid: pid_t, notBefore deadline: DispatchTime, generation: UInt64) {
        guard DispatchTime.now() < deadline else {
            activate(pid: pid)
            return
        }
        focusQueue.asyncAfter(deadline: deadline) {
            guard generation == focusGeneration else { return }
            activate(pid: pid)
        }
    }

    /// Counts picks. A `settle` chain captures this at its start and stops the moment it no longer
    /// matches, so a pick still waiting for its Desktop to arrive cannot activate its app up to two
    /// seconds later and yank the user off whatever they picked in the meantime. Activation used to
    /// be synchronous with the pick, which made that impossible by construction; the wait for the
    /// Space transition is what opened the gap.
    ///
    /// Only ever touched from `focusQueue`, which is serial — no lock needed, and
    /// `nonisolated(unsafe)` is exactly that claim stated to the compiler rather than to a reader.
    private nonisolated(unsafe) static var focusGeneration: UInt64 = 0

    @discardableResult
    private static func beginFocus() -> UInt64 {
        focusGeneration &+= 1
        return focusGeneration
    }

    /// Focuses a specific window of an app by its `CGWindowID` — used when a hover-preview thumbnail
    /// is clicked, so app mode can jump straight to that window. Raises and mains the matching AX
    /// window when it can be found; for apps whose AX window list is empty (Electron/Catalyst) it
    /// falls back to just activating the app.
    ///
    /// `placement` is the whole window/Space map, for a caller that has already read one — `focusApp`
    /// builds it to choose this window in the first place. Handing it over is not only the round
    /// trips saved: a re-read here can come back nil for a window that is demonstrably on a Desktop,
    /// and a nil is read below as "no Space to switch to", which ends in the blind raise that gathers
    /// the window onto the Desktop in front of the user.
    ///
    /// The whole map rather than this one window's entry, because the decision below turns on the
    /// app's *other* windows: whether any of them is already on screen is what decides whether macOS
    /// travels to this one or drags it here. It is the same single enumeration either way — `spaceState`
    /// builds the map, answers for one window and throws the rest away.
    static func focusWindow(
        id: CGWindowID, pid: pid_t, placement known: [CGWindowID: SpaceMover.SpaceState]? = nil
    ) {
        focusQueue.async {
            let generation = beginFocus()

            // A minimized window sits in the Dock, on no Desktop at all: there is nothing to switch
            // to first, it can never join the on-screen list the gate below waits on, and the
            // restore is the whole of the work. Not an edge case — the hover preview offers
            // minimized windows as thumbnails, so this is a path users reach by clicking one.
            //
            // Asked of the window server, not of Accessibility. `AX.isMinimized` on the app's AX
            // window list was the whole of this test, and it fails silently for any app that does
            // not publish the window: Ghostty lists one `AXWindow` while owning six, so a click on a
            // minimized thumbnail of the other five found no element, fell past this branch into the
            // Space path, correctly found no Space — minimized windows have none — and finished in
            // an activation that brought the app forward and left the window in the Dock. A dead
            // click; the logs show it hit every preview pick that was not already on screen.
            //
            // On no Space *and* not on screen is the signature of the Dock specifically. A window on
            // another Desktop is off screen too, but it does have a Space, so it still takes the
            // reveal path below.
            //
            // Hidden apps are excluded rather than tested, because they answer the same way for a
            // different reason and the cost of confusing the two is asymmetric: routing a hidden
            // app's off-Desktop window to the restore path would skip the Space switch it needs,
            // while routing a docked window through the reveal path merely takes the slower way to
            // the same raise. So anything hidden goes below and unhides first.
            let isHidden = NSRunningApplication(processIdentifier: pid)?.isHidden == true
            // `var` because the system-switch attempt below can move the window and hand back a
            // fresher reading; everything after that point must use the new one.
            var placed = known ?? SpaceMover.windowSpaces()
            var placement = placed[id]
            if SpaceMover.isAvailable, !isHidden, placement == nil, !isOnScreen(window: id) {
                restoreFromDock(window: id, pid: pid, generation: generation)
                return
            }

            // A hidden app's windows are likewise in no on-screen list, so the unhide has to happen
            // out here: inside the gate it was unreachable, because the gate could not open until it
            // had already happened. Its windows do still live on a Desktop, though, so the Space
            // logic below still applies and the poll waits for the unhide to land.
            if isHidden {
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
            // Read *before* the switch is issued: the notification it waits on can land while the
            // reveal call is still returning, and a count taken afterwards would miss it and then
            // wait for a second transition that never comes.
            // Ask macOS to travel there before doing it ourselves.
            //
            // `CGSManagedDisplaySetCurrentSpace` changes which Desktop is current without running
            // the transition macOS runs for a real switch, and the difference is visible: captured
            // one Desktop at a time across a private-call sweep, every screenshot came back with two
            // or three apps' menu bars drawn on top of each other, and a Chrome window belonging to
            // Desktop 4 rendered along the bottom edge of Desktop 6. The windows had not moved —
            // their Space assignment never changed — they were simply still being drawn. A genuine
            // Desktop change re-composites and clears them, which is exactly the "as soon as you
            // move to a new desktop they go back where they belong" report.
            //
            // Activating the app is the one way to get the *system's* switch, animation and all, and
            // on the default Mission Control setting that is precisely what it does: travel to the
            // window rather than drag it over. Only worth trying under that setting — with the
            // checkbox off the same call does the opposite, which is the behaviour every "gathering"
            // note in this file describes. `settleBySystemSwitch` polls for the arrival and reports
            // whether it got one; the private switch below is the fallback when it did not.
            //
            // And only when the app has nothing on screen already, which is the difference between
            // the two things activation can do. The Mission Control rule is "switch to a Space with
            // open windows for that application" — *a* Space, *any* of its windows. An app with a
            // window on some Space that is currently showing already satisfies it, so macOS has
            // nothing to travel to, and what the activation does instead is bring the app forward
            // right here and haul its off-Desktop windows over with it. That is the whole of the
            // reported bug, and it is why it needs two screens to appear: a second display is what
            // lets an app have a window on screen *and* a window a Desktop away at the same time.
            // Measured on it — Chrome with a window fullscreen on the second display and another on
            // Desktop 4, picked from Desktop 1: declined both rounds, twice, and the Desktop 4
            // window came over. The same build travelled in under 400ms for Teams, Ghostty, Spotify
            // and DataGrip in the same minute, and what distinguishes those is only that none of
            // them had a window on screen anywhere.
            //
            // So the test is not "will macOS travel", which cannot be asked, but "can it" — and when
            // it cannot, asking anyway is not a wasted second, it is the gather itself. The private
            // switch below handles this case correctly and is measured to composite properly.
            if let state = placement, state.windowSpace != state.currentSpace,
                SpaceMover.systemSwitchesSpaceOnActivate,
                !hasWindowOnScreen(pid: pid, placement: placed)
            {
                switch settleBySystemSwitch(
                    window: id, pid: pid, state: state, generation: generation)
                {
                case .arrived, .superseded:
                    return
                case .declined(let refreshedPlacement):
                    // Where everything is *now*, which is not necessarily where it was: the
                    // activation above may have moved the window, or moved the display to another of
                    // this app's Desktops. Both readings below act on this, and acting on the
                    // pre-activation one would send the user to a Desktop it had just left.
                    //
                    // The whole map is replaced, not just this window's entry. `hasWindowOnScreen`
                    // below is asked of `placed`, and after a travel to another of the app's Desktops
                    // that answer has inverted — the app has a window on screen now, and the veto
                    // must see it. Refreshing only `placement` left the veto reading pre-travel facts
                    // and letting the pick continue into the private switch, which is how a wrong-
                    // Desktop travel became a wrong-Desktop travel *plus* a phantom half-switch.
                    //
                    // Only when there *is* a reading. A placement read that failed is not a
                    // statement that the window has no Desktop, and adopting its emptiness turned it
                    // into one: `reveal` then reports nothing to switch to, `settle` is told nothing
                    // is in flight and may act blind, and the raise it makes gathers the window onto
                    // the Desktop in front of the user — the one outcome this whole path exists to
                    // prevent, and the "I picked a window on Desktop 2 and it came to Desktop 1,
                    // then went back when I switched Desktops" report. Keeping the last good reading
                    // falls back to the private switch instead, which is what the fallback is for.
                    if !refreshedPlacement.isEmpty {
                        placed = refreshedPlacement
                        placement = refreshedPlacement[id] ?? placement
                    }
                }
            }

            // Out of ways to move the display — so stop, rather than move the bookkeeping and leave
            // the screen behind.
            //
            // `reveal` below is the private switch, and on a two-display machine it is measured not
            // to switch anything. `CGSShowSpaces` + `CGSHideSpaces` + `CGSManagedDisplaySetCurrentSpace`
            // update the window server's *record* of which Desktop is current and never make the
            // display perform a transition: every query afterwards reports the destination while the
            // panel keeps compositing the Desktop the user was already on, with the window fronted
            // after it painted on top. That is the whole of the reported bug — "I clicked Chrome on
            // Desktop 3 and it came over to Desktop 1, and went back the moment I switched Desktops
            // by hand". Nothing moved either time; the second half was the next genuine transition
            // re-compositing and revealing where the window had been all along.
            //
            // Confirmed against the one instrument that cannot be fooled here. Every API — including
            // `screencapture`, which renders what the window server *believes* — reported the switch
            // as a success; the user's eyes reported the opposite, and a switch performed four ways
            // (show/hide/set, hide/show/set, set alone, and a real Mission Control transition) moved
            // the display only on the last of them.
            //
            // And there is no fourth way from here. Every remaining candidate has now been measured
            // directly, on a two-display desk with the second display holding a single Space — which
            // is what makes this reachable at all, since an app with a window there is permanently
            // "on screen" and so permanently in this branch.
            //
            // Synthetic ⌃-arrow is ignored. This used to walk the Desktops with Mission Control's own
            // shortcut, and the note here claimed the posting only failed from an untrusted harness.
            // Both halves were wrong: posting the identical events from a *trusted* scratch binary
            // moved neither display, and this app's own log shows the same walk giving up ("the
            // Mission Control shortcut moved nothing") on every pick that reached it. The walk cost
            // half a second and posted a stray ⌃-arrow into whatever app was frontmost, so it is gone
            // rather than merely unused.
            //
            // Activation will not travel for this app whatever it is asked: plain, fronted-first
            // (`FrontProcess.raise` then activate), and with the app's on-screen window *minimized*
            // so it owned nothing on screen anywhere — all three measured to stay put. The control
            // rules out the harness: an app in the same state but with nothing on screen travelled in
            // ~600ms through the very same call. Reaching the window would need the Dock's own
            // connection, which is what the tools that manage it inject into, and that needs SIP
            // partly disabled. So this is a real limit, not a missing trick.
            //
            // Doing nothing is the better failure. A pick that silently does not happen is a dead
            // click; a pick that smears a window across the Desktop the user is looking at reads as
            // the switcher having *moved their window*, and sends them hunting for it. The fronting
            // is skipped with it, which costs nothing — off-Space it is measured inert, and it is
            // only in company with the half-switch above that it paints anything.
            //
            // The preview strip asks `canReach` the same question before it draws, so a thumbnail
            // that would land here is badged as unreachable rather than left looking clickable.
            if let state = placement,
                !canReach(
                    state: state,
                    appHasWindowOnScreen: hasWindowOnScreen(pid: pid, placement: placed))
            {
                Log.general.notice(
                    """
                    focus window \(id, privacy: .public): pid \(pid, privacy: .public) has a window \
                    on screen, so macOS will not travel to space \
                    \(state.windowSpace, privacy: .public); leaving the Desktop alone
                    """)
                return
            }

            let changesBefore = spaceChanges.value
            let reveal = SpaceMover.reveal(window: id, state: placement)
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
                generation: generation, actWhenUnreached: !reveal.switched,
                // Only a pick that actually issued a switch has a transition to wait on. Without a
                // switch there is nothing in flight and no Desktop to drag the window off, so the
                // common same-Desktop pick keeps its two-hundredths of a second.
                awaitingSpaceChange: reveal.switched ? changesBefore : nil,
                notBefore: reveal.switched ? .now() + spaceSettleDelay : .now())
        }
    }

    /// Activates `pid` and waits to see whether macOS travels to the window's Desktop by itself.
    ///
    /// What the attempt to let macOS travel came to.
    private enum SystemSwitch {
        /// Arrived on the window's Desktop and the window was fronted there. The pick is over.
        case arrived
        /// The system did not travel, or travelled to a different Desktop of the same app. The
        /// caller falls back to the private switch — and must re-read placement first, since
        /// `placement` says where every one of the app's windows is *now*.
        ///
        /// Empty when the read failed, which is not the same as "nothing is placed" and must not be
        /// adopted as one — see the call site.
        case declined(placement: [CGWindowID: SpaceMover.SpaceState])
        /// A later pick replaced this one. Do nothing at all; the pick that superseded it owns the
        /// screen now, and falling back would drag the user off whatever they picked instead.
        case superseded
    }

    /// Activates `pid` — twice, if the first ask goes unanswered — and waits to see whether macOS
    /// travels to the window's Desktop by itself.
    ///
    /// Activation has two possible outcomes and they are opposites: travel to the window, or drag
    /// the window here. Which one you get is the Mission Control setting the caller checks. The
    /// setting is a statement of intent, though, not a guarantee — so this verifies, and the verdict
    /// is which Desktop we ended up on. Landing on the window's original Space is a switch; the
    /// window turning up on the Space we started from is a drag.
    ///
    /// A drag is reported as `declined` *with a fresh placement*, and that pairing is the point. The
    /// window is no longer where the caller's map says it is, and a fallback that trusted the stale
    /// reading would issue a private switch to the Desktop the window just left — travelling the
    /// user to an empty Desktop while the window sat behind them on the one they started from.
    ///
    /// Polls rather than waiting a fixed interval: the system's transition has no completion signal
    /// we can read (see `spaceSettleDelay`), and stopping the moment it lands keeps the pick quick.
    private static func settleBySystemSwitch(
        window id: CGWindowID, pid: pid_t, state: SpaceMover.SpaceState, generation: UInt64
    ) -> SystemSwitch {
        Log.general.notice(
            """
            focus window \(id, privacy: .public): asking macOS to travel to space \
            \(state.windowSpace, privacy: .public) from \(state.currentSpace, privacy: .public)
            """)
        // Blocks `focusQueue` while it waits, which is why the whole budget is under a second rather
        // than the couple of seconds the rest of this file allows itself: a pick that lands during
        // the wait queues behind it, and a switcher that stutters under fast repeated picks would be
        // its own bug.
        //
        // Spent in two rounds rather than one long wait, and the round boundary is where the
        // activation is re-issued. A decline is far more often a request macOS dropped than macOS
        // refusing to travel, and the log is unambiguous about it: every declined pick recorded so
        // far was repeated within a few minutes and travelled on the retry — Ghostty 6 -> 1 declining
        // after the full wait at 10:47:58, the identical pick landing in 410ms at 10:50:46. Nothing
        // about the two picks differs, so a second ask is the difference between them. Asking twice
        // is also the *only* fix worth making here: the private switch below re-points the window
        // server's current Space without the Dock's involvement, and every way it can leave the
        // display half-composited is a way for the picked window to appear on the Desktop the user
        // was already on. Fewer trips down that path is worth more than any hardening of it.
        //
        // The first round is the longer one, and it is sized to clear the arrival distribution
        // rather than to sit inside it. Re-measured across 145 switches: every arrival landed
        // between 380ms and 444ms, with 79 of them — 54% — past the 400ms of sleep the first round
        // used to budget. Twenty turns therefore ended a hair after the slowest arrivals, and the
        // only thing keeping those picks working was the second round catching them *after* it had
        // already thrown a fresh activation at a transition that was still running, which is
        // precisely what the paragraph above says must not happen. All three declines logged in
        // that window reached the second round and none of them travelled in it.
        //
        // 28 turns puts the boundary ~120ms past the slowest measured arrival, so a switch that is
        // coming lands in the first round and is never asked twice. The eight turns left to the
        // second round keep the re-ask for the case it was written for — a request macOS dropped
        // outright, which answers immediately or not at all — and hold the total budget where it
        // was, since it is `focusQueue` that pays for the wait.
        //
        // Only the display's current Space is read per turn — see `SpaceMover.currentSpace`. Asking
        // for the *window's* placement here instead would rebuild the whole display/Space map on
        // every one of these turns, which is the loop `spaceState` documents as the thing not to do.
        // That is also what makes a fine-grained poll affordable: the turn is one round-trip, so the
        // interval can be set by how promptly we want to notice the arrival rather than by what each
        // check costs. It used to be 50ms, which put up to a full 50ms of pure granularity between
        // macOS landing on the Desktop and this noticing — a fifth of the wait, and none of it work.
        rounds: for round in 0..<2 {
            if round > 0 {
                Log.general.notice(
                    """
                    focus window \(id, privacy: .public): no travel yet, asking pid \
                    \(pid, privacy: .public) a second time
                    """)
            }
            activate(pid: pid)
            for _ in 0..<(round == 0 ? 28 : 8) {
                usleep(20_000)
                guard generation == focusGeneration else { return .superseded }
                let now = SpaceMover.currentSpace(ofDisplay: state.display)
                guard now == state.windowSpace else {
                    // Travelled, but not to the Desktop we asked for — macOS picked a different one
                    // of this app's Spaces. Measured on Chrome with windows on two Desktops: picking
                    // the one on Space 4 activated the app and landed on Space 5, and the front
                    // window by z-order was the Space 4 one, so the destination is neither what we
                    // asked for nor predictable from the window list.
                    //
                    // Stop the moment it is seen. Polling on for the rest of the budget cannot help —
                    // macOS has already made its choice and will not travel twice for one activation
                    // — and the second round would only ask again and move the user a second time.
                    if let now, now != state.currentSpace {
                        Log.general.notice(
                            """
                            focus window \(id, privacy: .public): macOS travelled to space \
                            \(now, privacy: .public) instead of \(state.windowSpace, privacy: .public); \
                            giving up rather than asking again
                            """)
                        break rounds
                    }
                    continue
                }
                Log.general.notice(
                    """
                    focus window \(id, privacy: .public): macOS switched to space \
                    \(state.windowSpace, privacy: .public) on its own
                    """)
                // The app is up and on the right Desktop; this puts the *picked* window in front of
                // its siblings. Safe here in a way it is not before arrival — see `focusAndActivate`.
                //
                // "Arrived" is a weaker claim here than on the fallback path, and the deadline is
                // what accounts for the difference. The gate above is the window server's `Current
                // Space` field, which `spaceSettleDelay` documents as flipping while the transition
                // still has several hundred milliseconds to run — so this line can be reached
                // mid-transition, where the fallback path has waited the delay out before it acts.
                //
                // The raise and the front are sent anyway, because neither is what relocates a
                // window: an off-Space `AXRaise` is measured to do nothing, and `FrontProcess` names
                // one window by id rather than gathering an app's. Only the *activation fallbacks*
                // inside are the gathering call, and only those are held until the transition is
                // certainly over. On the 152 logged picks that reached here `FrontProcess` succeeded
                // every time, so the deadline costs the common case nothing at all — it is the
                // failure branch that would otherwise activate into a running transition and haul
                // the app's other windows over.
                focusAndActivate(
                    window: id, pid: pid, generation: generation,
                    activationNotBefore: .now() + spaceSettleDelay)
                return .arrived
            }
        }

        // It did not travel, or travelled somewhere else. One full placement read now — the only one
        // this function takes — both to say in the log which way it went and to hand the caller a map
        // it can act on.
        //
        // The *whole* map rather than this window's entry, which is what it used to return. The
        // caller's decision turns on where the app's *other* windows are, and after an activation
        // that moved the display those are exactly the facts that went stale: land on another of the
        // app's Desktops and the app now has a window on screen, which is the one condition that must
        // stop the pick going any further. Handing back a single `SpaceState` left the caller testing
        // that against its pre-travel map, concluding the app had nothing on screen, and falling
        // through to the private switch — the half-composited one that paints the window onto the
        // Desktop the user is looking at.
        let refreshedPlacement = SpaceMover.windowSpaces()
        let refreshed = refreshedPlacement[id]
        if let refreshed, refreshed.windowSpace != state.windowSpace {
            Log.general.notice(
                """
                focus window \(id, privacy: .public): activation dragged it from space \
                \(state.windowSpace, privacy: .public) to \(refreshed.windowSpace, privacy: .public) \
                instead of travelling
                """)
        } else {
            Log.general.notice(
                "focus window \(id, privacy: .public): macOS did not travel; using the private switch"
            )
        }
        return .declined(placement: refreshedPlacement)
    }

    /// Brings a minimized window back out of the Dock.
    ///
    /// Accessibility is the only way to unminimize — there is no window-server call for it — so the
    /// work here is entirely about getting an `AXUIElement` for a window whose app may not be
    /// offering one yet. Apps that build their tree lazily (Chromium, Electron) answer with nothing
    /// until they are activated, and apps like Ghostty publish only their front window whatever the
    /// state. Activating fixes both, so a failed lookup is retried once the app is up rather than
    /// treated as the end of it.
    ///
    /// The last branch logs instead of returning quietly. A pick that cannot be honoured is worth a
    /// line: silence here is indistinguishable from the bug this replaced.
    ///
    /// Neither bring-forward here is an `activate`, and that is not caution — it is the correctness
    /// of this branch's *entry* condition. "On no Space and not on screen" is meant to name the
    /// Dock, but it also names a window the window server declined to place, and it declines often:
    /// measured on macOS 26, `CGSCopyWindowsWithOptionsAndTags` places exactly *one* window per app
    /// — the frontmost — for Ghostty and VS Code, at every one of `0x0`, `0x2` and `0x7`. So a
    /// perfectly ordinary window sitting on Desktop 4 arrives here looking minimized, and an
    /// app-level activation would have hauled it onto the Desktop in front of the user. Fronting one
    /// named window cannot do that, and it still wakes the lazy accessibility trees below.
    private static func restoreFromDock(window id: CGWindowID, pid: pid_t, generation: UInt64) {
        if let element = axWindow(id: id, pid: pid) {
            raise(element: element)
            front(window: id, pid: pid)
            Log.general.notice("focus window \(id, privacy: .public): restored from the Dock")
            return
        }
        front(window: id, pid: pid)
        focusQueue.asyncAfter(deadline: .now() + 0.15) {
            guard generation == focusGeneration else { return }
            if let element = axWindow(id: id, pid: pid) {
                raise(element: element)
                Log.general.notice(
                    "focus window \(id, privacy: .public): restored from the Dock after fronting")
                return
            }
            // Fronting a single window is what wakes most lazily-built accessibility trees, but it
            // is a weaker signal than activation and a Chromium or Electron host can sleep through
            // it — and this is the branch where the window really is in the Dock, since nothing else
            // has produced it. So the app-level activation comes back for one last try rather than
            // leaving a minimized Chrome unrestorable, which is the bug the retry was written for.
            //
            // Its cost is the one this file spends the rest of its length avoiding: activation can
            // drag the app's *other* windows off the Desktops they live on. Paid only here, only
            // after fronting has already failed, and only to turn a dead pick into a live one.
            Log.general.notice(
                """
                focus window \(id, privacy: .public): fronting did not wake pid \
                \(pid, privacy: .public); activating to reach its window list
                """)
            activate(pid: pid)
            restoreWhenListed(window: id, pid: pid, attempts: 8, generation: generation)
        }
    }

    /// Polls `pid`'s Accessibility list for `window` after an activation, and unminimizes it the
    /// moment it turns up.
    ///
    /// A single wait cannot do this job, and the log says so: a lone 200ms shot at the list is what
    /// produced "does not list it over Accessibility — cannot restore" on a pick that had nothing
    /// wrong with it but its timing. Both halves of the wait are unbounded from here. `activate` is
    /// itself a hop to the main thread before the app is even asked to come up, and a lazily-built
    /// accessibility tree (Chromium, Electron) is published some time after that — with no signal to
    /// wait on for either. This is the same reasoning, and the same shape, as `settle`.
    ///
    /// Polling costs nothing while it waits: `asyncAfter` leaves `focusQueue` free between turns,
    /// unlike the blocking wait in `settleBySystemSwitch` whose cap is tight for exactly that
    /// reason. So the budget here is set by how long an app may reasonably take to answer rather
    /// than by what a later pick can afford to queue behind — and a later pick does not queue behind
    /// it at all, since the generation guard drops this the moment one arrives.
    ///
    /// Giving up is still a real outcome and still logged: the window is in the Dock and the only
    /// call that can bring it out needs an `AXUIElement` the app will not hand over.
    private static func restoreWhenListed(
        window id: CGWindowID, pid: pid_t, attempts: Int, generation: UInt64
    ) {
        guard attempts > 0 else {
            Log.general.notice(
                """
                focus window \(id, privacy: .public): minimized, and pid \
                \(pid, privacy: .public) does not list it over Accessibility — cannot restore
                """)
            return
        }
        focusQueue.asyncAfter(deadline: .now() + 0.1) {
            guard generation == focusGeneration else { return }
            guard let element = axWindow(id: id, pid: pid) else {
                restoreWhenListed(
                    window: id, pid: pid, attempts: attempts - 1, generation: generation)
                return
            }
            raise(element: element)
            Log.general.notice(
                "focus window \(id, privacy: .public): restored from the Dock after activating")
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
    /// How long after a Space switch is issued before anything may touch the window.
    ///
    /// A measured number standing in for a signal macOS does not offer. There is no "the transition
    /// has finished" call — `CGSGetSpaceTransitionState` and its siblings do not exist on macOS 26 —
    /// and every cheap proxy was measured lying:
    ///
    /// * the window server's `Current Space` field flips **0.2ms** after the switch is issued, long
    ///   before anything moves on screen;
    /// * `activeSpaceDidChange` posts within the first frame or two;
    /// * on-screen membership does not track Spaces at all. Sampled every 25ms across a switch, the
    ///   count of the *outgoing* Desktop's windows in `.optionOnScreenOnly` never changed — 16 of 18
    ///   before, 16 of 18 a second later, with the incoming Desktop's windows listed the whole time.
    ///   That is why `isOnScreen` opened the gate on the first poll of every pick ever logged.
    ///
    /// So the gate that was meant to keep a raise out of the transition never closed once, and the
    /// window-relocation it exists to prevent had a clear run. Waiting a fixed interval is the only
    /// honest option left; it costs a cross-Desktop pick a fraction of a second and costs the common
    /// same-Desktop pick nothing at all.
    private static let spaceSettleDelay: TimeInterval = 0.45

    private static func settle(
        window id: CGWindowID, pid: pid_t, attempts: Int, delay: TimeInterval,
        generation: UInt64, actWhenUnreached: Bool, awaitingSpaceChange: UInt64?,
        notBefore: DispatchTime
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
            // Two gates. The notification says a transition began and landed; `notBefore` says
            // enough of the clock has run for it to be over. Neither is sufficient alone — see
            // `spaceSettleDelay` for what each one was measured to be worth.
            let arrived = awaitingSpaceChange.map { spaceChanges.value > $0 } ?? true
            let waited = DispatchTime.now() >= notBefore
            // Only the switched path has anything to say: a same-Desktop pick opens both gates on
            // its first attempt. Which gate is holding is the whole question this logging exists to
            // answer.
            //
            // On-screen membership is *not* a gate any more, only a note in the line below. It was
            // one, and it never held: measured across a switch, the outgoing Desktop's windows stay
            // in `.optionOnScreenOnly` throughout and the incoming Desktop's are in it before the
            // switch is even issued. Kept because a pick that misbehaves is worth knowing the
            // on-screen reading for — just never again worth trusting.
            //
            // Read inside the branch rather than above it, which is the whole reason the two
            // comments were merged. `isOnScreen` is a `CGWindowListCopyWindowInfo` call, and reading
            // it eagerly charged every same-Desktop pick a window-server round trip for a value
            // that path never interpolates — the one pick shape in this file that is otherwise
            // measured in single-digit milliseconds.
            if awaitingSpaceChange != nil {
                Log.general.notice(
                    """
                    focus window \(id, privacy: .public): \
                    transition=\(arrived ? "landed" : "in flight", privacy: .public) \
                    waited=\(waited, privacy: .public) \
                    onScreen=\(isOnScreen(window: id), privacy: .public), \
                    \(attempts, privacy: .public) attempts left
                    """)
            }
            guard arrived, waited else {
                settle(
                    window: id, pid: pid, attempts: attempts - 1, delay: delay,
                    generation: generation, actWhenUnreached: actWhenUnreached,
                    awaitingSpaceChange: awaitingSpaceChange, notBefore: notBefore)
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
    ///
    /// `activationNotBefore` holds the two `activate` fallbacks — and only those — until a Desktop
    /// transition the caller knows may still be running has certainly finished. Defaults to now,
    /// which is right for every caller that already waited: `settle` opens on `spaceSettleDelay`,
    /// and a same-Desktop pick has no transition to sit out. Only `settleBySystemSwitch` passes a
    /// real one; see the note at its call.
    private static func focusAndActivate(
        window id: CGWindowID, pid: pid_t, generation: UInt64,
        activationNotBefore: DispatchTime = .now()
    ) {
        let raised = raise(window: id, pid: pid)
        // Front *this window*, not its app. `NSRunningApplication.activate()` is app-level, and on a
        // machine with several Desktops that is the very relocation the Space gate above exists to
        // prevent, arriving one line later by another route: it gathers the app's *other* windows
        // onto the Desktop in front of you, so reaching one Ghostty window still dragged the one on
        // Desktop 4 across. `FrontProcess` names the window to the window server instead, and the
        // siblings stay where the user left them. False means the private symbols are gone — plain
        // activation is wrong about Spaces, but a pick that does nothing at all is worse.
        let fronted = FrontProcess.focus(window: id, pid: pid)
        if !fronted {
            activate(pid: pid, notBefore: activationNotBefore, generation: generation)
        } else {
            verifyFront(
                window: id, pid: pid, generation: generation, notBefore: activationNotBefore)
        }
        // Where things actually ended up, half a second after the dust settles. The difference that
        // matters: `window == current` on the Desktop we switched *to* means the pick worked, while
        // the window having moved to the Desktop we came *from* means something relocated it.
        focusQueue.asyncAfter(deadline: .now() + 0.5) {
            // A superseded pick's diagnostic is not worth a whole display/Space enumeration on the
            // serial queue the pick that replaced it is waiting to use.
            guard generation == focusGeneration, let state = SpaceMover.spaceState(of: id) else {
                return
            }
            let stack = onScreenStack()
            Log.general.notice(
                """
                focus window \(id, privacy: .public): after activation \
                windowSpace=\(state.windowSpace, privacy: .public) \
                current=\(state.currentSpace, privacy: .public) \
                fronted=\(fronted, privacy: .public) \
                raised=\(raised, privacy: .public) \
                zrank=\(zRank(of: id, in: stack), privacy: .public) \
                top=[\(zTop(stack), privacy: .public)]
                """)
        }
        // Apps that build their accessibility tree lazily (Chromium, Electron) report *no* windows
        // until they are fronted, so the raise above found nothing to raise. Retry now that the app
        // is coming up — the only thing that makes the pick land for those apps.
        //
        // The fronting that wakes them is `FrontProcess` rather than the activation this used to
        // rely on, which suits this case better than the old order did: it names the window by id,
        // so the *right* window is already in front even while AX cannot see it, where activating
        // surfaced whichever window the app itself thought was frontmost.
        guard !raised else { return }
        focusQueue.asyncAfter(deadline: .now() + 0.15) {
            guard generation == focusGeneration else { return }
            raise(window: id, pid: pid)
        }
    }

    /// Checks that the private front-process call actually brought the app forward, and falls back
    /// to ordinary activation when it did not.
    ///
    /// `_SLPSSetFrontProcessWithOptions` returning success means the window server accepted the
    /// request, not that the app came up: a wedged process, or one that re-fronts a window of its
    /// own in response, leaves a pick that reported success and did nothing. Since this is the only
    /// path that fronts the window now, an unnoticed failure here is a pick that silently no-ops.
    ///
    /// The fallback is safe by this point in a way it is not earlier: the Space gate has already
    /// been passed, so the window is on the Desktop in front of us, and `FrontProcess` has already
    /// made it the app's front window — so there is nothing left elsewhere for a plain activation to
    /// drag over. That is exactly what makes it usable as a backstop rather than a reintroduction of
    /// the bug the fronting exists to avoid.
    ///
    /// `notBefore` is the caller's transition deadline. The 0.2s here is time enough for the front
    /// to take, not time enough for a Desktop transition to end, so the later of the two is what the
    /// fallback activation waits for.
    private static func verifyFront(
        window id: CGWindowID, pid: pid_t, generation: UInt64, notBefore: DispatchTime
    ) {
        focusQueue.asyncAfter(deadline: max(DispatchTime.now() + 0.2, notBefore)) {
            guard generation == focusGeneration else { return }
            // `frontmostApplication` is AppKit state, so it is asked for on the main thread — and
            // the answer is carried back here rather than acted on there.
            //
            // The guard above cannot cover the hop, and the frontmost test does not stand in for it:
            // a later pick having already brought another app forward is *exactly* the reading
            // `frontmost != pid`, so acting on it activates the superseded pick and hauls the user
            // back off whatever they picked instead — the two-second yank `focusGeneration` exists
            // to prevent, at a fifth of a second. The gap is short, but it is widest under a fast
            // repeated ⌘-Tab, when the main thread is busy with the panel's own layout pass and a
            // new pick is most likely to be arriving. So the generation is re-checked after the
            // round trip, back on `focusQueue` — the only thread it may be read from.
            DispatchQueue.main.async {
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                focusQueue.async {
                    guard generation == focusGeneration else { return }
                    guard front == pid else {
                        Log.general.notice(
                            "focus window \(id, privacy: .public): front did not take, activating pid \(pid, privacy: .public)"
                        )
                        activate(pid: pid)
                        return
                    }
                    // The app came forward but its window did not, which is a real and separate
                    // failure this used to be blind to: `frontmostApplication` is an *app* fact, and
                    // it reports success while the picked window sits behind the window of the app
                    // the user just left. Measured on Messages against Ghostty — `raised=true`,
                    // `fronted=true`, frontmost=Messages, and the window at z-rank 1 with Ghostty
                    // above it. Every call had done its job and the result was still wrong.
                    //
                    // The override arrives after the raise rather than instead of it: the panel is
                    // dismissed a turn before the focus work runs, and the front it hands back lands
                    // on top of what we just ordered. Re-asserting is what fixes it, and the proof is
                    // the workaround users found on their own — a second ⌘-Tab to the same app, which
                    // is precisely these two calls run again, and which always worked.
                    //
                    // Once, not a loop. This is a race with a dismissal that has already happened by
                    // the time we look, so a single re-assert either wins or the pick was superseded;
                    // retrying past that would fight whatever the user did next.
                    // One snapshot, read once. Taking a second for the log meant the line could name
                    // a rank the guard had not seen — and paid for another full window-server
                    // enumeration on the focus path to do it.
                    let rank = zRank(of: id, in: onScreenStack())
                    guard rank > 0 else { return }
                    Log.general.notice(
                        """
                        focus window \(id, privacy: .public): pid \(pid, privacy: .public) is front \
                        but the window is at z-rank \(rank, privacy: .public); re-raising
                        """)
                    raise(window: id, pid: pid)
                    _ = FrontProcess.focus(window: id, pid: pid)
                }
            }
        }
    }

    /// One layer-0 window from the on-screen list, reduced to what the pick diagnostics ask of it.
    ///
    /// A type rather than the raw `[String: Any]` so `zRank` becomes a pure function of a stack and
    /// can be tested against one — the same seam `frontWindow` uses, and for the same reason: its
    /// real input is a window-server snapshot no test can arrange.
    struct StackedWindow: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let owner: String
        let frame: CGRect
    }

    /// The on-screen layer-0 windows, front first.
    ///
    /// Layer 0 only, so panels and menus — including this app's own switcher — are neither counted
    /// as windows a pick failed to get above nor named as the thing in its way.
    ///
    /// Taken once and passed to both readers below. They used to fetch one each, which is two
    /// window-server round-trips for a single log line and — worse — two moments: a stack that moved
    /// between them produced a rank and a list of occupants that disagreed about what was on top.
    private static func onScreenStack() -> [StackedWindow] {
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { entry in
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                let id = entry[kCGWindowNumber as String] as? CGWindowID
            else { return nil }
            let bounds = entry[kCGWindowBounds as String] as? [String: CGFloat] ?? [:]
            return StackedWindow(
                id: id,
                pid: entry[kCGWindowOwnerPID as String] as? pid_t ?? 0,
                owner: entry[kCGWindowOwnerName as String] as? String ?? "?",
                frame: CGRect(
                    x: bounds["X"] ?? 0, y: bounds["Y"] ?? 0,
                    width: bounds["Width"] ?? 0, height: bounds["Height"] ?? 0))
        }
    }

    /// How many *other apps'* windows cover `window`, or -1 when it is not on screen.
    ///
    /// The signal the pick diagnostics were missing. "fronted=true" says the window server accepted
    /// the front change, not that the window ended up in front — and those two came apart for a
    /// Catalyst app that reported success on every count while staying visibly buried. Rank 0 is the
    /// claim worth logging, because it is the one the user can see.
    ///
    /// A raw position in the z-order was not that claim, and two filters separate them:
    ///
    /// *An app's own windows do not bury it.* Chrome floats a 347×22 link-preview bubble over its
    /// window whenever the cursor rests on a link — a child of the very window being raised. Measured
    /// across a day: three picks of Chrome's real window logged `zrank=1` with
    /// `Google Chrome#32382@347x22` on top, two of them spending a re-raise on a stack that was
    /// already correct. The failure worth catching is being buried under *another app*, which is what
    /// the Messages-behind-Ghostty case in `verifyFront` was.
    ///
    /// *A window that does not overlap does not cover.* This reads every display, so a window
    /// genuinely in front on its own monitor used to rank behind whatever was frontmost on another
    /// one. Overlap is the honest test on a single display too — a window beside the target obscures
    /// nothing.
    ///
    /// A target the window server reports with no bounds intersects nothing and so ranks 0. That is
    /// the right answer for a window with no area, and the wrong one only if `kCGWindowBounds` ever
    /// goes missing on a window that has some — in which case this reports success rather than a
    /// phantom failure, which is the safer of the two ways to be wrong.
    static func zRank(of window: CGWindowID, in stack: [StackedWindow]) -> Int {
        guard window != 0, let index = stack.firstIndex(where: { $0.id == window }) else {
            return -1
        }
        let target = stack[index]
        return stack[..<index].filter {
            $0.pid != target.pid && $0.frame.intersects(target.frame)
        }.count
    }

    /// The windows sitting in front of the on-screen stack, as `Owner#id@WxH`.
    ///
    /// Deliberately unfiltered where `zRank` is not. Naming the occupants is what separates "buried
    /// under the app I came from" from "second only to a window on the other screen", and the size is
    /// what exposes an app's invisible helper surfaces when one of them is the thing in the way —
    /// both readings `zRank` now discounts, so the log has to keep showing them or the discounting
    /// becomes unfalsifiable from the outside.
    ///
    /// App names only — no window titles, which carry document names and message subjects.
    private static func zTop(_ stack: [StackedWindow], count: Int = 3) -> String {
        guard !stack.isEmpty else { return "?" }
        return stack.prefix(count)
            .map { "\($0.owner)#\($0.id)@\(Int($0.frame.width))x\(Int($0.frame.height))" }
            .joined(separator: " ")
    }

    /// Whether the window is currently displayed — false while it sits on another Desktop, which is
    /// how a Desktop transition is known to have finished. Public `CGWindowList`, no private API.
    ///
    /// Snapshots the on-screen list and looks for the window in it, rather than asking about the one
    /// window directly. The direct form is what this used to do, and it answered `true` for
    /// everything: `.optionOnScreenOnly` *ignores* the `relativeToWindow` argument, so passing a
    /// window id alongside it returns every on-screen window rather than filtering to that one.
    /// Verified against a window id that named nothing at all — it came back with the full list of
    /// twenty-five. The gate was therefore open on its first attempt for every pick, the retry
    /// budget below it was unreachable, and so was the give-up branch that exists to keep a pick from
    /// dragging a window off the Desktop it lives on.
    ///
    /// Costs a full window-server snapshot, and runs up to fourteen times per switch on the
    /// latency-sensitive focus path — but a cheap answer that is always `true` is not an answer.
    private static func isOnScreen(window: CGWindowID) -> Bool {
        guard window != 0 else { return true }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return true }
        return list.contains { $0[kCGWindowNumber as String] as? CGWindowID == window }
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
            // The shared arithmetic, not a second copy of it: the promise both sides document is
            // that a window thrown either way lands in the same place, and one function is the only
            // thing that can keep it. Positioning without the shrink-to-fit left a window that
            // filled a 4K external at 4K on a laptop screen, pinned to the top-left with most of it
            // hanging off the bottom and right.
            let placed = WindowTiler.carried(frame, from: current, to: to)
            // Position, size, position, through the one writer — see `AX.setFrame`, which explains
            // why all three are needed: some apps clamp a move against their *current* size and
            // others clamp a resize against the screen edge from their old origin. This used to be
            // `setSize` then `setPosition`, which covers the first class and not the second, and
            // covered it differently from the chord that is meant to land in the same place. It
            // also collapses two `onOwningThread` hops into one.
            AX.setFrame(window, placed, sizing: true, repositionAfterSizing: true)
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
