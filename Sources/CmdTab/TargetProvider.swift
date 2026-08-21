import AppKit
import ApplicationServices

/// Builds the switcher list and keeps it in most-recently-used order.
///
/// macOS exposes no MRU ordering, so we keep our own: seeded from the on-screen window
/// z-order at launch, then maintained from activation notifications.
///
/// Enumeration is cached. Every Accessibility call is IPC to another process, and the switcher
/// is driven from an event tap that must never stall, so `snapshot()` returns the cache
/// instantly and `refresh()` updates it off the main thread.
/// `@MainActor` states what was already true and previously only written down: every stored
/// property here is touched from the main thread, and the only work that leaves it is the `axQueue`
/// block, which is handed local copies and reaches back through `MainActor.assumeIsolated`. Under
/// Swift 5 that was a convention a new `DispatchQueue.async` could quietly break; now it is checked.
@MainActor
final class TargetProvider {
    // Every `static` below is `nonisolated`: they are pure helpers and Accessibility/CGS reads that
    // touch no instance state, and several are called from `axQueue` on purpose — keeping that work
    // off the main thread is the entire reason this class exists. Without the annotation the
    // `@MainActor` above would drag them onto the thread they were written to avoid.

    /// Cross-app order. See `RecencyList` for the two rules it enforces and why each matters.
    private var mru = RecencyList<pid_t>(limit: TargetProvider.mruLimit)
    /// Most-recently-focused window ids, newest first — the per-window analogue of `mru`.
    private var windowMRU = RecencyList<CGWindowID>(limit: TargetProvider.mruLimit)
    private var cache: [SwitchTarget] = []
    private let axQueue = DispatchQueue(label: "com.cmdtab.accessibility", qos: .userInteractive)

    /// How tiles are ordered. Recently-used keeps the MRU list; alphabetical ignores it.
    var sortOrder: SortOrder = .recentlyUsed

    /// Read the Dock for notification badges during refresh. Off skips the Accessibility walk
    /// entirely rather than merely hiding the result.
    var notificationBadges: Bool = true

    /// Bundle identifiers the user has excluded. Also keeps their windows out of the same-app cycle.
    var excludedBundleIDs: Set<String> = []

    /// Hide apps that own no on-screen window. Only meaningful in app mode — a window list has no
    /// empty apps in it to hide.
    var hideEmptyApps: Bool = false

    /// Whether a refresh builds one target per app or one per window.
    var mode: SwitcherMode = .apps

    /// Per-app overrides. Only apps the user has given a rule appear here.
    var appRules: [String: AppRule] = [:]

    /// Favourited apps, in the user's order. Any that aren't running are shown as launchable tiles.
    var favoriteBundleIDs: [String] = [] {
        didSet { appInfoCache = appInfoCache.filter { favoriteBundleIDs.contains($0.key) } }
    }

    /// Give the favourites the first slots of the app list, in the user's order: the running ones,
    /// then the ones that are only launchable. A favourite is then in the same place every time
    /// bar the apps you have opened or quit since, and is reachable by its number. Off leaves them
    /// to the sort, with the ones that aren't running appended at the end.
    ///
    /// App mode only. A window list has as many tiles per app as the app has windows, so no app can
    /// hold a slot in it.
    var pinFavoritesFirst: Bool = true

    /// Resolved metadata for launchable favourites, keyed by bundle id.
    ///
    /// `FavoritesStore.appInfo` is a LaunchServices lookup plus two disk reads (display name, icon),
    /// and it runs on the main thread for every favourite on every refresh — even though the answer
    /// only changes when the app is moved or uninstalled. Bounded by the favourites list, which the
    /// `didSet` above prunes it back to.
    private var appInfoCache: [String: (url: URL, name: String, icon: NSImage)] = [:]

    /// Upper bound on both MRU lists.
    ///
    /// Nothing past the switcher's own list length affects ordering, so the tail is dead weight —
    /// and without a cap `windowMRU` grows by one entry for every window ever focused and never
    /// sheds any, because a closed window posts no notification. On a machine left up for weeks that
    /// turned every activation into an O(n) scan over thousands of stale ids.
    private static let mruLimit = 256

