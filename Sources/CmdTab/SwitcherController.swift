import AppKit
import Combine
import CoreGraphics
import SwiftUI

private enum Key {
    static let tab = 48
    static let escape = 53
    static let delete = 51
    static let leftArrow = 123
    static let rightArrow = 124
    static let downArrow = 125
    static let upArrow = 126
    static let enter = 36

    /// Keycodes for 1–9 and 0 on the number row and again on the keypad, mapped to the tile position
    /// each one selects. The number row is not sequential — 5, 6, 7, 8 and 9 are 23, 22, 26, 28, 25 —
    /// so this has to be a table. 0 sits past 9 on the keyboard, so it takes the tenth tile.
    ///
    /// These are physical key positions, which is right for the keys labelled 0–9 on ANSI-style
    /// layouts. A layout that puts digits behind Shift (AZERTY) would still match by position.
    static let digits: [Int: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9, 29: 10,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9, 82: 10,
    ]
}

/// Owns the switcher's state machine and decides which key events to swallow.
///
/// Everything here runs on the main thread from inside the event tap callback, so it must stay
/// cheap. The expensive part — enumerating windows over Accessibility — is deferred to the
/// provider's background refresh and lands after the panel is already on screen.
///
/// The invariant that keeps this safe, and that any new feature on the key path has to hold to:
/// **`handle` reads cheap in-memory state, decides swallow / don't-swallow, and posts everything
/// else.** A tap that overruns the system's deadline is disabled outright, and while it is down
/// every keystroke on the machine is dropped — so SwiftUI layout, Accessibility calls, LaunchServices
/// and NSWorkspace all belong behind a `DispatchQueue.main.async`, never inline.
///
/// What that `async` does and does not buy, because the difference is easy to get wrong and the
/// failure it hides is the loudest one this app has: it gets the *callback* to return, which is the
/// only thing the callback itself can control. It does not take the work off the tap's thread. The
/// run-loop source is added to `CFRunLoopGetMain()` (see `EventTap.start`), so posted work runs on
/// the very loop the tap is serviced from, ahead of the *next* event — and the system's deadline
/// runs from when an event is posted, not from when the callback is entered, so a main thread busy
/// elsewhere starves the tap just as effectively as a slow callback would. Posting is therefore
/// necessary and not sufficient: anything landing on main has to be short as well. Work that cannot
/// promise that gets a queue of its own — `TargetProvider.axQueue`, `WindowTiler.queue`,
/// `SwitchTarget.focusQueue`, `LaunchArrangementWatcher.axQueue` — which is where every
/// Accessibility call in this app lives, and the mouse tap goes one further and takes a whole
/// thread (`MouseWindowDrag.TapThread`). The keyboard tap cannot follow it there: `handle` touches
/// main-actor state throughout, so its home is main and the burden stays on keeping main free.
@MainActor
final class SwitcherController {
    private let model = SwitcherModel()
    private let provider = TargetProvider()
    private lazy var panels = PanelGroup(model: model)
    private lazy var preview = PreviewCoordinator(switcher: panels) { [weak self] in
        self?.isVisible ?? false
    }
    /// Live window thumbnails drawn as tile artwork in window mode. Off by default; see the type.
    private let thumbnails = TileThumbnails()
    /// Republishes captures into the model as they land.
    ///
    /// A subscription rather than sampling `thumbnails.images` at the call site: the captures arrive
    /// in batches over the life of the session, long after `beginThumbnails` returned, and the whole
    /// design is that the panel does not wait for them. Sampling once would show only whatever had
    /// happened to complete before the panel drew, which on a cold list is nothing.
    private var thumbnailSubscription: AnyCancellable?
    private var tap: EventTap?
    private var isVisible = false {
        didSet {
            publishTapState()
            // Focus must not wander while a list built from the old frontmost app is on screen —
            // see `FocusFollowsMouse.isSwitcherVisible`.
            focusFollows.isSwitcherVisible = isVisible
        }
    }
    /// Second source of truth for "is the trigger still down". See `startWatchdog`.
    private var watchdog: Timer?

    // Quick-switch arming: between a trigger press and the show-delay firing, the panel is not yet
    // on screen. Releasing the modifier in that window switches straight to the previous target.
    private var armed = false { didSet { publishTapState() } }
    private var armedBackwards = false
    private var armedTargets: [SwitchTarget] = []
    private var armWorkItem: DispatchWorkItem?
    /// Modifiers of whichever hotkey opened the current session; releasing them ends it.
    private var activeHeld: CGEventFlags = [.maskCommand] { didSet { publishTapState() } }

    // A same-app cycle whose window list is still being fetched. The list can't be built on the tap
    // callback (per-window Accessibility walk), so the trigger is swallowed before there is anything
    // to show — which means a modifier released inside that window has to be remembered and acted on
    // when the list lands. Without that, a quick tap — by far the most common way this key is used —
    // would do nothing at all.
    private var pendingSameApp = false { didSet { publishTapState() } }
    private var pendingSameAppReleased = false
    private var sameAppDeadline: DispatchWorkItem?
    /// How long to wait for the frontmost app's window list before abandoning the cycle.
    private let sameAppTimeout: TimeInterval = 2

    /// Bumped whenever a session begins or ends. Async work started by one session carries the token
    /// it was launched under and drops itself if the token has moved on, so a slow fetch can never
    /// reach in and mutate a session it does not belong to.
    private var sessionToken = 0

    /// Whether the open session's list was narrowed by its opener rather than built from
    /// `provider.mode`. See `showWith`, which sets it, and the background refresh it gates.
    private var isScopedSession = false

    /// Icons already resolved for launch suggestions, held across keystrokes.
    ///
    /// `NSWorkspace.icon(forFile:)` is disk-backed, and `updateLaunchSuggestions` is reached
    /// synchronously from the tap callback — the one place in this app where being slow costs the
    /// user every keystroke on the machine. Uncached it was paid per suggestion per keystroke, with
    /// a cold IconServices or a bundle on a slow volume in the tail. Favourites already get this
    /// treatment through `TargetProvider.appInfoCache`; this is the same bargain for the catalogue.
    /// Bounded by the number of installed apps, and an icon changing mid-session is not worth an
    /// invalidation path.
    private var launchIcons: [String: NSImage] = [:]

    /// Whether this session is *allowed* to stay up after the trigger is released.
    private var isSticky = false { didSet { publishTapState() } }

    /// The session's end-of-life rules, as a value. See `SessionRelease` — the logic lives there so
    /// it can be tested without an event tap, a panel or Accessibility.
    private var release: SessionRelease {
        SessionRelease(isSticky: isSticky, activeHeld: activeHeld)
    }

    private var staysOpenOnRelease: Bool { release.staysOpenOnRelease }

    /// Set from Settings: whether a session stays up when the trigger is released.
    var stickyMode = false
    private var stickyOutsideMonitor: Any?
    private var stickyIdleTimer: Timer?
    private var stickyCeilingTimer: Timer?
    /// When the sticky session was last touched, polled by `stickyIdleTimer`.
    private var lastStickyActivity = Date()
    /// How long a sticky session may sit untouched before it dismisses itself.
    private let stickyIdleTimeout: TimeInterval = 20
    /// Absolute cap on a sticky session, never extended by activity. The idle timer alone was not a
    /// bound at all: every keystroke resets it, and while the panel is up every keystroke on the
    /// machine is swallowed — so someone typing at a panel they cannot see (on another display, say)
    /// held their own keyboard captive indefinitely, which is the failure that started all of this.
    private let stickyMaxDuration: TimeInterval = 60

    /// Relayouts immediately when the panel is already up, so dragging a slider in settings
    /// resizes a visible switcher live.
    var metrics: Metrics {
        get { model.metrics }
        set {
            guard newValue != model.metrics else { return }
            model.metrics = newValue
            if isVisible { panels.layout() }
        }
    }

    /// The window-tiling bindings, as a snapshot the tap callback can read without touching a store.
    /// Pushed by `AppDelegate` whenever they change.
    var tiling: WindowTilingBindings = .defaults {
        didSet {
            publishTapState()
            dragSnap.gap = tiling.gap
            mouseWindowDrag.gap = tiling.gap
            targetHighlight.gap = tiling.gap
            launchArrangements.gap = tiling.gap
            displayLayouts.isEnabled = tiling.restoresLayoutOnDisplayChange
            guard tiling.dragSnap != oldValue.dragSnap else { return }
            dragSnap.isEnabled = tiling.dragSnap
        }
    }
    private let dragSnap = DragSnap()
    /// Remembers the window layout per set of displays, and puts it back when one returns.
    private let displayLayouts = DisplayLayouts()

    /// Hold-a-modifier-and-drag to move or resize. Pushed by `AppDelegate`, like the bindings.
    var mouseDrag: MouseDragSettings = .init() {
        didSet {
            mouseWindowDrag.settings = mouseDrag
            targetHighlight.settings = mouseDrag
        }
    }
    private let mouseWindowDrag = MouseWindowDrag()
    /// Outlines the window the chord would grab, before anything is pressed.
    private let targetHighlight = ModifierTargetHighlight()

    /// Focus follows the pointer. Pushed by `AppDelegate` on its own channel, like `mouseDrag`.
    var focusFollowsMouse: FocusFollowsMouseSettings = .init() {
        didSet { focusFollows.settings = focusFollowsMouse }
    }
    private let focusFollows = FocusFollowsMouse()

    /// Wires the one thing the two mouse gestures have to agree about.
    ///
    /// They share a chord by design and are told apart only by whether a button goes down — and the
    /// press that tells them apart is swallowed by the drag's own tap, so the pointing gesture
    /// cannot see it. Both objects are owned here, so the introduction is made here, which is where
    /// every other cross-object hook in this class is set up.
    ///
    /// In `init` rather than `start()`: the mouse gestures install themselves from settings pushed
    /// by `AppDelegate`, which happens whether or not the keyboard tap ever comes up, and `start()`
    /// returns early when it does not.
    init() {
        mouseWindowDrag.onClaimChord = { [weak self] in
            Task { @MainActor in self?.targetHighlight.standDown(claimedBy: "a drag") }
        }
    }

