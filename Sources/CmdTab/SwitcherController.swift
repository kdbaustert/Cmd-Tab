import AppKit
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
@MainActor
final class SwitcherController {
    private let model = SwitcherModel()
    private let provider = TargetProvider()
    private lazy var panels = PanelGroup(model: model)
    private lazy var preview = PreviewCoordinator(switcher: panels) { [weak self] in
        self?.isVisible ?? false
    }
    private var tap: EventTap?
    private var isVisible = false
    /// Second source of truth for "is the trigger still down". See `startWatchdog`.
    private var watchdog: Timer?

    // Quick-switch arming: between a trigger press and the show-delay firing, the panel is not yet
    // on screen. Releasing the modifier in that window switches straight to the previous target.
    private var armed = false
    private var armedBackwards = false
    private var armedTargets: [SwitchTarget] = []
    private var armWorkItem: DispatchWorkItem?
    /// Modifiers of whichever hotkey opened the current session; releasing them ends it.
    private var activeHeld: CGEventFlags = [.maskCommand]

    // A same-app cycle whose window list is still being fetched. The list can't be built on the tap
    // callback (per-window Accessibility walk), so the trigger is swallowed before there is anything
    // to show — which means a modifier released inside that window has to be remembered and acted on
    // when the list lands. Without that, a quick tap — by far the most common way this key is used —
    // would do nothing at all.
    private var pendingSameApp = false
    private var pendingSameAppReleased = false
    private var sameAppDeadline: DispatchWorkItem?
    /// How long to wait for the frontmost app's window list before abandoning the cycle.
    private let sameAppTimeout: TimeInterval = 2

    /// Bumped whenever a session begins or ends. Async work started by one session carries the token
    /// it was launched under and drops itself if the token has moved on, so a slow fetch can never
    /// reach in and mutate a session it does not belong to.
    private var sessionToken = 0

    /// Whether this session is *allowed* to stay up after the trigger is released.
    private var isSticky = false

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

    /// Grid or list. Relayouts a visible panel, like the metrics do — it changes the panel's whole
    /// shape, so leaving an open switcher on the old one would be the odd behaviour.
    var layout: SwitcherLayout {
        get { model.layout }
        set {
            guard newValue != model.layout else { return }
            model.layout = newValue
            if isVisible { panels.layout() }
        }
    }

    /// The window-tiling bindings, as a snapshot the tap callback can read without touching a store.
    /// Pushed by `AppDelegate` whenever they change.
    var tiling: WindowTilingBindings = .defaults {
        didSet {
            dragSnap.gap = tiling.gap
            mouseWindowDrag.gap = tiling.gap
            targetHighlight.gap = tiling.gap
            launchArrangements.gap = tiling.gap
            guard tiling.dragSnap != oldValue.dragSnap else { return }
            dragSnap.isEnabled = tiling.dragSnap
        }
    }
    private let dragSnap = DragSnap()

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
    /// Per-app jump chords, same arrangement.
    var activations = DirectActivations()
    /// The hide-all / show-all chords.
    var allWindows = AllWindowsShortcuts()
    /// Chords that restore a saved window layout.
    var layouts = LayoutShortcuts()
    /// Extra triggers that open a narrowed window list.
    var scopedTriggers = ScopedTriggers()