    init() {
        // Seeded in reverse: `touch` prepends, so replaying the z-order back-to-front leaves the
        // frontmost app at the head where it belongs.
        for pid in Self.zOrderedPIDs().reversed() { mru.touch(pid) }
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            center.addObserver(
                self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func workspaceChanged(_ note: Notification) {
        let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
        switch note.name {
        case NSWorkspace.didActivateApplicationNotification:
            if let pid = app?.processIdentifier {
                touch(pid)
                activationGeneration &+= 1
                touchFocusedWindow(of: pid, generation: activationGeneration)
            }
        case NSWorkspace.didTerminateApplicationNotification:
            // Drop the pid outright. Nothing else ever removed one, so the list only grew — see
            // `mruLimit`, which is the backstop rather than the fix.
            if let pid = app?.processIdentifier { mru.remove(pid) }
        default:
            break
        }
        refresh()
    }

    private func touch(_ pid: pid_t) {
        mru.touch(pid)
    }

    /// How many times to re-ask a just-launched app for its focused window, and how long to wait
    /// between tries.
    ///
    /// An app that activates on *launch* has no focused window to report yet: the process is up well
    /// before it has drawn, which is the same timing `LaunchArrangementWatcher` polls around. The
    /// read fails, and without a retry the window the user just opened never enters `windowMRU` —
    /// so window mode ranks it last (`Int.max`) and falls back to AX z-order until they switch away
    /// and back. Five seconds covers a cold launch; it costs nothing on the ordinary case, because
    /// an app that is already up answers on the first try and never reaches the retry at all.
    private nonisolated static let focusedWindowAttempts = 25
    private nonisolated static let focusedWindowRetryDelay: TimeInterval = 0.2

    /// How recently an app must have launched for "no focused window" to mean "has not drawn one
    /// yet" rather than "has none".
    ///
    /// Without this the poll is not confined to the launch it was written for. An app that is merely
    /// open with nothing on screen — Finder with every window closed is the standing example —
    /// answers nothing on every activation for as long as it runs, and each one would buy a
    /// five-second Accessibility poll on `axQueue`, the same serial queue a refresh and the same-app
    /// cycle run on. Generous, because it has to cover the whole poll plus however long the app took
    /// to get from process start to the activation that starts it.
    private nonisolated static let focusedWindowLaunchGrace: TimeInterval = 30

    /// Bumped on every activation. A poll carries the value it started under and stops as soon as a
    /// newer activation supersedes it.
    ///
    /// Two things, both of which the frontmost check alone got wrong. Re-activating the same app
    /// used to leave the running poll in place and start a second one beside it, so flipping between
    /// two window-less apps stacked chains on a serial queue. And the frontmost check happens before
    /// the Accessibility read, which can block for `AX.timeout` — long enough for the user to switch
    /// away and the new app to record its own window first, leaving the stale answer to land on top
    /// of it. The generation is checked again at the insert, which is the only place that matters.
    private var activationGeneration = 0

    /// Records the just-activated app's focused window as most-recently-used, so window mode can
    /// order an app's windows by real recency rather than raw AX z-order. Clicking a background app's
    /// window activates it and fires this too, so the MRU tracks external switches, not just ours.
    /// Runs the Accessibility read off the main thread — the same event-tap constraint as elsewhere.
    /// Records a window the switcher itself brought forward.
    ///
    /// `windowMRU` was otherwise written from one place — `touchFocusedWindow`, reached only from
    /// `didActivateApplicationNotification`. A same-app pick fronts a window *within* the app that
    /// is already frontmost, so no activation fires and the pick went unrecorded. That is worse
    /// than not tracking it at all: the single stale entry ranks 0 while every sibling ranks
    /// `Int.max`, so it outranks the AX z-order the README says this case falls back to, and stays
    /// pinned at index 0. A second tap of the same-app chord then re-selected the window already in
    /// front and the third window of an app was unreachable by tapping.
    ///
    /// No generation guard, unlike `touchFocusedWindow`: this is not a late answer to an
    /// asynchronous read, it is the switcher stating what it just did.
    func noteFocused(window id: CGWindowID) {
        windowMRU.touch(id)
    }

    private func touchFocusedWindow(
        of pid: pid_t, generation: Int, remaining: Int = TargetProvider.focusedWindowAttempts
    ) {
        // Our own activation — opening Settings switches the policy to `.regular` and takes focus —
        // is not a window anyone can switch to: `switchableApps()` drops this process from the list,
        // so the id would sit at the head of `windowMRU` where nothing can ever match it. It also
        // keeps the read below aimed at another process, which is what makes it IPC and therefore
        // safe to run off the main thread at all.
        guard pid != ProcessInfo.processInfo.processIdentifier else { return }
        axQueue.async { [weak self] in
            // Only a failure to read the attribute means "ask again". An app that answered with a
            // window whose `CGWindowID` will not resolve has given its final answer — that is the
            // documented Electron/Catalyst case in `windowID(matching:pid:)`, and it does not
            // improve with time. Retrying it would put a five-second poll on every activation of
            // the apps most likely to hit it.
            let (window, error) = AX.readElement(
                AX.application(pid), kAXFocusedWindowAttribute as String)
            guard let window else {
                self?.retryFocusedWindow(
                    of: pid, generation: generation, remaining: remaining, after: error)
                return
            }
            guard let id = Self.windowID(window) else { return }
            Log.targets.log(
                level: Log.traceLevel,
                "focused window: pid \(pid, privacy: .public) -> win \(id, privacy: .public) on try \(TargetProvider.focusedWindowAttempts - remaining + 1, privacy: .public)"
            )
            DispatchQueue.main.async {
                // `assumeIsolated` rather than a `Task`: this is already on the main thread, and a
                // `Task` hop would let a later activation's answer land first.
                MainActor.assumeIsolated {
                    // `windowMRU`'s head is meant to be the window in focus now, so an answer the
                    // user has already switched away from must not insert itself there — however
                    // long the read above took to come back.
                    guard let self, generation == self.activationGeneration else { return }
                    self.windowMRU.touch(id)
                }
            }
        }
    }

    /// Schedules another attempt at `pid`'s focused window, if one is still worth making.
    ///
    /// Three things have to hold. The failure has to be the retryable kind — see `isRetryable`. The
    /// app has to still be frontmost under the generation the poll started with, which ends it the
    /// moment attention moves on and covers an app quit mid-poll, since a dead pid is not frontmost
    /// either. And the app has to have launched recently enough for a missing window to be a window
    /// that has not arrived yet rather than one that does not exist — see `focusedWindowLaunchGrace`.
    /// `nonisolated` because it is called from `axQueue`. Nothing in it touches instance state:
    /// it consults two `nonisolated` statics, logs, and posts the next attempt to the main thread,
    /// where `assumeIsolated` re-enters the actor for the part that does.
    private nonisolated func retryFocusedWindow(
        of pid: pid_t, generation: Int, remaining: Int, after error: AXError
    ) {
        guard remaining > 1, Self.isRetryable(error) else {
            Log.targets.log(
                level: Log.traceLevel,
                "focused window: pid \(pid, privacy: .public) never reported one; giving up (AXError \(error.rawValue, privacy: .public))"
            )
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.focusedWindowRetryDelay) {
            [weak self] in
            MainActor.assumeIsolated {
                guard let self, generation == self.activationGeneration,
                    let app = NSWorkspace.shared.frontmostApplication,
                    app.processIdentifier == pid,
                    Self.isJustLaunched(app)
                else { return }
                self.touchFocusedWindow(of: pid, generation: generation, remaining: remaining - 1)
            }
        }
    }

    /// Whether a failed read is worth repeating.
    ///
    /// `.apiDisabled` is Accessibility switched off for *us*, not a slow app: this provider observes
    /// activations from the moment it is constructed, which is before `AppDelegate` has even checked
    /// trust, so an ungranted user would otherwise buy a five-second poll behind every app switch on
    /// the machine for as long as they left the prompt unanswered. `.notImplemented` is an app that
    /// does not answer the Accessibility API at all. Neither changes inside five seconds.
    private nonisolated static func isRetryable(_ error: AXError) -> Bool {
        switch error {
        case .apiDisabled, .notImplemented: return false
        default: return true
        }
    }

    /// Whether `app` is new enough that a missing focused window is a launch still in progress.
    ///
    /// An unknown launch date is treated as recent: the date is missing rarely and only for
    /// processes that could not be read, and losing the retry there would quietly reintroduce the
    /// ordering bug it exists to fix. The bounded attempt count is the backstop.
    private nonisolated static func isJustLaunched(_ app: NSRunningApplication) -> Bool {
        guard let launched = app.launchDate else { return true }
        return Date().timeIntervalSince(launched) < focusedWindowLaunchGrace
    }

    /// Whatever we last computed. Never blocks.
    func snapshot() -> [SwitchTarget] { cache }

    // MARK: - Refresh

    /// How long a refresh request waits for others to join it.
    ///
    /// `refresh()` is called from every workspace notification and from several settings setters,
    /// and its prelude runs on the main thread — the same thread that services the event tap, where
    /// a stall costs the user every keystroke on the machine. Bursts are routine: `hideOthers`
    /// posts one notification per app hidden, and an unstepped settings slider posts one per drag
    /// tick. Each used to mean a full enumeration, piling onto a serial queue behind a Dock walk
    /// that can take the full Accessibility timeout. They now collapse into a single pass.
    private let coalesceWindow: TimeInterval = 0.15
    private var coalesceWork: DispatchWorkItem?
    /// Callers waiting on the next pass; all are answered with the same result.
    private var pendingHandlers: [@Sendable ([SwitchTarget]) -> Void] = []
    /// A pass is on the queue. Never enqueue a second — the queue is serial, so it would only
    /// deepen the backlog the coalescing above exists to prevent.
    private var isRefreshing = false
    /// A request arrived while a pass was in flight; run one more once it lands.
    private var wantsAnotherRefresh = false

    /// Recomputes the list off-thread, then hands the result back on main. Coalesced — see
    /// `coalesceWindow`. `handler`, if given, fires when the next completed pass lands.
    func refresh(then handler: ((@Sendable ([SwitchTarget]) -> Void))? = nil) {
        if let handler { pendingHandlers.append(handler) }
        guard coalesceWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.coalesceWork = nil
            self.performRefresh()
        }
        coalesceWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + coalesceWindow, execute: work)
    }