    /// Brings up the two mouse gestures if an earlier attempt was refused for want of Accessibility.
    ///
    /// Called alongside `start()`, because both need the same grant and neither notices it arriving:
    /// the settings that install them are pushed once, at construction, which on a first run is
    /// before the user has answered the system prompt. `start()` is the keyboard tap's equivalent
    /// and is already wired to the trust handler; this is the rest of what that handler has to
    /// revive. Idempotent — on a launch that was trusted all along, both calls do nothing.
    func retryMouseGestures() {
        mouseWindowDrag.retryInstallIfNeeded()
        targetHighlight.retryInstallIfNeeded()
    }
    /// Per-app jump chords, same arrangement.
    var activations = DirectActivations() { didSet { publishTapState() } }
    /// The hide-all / show-all chords.
    var allWindows = AllWindowsShortcuts() { didSet { publishTapState() } }
    /// Extra triggers that open a narrowed window list.
    var scopedTriggers = ScopedTriggers() { didSet { publishTapState() } }

    /// User-configurable key bindings for the in-switcher window actions.
    var shortcuts: SwitcherShortcuts = .defaults {
        didSet {
            publishTapState()
            warnAboutShadowedActions()
        }
    }
    /// Whether those bindings are live at all. Off leaves every ⌥-key to type-to-filter.
    var actionsEnabled = false { didSet { publishTapState() } }
    /// Confirm before quit / force-quit.
    var confirmsDestructiveActions = true

    /// Per-app overrides. Rebuilds the list, since `expandWindows` and `displayName` both change
    /// what the targets are.
    var appRules: [String: AppRule] = [:] {
        didSet {
            guard appRules != oldValue else { return }
            provider.appRules = appRules
            dragSnap.appRules = appRules
            mouseWindowDrag.appRules = appRules
            targetHighlight.appRules = appRules
            launchArrangements.appRules = appRules
            displayLayouts.appRules = appRules
            provider.refresh()
        }
    }

    /// Snaps an app's first window as it opens, for the apps that ask for it.
    private let launchArrangements = LaunchArrangementWatcher()

    /// Kept as a property rather than folded into `SwitcherSettings`: `ExclusionStore` pushes this
    /// on its own change notification, independently of the behaviour block.
    var excludedBundleIDs: Set<String> {
        get { provider.excludedBundleIDs }
        set {
            guard newValue != provider.excludedBundleIDs else { return }
            provider.excludedBundleIDs = newValue
            provider.refresh()
        }
    }

    /// As above, from `FavoritesStore`.
    var favoriteBundleIDs: [String] {
        get { provider.favoriteBundleIDs }
        set {
            guard newValue != provider.favoriteBundleIDs else { return }
            provider.favoriteBundleIDs = newValue
            provider.refresh()
        }
    }

    // MARK: - Settings

    /// Applies a whole settings block, rebuilding the target list at most once and laying the panel
    /// out at most once however many values changed.
    ///
    /// This is the point of `SwitcherSettings`. As twenty-six separate setters, each guarding and
    /// acting on its own, a single pass through `AppDelegate.applyBehavior` could run seven full
    /// enumerations and five layouts — and `BehaviorStore` posts its change notification once per
    /// slider tick during a drag, so that arithmetic ran on the thread servicing the event tap.
    /// Seeing the settings together is what makes the coalescing possible.
    func apply(_ settings: SwitcherSettings) {
        // --- the list itself ---
        var needsRefresh = false
        func setProvider<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<TargetProvider, T>, _ value: T) {
            guard provider[keyPath: keyPath] != value else { return }
            provider[keyPath: keyPath] = value
            needsRefresh = true
        }
        setProvider(\.mode, settings.mode)
        setProvider(\.sortOrder, settings.sortOrder)
        setProvider(\.hideEmptyApps, settings.hideEmptyApps)
        setProvider(\.groupWindowsByApp, settings.groupWindowsByApp)
        setProvider(\.pinFavoritesFirst, settings.pinFavoritesFirst)
        setProvider(\.notificationBadges, settings.notificationBadges)