    /// User-configurable key bindings for the in-switcher window actions.
    var shortcuts: SwitcherShortcuts = .defaults {
        didSet { warnAboutShadowedActions() }
    }
    /// Whether those bindings are live at all. Off leaves every ⌥-key to type-to-filter.
    var actionsEnabled = false
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
            launchArrangements.appRules = appRules
            provider.refresh()
        }
    }

    /// Snaps an app's first window as it opens, for the apps that ask for it.
    private let launchArrangements = LaunchArrangementWatcher()

    /// Applications or individual windows. Rebuilds the list, since it changes what a target *is*.
    var mode: SwitcherMode {
        get { provider.mode }
        set {
            guard newValue != provider.mode else { return }
            provider.mode = newValue
            provider.refresh()
        }
    }

    var excludedBundleIDs: Set<String> {
        get { provider.excludedBundleIDs }
        set {
            guard newValue != provider.excludedBundleIDs else { return }
            provider.excludedBundleIDs = newValue
            provider.refresh()
        }
    }

    var favoriteBundleIDs: [String] {
        get { provider.favoriteBundleIDs }
        set {
            guard newValue != provider.favoriteBundleIDs else { return }
            provider.favoriteBundleIDs = newValue
            provider.refresh()
        }
    }

    // Both guarded on an actual change, like every other setter here. `AppDelegate.applyBehavior`
    // re-pushes the whole settings block on every `BehaviorStore` notification — which an unstepped
    // slider posts once per drag tick — so an unguarded setter turned a slider drag into a stream of
    // full list rebuilds, each with its main-thread prelude on the thread that services the tap.
    var sortOrder: SortOrder {
        get { provider.sortOrder }
        set {
            guard newValue != provider.sortOrder else { return }
            provider.sortOrder = newValue
            provider.refresh()
        }
    }

    var hideEmptyApps: Bool {
        get { provider.hideEmptyApps }
        set {
            guard newValue != provider.hideEmptyApps else { return }
            provider.hideEmptyApps = newValue
            provider.refresh()
        }
    }

    var panelAppearance: PanelAppearance {
        get { panels.appearanceMode }
        set {
            panels.appearanceMode = newValue
            if isVisible { panels.layout() }
        }
    }

    var panelPosition: PanelPosition {
        get { panels.positionMode }
        set {
            panels.positionMode = newValue
            if isVisible { panels.layout() }
        }
    }

    /// Which displays the switcher occupies. Takes effect on the next session — changing the number
    /// of panels under a live selection would mean tearing windows out from under the user.
    var panelScreens: PanelScreens {
        get { panels.screens }
        set { panels.screens = newValue }
    }

    var highlightColor: Color {
        get { model.highlightColor }
        set { model.highlightColor = newValue }
    }

    var showNumbers: Bool {
        get { model.showNumbers }
        set { model.showNumbers = newValue }
    }

    var showDisplayBadges: Bool {
        get { model.showDisplayBadges }
        set { model.showDisplayBadges = newValue }
    }

    var showSpaceBadges: Bool {
        get { model.showSpaceBadges }
        set { model.showSpaceBadges = newValue }
    }

    /// Dock notification badges. Changing it re-reads the Dock, so a toggle takes effect at once.
    var notificationBadges: Bool {
        get { provider.notificationBadges }
        set {
            guard newValue != provider.notificationBadges else { return }
            provider.notificationBadges = newValue
            provider.refresh()
        }
    }

    var tileCorner: CGFloat {
        get { model.tileCorner }
        set { model.tileCorner = newValue }
    }

    var titleFontName: String {
        get { model.titleFontName }
        set {
            guard newValue != model.titleFontName else { return }
            model.titleFontName = newValue
            if isVisible { panels.layout() }
        }
    }

    var titleFontSize: CGFloat {
        get { model.titleFontSize }
        set {
            guard newValue != model.titleFontSize else { return }
            model.titleFontSize = newValue
            if isVisible { panels.layout() }
        }
    }

    var fade: Bool {
        get { panels.fade }
        set { panels.fade = newValue }
    }

    var panelMaterial: PanelMaterial {
        get { model.material }
        set { model.material = newValue }
    }

    /// nil = the material's built-in blur; a value overrides it. Relayout so an open panel reflects
    /// the change (the view is rebuilt from scratch on layout).
    var panelBlur: Double? {
        get { model.blurRadius }
        set {
            guard newValue != model.blurRadius else { return }
            model.blurRadius = newValue
            if isVisible { panels.layout() }
        }
    }

    var maxColumns: Int {
        get { panels.maxColumns }
        set {
            guard newValue != panels.maxColumns else { return }
            panels.maxColumns = newValue
            if isVisible { panels.layout() }
        }
    }

    /// A tap that opens the switcher waits this long before drawing; released sooner, it switches
    /// straight to the previous target with no panel flash. 0 keeps the panel instant.
    var showDelay: TimeInterval = 0

    /// App mode: float live window thumbnails when a tile is hovered.
    var windowPreview: Bool {
        get { panels.windowPreviewEnabled }
        set { panels.windowPreviewEnabled = newValue }
    }

    /// Optional second trigger that opens the frontmost app's windows instead of the whole list.
    /// nil leaves the combination alone, which matters because the default (⌘-`) is one apps use
    /// themselves.
    var sameAppHotkey: Hotkey?

    /// The combination that opens the switcher. Changing it re-syncs the system ⌘-Tab: the native
    /// switcher is suppressed only while *our* trigger is exactly ⌘-Tab.
    var hotkey: Hotkey = .commandTab {
        didSet {
            warnAboutShadowedActions()
            guard hotkey != oldValue, isRunning else { return }
            SystemSwitcher.setNativeEnabled(!hotkey.isCommandTab)
        }
    }

    /// Logs a trigger/action modifier collision.
    ///
    /// Settings refuses to *create* this combination, but a config written before that check existed,
    /// imported from another machine, or hand-edited in the defaults plist can still arrive here —
    /// and the symptom (actions dead, their keys typing into the filter) gives no hint of the cause.
    private func warnAboutShadowedActions() {
        guard actionsEnabled else { return }
        let shadowed = shortcuts.actionsShadowed(by: hotkey)
        guard !shadowed.isEmpty else { return }
        Log.tap.error(
            """
            trigger \(self.hotkey.displayString, privacy: .public) claims a modifier \
            \(shadowed.count, privacy: .public) action(s) need as an extra; they cannot fire: \
            \(shadowed.map(\.title).joined(separator: ", "), privacy: .public)
            """)
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
        Log.general.notice(
            "started: tap=ok nativeDisabled=\(disabled) symbolAvailable=\(SystemSwitcher.isAvailable)")
        provider.refresh { targets in
            Log.targets.notice("initial refresh: \(targets.count) targets")
        }
        return true
    }

    /// Opens a sticky session from outside the keyboard — the menu bar item. Always sticky, since
    /// there is no held modifier that could end it.
    func openSticky() {
        guard !isVisible else { return }
        let targets = provider.snapshot()
        guard !targets.isEmpty else { return }
        // An armed quick-switch is not "visible", so the guard above lets it through — and the arm
        // would then fire into `showWith` a second time, resetting the model under the panel the
        // user is already looking at.
        armed = false
        armWorkItem?.cancel()
        armWorkItem = nil
        // The arm we just cancelled had started a watchdog, and nothing below re-owns it: `showWith`
        // skips `startWatchdog` for an empty `activeHeld`. Left alone it ticks 5×/s for the whole
        // sticky session with no session to watch.
        stopWatchdog()
        beginSession()
        activeHeld = []
        isSticky = true
        showWith(targets: targets, backwards: false)
    }

    func stop() {
        cancel()
        tap?.stop()
        tap = nil
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
            Log.tap.debug("flagsChanged: flags=\(flags.rawValue, privacy: .public) held=\(self.activeHeld.rawValue, privacy: .public) stillHeld=\(self.stillHeld(flags, self.activeHeld), privacy: .public)")
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
            Log.tap.debug("visible: code=\(code, privacy: .public) flags=\(flags.rawValue, privacy: .public) held=\(self.activeHeld.rawValue, privacy: .public) commit=\(self.release.shouldCommit(flags: flags), privacy: .public)")
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

        // Idle. The order below *is* the precedence documented in `ShortcutAudit.Kind`, and it is
        // load-bearing: openers first, so nothing a user (or a hand-edited `config.json`) binds can
        // take ⌘-Tab away from the switcher itself. The recorders refuse a chord a trigger already
        // claims, but a config file is not a recorder — and a settings file that quietly disabled
        // the app's whole reason for existing would be very hard to diagnose.
        //
        // Openers are keydown-only; the global actions below match on both edges. Swallowing only
        // the keydown left an unpaired key-up on the way to the frontmost app, and anything tracking
        // raw key state from up/down pairs — virtualisers, VNC and RDP clients, remote terminals —
        // reads that as a release with no press. The visible-panel branch swallows both for the
        // same reason.
        let backwards = flags.contains(.maskShift)
        if type == .keyDown {
            if code == hotkey.keyCode, modifiersMatch(flags, hotkey.heldModifiers) {
                return open(backwards: backwards)
            }
            // After the main trigger, so binding both to the same chord keeps the switcher.
            if let sameApp = sameAppHotkey, code == sameApp.keyCode,
                modifiersMatch(flags, sameApp.heldModifiers) {
                return openSameApp(backwards: backwards)
            }
            // Scoped triggers last among the openers, for the same reason: a chord shared with
            // either built-in trigger keeps its built-in meaning.
            if !NSApp.isActive, let match = scopedTriggers.scope(code: code, flags: flags) {
                return openScoped(match.scope, held: match.held, backwards: backwards)
            }
        }

        // The global actions, all inert while we are frontmost: their recorders live in the settings
        // window, and a bound chord matched here would be swallowed before the recorder's own
        // monitor could see it — so no assigned combination could ever be re-recorded. The two
        // built-in triggers above are deliberately *not* guarded, since they are recorded by a
        // different control and opening the switcher from the settings window is long-standing.
        guard !NSApp.isActive else {
            // The commonest "my shortcut does nothing": the settings window has focus, so every
            // global chord below is deliberately inert. Logged once per press, and only for a
            // chord that would otherwise have fired, so this is not a line per keystroke.
            if type == .keyDown, tiling.arrangement(code: code, flags: flags) != nil {
                Log.tap.notice("tiling: inert — Cmd-Tab is frontmost (settings window focused)")
            }
            return false
        }
        // Only a fresh keydown acts. Key repeat is swallowed but ignored — cycling ½ → ⅔ → ⅓ under
        // autorepeat would strobe a window through every width in a fraction of a second — and the
        // keyup only ever has to be consumed, not acted on.
        let acts = type == .keyDown && event.getIntegerValueField(.keyboardEventAutorepeat) == 0
        if let bundleID = activations.bundleID(code: code, flags: flags) {
            if acts { GlobalActions.activate(bundleID: bundleID) }
            return true
        }
        if let action = allWindows.action(code: code, flags: flags) {
            if acts { GlobalActions.perform(action) }
            return true
        }
        // Before tiling, so a chord shared with an arrangement restores the layout: a layout is the
        // more specific instruction, and the user had to record it against a named thing to have it
        // at all. The Windows pane warns about the clash either way.
        if let id = layouts.layoutID(code: code, flags: flags) {
            if acts {
                Log.tap.notice("layout: restoring \(id, privacy: .public)")
                DispatchQueue.main.async { WindowLayoutsStore.shared.restore(id: id) }
            }
            return true
        }
        if let arrangement = tiling.arrangement(code: code, flags: flags) {
            if acts {
                Log.tap.notice("tiling: \(arrangement.rawValue, privacy: .public) matched")
                applyTiling(arrangement)
            }
            return true
        }
        // Nothing claimed it. Logged only when a real modifier was held, which keeps this off the
        // per-keystroke path while still catching "I pressed the chord and nothing happened".
        if type == .keyDown, tiling.isEnabled,
            !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty {
            Log.tap.debug(
                """
                tiling: no binding for key \(code, privacy: .public) \
                flags \(flags.rawValue, privacy: .public)
                """)
        }
        return false
    }

    /// Snaps the focused window. Both reads here are main-thread reads and this runs on the tap's
    /// own callback (which is on the main run loop), so they happen inline; every Accessibility
    /// call — the part that can block — happens on `WindowTiler`'s queue.
    private func applyTiling(_ arrangement: WindowArrangement) {
        let cycleWidths = tiling.cycleWidths
        let gap = tiling.gap
        // Posted, not inline. `frontmostApplication` and the screen walk are both NSWorkspace/AppKit
        // reads, which the class invariant keeps off the tap callback — and there is nothing to
        // report back, since the key is already swallowed by the time this runs.
        let rules = appRules
        DispatchQueue.main.async {
            guard let front = NSWorkspace.shared.frontmostApplication,
                let pid = Optional(front.processIdentifier),
                pid != ProcessInfo.processInfo.processIdentifier
            else {
                Log.tap.notice("tiling: no frontmost app to act on")
                return
            }
            // An app the user has told us never to tile. Checked here rather than in `WindowTiler`
            // so the tiler stays a pure geometry writer with no opinion about settings.
            if let id = front.bundleIdentifier, rules[id]?.neverTile == true {
                Log.tap.notice("tiling: \(id, privacy: .public) is set to never tile")
                return
            }
            Log.tap.notice(
                "tiling: applying to pid \(pid, privacy: .public), gap \(gap, privacy: .public)")
            WindowTiler.apply(
                arrangement, pid: pid, areas: WindowTiler.visibleAreas(),
                cycleWidths: cycleWidths, gap: gap)
        }
    }

    /// Moves the highlight.
    private func advance(_ delta: Int) {
        model.step(delta)
        // Off the tap callback — see `scheduleLayout`.
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
    /// disk — so it is safe on the keystroke path. The icon lookup is the only I/O and happens for
    /// at most a handful of results.
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
        let suggestions = InstalledApps.matches(query, excluding: excluded).map { entry in
            SwitchTarget(
                id: "launch:\(entry.bundleID)", kind: .launch(entry.url), title: entry.name,
                appName: entry.name,
                icon: NSWorkspace.shared.icon(forFile: entry.url.path),
                isMinimized: false, isHidden: false)
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
            self.panels.layout()
            // The list under a stationary cursor may have changed — a tile quit, closed or hidden,
            // or a background refresh folded in a new one — so the strip has to follow whatever is
            // under the pointer now. Deduped downstream, so an unchanged target costs nothing.
            self.panels.refreshPreview()
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
        let targets = provider.snapshot()
        guard !targets.isEmpty else {
            Log.targets.error("trigger with an empty list; cache not warm?")
            return false
        }
        // Only past the guard: assigning session state before the bail-out left `isSticky` latched
        // true after a press that never opened anything, so the *next* session — including one from
        // a different hotkey — silently came up sticky.
        beginSession()
        activeHeld = hotkey.heldModifiers
        isSticky = stickyMode
        if showDelay > 0 {
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
            if !isSticky { startWatchdog() }
            return true
        }
        showWith(targets: targets, backwards: backwards)
        return true
    }

    /// Opens the frontmost app's windows — the same-app cycle. Always swallows the key: the window
    /// list arrives asynchronously, so there is no way to know yet whether there is anything to show,
    /// and letting the chord through would fire it in the app behind us a moment later.
    private func openSameApp(backwards: Bool) -> Bool {
        guard !pendingSameApp, !isVisible, !armed else { return true }
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
            // The fetch is unbounded (an Accessibility walk against a possibly wedged app), so by
            // the time it lands the user may have abandoned this cycle and opened a normal session.
            // Acting on it then would stop *that* session's watchdog — deleting the failsafe that
            // stands between a missed modifier-release and a machine-wide keyboard lockout.
            guard let self, self.pendingSameApp, token == self.sessionToken else { return }
            self.sameAppDeadline?.cancel()
            self.sameAppDeadline = nil
            self.pendingSameApp = false

            // One window is nothing to cycle between, and zero means the app exposes none.
            guard targets.count > 1 else {
                self.pendingSameAppReleased = false
                self.stopWatchdog()
                return
            }
            guard self.pendingSameAppReleased else {
                self.showWith(targets: targets, backwards: backwards, mode: .windows)
                return
            }
            // Tapped and released before the list landed: do the switch without ever drawing.
            self.pendingSameAppReleased = false
            self.stopWatchdog()
            let target = targets[backwards ? targets.count - 1 : 1]
            DispatchQueue.main.async { target.focus() }
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
        guard !pendingSameApp, !isVisible, !armed else { return true }
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

        let receive: ([SwitchTarget]) -> Void = { [weak self] targets in
            guard let self, self.pendingSameApp, token == self.sessionToken else { return }
            self.sameAppDeadline?.cancel()
            self.sameAppDeadline = nil
            self.pendingSameApp = false

            let filtered = Self.filter(targets, to: scope)
            guard !filtered.isEmpty else {
                self.pendingSameAppReleased = false
                self.stopWatchdog()
                return
            }
            guard self.pendingSameAppReleased else {
                self.showWith(targets: filtered, backwards: backwards, mode: .windows)
                return
            }
            // Tapped and released before the list landed: switch without ever drawing.
            self.pendingSameAppReleased = false
            self.stopWatchdog()
            let index = backwards ? filtered.count - 1 : min(1, filtered.count - 1)
            let target = filtered[index]
            DispatchQueue.main.async { target.focus() }
        }

        if scope == .frontApp {
            provider.frontAppWindowTargets(then: receive)
        } else {
            provider.allWindowTargets(then: receive)
        }
        return true
    }

    /// Narrows a window list to a scope. `.frontApp` and `.allWindows` are already exactly what was
    /// fetched, so only the two filtering scopes do anything here.
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
        let mode = mode ?? provider.mode
        model.mode = mode
        model.begin(targets)
        // The frontmost app/window is index 0, so a plain tap lands on the previous one.
        model.selection = backwards ? targets.count - 1 : min(1, targets.count - 1)

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
            self.panels.show()
            // `.public` deliberately: interpolation redacts by default, and this line reading
            // `frame=<private>` is exactly why a log full of apparently healthy shows could not
            // tell a panel that drew from one that came up 0×0 or fully transparent. There is
            // nothing personal in a rectangle.
            Log.general.notice(
                """
                panel shown: \(self.panels.diagnostics, privacy: .public) \
                targets=\(self.model.targets.count, privacy: .public)
                """)

            // The cache can be a moment stale; fold in a fresh list without disturbing the highlight.
            self.provider.refresh { [weak self] fresh in
                guard let self, self.isVisible else { return }
                self.model.update(targets: fresh)
                self.finishListMutation()
            }
        }
    }

    private func hide() {
        isVisible = false
        isSticky = false
        // Anything still in flight belongs to the session just ended.
        beginSession()
        stopWatchdog()
        stopStickyGuards()
        panels.hide()
        preview.teardown()
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
            target.focus()
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
            let index = armedBackwards ? armedTargets.count - 1 : min(1, armedTargets.count - 1)
            if armedTargets.indices.contains(index) {
                let target = armedTargets[index]
                DispatchQueue.main.async { target.focus() }
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
        // Idempotent. `showWith` can run twice for one visible panel (a menu-bar open racing an
        // in-flight arm), and assigning straight over `stickyOutsideMonitor` orphaned the previous
        // one — a global mouse monitor that outlived every later session and cancelled them.
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
            scheduleLayout()
        }
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