    private func performRefresh() {
        // Already running: follow it with one more rather than stacking a second enumeration behind
        // it. `pendingHandlers` is deliberately left alone — the follow-up pass answers them.
        guard !isRefreshing else {
            wantsAnotherRefresh = true
            return
        }
        isRefreshing = true
        let handlers = pendingHandlers
        pendingHandlers = []

        let sortOrder = self.sortOrder
        let hideEmptyApps = self.hideEmptyApps
        let wantsBadges = self.notificationBadges
        let mode = self.mode
        let apps = switchableApps()
        let order = mru.entries
        // Both read on the main thread, like everything else in this prelude: the window builder
        // needs them and they are only used when the mode asks for windows.
        let windowMRU = self.windowMRU.entries
        let rules = self.appRules
        // Apps the user has asked to always see window-by-window, even in app mode.
        let expanding = mode == .apps
            ? apps.filter { $0.bundleID.map { rules[$0]?.expandWindows == true } ?? false }
            : []
        let needsFrames = mode == .windows || !expanding.isEmpty
        let screenFrames = needsFrames && NSScreen.screens.count > 1 ? Self.screenCGFrames() : []
        // Favourites that aren't running, resolved here on the main thread (NSWorkspace).
        let launchTargets = launchFavorites()
        // Pinning has to put each favourite's tiles where the favourite sits, and a tile knows its
        // pid but not its bundle id — so the mapping is carried over from the app list.
        let pinning = pinFavoritesFirst && mode == .apps && !favoriteBundleIDs.isEmpty
        let favoriteOrder = pinning ? favoriteBundleIDs : []
        let bundleIDsByPID = pinning
            ? Dictionary(
                apps.compactMap { app in app.bundleID.map { (app.pid, $0) } },
                uniquingKeysWith: { first, _ in first })
            : [:]

        axQueue.async { [weak self] in
            // The work the tap callback is kept away from. Paired with the `tap` signpost, this is
            // what makes the separation visible in a trace: a refresh interval overlapping a tap
            // interval is the design working, one *inside* it is the bug this arrangement exists to
            // prevent.
            let refresh = Signpost.targets.beginInterval(
                "refresh", id: Signpost.targets.makeSignpostID())

            // On the background queue: reading the Dock is Accessibility IPC to another process.
            let badges = wantsBadges ? DockBadges.current() : [:]
            var targets: [SwitchTarget]
            switch mode {
            case .apps:
                targets = Self.appTargets(
                    apps, order: order, sortOrder: sortOrder, badges: badges)
                // Windows on ANY Space, so a fullscreen app (which lives on its own Space) still
                // counts as non-empty rather than being dropped. A nil answer is the window list
                // refusing to be read, not a machine with no windows on it — filtering against it
                // would remove every app there is, and an empty refresh landing under an open
                // switcher dismisses the session outright (`finishListMutation`). Leaving the list
                // unfiltered for one pass shows at worst a few empty apps; the alternative is the
                // panel vanishing a moment after it opened.
                if hideEmptyApps, let owning = Self.windowOwningPIDs() {
                    targets.removeAll { !owning.contains($0.pid) }
                }
                // Splice each expanded app's windows in where its single tile was, so the list keeps
                // the order the sort produced rather than gathering them at one end.
                if !expanding.isEmpty {
                    let windows = Self.withSpaceBadges(
                        Self.windowTargets(
                            expanding, order: order, sortOrder: sortOrder,
                            windowMRU: windowMRU, screenFrames: screenFrames, badges: badges))
                    let byPID = Dictionary(grouping: windows, by: \.pid)
                    targets = targets.flatMap { target -> [SwitchTarget] in
                        // An expanded app with no windows keeps its app tile: dropping it would make
                        // the app vanish from the switcher entirely, which the rule never promised.
                        guard let replacement = byPID[target.pid], !replacement.isEmpty else {
                            return [target]
                        }
                        return replacement
                    }
                }
            case .windows:
                // The same walk the same-app cycle does, over every switchable app rather than one.
                // `hideEmptyApps` is skipped: an app with no windows contributes no tiles here
                // anyway, so it has nothing left to hide.
                targets = Self.withSpaceBadges(
                    Self.windowTargets(
                        apps, order: order, sortOrder: sortOrder,
                        windowMRU: windowMRU, screenFrames: screenFrames, badges: badges))
            }
            if pinning {
                // The favourites take the front of the list, each running one bringing its own
                // tiles with it and each one that isn't running contributing its launch tile, so
                // the block reads the same either way.
                targets = Self.pinningFavorites(
                    targets, order: favoriteOrder, bundleIDs: bundleIDsByPID,
                    launchTiles: Dictionary(launchTargets, uniquingKeysWith: { first, _ in first }))
            } else {
                // Launchable favourites go last otherwise. A favourite has no windows to list, but
                // it was starred precisely so it stays reachable — dropping it in window mode would
                // make a user's pin vanish on a setting they changed for an unrelated reason.
                targets += launchTargets.map(\.1)
            }
            // Ended before the hop back, so the interval is the enumeration itself rather than the
            // enumeration plus however long the main thread took to get round to us. The count is
            // the scaling factor: a refresh is per-app Accessibility IPC, so "slow" and "a lot of
            // windows open" are the same reading and the trace should say which.
            Signpost.targets.endInterval("refresh", refresh, "targets=\(targets.count)")
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.cache = targets
                    self.isRefreshing = false
                    handlers.forEach { $0(targets) }
                    if self.wantsAnotherRefresh {
                        self.wantsAnotherRefresh = false
                        self.refresh()
                    }
                }
            }
        }
    }

    /// The frontmost app's windows, for the same-app cycle. Independent of the switcher's global
    /// mode: this shows one app's windows whether the switcher is normally in app or window mode.
    ///
    /// Deliberately not cached like `snapshot()`. The cache exists so the trigger can draw the panel
    /// without waiting; this trigger is rarer, and keeping a second list warm would mean running the
    /// per-window Accessibility walk on every refresh for a feature most sessions never use.
    func frontAppWindowTargets(then handler: @escaping @Sendable ([SwitchTarget]) -> Void) {
        // Hops off the caller's turn before touching anything. The only caller is the same-app
        // hotkey, which is handled inside the CGEventTap callback, and the prelude below is not
        // cheap: `switchableApps()` enumerates every running application and faults in each one's
        // icon. Run inline that is the same overrun hazard `showWith` moves `provider.refresh` off
        // the callback to avoid — and an overrun costs the user every keystroke on the machine.
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return handler([]) }
                self.collectFrontAppWindowTargets(then: handler)
            }
        }
    }

    /// Every switchable app's windows, for a scoped trigger.
    ///
    /// Uncached for the same reason `frontAppWindowTargets` is: this is the per-window Accessibility
    /// walk, and keeping a second list warm would mean paying it on every refresh for a feature most
    /// sessions never use. Hops off the caller's turn first — the caller is the event-tap callback.
    func allWindowTargets(then handler: @escaping @Sendable ([SwitchTarget]) -> Void) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return handler([]) }
                let apps = self.switchableApps()
                let sortOrder = self.sortOrder
                let order = self.mru.entries
                let windowMRU = self.windowMRU.entries
                // Guarded on the screen count like the other two builders: `displayIndex` is only
                // meant to be set with more than one display, and that nil is what suppresses the
                // badge. Unguarded, one display returned a one-element array and every window
                // resolved to index 0 — a "1" on every tile in a scoped session, on a machine
                // where the main switcher shows none.
                let screenFrames = NSScreen.screens.count > 1 ? Self.screenCGFrames() : []

                self.axQueue.async {
                    let targets = Self.windowTargets(
                        apps, order: order, sortOrder: sortOrder,
                        windowMRU: windowMRU, screenFrames: screenFrames)
                    let badged = Self.withSpaceBadges(targets)
                    DispatchQueue.main.async { handler(badged) }
                }
            }
        }
    }

    private func collectFrontAppWindowTargets(then handler: @escaping @Sendable ([SwitchTarget]) -> Void) {
        guard let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
            let app = switchableApps().first(where: { $0.pid == pid })
        else { return handler([]) }

        let sortOrder = self.sortOrder
        let windowMRU = self.windowMRU.entries
        let screenFrames = NSScreen.screens.count > 1 ? Self.screenCGFrames() : []

        axQueue.async {
            let targets = Self.windowTargets(
                [app], order: [pid], sortOrder: sortOrder,
                windowMRU: windowMRU, screenFrames: screenFrames)
            // Badged here, not in the hop below: `spaceIndices` is a CGS round-trip per window, and
            // evaluating it inside the `main.async` body put that IPC on the thread that services
            // the event tap.
            let badged = Self.withSpaceBadges(targets)
            DispatchQueue.main.async { handler(badged) }
        }
    }

    // MARK: - Window helpers

    /// The `CGWindowID` for an Accessibility window element, for the apps where
    /// `_AXUIElementGetWindow` returns 0 (Electron and Catalyst hosts, mainly).
    ///
    /// Matches on pid *and* frame, not "the app's frontmost window". An app-scoped guess moves
    /// whichever window happens to be in front — during a same-app cycle that is rarely the one
    /// selected, and under key-repeat it picks a different window each time, scattering several
    /// windows across Spaces instead of walking one.
    ///
    /// Deliberately no `.optionOnScreenOnly`: the entire point of a move-to-Space is that the window
    /// may be on a Space you are not currently looking at, which that flag excludes.
    nonisolated static func windowID(matching element: AXUIElement, pid: pid_t) -> CGWindowID? {
        guard let origin = AX.position(element), let size = AX.size(element) else { return nil }
        guard
            let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return nil }

        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                window[kCGWindowOwnerPID as String] as? pid_t == pid,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { continue }
            // AX position/size and CGWindowList bounds share a top-left origin space. A couple of
            // points of slack absorbs rounding rather than requiring exact equality.
            let tolerance: CGFloat = 2
            guard abs(bounds.origin.x - origin.x) < tolerance,
                abs(bounds.origin.y - origin.y) < tolerance,
                abs(bounds.width - size.width) < tolerance,
                abs(bounds.height - size.height) < tolerance
            else { continue }
            return window[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    /// PIDs owning at least one real window on ANY Space (no on-screen restriction). Used by the
    /// "hide apps with no open windows" filter so fullscreen / other-Space apps are not dropped.
    ///
    /// nil when the window list could not be read at all, which is a different answer from "nobody
    /// owns a window" and has to stay distinguishable: the caller filters every app out of the
    /// switcher on an empty set, and this read does fail transiently — across a Space switch, on
    /// wake, and under window-server pressure.
    private nonisolated static func windowOwningPIDs() -> Set<pid_t>? {
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }
        var pids = Set<pid_t>()
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pids.insert(pid)
        }
        return pids
    }

    /// Parses the `CGWindowID` back out of a `"win:<id>"` target id, if it carries one.
    /// `SwitchTarget.windowID` forwards here so the format is understood in exactly one place.
    nonisolated static func windowID(fromTargetID id: String) -> CGWindowID? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, parts[0] == "win", let value = UInt32(parts[1]) else { return nil }
        return value
    }

    // MARK: - App list

    /// Metadata snapshotted on the main thread; `NSRunningApplication` is not safe to poke at
    /// from the Accessibility queue.
    struct AppInfo {
        let pid: pid_t
        let name: String
        let bundleID: String?
        let icon: NSImage?
        let isHidden: Bool
    }

    /// Marked for the main-loop monitor rather than at each of its three call sites: this is the
    /// NSWorkspace walk plus an icon fault per running app, it is the most expensive thing this
    /// class does on the main thread, and marking it here means a stall names it whichever entry
    /// point asked.
    private func switchableApps() -> [AppInfo] {
        MainLoopMonitor.marking("app enumeration") { uncheckedSwitchableApps() }
    }

    private func uncheckedSwitchableApps() -> [AppInfo] {
        let mine = ProcessInfo.processInfo.processIdentifier
        let excluded = excludedBundleIDs
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != mine,
                  !app.isTerminated else { return nil }
            // An app with no bundle identifier can't be excluded — there is nothing stable to
            // key the exclusion on — so it always stays in the list.
            if let bundleID = app.bundleIdentifier, excluded.contains(bundleID) { return nil }
            let name = app.localizedName ?? "Unknown"
            // The per-app name override is applied here rather than at each tile, so everything
            // downstream — both tile builders, the caption, and the fuzzy match, which scores the
            // app name as well as the title — sees the name the user chose and nothing has to
            // remember to ask twice.
            let renamed = app.bundleIdentifier.map { appRules[$0]?.label(or: name) ?? name } ?? name
            return AppInfo(
                pid: app.processIdentifier,
                name: renamed,
                bundleID: app.bundleIdentifier,
                icon: app.icon,
                isHidden: app.isHidden)
        }
    }

    /// Launchable tiles for favourites that aren't currently running (and aren't excluded), in the
    /// user's favourites order. Runs on the main thread — `NSWorkspace` app lookups want it, which
    /// is exactly why the resolved metadata is cached in `appInfoCache` rather than re-derived from
    /// LaunchServices and disk on every pass.
    ///
    /// Paired with the bundle identifier each tile came from: pinning has to slot a tile in at its
    /// favourite's position, and a `SwitchTarget` carries no bundle id of its own.
    private func launchFavorites() -> [(String, SwitchTarget)] {
        MainLoopMonitor.marking("favourite resolution") { uncheckedLaunchFavorites() }
    }

    private func uncheckedLaunchFavorites() -> [(String, SwitchTarget)] {
        guard !favoriteBundleIDs.isEmpty else { return [] }
        let excluded = excludedBundleIDs
        let running = Set(
            NSWorkspace.shared.runningApplications.compactMap { $0.bundleIdentifier })
        return favoriteBundleIDs.compactMap { id in
            guard !running.contains(id), !excluded.contains(id) else { return nil }
            if let cached = appInfoCache[id] {
                return (id, Self.launchTarget(id: id, info: cached))
            }
            // A failure is deliberately not cached: an app that isn't installed yet should be picked
            // up when it arrives, rather than being remembered as missing for the whole session.
            guard let info = FavoritesStore.appInfo(for: id) else { return nil }
            appInfoCache[id] = info
            return (id, Self.launchTarget(id: id, info: info))
        }
    }

    /// Moves the running favourites to the front of a built list, in the user's order, and leaves
    /// the launchable ones at the very end — behind every app that is actually open.
    ///
    /// Two blocks with the whole list between them, because the two kinds of tile are answers to
    /// different questions. Every open app is something to switch to, which is what a ⌘-Tab press
    /// almost always wants; a launch tile is a favourite that would have to start first, and no
    /// press that means "switch" should have to walk past one. Being starred orders an app among
    /// the open ones — it does not promote an app that isn't open over one that is.
    ///
    /// A favourite contributes whatever tiles it already has — one for the app, or several if it is
    /// an app the user has asked to see window-by-window. Everything else keeps the order the sort
    /// gave it, between the two blocks.
    nonisolated static func pinningFavorites(
        _ targets: [SwitchTarget], order: [String], bundleIDs: [pid_t: String],
        launchTiles: [String: SwitchTarget]
    ) -> [SwitchTarget] {
        var running: [SwitchTarget] = []
        var launchable: [SwitchTarget] = []
        var hoisted = Set<String>()
        for bundleID in order {
            let owned = targets.filter { bundleIDs[$0.pid] == bundleID }
            guard owned.isEmpty else {
                running += owned
                hoisted.formUnion(owned.map(\.id))
                continue
            }
            // Not running, uninstalled, or excluded — only the first of those has a tile.
            if let tile = launchTiles[bundleID] { launchable.append(tile) }
        }
        return running + targets.filter { !hoisted.contains($0.id) } + launchable
    }

    /// Where a plain tap — press and release the trigger without waiting for the panel — should
    /// land in a list this provider built.
    ///
    /// Normally the second tile: the frontmost app is first, so the one behind it is the one a tap
    /// means. Pinning breaks that arithmetic, since the front app can be anywhere in the list and
    /// the second tile is whichever favourite the user put there. The previous app is then found
    /// through the MRU instead, which keeps ⌘-Tab's oldest habit working — tap to go back, tap
    /// again to come back — while the pinned block keeps the front of the list.
    func tapIndex(in targets: [SwitchTarget], mode: SwitcherMode) -> Int {
        guard !targets.isEmpty else { return 0 }
        let natural = min(1, targets.count - 1)
        guard pinFavoritesFirst, mode == .apps, !favoriteBundleIDs.isEmpty else { return natural }
        return Self.previousAppIndex(in: targets, mru: mru.entries) ?? natural
    }

    /// The tile for the app used before the current one, by MRU. Launch tiles are skipped: they all
    /// share a placeholder pid, and an app that is not running was not used before this one either.
    nonisolated static func previousAppIndex(in targets: [SwitchTarget], mru: [pid_t]) -> Int? {
        var seenFront = false
        for pid in mru {
            guard let index = targets.firstIndex(where: { !$0.isLaunchable && $0.pid == pid })
            else { continue }
            // The first hit is the front app, or — when the front app is not in the list at all,
            // having been excluded or hidden as empty — the most recent one that is. Either way the
            // tap goes to the one behind it, which is exactly where an unpinned list would put it.
            guard seenFront else {
                seenFront = true
                continue
            }
            return index
        }
        return nil
    }

    private nonisolated static func launchTarget(
        id: String, info: (url: URL, name: String, icon: NSImage)
    ) -> SwitchTarget {
        SwitchTarget(
            id: "launch:\(id)", kind: .launch(info.url), title: info.name, appName: info.name,
            icon: info.icon, isMinimized: false, isHidden: false)
    }

    /// Apps that currently own an on-screen window, front to back. Only used to seed the MRU
    /// list at launch — this needs no Screen Recording permission because we read pids and
    /// layers, never window titles.
    private nonisolated static func zOrderedPIDs() -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var seen = Set<pid_t>()
        var ordered: [pid_t] = []
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if seen.insert(pid).inserted { ordered.append(pid) }
        }
        return ordered
    }

    nonisolated static func sorted(
        _ apps: [AppInfo], by order: [pid_t], sortOrder: SortOrder
    ) -> [AppInfo] {
        if sortOrder == .alphabetical {
            return apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        let rank = RecencyList<pid_t>.ranks(of: order)
        return apps.enumerated().sorted { a, b in
            let ra = rank[a.element.pid] ?? Int.max
            let rb = rank[b.element.pid] ?? Int.max
            // Fall back to the workspace's own ordering so the sort stays stable.
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    // MARK: - Target construction

    private nonisolated static func appTargets(
        _ apps: [AppInfo], order: [pid_t], sortOrder: SortOrder, badges: [String: String]
    ) -> [SwitchTarget] {
        sorted(apps, by: order, sortOrder: sortOrder).map { app in
            SwitchTarget(
                id: "app:\(app.pid)",
                kind: .app(app.pid),
                title: app.name,
                appName: app.name,
                icon: app.icon,
                isMinimized: false,
                isHidden: app.isHidden,
                badge: app.bundleID.flatMap { badges[$0] })
        }
    }

    private nonisolated static func windowTargets(
        _ apps: [AppInfo], order: [pid_t], sortOrder: SortOrder,
        windowMRU: [CGWindowID], screenFrames: [CGRect], badges: [String: String] = [:]
    ) -> [SwitchTarget] {
        let mruRank = RecencyList<CGWindowID>.ranks(of: windowMRU)
        return sorted(apps, by: order, sortOrder: sortOrder).flatMap { app -> [SwitchTarget] in
            // `AX.application` applies the messaging timeout: a wedged app must not wedge the
            // switcher with it.
            let windows = AX.windows(of: AX.application(app.pid))

            // Keep the AX index as a stable tiebreak, and the MRU rank to reorder within the app.
            var built: [(target: SwitchTarget, axIndex: Int, rank: Int)] = []
            for (index, window) in windows.enumerated() {
                guard AX.isSwitchableWindow(window) else { continue }

                let title = AX.copyString(window, kAXTitleAttribute) ?? ""
                let minimized = AX.isMinimized(window)
                let wid = windowID(window)
                let id = wid.map { "win:\($0)" } ?? "win:\(app.pid):\(index)"
                let display = screenFrames.isEmpty ? nil : displayIndex(of: window, in: screenFrames)

                let target = SwitchTarget(
                    id: id,
                    kind: .window(app.pid, window),
                    title: title.isEmpty ? app.name : title,
                    appName: app.name,
                    icon: app.icon,
                    isMinimized: minimized,
                    isHidden: app.isHidden,
                    displayIndex: display,
                    badge: app.bundleID.flatMap { badges[$0] })
                built.append((target, index, wid.flatMap { mruRank[$0] } ?? Int.max))
            }
            // Recently-used mode orders an app's windows by our tracked focus recency, falling back
            // to AX z-order; alphabetical leaves them in AX order.
            if sortOrder == .recentlyUsed {
                built.sort { $0.rank == $1.rank ? $0.axIndex < $1.axIndex : $0.rank < $1.rank }
            }
            return built.map(\.target)
        }
    }

    /// Tags each window with the Space it lives on. A no-op with a single Space, which is what keeps
    /// the badge off the tiles for everyone who doesn't use them.
    private nonisolated static func withSpaceBadges(_ targets: [SwitchTarget]) -> [SwitchTarget] {
        let indices = SpaceMover.spaceIndices(of: targets.compactMap { windowID(fromTargetID: $0.id) })
        guard !indices.isEmpty else { return targets }
        return targets.map { target in
            guard let id = windowID(fromTargetID: target.id), let index = indices[id] else {
                return target
            }
            var tagged = target
            tagged.spaceIndex = index
            return tagged
        }
    }

    /// Which display a window sits on: the one its centre falls on, or failing that the one it
    /// overlaps most. Drives the multi-display badge and the current-display scope.
    ///
    /// The fallback matters more than it looks. A window can sit with its centre on no display at
    /// all — dragged half off an edge, or stranded where a monitor used to be — and answering "no
    /// display" for those dropped them from the current-display scope entirely, which is a list
    /// whose whole job is to show the windows over there.
    private nonisolated static func displayIndex(of window: AXUIElement, in frames: [CGRect]) -> Int? {
        guard let origin = AX.position(window), let size = AX.size(window) else { return nil }
        // Shared with the in-switcher move and the tiling chords, so the badge on a tile and the
        // display the move counts from can no longer disagree. Full frames here rather than visible
        // areas — see `screenCGFrames` — but the rule applied to them is the one rule.
        return WindowTiler.homeDisplay(
            of: CGRect(origin: origin, size: size), in: frames)
    }

    /// Every display's full frame in Quartz (top-left) coordinates, to match AX window positions.
    ///
    /// Full frames, deliberately: this places a window *among* the displays for the badge, where the
    /// menu bar and the Dock are part of the display a window is on. Anything that has to place a
    /// window *within* one — tiling, the cross-display move — wants `WindowTiler.visibleAreas()`
    /// instead, or it will put the window under the menu bar.
    nonisolated static func screenCGFrames() -> [CGRect] {
        let primaryHeight =
            NSScreen.primary?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let f = screen.frame
            return CGRect(
                x: f.origin.x, y: primaryHeight - f.origin.y - f.height,
                width: f.width, height: f.height)
        }
    }

    // MARK: - Accessibility helpers

    /// `_AXUIElementGetWindow` is private but gives us a stable identity for each window, which
    /// keeps SwiftUI from re-animating tiles on every refresh. Falls back to a positional id.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>)
        -> AXError

    private nonisolated static let getWindow: GetWindowFn? = {
        // The global handle only exposes it once ApplicationServices is actually loaded, so
        // fall back to the framework by path.
        let paths: [String?] = [
            nil,
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "_AXUIElementGetWindow") else { continue }
            return unsafeBitCast(symbol, to: GetWindowFn.self)
        }
        return nil
    }()

    /// The `CGWindowID` for an AX window element (via the private `_AXUIElementGetWindow`). Internal
    /// so the Space move can turn a resolved window element into a window number.
    nonisolated static func windowID(_ window: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The `CGWindowID`s of an app's switchable windows, in Accessibility order (front-to-back) so
    /// the hover preview can match window mode's ordering. This is the set window mode shows, so it
    /// already excludes the phantom backing windows Electron/Catalyst apps expose. May come back
    /// empty — or fail to line up with the captured windows — for apps whose AX windows don't map to
    /// a resolvable `CGWindowID`; the caller falls back accordingly. Runs Accessibility IPC, so keep
    /// it off the tap.
    nonisolated static func switchableWindowIDs(for pid: pid_t) -> [CGWindowID] {
        AX.windows(of: AX.application(pid)).filter(AX.isSwitchableWindow).compactMap(windowID)
    }
}