        // --- the panel's shape ---
        var needsLayout = false
        func setPanels<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<PanelGroup, T>, _ value: T) {
            guard panels[keyPath: keyPath] != value else { return }
            panels[keyPath: keyPath] = value
            needsLayout = true
        }
        func setModel<T: Equatable>(_ keyPath: ReferenceWritableKeyPath<SwitcherModel, T>, _ value: T, relayout: Bool) {
            guard model[keyPath: keyPath] != value else { return }
            model[keyPath: keyPath] = value
            if relayout { needsLayout = true }
        }
        setPanels(\.appearanceMode, settings.panelAppearance)
        setPanels(\.positionMode, settings.panelPosition)
        setPanels(\.maxColumns, settings.maxColumns)
        setModel(\.layout, settings.layout, relayout: true)
        setModel(\.titleFontName, settings.titleFontName, relayout: true)
        setModel(\.titleFontSize, settings.titleFontSize, relayout: true)
        setModel(\.blurRadius, settings.panelBlur, relayout: true)

        // Values a live panel picks up on its next draw without being laid out again.
        setModel(\.highlightColor, settings.highlightColor, relayout: false)
        setModel(\.showNumbers, settings.showNumbers, relayout: false)
        setModel(\.showDisplayBadges, settings.showDisplayBadges, relayout: false)
        setModel(\.showSpaceBadges, settings.showSpaceBadges, relayout: false)
        setModel(\.tileCorner, settings.tileCorner, relayout: false)
        setModel(\.material, settings.panelMaterial, relayout: false)

        // Neither rebuilds nor relayouts: read at the start of the next session.
        panels.screens = settings.panelScreens
        panels.fade = settings.fade
        panels.windowPreviewEnabled = settings.windowPreview
        // Turning it off clears whatever was captured, so a later session cannot show a photograph
        // of a window as it looked before the feature was switched off.
        thumbnails.isEnabled = settings.windowThumbnailTiles
        if !settings.windowThumbnailTiles { model.thumbnails = [:] }

        // --- session behaviour, held here ---
        showDelay = settings.showDelay
        windowSpaceScope = settings.windowSpaceScope
        launchFromSearch = settings.launchFromSearch
        stickyMode = settings.stickyMode
        sameAppHotkey = settings.sameAppHotkey
        // Last, and a plain assignment so its `didSet` still re-syncs the system ⌘-Tab.
        hotkey = settings.hotkey

        if needsRefresh { provider.refresh() }
        if needsLayout, isVisible { panels.layout() }
    }

    /// A tap that opens the switcher waits this long before drawing; released sooner, it switches
    /// straight to the previous target with no panel flash. 0 keeps the panel instant.
    var showDelay: TimeInterval = 0

    /// Which Desktops the main list may draw window tiles from.
    ///
    /// Held here rather than pushed into `TargetProvider` with the rest of the list settings, and
    /// that is the whole point of it: the provider builds its cache when an app activates, and the
    /// Desktop in front changes without activating anything — switch to an empty Desktop and no
    /// refresh happens at all. A filter baked into the cache would answer for the Desktop you left.
    /// Applied in `open` instead, against a Space reading taken at that moment.
    var windowSpaceScope: WindowSpaceScope = .allDesktops

    /// Optional second trigger that opens the frontmost app's windows instead of the whole list.
    /// nil leaves the combination alone, which matters because the default (⌘-`) is one apps use
    /// themselves.
    var sameAppHotkey: Hotkey? { didSet { publishTapState() } }

    /// The combination that opens the switcher. Changing it re-syncs the system ⌘-Tab: the native
    /// switcher is suppressed only while *our* trigger is exactly ⌘-Tab.
    var hotkey: Hotkey = .commandTab {
        didSet {
            publishTapState()
            warnAboutShadowedActions()
            guard hotkey != oldValue, isRunning else { return }
            SystemSwitcher.setNativeEnabled(!hotkey.isCommandTab)
        }
    }

    // MARK: - Tap state mirror

    /// The decision inputs, published where a tap on another thread could read them. See `TapState`.
    ///
    /// Not yet load-bearing: the tap still runs on the main run loop and `handle` still reads the
    /// live properties. What it does today is prove itself — every keystroke checks the mirror
    /// against the truth, so a mutation that forgets to publish is a log line now rather than an
    /// intermittent misroute later.
    private let tapMirror = TapStateMirror()

    private var activeObservers: [NSObjectProtocol] = []

    /// Starts mirroring whether Cmd-Tab is frontmost. Called from `start()`, alongside the tap.
    ///
    /// `NSApp.isActive` is the one main-thread-only AppKit read on the decision path, so it is the
    /// one input a tap on another thread could not simply take with it — it has to be observed
    /// instead.
    ///
    /// The notifications re-*publish* rather than cache a bool of their own, which is what makes
    /// this self-checking. `liveTapState` reads the AppKit truth; the mirror holds the truth as of
    /// the last publish; so a notification that fails to arrive shows up in `verify` as a stale
    /// `isAppActive`, named in the log, instead of as a tiling chord that silently stops working.
    /// Caching the value from the notification name would have made the two agree by construction
    /// and checked nothing.
    private func startActiveMirror() {
        guard activeObservers.isEmpty else { return }
        let center = NotificationCenter.default
        let republish: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.publishTapState() }
        }
        activeObservers = [
            center.addObserver(
                forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main,
                using: republish),
            center.addObserver(
                forName: NSApplication.didResignActiveNotification, object: nil, queue: .main,
                using: republish),
        ]
        // Seeded rather than assumed: the notifications report only *changes*, and Settings can
        // already be frontmost by the time trust is granted and this runs.
        publishTapState()
    }

    private func stopActiveMirror() {
        activeObservers.forEach(NotificationCenter.default.removeObserver)
        activeObservers = []
    }

    /// The decision inputs as they are right now, read from the live properties.
    ///
    /// The single place that knows how a `TapState` is assembled, so the published copy and the copy
    /// `verify` compares against can never be built two different ways.
    private var liveTapState: TapState {
        TapState(
            isVisible: isVisible,
            armed: armed,
            pendingSameApp: pendingSameApp,
            isSticky: isSticky,
            activeHeldRaw: activeHeld.rawValue,
            hotkey: hotkey,
            sameAppHotkey: sameAppHotkey,
            scopedTriggers: scopedTriggers,
            activations: activations,
            allWindows: allWindows,
            tiling: tiling,
            shortcuts: shortcuts,
            actionsEnabled: actionsEnabled,
            // The AppKit truth, deliberately — see `startActiveMirror` for why this one field is
            // read live rather than taken from a cache the notifications maintain.
            isAppActive: NSApp.isActive,
            hasQuery: !model.query.isEmpty)
    }

    /// Publishes the current inputs to the mirror.
    ///
    /// Called from `didSet` on every property in the set rather than from the places that assign
    /// them, and that is deliberate: there are sixteen assignment sites for the five session flags
    /// alone, and a rule that lives on the property cannot be forgotten by a new call site the way a
    /// rule that lives at the call sites can. The one thing `didSet` cannot cover is state owned
    /// elsewhere — `model.query` — which publishes from `setQuery`.
    private func publishTapState() {
        tapMirror.publish(liveTapState)
    }

    /// Logs a trigger/action modifier collision.
    ///
    /// Settings refuses to *create* this combination, but a config written before that check existed,
    /// imported from another machine, or hand-edited in the defaults plist can still arrive here —
    /// and the symptom (actions dead, their keys typing into the filter) gives no hint of the cause.
    private func warnAboutShadowedActions() {
        guard actionsEnabled else { return }
        // Every opening chord. A scoped trigger sets `activeHeld` just as the main trigger does, so
        // it shadows actions identically — and being the family no recorder checked, it is the one
        // most likely to arrive in this state.
        for chord in SwitcherShortcuts.openingChords() {
            let shadowed = shortcuts.actionsShadowed(by: chord)
            guard !shadowed.isEmpty else { continue }
            Log.tap.error(
                """
                trigger \(chord.displayString, privacy: .public) claims a modifier \
                \(shadowed.count, privacy: .public) action(s) need as an extra; they cannot fire: \
                \(shadowed.map(\.title).joined(separator: ", "), privacy: .public)
                """)
        }
    }

    var isRunning: Bool { tap?.isRunning ?? false }

    // MARK: - Lifecycle

    /// Returns false if the event tap could not be created, which in practice always means
    /// Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }
        let tap = EventTap { [weak self] type, event in
            self?.handle(type: type, event: event) ?? false
        }
        guard tap.start() else {
            Log.tap.error("event tap failed to create (trusted=\(Permissions.isTrusted))")
            return false
        }
        self.tap = tap
        // Alongside the tap, since it feeds the same decision and is only needed once one is live.
        startActiveMirror()
        panels.onPick = { [weak self] index in self?.pick(index) }
        panels.onScroll = { [weak self] step in
            guard let self, self.isVisible else { return }
            // Scroll and hover are the advertised way to move the selection in a stay-open session,
            // so they have to count as activity. Without this the idle timer measured *keystrokes*,
            // not use, and dismissed a panel the user was actively browsing with the mouse.
            self.resetStickyIdle()
            self.advance(step)
        }
        panels.onPreviewHover = { [weak self] target in
            // Deduped upstream to target *changes*, so this is real navigation, not a mouse twitch.
            self?.resetStickyIdle()
            self?.preview.hover(target)
        }
        panels.isOverPreview = { [weak self] point in self?.preview.isShowing(point) ?? false }
        // A display came or went under an open session. The targets carry a display badge resolved
        // against `NSScreen.screens` as it was when they were built, and the provider watches
        // NSWorkspace rather than screen parameters, so this is the only thing that renumbers them.
        panels.onDisplaysChanged = { [weak self] in
            guard let self else { return }
            // A scoped session keeps the list its opener gave it — see `showWith`. Renumbering a
            // badge is not worth widening one app's windows into every window on the machine.
            guard !self.isScopedSession else { return self.provider.refresh() }
            // With a handler, not bare: `refresh()` alone only rewrites the provider's cache, and
            // `model.update(targets:)` is the one thing that reaches the open session's list. Bare,
            // this renumbered nothing at all, which is the entire job it was wired up to do.
            let token = self.sessionToken
            self.provider.refresh { [weak self] fresh in
                MainActor.assumeIsolated {
                    guard let self, self.isVisible, token == self.sessionToken else { return }
                    self.model.update(targets: fresh)
                    self.finishListMutation()
                }
            }
        }
        preview.onPick = { [weak self] thumb in
            guard let self, self.isVisible else { return }
            Log.tap.notice(
                "preview pick: window \(thumb.windowID, privacy: .public) of pid \(thumb.pid, privacy: .public)"
            )
            self.hide()
            // Off the click, for the same reason `commit()` defers: raising a window is an AX
            // round-trip against a process that may not answer promptly.
            DispatchQueue.main.async {
                SwitchTarget.focusWindow(id: thumb.windowID, pid: thumb.pid)
            }
        }
        // Only wrestle ⌘-Tab away from the system when that is actually our trigger; a custom
        // hotkey leaves the native switcher alone.
        let disabled = hotkey.isCommandTab ? SystemSwitcher.setNativeEnabled(false) : false
        // Screen Recording is reported here because it is the one permission that can be revoked
        // without the user doing anything: it is pinned to the code signature, so a re-signed build
        // loses it silently and the only symptom is that hover previews stop appearing.
        Log.general.notice(
            """
            started: tap=ok nativeDisabled=\(disabled) \
            symbolAvailable=\(SystemSwitcher.isAvailable) \
            screenRecording=\(Permissions.canCaptureScreen)
            """)
        provider.refresh { [weak self] targets in
            MainActor.assumeIsolated {
                Log.targets.notice("initial refresh: \(targets.count) targets")
                // `!isVisible` because `begin` is a hard reset — it clears the query and the
                // selection the caller is expected to set afterwards, which this warm-up does not.
                // Registered before `showWith`'s handler, it would run first in the same
                // `handlers.forEach` and destroy the very anchor `update(targets:)` exists to
                // preserve. Reachable when trust is granted while running: the tap goes live before
                // this is registered, so a ⌘-Tab inside the coalesce window opens a real session.
                guard let self, !self.isVisible else { return }
                // Here rather than beside the other `warm` calls in `AppDelegate`, because a warm-up
                // that lays out an empty list warms the wrong thing: the tiles are most of what the
                // first render costs. Seeding the model is what a session opening does anyway
                // (`showWith` calls `begin` every time), so this leaves it in the state the next one
                // would have put it in regardless.
                self.model.begin(targets)
                self.panels.prewarm()
            }
        }
        return true
    }

    func stop() {
        cancel()
        tap?.stop()
        tap = nil
        stopActiveMirror()
        SystemSwitcher.restoreNativeIfNeeded()
    }

    // MARK: - Event handling

    /// See `TriggerModifiers` — the arithmetic lives there so it can be tested on its own.
    private func modifiersMatch(_ flags: CGEventFlags, _ held: CGEventFlags) -> Bool {
        TriggerModifiers.opens(flags, held: held)
    }

    private func stillHeld(_ flags: CGEventFlags, _ held: CGEventFlags) -> Bool {
        TriggerModifiers.stillHeld(flags, held: held)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        // The mirror earning its keep. Both sides are readable from this thread for as long as the
        // tap lives on the main run loop, so this is the window in which a missed publish can be
        // caught for free — see `TapStateMirror.verify`. It is also the line to delete when the tap
        // moves: at that point the mirror *is* the input and there is nothing left to compare to.
        //
        // Key-downs only. This is scaffolding on the hottest path in the app, where the rule is that
        // nothing but trivial state changes hands, and building a `TapState` walks a few small
        // collections to compare them. Key-down is where every routing decision is actually taken —
        // `flagsChanged` returns above and a key-up is either swallowed or ignored — so restricting
        // it costs no coverage: any publish a modifier event failed to make is caught by the next
        // key-down, which is the first event that could act on it.
        if type == .keyDown { tapMirror.verify(against: liveTapState) }

        // Mask event.flags to device-independent bits only — on macOS 26, event.flags can include
        // device-dependent bits that don't match the device-independent masks we check against.
        // Polling CGEventSource.flagsState avoids those bits but races: the modifier state can
        // change between event creation and handler execution, causing stale reads.
        let flags = event.flags.intersection([
            .maskAlphaShift, .maskShift, .maskControl, .maskAlternate, .maskCommand,
            .maskHelp, .maskSecondaryFn, .maskNumericPad, .maskNonCoalesced,
        ])

        // Modifier events are never swallowed — other apps need to track modifier state, and this
        // is also the escape hatch that guarantees the panel can always be dismissed.
        if type == .flagsChanged {
            Log.tap.log(level: Log.traceLevel, "flagsChanged: flags=\(flags.rawValue, privacy: .public) held=\(self.activeHeld.rawValue, privacy: .public) stillHeld=\(self.stillHeld(flags, self.activeHeld), privacy: .public)")
            // A sticky session is defined by *not* ending here — releasing the modifier is how the
            // user gets their hands back, not how they commit.
            if !staysOpenOnRelease, (isVisible || armed || pendingSameApp), !stillHeld(flags, activeHeld) {
                releaseTrigger()
            }
            return false
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // While the panel is up it owns the keyboard, like the system switcher.
        if isVisible {
            Log.tap.log(level: Log.traceLevel, "visible: code=\(code, privacy: .public) flags=\(flags.rawValue, privacy: .public) held=\(self.activeHeld.rawValue, privacy: .public) commit=\(self.release.shouldCommit(flags: flags), privacy: .public)")
            if release.shouldCommit(flags: flags) {
                commit()
                return false
            }
            if type == .keyUp { return true }
            resetStickyIdle()
            return handleVisibleKey(code, flags, event)
        }

        // Armed: a trigger press is waiting out the show-delay. A second press shows immediately.
        if armed {
            if type == .keyUp { return true }
            if !stillHeld(flags, activeHeld) { releaseTrigger(); return true }
            showFromArm()
            // `advance` rather than a bare `layout()`: this runs on the tap callback, where a full
            // NSHostingView rebuild is the one thing that must not happen inline.
            if code == hotkey.keyCode {
                advance(flags.contains(.maskShift) ? -1 : 1)
            }
            return true
        }

        // Idle. Which binding claims the keystroke — and whether it is swallowed — is decided by
        // `TapRouting.idle`, which is pure and tested. The precedence it encodes is the one
        // documented in `ShortcutAudit.Kind` and it is load-bearing; it used to live here as the
        // order of a run of `if` statements reachable only through a live event tap, which meant it
        // could only be checked by pressing keys and watching.
        //
        // What stays here is everything that is *not* a decision: performing the effect, and
        // logging.
        let isAppActive = NSApp.isActive
        let decision = TapRouting.idle(
            TapRouting.Event(
                type: type, keyCode: code, flags: flags,
                isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0),
            bindings: routingBindings(),
            isAppActive: isAppActive)

        // A keystroke this app claims is proof the held chord is being used as a *keyboard* gesture,
        // so the hold-and-point gesture stands down exactly as it does when a drag claims it — see
        // `ModifierTargetHighlight.standDown(claimedBy:)`.
        //
        // Both mouse chords double as tiling modifiers: ⌃⌘ is the shipped resize chord *and* the
        // shipped chord for all four halves. Holding it armed the pointing gesture at the same
        // moment the arrow fired the tile, and the chord coming up then completed that gesture from
        // a cursor which had never left its dot — an offset `PointDirection.zone` reads as "nowhere
        // to point" and answers with `.maximize`. So the window was tiled to a half and instantly
        // replaced by a full-screen one, which reads as the shortcut being broken rather than as two
        // gestures on one chord. It is the same failure `standDown` was written for, from the one
        // claimant nobody had counted.
        //
        // Keyed on every claimed decision rather than on `.tile` alone: an activation or an
        // all-windows action bound to a mouse chord ends exactly the same way, and `.consume` is the
        // key-up edge of one of those.
        if decision.swallows { targetHighlight.standDown(claimedBy: "a keyboard binding") }

        switch decision {
        case .pass:
            // Nothing claimed it. Logged only when a real modifier was held, which keeps this off
            // the per-keystroke path while still catching "I pressed the chord and nothing
            // happened". Skipped while we are frontmost: there the chord is inert by design, which
            // `.tilingInert` already reports, and "no binding" would be the wrong explanation.
            if !isAppActive, type == .keyDown, tiling.isEnabled,
                !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty {
                Log.tap.log(
                    level: Log.traceLevel,
                    """
                    tiling: no binding for key \(code, privacy: .public) \
                    flags \(flags.rawValue, privacy: .public)
                    """)
            }
        case .consume:
            break
        case .open(let backwards):
            return open(backwards: backwards)
        case .openSameApp(let backwards):
            return openSameApp(backwards: backwards)
        case .openScoped(let scope, let held, let backwards):
            return openScoped(scope, held: held, backwards: backwards)
        case .activate(let bundleID):
            GlobalActions.activate(bundleID: bundleID)
        case .allWindows(let action):
            GlobalActions.perform(action)
        case .tile(let arrangement):
            Log.tap.notice("tiling: \(arrangement.rawValue, privacy: .public) matched")
            applyTiling(arrangement)
        case .tilingInert:
            // The commonest "my shortcut does nothing": the settings window has focus, so every
            // global chord is deliberately inert. Logged once per press, and only for a chord that
            // would otherwise have fired, so this is not a line per keystroke.
            Log.tap.notice("tiling: inert — Cmd-Tab is frontmost (settings window focused)")
        }
        return decision.swallows
    }

    /// The controller's live binding tables, as the lookups `TapRouting` matches against.
    ///
    /// Rebuilt per event rather than cached: each closure reads a stored property that the settings
    /// window can change at any moment, and a cached table would answer with the bindings that were
    /// in force when it was built. The closures capture `self` unowned — this runs on the tap
    /// callback, synchronously, and the controller outlives the tap it owns.
    private func routingBindings() -> TapRouting.Bindings {
        TapRouting.Bindings(
            openerMatches: { [unowned self] code, flags in
                code == self.hotkey.keyCode && self.modifiersMatch(flags, self.hotkey.heldModifiers)
            },
            sameAppMatches: { [unowned self] code, flags in
                guard let sameApp = self.sameAppHotkey else { return false }
                return code == sameApp.keyCode
                    && self.modifiersMatch(flags, sameApp.heldModifiers)
            },
            scopedMatch: { [unowned self] code, flags in
                self.scopedTriggers.scope(code: code, flags: flags)
            },
            activationMatch: { [unowned self] code, flags in
                self.activations.bundleID(code: code, flags: flags)
            },
            allWindowsMatch: { [unowned self] code, flags in
                self.allWindows.action(code: code, flags: flags)
            },
            tilingMatch: { [unowned self] code, flags in
                self.tiling.arrangement(code: code, flags: flags)
            })
    }

    /// Snaps the focused window. Both reads here are main-thread reads and this runs on the tap's
    /// own callback (which is on the main run loop), so they happen inline; every Accessibility
    /// call — the part that can block — happens on `WindowTiler`'s queue.
    private func applyTiling(_ arrangement: WindowArrangement) {
        let cycleWidths = tiling.cycleWidths
        let gap = tiling.gap
        let follows = tiling.followsDesktopMove
        let warpsPointer = tiling.pointerFollowsDisplayMove
        // Posted, not inline. `frontmostApplication` and the screen walk are both NSWorkspace/AppKit
        // reads, which the class invariant keeps off the tap callback — and there is nothing to
        // report back, since the key is already swallowed by the time this runs.
        let rules = appRules
        DispatchQueue.main.async {
            // Our own windows are tiled like anyone else's. The switcher panel does not activate
            // this app, so being frontmost means an ordinary window — Settings, or the permissions
            // window — is in front, and a chord that works on every other window has no business
            // refusing that one.
            guard let front = NSWorkspace.shared.frontmostApplication,
                let pid = Optional(front.processIdentifier)
            else {
                Log.tap.notice("tiling: no frontmost app to act on")
                return
            }
            // Focus first, and *before* the `neverTile` guard below: that rule is about this app
            // resizing someone's windows, and moving the keyboard to a window resizes nothing. An
            // app excluded from tiling is still an app you need to be able to reach.
            if let direction = arrangement.focusStep {
                WindowNavigator.focus(direction, from: pid)
                return
            }
            // An app the user has told us never to tile. Checked here rather than in `WindowTiler`
            // so the tiler stays a pure geometry writer with no opinion about settings.
            if let id = front.bundleIdentifier, rules[id]?.neverTile == true {
                Log.tap.notice("tiling: \(id, privacy: .public) is set to never tile")
                return
            }
            // A swap needs the window *next to* this one, which no frame computed from one screen
            // can express — so it never reaches the tiler either. It re-checks `neverTile` for both
            // ends; see `WindowNavigator.swap`.
            if let direction = arrangement.swapStep {
                WindowNavigator.swap(direction, from: pid, rules: rules)
                return
            }
            // A Desktop move is not geometry, so it does not go to the tiler. `WindowTiler.apply`
            // computes a frame and writes it over Accessibility; there is no frame that expresses
            // "one Desktop along", and the move takes seconds and drives the pointer. See
            // `DesktopMover`.
            if let step = arrangement.desktopStep {
                Log.tap.notice(
                    "desktop move: pid \(pid, privacy: .public), step \(step, privacy: .public)")
                DesktopMover.move(pid: pid, step: step, follow: follows)
                return
            }
            Log.tap.notice(
                "tiling: applying to pid \(pid, privacy: .public), gap \(Int(gap), privacy: .public)")
            WindowTiler.apply(
                arrangement, pid: pid, areas: WindowTiler.visibleAreas(),
                cycleWidths: cycleWidths, gap: gap, warpsPointer: warpsPointer)
        }
    }

    /// Runs a `cmdtab://` request.
    ///
    /// Routed through exactly the same functions the chords use, so a URL and a keypress cannot
    /// drift apart in what they do — which is the whole reason this is three lines rather than a
    /// second implementation of each action.
    ///
    /// The two master switches are treated differently on purpose. **Tiling's** switch is not
    /// consulted: it exists to stop this app *claiming global chords* from other applications, and a
    /// URL claims nothing from anybody — refusing to tile because a checkbox about hotkeys is off
    /// would be a setting doing something it never described. The **Desktop moves'** switch is
    /// consulted, because that one is not about chords at all: it guards a gesture that seizes the
    /// pointer and flashes Mission Control for the better part of a second, and consent to that is
    /// not something a URL should be able to route around.
    func perform(_ command: URLCommand) {
        switch command {
        case .arrangement(let arrangement):
            if arrangement.desktopStep != nil, !tiling.desktopMoves {
                Log.general.notice("url: desktop moves are switched off; ignoring")
                return
            }
            applyTiling(arrangement)
        case .activate(let bundleID):
            GlobalActions.activate(bundleID: bundleID)
        case .allWindows(let action):
            GlobalActions.perform(action)
        }
    }

    /// Moves the highlight.
    private func advance(_ delta: Int) {
        model.step(delta)
        // Off the tap callback — see `scheduleLayout`.
        scheduleLayout()
    }

    /// Moves the highlight one row up or down.
    ///
    /// The stride comes from the panel, which is the only thing that knows where the list wrapped —
    /// it is a function of the display the panel drew on and the metrics it drew with, neither of
    /// which the controller may go reading from here. See `PanelGroup.rowStride`.
    private func advanceRow(_ delta: Int) {
        model.stepRow(delta, stride: panels.rowStride)
        // Off the tap callback, exactly as `advance` is.
        scheduleLayout()
    }

    private func handleVisibleKey(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) -> Bool {
        // The trigger key. While the chord is held it advances the selection, the classic cycle; once
        // the chord is up — a stay-open session — it switches to whatever is highlighted, because
        // there is no longer a release to do that job. Deliberately *before* `endSteering`, so a Tab
        // out of a steered window strip still commits the window the strip has selected.
        if code == hotkey.keyCode {
            // Only the real Tab key may become the go key, and only on a fresh press.
            //
            // A trigger bound to a printable key is legal (`HotkeyRecorder` takes any key with
            // ⌘/⌥/⌃, so ⌘-E is bindable), and promoting *that* key to "switch now" made it both
            // uncommittable and untypable once the chord was up: pressing `e` to filter for "Excel"
            // switched apps instead, with no way back. It cycles the highlight there, as it did
            // before Tab-commit existed.
            //
            // An auto-repeat is the user still leaning on the key from the cycle they started, not a
            // fresh press meaning "go". Letting ⌘ up a moment before Tab is the ordinary way this
            // gesture ends, and without this the next repeat commits and closes the panel — exactly
            // the stay-open failure this predicate was written to fix.
            let repeated = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if code == Key.tab, !repeated, release.tabCommits(flags: flags) {
                commit()
                return true
            }
            advance(flags.contains(.maskShift) ? -1 : 1)
            return true
        }

        // The modifiers held on top of the trigger. ⌥/⌃ mean the key is not meant as text, so it
        // never reaches type-to-filter. The trigger's own modifiers are subtracted so a trigger that
        // itself uses ⌥/⌃ (e.g. ⌘⌥-Tab) doesn't make every key look modified and swallow the query.
        let extra = flags.intersection([.maskAlternate, .maskShift, .maskControl])
            .subtracting(activeHeld)
        // Configurable window actions, ahead of the navigation switch below so a bound ⌥←/→ reaches
        // its binding rather than being eaten as a plain arrow. An arrow carrying no extra modifier
        // never gets this far, since `extra` is empty for it.
        if actionsEnabled, !extra.isEmpty {
            if let action = shortcuts.action(code: code, extra: extra) {
                Log.tap.notice(
                    "action \(action.rawValue, privacy: .public) (key \(code, privacy: .public))")
                perform(action)
                return true
            }
            // Only when ⌥/⌃ is involved. Shift alone means a typed capital going to type-to-filter,
            // which is once per keystroke — far too hot for the tap callback, where the file's own
            // header insists the work stays trivial.
            if !extra.intersection([.maskAlternate, .maskControl]).isEmpty {
                Log.tap.notice(
                    "no action for key \(code, privacy: .public) extra \(extra.rawValue, privacy: .public)")
            }
        }
        // Navigation and editing keys.
        switch code {
        case Key.escape:
            // Unconditional, deliberately. While the panel is up this handler swallows every key on
            // the system, so Escape is the user's last-resort way out and must never depend on any
            // other state. Backspace already backs out of a query character by character, so making
            // Escape search-field-like ("first press clears the query") bought very little and cost
            // the one exit that is supposed to always work.
            cancel()
            return true
        case Key.rightArrow: advance(1); return true
        case Key.leftArrow: advance(-1); return true
        // A row rather than a tile. Both keys were swallowed and did nothing until now, which in a
        // grid is the one arrow direction there is no other way to travel in: reaching the tile
        // below meant pressing → as many times as the grid is wide.
        case Key.downArrow: advanceRow(1); return true
        case Key.upArrow: advanceRow(-1); return true
        case Key.enter: commit(); return true
        case Key.delete:
            if !model.query.isEmpty { setQuery(String(model.query.dropLast())) }
            return true
        default: break
        }
        // A digit jumps straight to that tile — but only with no query, so a query can still contain
        // digits (typing into a filtered list rather than jumping).
        if model.query.isEmpty, Key.digits[code] != nil {
            jump(to: Key.digits[code]!)
            return true
        }
        // Anything else that resolves to a visible character extends the filter query. ⌥/⌃ are action
        // modifiers, so a key held with either never types.
        if extra.intersection([.maskAlternate, .maskControl]).isEmpty,
            let character = Self.typedCharacter(from: event) {
            setQuery(model.query + character)
            return true
        }
        // Command is held, so passing keys through would fire shortcuts in the app behind us.
        return true
    }

    /// Applies a new filter query and relays out — the list, and often its column count, change.
    private func setQuery(_ query: String) {
        model.setQuery(query)
        // The one decision input `didSet` cannot reach, since the query lives on the model. Only
        // whether there *is* one is mirrored — see `TapState.hasQuery`.
        publishTapState()
        updateLaunchSuggestions(for: query)
        scheduleLayout()
    }

    /// Whether a query that matches nothing running may offer installed apps to launch.
    var launchFromSearch = true

    /// Offers installed apps when the query has matched nothing on screen.
    ///
    /// Only on an empty result, deliberately: the switcher is a switcher, and padding a list that
    /// already has what you asked for with apps you would have to launch is noise. This is the
    /// moment the panel would otherwise say "No matches", which is exactly when a launcher is
    /// useful and nothing is being displaced.
    ///
    /// Runs against `InstalledApps`' in-memory catalogue — a filter over a few hundred strings, no
    /// disk — so it is safe on the keystroke path. The icon lookup is the one piece of I/O, and it
    /// is memoised in `launchIcons` for exactly that reason: this is reached from `setQuery`, which
    /// is reached from the tap callback, so an uncached `icon(forFile:)` per suggestion per
    /// keystroke is disk-backed LaunchServices work inline on the key path — the one thing the
    /// class comment's invariant says must never go there.
    private func updateLaunchSuggestions(for query: String) {
        guard launchFromSearch, !model.matchesAnything, !query.isEmpty else {
            model.setLaunchSuggestions([])
            return
        }
        // Only the apps that actually have a tile, not every app that happens to be running.
        //
        // Excluding all running apps left a hole with "hide apps with no open windows" turned on: an
        // app that is running but owns no window — a Finder whose last window was closed is the one
        // people hit — was filtered out of the switcher for having no window *and* refused a launch
        // suggestion for being running, so there was no way to reach it at all. A running app that
        // does have a tile is still excluded, which is all this was ever for: a suggestion must
        // never duplicate a tile the user is already looking at.
        //
        // Picking such a suggestion is correct rather than a fudge: `openApplication` on an already
        // running app is a reopen event, which is what makes it produce a window.
        var excluded = provider.excludedBundleIDs
        let tiled = Set(model.targets.map(\.pid))
        for app in NSWorkspace.shared.runningApplications {
            guard let id = app.bundleIdentifier, tiled.contains(app.processIdentifier) else {
                continue
            }
            excluded.insert(id)
        }
        // A favourite that isn't running already carries a `launch:<bundleID>` tile, and a
        // suggestion for the same app builds the identical id — `ForEach(id:)` then has duplicate
        // ids, so the app shows twice and both ⌘-number and hit-testing count both. The loop above
        // can never catch these: a launchable favourite is not running, by construction. Matched on
        // the id rather than the name because the two names come from different sources
        // (`FileManager.displayName` for the tile, `CFBundleDisplayName` for the catalogue), which
        // is precisely what lets a query hit one and miss the other.
        let alreadyTiled = Set(model.targets.map(\.id))
        let suggestions = InstalledApps.matches(query, excluding: excluded)
            .filter { !alreadyTiled.contains("launch:\($0.bundleID)") }
            .map { entry -> SwitchTarget in
                let icon: NSImage?
                if let cached = launchIcons[entry.bundleID] {
                    icon = cached
                } else {
                    let resolved = NSWorkspace.shared.icon(forFile: entry.url.path)
                    launchIcons[entry.bundleID] = resolved
                    icon = resolved
                }
                return SwitchTarget(
                    id: "launch:\(entry.bundleID)", kind: .launch(entry.url), title: entry.name,
                    appName: entry.name, icon: icon, isMinimized: false, isHidden: false)
            }
        model.setLaunchSuggestions(suggestions)
        // Re-run the query so the freshly added tiles are matched and one of them is selected;
        // without it the panel would show suggestions with nothing highlighted.
        if !suggestions.isEmpty { model.setQuery(query) }
    }

    /// Set while a relayout is already queued for the next main-loop turn.
    private var layoutQueued = false

    /// Relayout on the next main-loop turn instead of inline, and at most once per turn.
    ///
    /// `panels.layout()` reassigns the hosting view's root, runs `layoutSubtreeIfNeeded`, reads
    /// `fittingSize` and resizes the window — all synchronous SwiftUI work, and once per panel when
    /// mirrored across displays. Every caller on the key path runs inside the `CGEventTap` callback,
    /// and a tap that overruns the system's deadline is disabled outright: macOS posts
    /// `tapDisabledByTimeout` and *every* keystroke during the stall is dropped machine-wide.
    /// Type-to-filter made that a per-character risk rather than a per-Tab-press one.
    ///
    /// Hopping off the callback keeps the tap's own work trivial, but on its own it does not bound
    /// the load: a burst of key events (auto-repeat on the trigger, a fast typist filtering) posted
    /// one full layout each onto the very run loop the tap is serviced from. Collapsing the burst
    /// into one layout is what actually caps it.
    private func scheduleLayout() {
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutQueued = false
            guard self.isVisible else { return }
            MainLoopMonitor.marking("panel layout") {
                self.panels.layout()
                // The list under a stationary cursor may have changed — a tile quit, closed or
                // hidden, or a background refresh folded in a new one — so the strip has to follow
                // whatever is under the pointer now. Deduped downstream, so an unchanged target
                // costs nothing.
                self.panels.refreshPreview()
            }
        }
    }

    /// The character a key event would type, ignoring ⌘/⌥/⌃ (Shift/Caps kept for case) and honouring
    /// the active keyboard layout, so type-to-filter follows the physical keys the user actually
    /// presses. Returns nil for control keys and anything that isn't a plain letter/number/space/dash.
    private static func typedCharacter(from event: CGEvent) -> String? {
        guard let copy = event.copy() else { return nil }
        copy.flags = copy.flags.intersection([.maskShift, .maskAlphaShift])
        var length = 0
        var buffer = [UniChar](repeating: 0, count: 4)
        copy.keyboardGetUnicodeString(maxStringLength: 4, actualStringLength: &length, unicodeString: &buffer)
        guard length == 1 else { return nil }
        let string = String(utf16CodeUnits: buffer, count: 1)
        guard let scalar = string.unicodeScalars.first else { return nil }
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
            .union(CharacterSet(charactersIn: "-_.'"))
        return allowed.contains(scalar) ? string : nil
    }

    // MARK: - Actions

    /// Opens the switcher, or arms a quick-switch if a show-delay is set. Returns false — declining
    /// to swallow — only when there is nothing to show.
    @discardableResult
    private func open(backwards: Bool) -> Bool {
        // Filtered here rather than in the cache — see `windowSpaceScope`. Only the main trigger
        // does this: the same-app cycle and the scoped triggers are each a deliberate request for a
        // named subset, and narrowing one of those by a *global* setting would mean a chord bound to
        // "all windows" quietly showing some of them.
        let targets = windowSpaceScope == .currentDesktop
            ? Self.onCurrentDesktop(provider.snapshot())
            : provider.snapshot()
        // Decided before anything is assigned — see `SessionOpen.plan`, which exists so the order
        // cannot drift: session state set before the bail-out left `isSticky` latched true after a
        // press that opened nothing, so the *next* session, including one from a different hotkey,
        // silently came up sticky.
        let plan = SessionOpen.plan(
            hasTargets: !targets.isEmpty, showDelay: showDelay, isSticky: stickyMode)
        guard plan != .decline else {
            Log.targets.error("trigger with an empty list; cache not warm?")
            return false
        }
        beginSession()
        activeHeld = hotkey.heldModifiers
        isSticky = stickyMode
        if case .arm(let watchdog) = plan {
            armed = true
            armedBackwards = backwards
            armedTargets = targets
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.showFromArm() }
            }
            armWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
            // Armed swallows keys too, and gets out the same way — so it needs the same failsafe.
            // Not for a sticky session: it does not end on release at all, so the poll can never act
            // (`watchdogTick` returns at its first guard), and nothing downstream stops it — it just
            // woke the main runloop 5×/s for the life of the panel, up to the 60 s ceiling.
            if watchdog { startWatchdog() }
            return true
        }
        showWith(targets: targets, backwards: backwards)
        return true
    }

    /// Opens the frontmost app's windows — the same-app cycle. Always swallows the key: the window
    /// list arrives asynchronously, so there is no way to know yet whether there is anything to show,
    /// and letting the chord through would fire it in the app behind us a moment later.
    private func openSameApp(backwards: Bool) -> Bool {
        guard AsyncSession.canOpen(pendingSameApp: pendingSameApp, isVisible: isVisible, armed: armed)
        else { return true }
        let token = beginSession()
        activeHeld = sameAppHotkey?.heldModifiers ?? [.maskCommand]
        // Never inherits stickiness from the main trigger's setting — this hotkey was not the one
        // the user asked to stay open.
        isSticky = false
        pendingSameApp = true
        pendingSameAppReleased = false
        startWatchdog()

        // The fetch is an Accessibility walk against an app that may be wedged, and it has no bound
        // of its own. Without a deadline a result landing long after the user gave up still switches
        // their windows — mid-sentence, in whatever they moved on to. Bumping the token is what makes
        // the late callback drop itself.
        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSameApp, token == self.sessionToken else { return }
            Log.tap.notice("same-app window fetch timed out; abandoning the cycle")
            self.beginSession()
            self.stopWatchdog()
        }
        sameAppDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + sameAppTimeout, execute: deadline)

        provider.frontAppWindowTargets { [weak self] targets in
            // `assumeIsolated`, not a `Task`: `TargetProvider` always hops back to the main thread
            // before calling a handler, so this *is* already on the main actor — the closure is
            // `@Sendable` only because it crossed `axQueue` to get here. A `Task` would defer the
            // work to a later turn, and the session it belongs to could end in between.
            MainActor.assumeIsolated {
            // The fetch is unbounded (an Accessibility walk against a possibly wedged app), so by
            // the time it lands the user may have abandoned this cycle and opened a normal session.
            // Acting on it then would stop *that* session's watchdog — deleting the failsafe that
            // stands between a missed modifier-release and a machine-wide keyboard lockout.
            guard let self else { return }
            // One window is nothing to cycle *between*, so this path wants two.
            let outcome = AsyncSession.outcome(
                isCurrent: self.pendingSameApp && token == self.sessionToken,
                count: targets.count, atLeast: 2,
                wasReleased: self.pendingSameAppReleased, backwards: backwards)
            guard outcome != .stale else { return }
            self.sameAppDeadline?.cancel()
            self.sameAppDeadline = nil
            self.pendingSameApp = false

            switch outcome {
            case .stale:
                return
            case .abandon:
                self.pendingSameAppReleased = false
                self.stopWatchdog()
            case .show:
                self.showWith(targets: targets, backwards: backwards, mode: .windows)
            case .focus(let index):
                // Tapped and released before the list landed: do the switch without ever drawing.
                self.pendingSameAppReleased = false
                self.stopWatchdog()
                let target = targets[index]
                DispatchQueue.main.async { self.focus(target) }
            }
            }
        }
        return true
    }

    /// Opens a scoped session: the window list narrowed to one app, one display, or the minimized
    /// ones.
    ///
    /// Shares the same-app cycle's shape — the list arrives asynchronously, so the chord is always
    /// swallowed and the same session token, deadline and watchdog guard the late callback. `.frontApp`
    /// routes through the existing front-app fetch rather than filtering the whole list: that walk
    /// touches one app instead of every running one, which is the difference between a few
    /// Accessibility round-trips and a few hundred.
    private func openScoped(_ scope: SwitcherScope, held: CGEventFlags, backwards: Bool) -> Bool {
        guard AsyncSession.canOpen(pendingSameApp: pendingSameApp, isVisible: isVisible, armed: armed)
        else { return true }
        let token = beginSession()
        activeHeld = held
        // Not inherited from the main trigger's setting: this chord is not the one the user asked to
        // stay open, the same reasoning `openSameApp` uses.
        isSticky = false
        pendingSameApp = true
        pendingSameAppReleased = false
        startWatchdog()

        let deadline = DispatchWorkItem { [weak self] in
            guard let self, self.pendingSameApp, token == self.sessionToken else { return }
            Log.tap.notice("scoped window fetch timed out; abandoning")
            self.beginSession()
            self.stopWatchdog()
        }
        sameAppDeadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + sameAppTimeout, execute: deadline)

        // `@Sendable` because it is handed to `TargetProvider`, which builds its list on `axQueue`.
        // It is still only ever *called* on the main thread — see the note in `openSameApp`.
        let receive: @Sendable ([SwitchTarget]) -> Void = { [weak self] targets in
            MainActor.assumeIsolated {
            guard let self else { return }
            let filtered = Self.filter(targets, to: scope)
            // One hit is a successful search here, not an empty one — narrowing to "minimized
            // windows" and finding exactly one is worth switching to.
            let outcome = AsyncSession.outcome(
                isCurrent: self.pendingSameApp && token == self.sessionToken,
                count: filtered.count, atLeast: 1,
                wasReleased: self.pendingSameAppReleased, backwards: backwards)
            guard outcome != .stale else { return }
            self.sameAppDeadline?.cancel()
            self.sameAppDeadline = nil
            self.pendingSameApp = false

            switch outcome {
            case .stale:
                return
            case .abandon:
                self.pendingSameAppReleased = false
                self.stopWatchdog()
            case .show:
                self.showWith(targets: filtered, backwards: backwards, mode: .windows)
            case .focus(let index):
                // Tapped and released before the list landed: switch without ever drawing.
                self.pendingSameAppReleased = false
                self.stopWatchdog()
                let target = filtered[index]
                DispatchQueue.main.async { self.focus(target) }
            }
            }
        }

        if scope == .frontApp {
            provider.frontAppWindowTargets(then: receive)
        } else {
            provider.allWindowTargets(then: receive)
        }
        return true
    }

    /// Narrows a window list to a scope. `.frontApp` and `.allWindows` are already exactly what was
    /// fetched, so only the three filtering scopes do anything here.
    private static func filter(_ targets: [SwitchTarget], to scope: SwitcherScope) -> [SwitchTarget] {
        switch scope {
        case .frontApp, .allWindows:
            return targets
        case .minimized:
            return targets.filter(\.isMinimized)
        case .currentDisplay:
            // `displayIndex` is only populated when there is more than one display to tell apart, so
            // with one screen every window trivially qualifies — which is the right answer anyway.
            guard NSScreen.screens.count > 1,
                let cursorScreen = NSScreen.underCursor,
                let index = NSScreen.screens.firstIndex(of: cursorScreen)
            else { return targets }
            return targets.filter { $0.displayIndex == index }
        case .currentDesktop:
            return onCurrentDesktop(targets)
        }
    }

    /// The windows on whichever Desktop is in front — of each display, on a machine with several.
    ///
    /// The current Space is read *here*, not carried on the targets. A window's own Space does not
    /// change when you switch Desktops, but which Space is in front does, and the target list is
    /// built at refresh time — which is to say, at the last moment an app happened to activate.
    /// Switching to an empty Desktop and pressing the trigger activates nothing, so a list filtered
    /// against a remembered "current" would show the Desktop you just left.
    ///
    /// A window with no Space at all is **kept**, not dropped. That is a minimized window (which
    /// occupies no Space and is in the Dock, which is everywhere) and it is also every window on a
    /// machine where the private Space calls are unavailable — so the failure mode of this filter is
    /// showing too much rather than a switcher that has silently gone empty.
    private static func onCurrentDesktop(_ targets: [SwitchTarget]) -> [SwitchTarget] {
        let current = SpaceMover.currentSpaceIDs()
        guard !current.isEmpty else { return targets }
        return targets.filter { target in
            guard let space = target.spaceID else { return true }
            return current.contains(space)
        }
    }

    /// Invalidates anything still in flight from a previous session and returns the new token.
    @discardableResult
    private func beginSession() -> Int {
        sessionToken &+= 1
        pendingSameApp = false
        pendingSameAppReleased = false
        sameAppDeadline?.cancel()
        sameAppDeadline = nil
        return sessionToken
    }

    /// The show-delay elapsed (or a re-press arrived) while still held: actually draw the panels.
    private func showFromArm() {
        guard armed else { return }
        armWorkItem?.cancel()
        armWorkItem = nil
        armed = false
        showWith(targets: armedTargets, backwards: armedBackwards)
    }

    /// `mode` is what the tiles *are*: it drives whether they carry their own title and whether the
    /// caption names the owning app.
    ///
    /// Defaulted to the user's setting rather than to `.apps`, so the main list presents itself the
    /// way the provider built it. The same-app cycle passes `.windows` explicitly — it shows one
    /// app's windows whatever the setting says, which is the whole point of it.
    private func showWith(
        targets: [SwitchTarget], backwards: Bool, mode: SwitcherMode? = nil
    ) {
        // An explicit `mode` is exactly what distinguishes a narrowed session from the global one:
        // only `openSameApp` and `openScoped` pass it, and both hand in a list already filtered to
        // one app, one display, or the minimized windows. The global openers pass nothing and take
        // `provider.mode`. Recorded because the background refresh below must not touch a narrowed
        // session — see the guard there.
        isScopedSession = mode != nil
        let token = sessionToken
        let mode = mode ?? provider.mode
        model.mode = mode
        model.begin(targets)
        // The frontmost app/window is index 0, so a plain tap lands on the previous one — unless
        // pinned favourites hold the front of the list, which is what `tapIndex` answers for.
        model.selection = backwards
            ? targets.count - 1
            : provider.tapIndex(in: targets, mode: mode)

        // The state flip stays synchronous — the very next key event has to see `isVisible` — but
        // everything that *costs* anything is deferred. `panels.show()` runs a full SwiftUI layout,
        // and `provider.refresh` does `switchableApps()`, screen-frame lookups and `launchFavorites`
        // (NSWorkspace/LaunchServices) on the calling thread before it ever reaches its background
        // queue. All of that was running inside the event-tap callback, which is the one place in
        // this app where being slow costs the user every keystroke on the machine.
        isVisible = true
        // The two session shapes get different safety nets. A held-modifier session is watched by
        // polling the hardware for the release its `flagsChanged` may never deliver; a sticky one
        // does not end on release at all, so its net is the guards below — click-away, idle, ceiling.
        if isSticky {
            // Nothing should have started the poll for a sticky session, but this is the one place
            // that knows the session shape for certain, and an orphaned watchdog is a timer no later
            // code owns.
            stopWatchdog()
            startStickyGuards()
        } else if !activeHeld.isEmpty {
            startWatchdog()
        }

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            MainLoopMonitor.marking("panel show") { self.panels.show() }
            // `.public` deliberately: interpolation redacts by default, and this line reading
            // `frame=<private>` is exactly why a log full of apparently healthy shows could not
            // tell a panel that drew from one that came up 0×0 or fully transparent. There is
            // nothing personal in a rectangle.
            Log.general.notice(
                """
                panel shown: \(self.panels.diagnostics, privacy: .public) \
                targets=\(self.model.targets.count, privacy: .public)
                """)

            // Only the global session folds in a fresh list. `provider.refresh` rebuilds from
            // `provider.mode` over every switchable app and has no notion of the narrowing
            // `openSameApp` and `openScoped` applied, while `model.update` replaces the list
            // wholesale — so for a narrowed session this swapped one app's windows for every window
            // on the machine, mid-hold, 0.15s after the panel came up. In the default `.apps` mode
            // the `win:` anchor is not even present in the fresh list, so `reapply` fell back to
            // `min(selection, count - 1)`, the highlight jumped, and releasing ⌘ committed the
            // wrong app.
            guard !self.isScopedSession else { return }
            // The cache can be a moment stale; fold in a fresh list without disturbing the highlight.
            self.provider.refresh { [weak self] fresh in
                // `@Sendable` because the list is built on `axQueue`; still only ever *called* on
                // the main thread, which is where `TargetProvider` hands its handlers back.
                MainActor.assumeIsolated {
                    // `token` for the same reason every other async completion here carries one: a
                    // pass outlives the session that asked for it, and answering into the next one
                    // is answering with the wrong list.
                    guard let self, self.isVisible, token == self.sessionToken else { return }
                    self.model.update(targets: fresh)
                    self.finishListMutation()
                }
            }
        }
    }

    private func hide() {
        isVisible = false
        isSticky = false
        isScopedSession = false
        // Anything still in flight belongs to the session just ended.
        beginSession()
        stopWatchdog()
        stopStickyGuards()
        panels.hide()
        preview.teardown()
        // A thumbnail is a photograph of a moment. Showing the next session what the last one
        // looked like is worse than showing it an icon.
        thumbnails.cancel()
        model.thumbnails = [:]
    }

    /// Brings a target forward, recording a window pick on the way.
    ///
    /// Every commit path goes through here so the window MRU sees the pick. See
    /// `TargetProvider.noteFocused(window:)` for why the activation notification cannot: a same-app
    /// pick never changes the frontmost app, so it never fires one.
    private func focus(_ target: SwitchTarget) {
        if let id = target.windowID { provider.noteFocused(window: id) }
        target.focus()
    }

    private func commit() {
        guard isVisible else { return }
        let target = model.selected
        let rules = appRules
        hide()
        // Off the tap callback — activating an app is an AX / NSWorkspace round-trip against a
        // process that may not answer promptly.
        DispatchQueue.main.async {
            guard let target else { return }
            if Self.hidesInsteadOfSwitching(to: target, rules: rules) {
                Log.tap.notice("commit: pid \(target.pid, privacy: .public) is already front — hiding")
                target.hideApp()
                return
            }
            // The ordinary switch used to be the one outcome that logged nothing, so a session read
            // back afterwards ended at "panel shown" with no record of what it picked — and an app
            // pick leaves no other trace at all, since only the cross-Desktop window path narrates
            // itself. The target id is `app:<pid>` / `win:<id>` / `launch:<bundle>`, which names the
            // kind and the thing without carrying a window title.
            Log.tap.notice(
                "commit: \(target.id, privacy: .public) pid \(target.pid, privacy: .public)")
            self.focus(target)
        }
    }

    /// Whether committing to `target` should hide it rather than switch to it.
    ///
    /// Only when it is *already* frontmost, and only for an app the user has asked this of. Cycling
    /// back to where you started and releasing is otherwise a no-op — the one commit that cannot
    /// mean "bring this forward", since it is already there.
    ///
    /// A launch tile is excluded outright: its app is by definition not running, so it cannot be
    /// frontmost, and its -1 pid would match any other launch tile's.
    ///
    /// Main-thread only — `NSWorkspace` and `NSRunningApplication` both want it.
    private static func hidesInsteadOfSwitching(
        to target: SwitchTarget, rules: [String: AppRule]
    ) -> Bool {
        guard !target.isLaunchable,
            let front = NSWorkspace.shared.frontmostApplication,
            front.processIdentifier == target.pid,
            let bundleID = front.bundleIdentifier
        else { return false }
        return rules[bundleID]?.hideWhenFrontmost == true
    }

    /// Modifier released. In the tap window this is a quick-switch to the previous target with no
    /// panel; once the panel is up it is a normal commit.
    private func releaseTrigger() {
        // The list is still in flight; remember the release so the fetch can act on it.
        if pendingSameApp {
            pendingSameAppReleased = true
            return
        }
        if armed {
            armWorkItem?.cancel()
            armWorkItem = nil
            armed = false
            stopWatchdog()
            let index = armedBackwards
                ? armedTargets.count - 1
                : provider.tapIndex(in: armedTargets, mode: provider.mode)
            if armedTargets.indices.contains(index) {
                let target = armedTargets[index]
                DispatchQueue.main.async { self.focus(target) }
            }
            return
        }
        commit()
    }

    private func cancel() {
        armed = false
        armWorkItem?.cancel()
        armWorkItem = nil
        beginSession()
        stopWatchdog()
        guard isVisible else { return }
        hide()
    }

    // MARK: - Session watchdog

    /// Polls the *real* modifier state for as long as a session is open.
    ///
    /// The normal way a session ends is a `.flagsChanged` telling us the trigger modifier came up.
    /// That event is not guaranteed to arrive: another session-level, head-inserted tap ahead of
    /// ours can consume it, and keyboard remappers (Karabiner and the like) both rewrite and
    /// synthesize modifier events. A missed release used to be unrecoverable — `isVisible` stayed
    /// true, and since `handleVisibleKey` swallows every key that reaches it, the result was a
    /// system-wide keyboard lockout with no way out but killing the app or logging out.
    ///
    /// Querying the hardware state gives us an exit that does not depend on an event being
    /// delivered. Deliberately *not* a timeout: holding the trigger for a long time is legitimate,
    /// so the session ends when the modifier is actually up, never merely because time passed.
    private func startWatchdog() {
        guard watchdog == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.watchdogTick() }
        }
        // A failsafe poll, so the exact instant it fires does not matter. The tolerance lets the run
        // loop batch it with other work instead of forcing a wakeup of its own — this runs on the
        // same loop the event tap is serviced from, and only ever while a session is open.
        timer.tolerance = 0.05
        RunLoop.main.add(timer, forMode: .common)
        watchdog = timer
    }

    private func stopWatchdog() {
        watchdog?.invalidate()
        watchdog = nil
    }

    // MARK: - Sticky session guards

    /// A sticky session has no held modifier, so `startWatchdog`'s hardware poll has nothing to
    /// check — and this is still a state that swallows every key on the machine. These two guards
    /// are what replace it: a click anywhere outside the panel, and a hard inactivity ceiling.
    /// Escape stays the immediate manual exit, as everywhere else.
    private func startStickyGuards() {
        // Idempotent. `showWith` can run twice for one visible panel — the case that first showed it
        // was a menu-bar open racing an in-flight arm, and that entry point is gone, but assigning
        // straight over `stickyOutsideMonitor` orphaned the previous one: a global mouse monitor
        // that outlived every later session and cancelled them. Cheap insurance to keep.
        stopStickyGuards()
        // A global monitor only sees events bound for *other* apps. Our panels are non-activating
        // and receive their clicks through `sendEvent`, so anything arriving here is by definition
        // a click outside the switcher.
        stickyOutsideMonitor = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSticky else { return }
                self.cancel()
            }
        }
        // One repeating check against `lastStickyActivity`, rather than tearing down and rebuilding
        // a one-shot timer on every keystroke — that churned a run-loop source per key, on the loop
        // that has to service the event tap. The coarse interval is deliberate: this only has to
        // notice a panel that was walked away from.
        lastStickyActivity = Date()
        let idle = Timer(timeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSticky,
                    Date().timeIntervalSince(self.lastStickyActivity) >= self.stickyIdleTimeout
                else { return }
                Log.tap.notice("sticky session idle; dismissing so the keyboard is not held")
                self.cancel()
            }
        }
        idle.tolerance = 0.5
        RunLoop.main.add(idle, forMode: .common)
        stickyIdleTimer = idle

        // The absolute cap, started once and never restarted. This is the piece that actually bounds
        // how long the keyboard can stay captured; the idle timer only measures *quiet*, and a
        // session being typed into is never quiet.
        let ceiling = Timer(timeInterval: stickyMaxDuration, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isSticky else { return }
                Log.tap.error("sticky session hit its ceiling; dismissing to release the keyboard")
                self.cancel()
            }
        }
        ceiling.tolerance = 1
        RunLoop.main.add(ceiling, forMode: .common)
        stickyCeilingTimer = ceiling
    }

    private func stopStickyGuards() {
        if let stickyOutsideMonitor { NSEvent.removeMonitor(stickyOutsideMonitor) }
        stickyOutsideMonitor = nil
        stickyIdleTimer?.invalidate()
        stickyIdleTimer = nil
        stickyCeilingTimer?.invalidate()
        stickyCeilingTimer = nil
    }

    /// Restarts the inactivity countdown. Called on every keystroke the panel handles, so it only
    /// bites when the switcher has genuinely been abandoned — walked away from, or opened by accident
    /// and forgotten. It is *not* the bound on keyboard capture; `stickyCeilingTimer` is.
    ///
    /// A bare timestamp write: the timer that reads it is started once per sticky session in
    /// `startStickyGuards`. This is on the key path, where the rule is that nothing but cheap
    /// in-memory state changes hands.
    private func resetStickyIdle() {
        guard isSticky else { return }
        lastStickyActivity = Date()
    }

    private func watchdogTick() {
        // A sticky session has no modifier to poll, so the release this looks for is meaningless —
        // acting on it quick-switches out of a session the user asked to stay open. `flagsChanged`
        // already carries this guard; the watchdog is the other half and was missing it, which made
        // sticky mode silently do nothing whenever a show-delay let the watchdog start first. Neither
        // `open` nor `showWith` starts the poll for a sticky session any more, so this is now the
        // backstop rather than the fix — a session that turns sticky under a running timer stops it
        // in `showWith`, and this makes the window between the two harmless.
        guard !staysOpenOnRelease else { return }
        guard isVisible || armed || pendingSameApp else {
            stopWatchdog()
            return
        }
        // `.combinedSessionState` is the post-tap view of what is physically held, so it stays
        // right even when the event that would have told us never reached our callback.
        guard !stillHeld(CGEventSource.flagsState(.combinedSessionState), activeHeld) else { return }
        Log.tap.error("watchdog: trigger released with no flagsChanged; ending session")
        releaseTrigger()
    }

    /// Switches straight to the numbered tile rather than just moving the highlight — the number
    /// is a shortcut, and waiting for ⌘ to come up would make it slower than the arrow keys.
    ///
    /// A digit past the end of the list is still swallowed. Letting it through would fire ⌘-7 in
    /// whatever app is behind the panel, which is a far worse outcome than doing nothing.
    private func jump(to number: Int) {
        let index = number - 1
        guard model.targets.indices.contains(index) else {
            Log.tap.notice("cmd-\(number): no such target (\(self.model.targets.count) shown)")
            return
        }
        model.selection = index
        Log.tap.notice("cmd-\(number): -> \(self.model.targets[index].title)")
        commit()
    }

    /// Dismiss only when nothing is left at all (a query matching nothing keeps the panel up),
    /// otherwise relayout.
    private func finishListMutation() {
        if !model.hasAnyTarget {
            // Worth a line: the session opened with a list, so something emptied it underneath the
            // user. That is a legitimate outcome (the last window closed) and also what a failed
            // window-list read used to look like, which made the panel appear to vanish on its own.
            Log.targets.notice("refresh emptied the list under an open session; dismissing")
            cancel()
        } else {
            beginThumbnails()
            scheduleLayout()
        }
    }

    /// Starts (or extends) thumbnail capture for the current list, and republishes what has landed.
    ///
    /// Nothing waits on this: the panel is already on screen drawing icons, and each tile swaps to
    /// its capture when that capture arrives. A no-op unless the feature is on and the mode is
    /// window mode — an app tile has no single window to photograph.
    private func beginThumbnails() {
        guard thumbnails.isEnabled, model.mode == .windows else { return }
        if thumbnailSubscription == nil {
            thumbnailSubscription = thumbnails.$images
                .sink { [weak self] images in self?.model.thumbnails = images }
        }
        thumbnails.begin(for: model.targets)
    }

    // MARK: - In-switcher window actions

    /// Dispatches a bound window action to its handler. A not-running favourite (launch tile) has no
    /// window or process to act on — and every such tile shares the -1 pid sentinel, so letting an
    /// action through would hit *all* of them (or, for hide-others, hide the entire session).
    private func perform(_ action: SwitcherAction) {
        guard model.selected?.isLaunchable == false else { return }
        // Off the tap callback: every one of these reaches Accessibility or NSWorkspace, and
        // `hideOthers` walks the whole running-application list. See the type's doc comment.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            guard !self.confirmsDestructiveActions || !action.isDestructive else {
                self.confirmThenExecute(action)
                return
            }
            self.execute(action)
        }
    }

    /// Asks before quitting. The panel is torn down first: it sits above every other window at a
    /// level an `NSAlert` cannot clear, so the sheet would otherwise open *behind* the switcher with
    /// the keyboard still swallowed by the tap — an app that appears wedged.
    ///
    /// The target is captured before the dismissal, since dismissing clears the selection.
    private func confirmThenExecute(_ action: SwitcherAction) {
        guard let target = model.selected else { return }
        let name = target.appName
        cancel()
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            action == .forceQuit ? "Force-quit \(name)?" : "Quit \(name)?"
        alert.informativeText =
            action == .forceQuit
            ? "\(name) will be terminated immediately. Unsaved changes in every one of its windows "
                + "are lost."
            : "Every window \(name) has open will close. Unsaved changes may be lost."
        alert.addButton(withTitle: action == .forceQuit ? "Force Quit" : "Quit")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // The panel is already down, so this acts on the captured target rather than the selection.
        if action == .forceQuit { target.forceQuitApp() } else { target.quitApp() }
        Log.tap.notice(
            "execute \(action.rawValue, privacy: .public) on pid \(target.pid, privacy: .public) (confirmed)")
    }

    private func execute(_ action: SwitcherAction) {
        // pid, not title: titles carry document names, mail subjects and URLs, and `.public` would
        // persist them in the unified log for anything that can run `log show` to read.
        Log.tap.notice(
            "execute \(action.rawValue, privacy: .public) on pid \(self.model.selected?.pid ?? -1, privacy: .public)")
        switch action {
        case .quit: quitSelected()
        case .forceQuit: forceQuitSelected()
        case .close: closeSelectedWindow()
        case .hide: hideSelected()
        case .hideOthers: hideOthers()
        case .minimize: minimizeSelected()
        case .zoom: zoomSelected()
        case .moveDisplayPrev: moveSelectedWindow(acrossDisplays: -1)
        case .moveDisplayNext: moveSelectedWindow(acrossDisplays: 1)
        case .tileLeftHalf, .tileRightHalf, .tileTopHalf, .tileBottomHalf:
            guard let arrangement = action.arrangement else { return }
            tileSelectedWindow(arrangement)
        }
    }

    private func quitSelected() {
        guard let target = model.selected else { return }
        target.quitApp()
        model.remove { $0.pid == target.pid }
        finishListMutation()
    }

    /// Force-terminates the selected app.
    private func forceQuitSelected() {
        guard let target = model.selected else { return }
        target.forceQuitApp()
        model.remove { $0.pid == target.pid }
        finishListMutation()
    }

    /// Closes the highlighted window (window mode) or the frontmost window of the highlighted app
    /// (app mode), then drops it from the list without dismissing the switcher.
    ///
    /// Optimistic like `quitSelected`, and deliberately without a refresh: the close is an async AX
    /// call on another queue, so refreshing here can enumerate the window before it is gone and fold
    /// it straight back in.
    private func closeSelectedWindow() {
        guard let target = model.selected else { return }
        target.closeWindow()
        // Window mode: drop just that tile. App mode: the app stays (it may have other windows).
        guard case .window = target.kind else { return }
        model.remove { $0.id == target.id }
        finishListMutation()
    }

    /// Hides the highlighted app and takes it (and any of its windows) out of the list.
    private func hideSelected() {
        guard let target = model.selected else { return }
        target.hideApp()
        model.remove { $0.pid == target.pid }
        finishListMutation()
    }

    /// Minimizes the selected window (or the app's front window). The tile stays — a minimized window
    /// is still switchable — so the panel just relays out.
    private func minimizeSelected() {
        model.selected?.minimizeWindow()
        scheduleLayout()
    }

    /// Zooms (maximize / restore) the selected window.
    private func zoomSelected() {
        model.selected?.zoomWindow()
    }

    /// Moves the selected window to the next/previous display, wrapping around.
    ///
    /// Visible areas, not full display frames: this is the same move the ⌃⌘⇧-arrow chords make, and
    /// they measure against `visibleAreas` too. Handed the full frames instead, a window sitting at
    /// the top of one display landed under the destination's menu bar — and the two paths disagreed
    /// by the menu bar and Dock insets, which is exactly the promise `WindowTiler.apply` documents
    /// they keep.
    private func moveSelectedWindow(acrossDisplays delta: Int) {
        model.selected?.moveWindow(
            acrossDisplays: delta, visibleAreas: WindowTiler.visibleAreas())
    }

    /// Tiles the highlighted window, through the same tiler as the global ⌃⌘-arrow chords: one
    /// restore point, one width cycle, one gap, so the two routes cannot drift apart.
    ///
    /// Deliberately *not* gated on `tiling.isEnabled`. That switch exists so the sizing chords are
    /// not claimed system-wide on an install that never asked for them; these keys are claimed from
    /// nobody, being live only while the panel is up and only with window actions switched on. A row
    /// under "Window actions" that did nothing because of a checkbox on the Windows tab is exactly
    /// the failure `WindowTilingBindings.arrangement(code:flags:)` already refuses to ship.
    ///
    /// `neverTile` is honoured, as it is on every other snap path — see `MouseWindowDrag.appRules`,
    /// which lists them. An app told never to be tiled is left alone from here too.
    private func tileSelectedWindow(_ arrangement: WindowArrangement) {
        guard let target = model.selected else { return }
        if let id = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier,
            appRules[id]?.neverTile == true {
            Log.tap.notice("tiling: \(id, privacy: .public) is set to never tile")
            return
        }
        target.tileWindow(
            arrangement, visibleAreas: WindowTiler.visibleAreas(),
            cycleWidths: tiling.cycleWidths, gap: tiling.gap)
    }

    /// Hides every other regular app, leaving the selected one (and Cmd-Tab) alone.
    private func hideOthers() {
        guard let keep = model.selected?.pid else { return }
        let mine = ProcessInfo.processInfo.processIdentifier
        for app in NSWorkspace.shared.runningApplications
        where app.activationPolicy == .regular
            && app.processIdentifier != keep && app.processIdentifier != mine {
            app.hide()
        }
    }

    /// A tile was clicked: select and commit it in one go.
    private func pick(_ index: Int) {
        guard isVisible, model.targets.indices.contains(index) else { return }
        model.selection = index
        commit()
    }

}
