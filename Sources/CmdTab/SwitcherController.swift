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

    /// Keycodes for 1–9 on the number row and again on the keypad. The number row is not
    /// sequential — 5, 6, 7, 8 and 9 are 23, 22, 26, 28, 25 — so this has to be a table.
    ///
    /// These are physical key positions, which is right for the keys labelled 1–9 on ANSI-style
    /// layouts. A layout that puts digits behind Shift (AZERTY) would still match by position.
    static let digits: [Int: Int] = [
        18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
        83: 1, 84: 2, 85: 3, 86: 4, 87: 5, 88: 6, 89: 7, 91: 8, 92: 9,
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

    var showBadges: Bool {
        get { model.showBadges }
        set { model.showBadges = newValue }
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

    /// User-configurable key bindings for the in-switcher window actions.
    var shortcuts: SwitcherShortcuts = .defaults {
        didSet { warnAboutShadowedActions() }
    }

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
            // Deduped upstream to target *changes*, so this is a real navigation, not a mouse twitch.
            self?.resetStickyIdle()
            self?.preview.hover(target)
        }
        panels.isOverPreview = { [weak self] point in self?.preview.isShowing(point) ?? false }
        preview.onPick = { [weak self] thumb in
            SwitchTarget.focusWindow(id: thumb.id, pid: thumb.pid)
            self?.cancel()
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
        let flags = event.flags

        // Modifier events are never swallowed — other apps need to track modifier state, and this
        // is also the escape hatch that guarantees the panel can always be dismissed.
        if type == .flagsChanged {
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

        // Idle: only a trigger keydown opens anything.
        if type == .keyUp { return false }
        let backwards = flags.contains(.maskShift)
        if code == hotkey.keyCode, modifiersMatch(flags, hotkey.heldModifiers) {
            return open(backwards: backwards)
        }
        // Checked after the main trigger, so binding both to the same chord keeps the switcher.
        if let sameApp = sameAppHotkey, code == sameApp.keyCode,
            modifiersMatch(flags, sameApp.heldModifiers) {
            return openSameApp(backwards: backwards)
        }
        return false
    }

    /// Moves the highlight and keeps the keyboard-selected preview in step with it.
    private func advance(_ delta: Int) {
        // Moving the highlight abandons any drill, in flight or engaged. Without this a capture
        // started for the tile you *were* on lands afterwards, adopts the strip, and Return commits
        // a window of an app you already arrowed past.
        preview.endSteering()
        model.step(delta)
        // Off the tap callback — see `scheduleLayout`.
        scheduleLayout(previewSelected: true)
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
            // Moving to another app abandons any drill-down: the strip belongs to the app you left.
            preview.endSteering()
            advance(flags.contains(.maskShift) ? -1 : 1)
            return true
        }

        // While the window strip is steered, the arrows and Return drive it instead of the tiles.
        // Escape deliberately falls through to the unconditional cancel below: it is the failsafe
        // out of a state that swallows every key on the machine, so it must never be repurposed
        // into "leave this sub-mode". ↑ is the way back to the tiles.
        if preview.isSteering {
            switch code {
            case Key.escape: break
            case Key.leftArrow: preview.moveSteering(-1); return true
            case Key.rightArrow, Key.downArrow: preview.moveSteering(1); return true
            case Key.upArrow: preview.endSteering(); return true
            case Key.enter: commit(); return true
            // ⌘ is held, so anything else would fire a shortcut in the app behind us.
            default: return true
            }
        }
        // Configurable window actions. Each is bound to a key plus *extra* modifiers on top of the
        // held trigger; ⌥/⌃ keep the action keys clear of the type-to-filter query. Subtract the
        // trigger's own modifiers so a trigger that itself uses ⌥/⌃ (e.g. ⌘⌥-Tab) doesn't make every
        // key look like an action and swallow the query.
        let extra = flags.intersection([.maskAlternate, .maskShift, .maskControl])
            .subtracting(activeHeld)
        if !extra.isEmpty {
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
        case Key.downArrow: enterDrill(); return true
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
        scheduleLayout()
    }

    /// Set while a relayout is already queued for the next main-loop turn.
    private var layoutQueued = false
    /// Whether the queued relayout should re-point the preview at the *selected* tile rather than
    /// re-resolving it against the cursor. Sticky across coalesced requests: if any caller in the
    /// batch was a keyboard move, the batch is a keyboard move.
    private var layoutWantsSelectedPreview = false

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
    private func scheduleLayout(previewSelected: Bool = false) {
        if previewSelected { layoutWantsSelectedPreview = true }
        guard !layoutQueued else { return }
        layoutQueued = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.layoutQueued = false
            let wantsSelected = self.layoutWantsSelectedPreview
            self.layoutWantsSelectedPreview = false
            guard self.isVisible else { return }
            self.panels.layout()
            if wantsSelected {
                self.panels.previewSelectedTile()
            } else {
                self.panels.refreshHoverPreview()
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

    /// `mode` is presentation only — there is no user-facing mode setting. The main list is apps,
    /// the same-app cycle is one app's windows. It drives whether tiles carry their own title and
    /// whether the caption names the owning app.
    private func showWith(
        targets: [SwitchTarget], backwards: Bool, mode: SwitcherMode = .apps
    ) {
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
            Log.general.notice("panel shown: frame=\(NSStringFromRect(self.panels.frame))")

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

    /// ↓ hands the arrows to the selected app's window strip — the gesture people bring over from
    /// the native ⌘-Tab, which expands an app's windows the same way.
    ///
    /// Requires app mode with previews on, because the strip *is* the feature: there is nothing to
    /// steer without it. A launch tile has no windows either. Both cases no-op rather than entering
    /// an empty mode.
    private func enterDrill() {
        guard model.mode == .apps, panels.windowPreviewEnabled,
            let target = model.selected, !target.isLaunchable,
            let rect = panels.selectedTileScreenRect
        else { return }
        preview.beginSteering(pid: target.pid, tileRect: rect)
    }

    private func commit() {
        guard isVisible else { return }
        // A steered strip means the user picked a specific window, not the app. Read it before
        // `hide()`, which tears the strip down and clears the selection.
        let thumb = preview.selectedThumb
        let target = model.selected
        hide()
        // Off the tap callback — activating an app is an AX / NSWorkspace round-trip against a
        // process that may not answer promptly.
        DispatchQueue.main.async {
            if let thumb {
                SwitchTarget.focusWindow(id: thumb.id, pid: thumb.pid)
            } else {
                target?.focus()
            }
        }
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

    private func quitSelected() {
        guard let target = model.selected else { return }
        target.quitApp()
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

    /// Shared tail for the in-switcher actions: dismiss only when nothing is left at all (a query
    /// matching nothing keeps the panel up), otherwise relayout and follow the cursor with the preview.
    private func finishListMutation() {
        if !model.hasAnyTarget {
            cancel()
        } else {
            scheduleLayout()
        }
    }

    /// Dispatches a bound window action to its handler. A not-running favourite (launch tile) has no
    /// window or process to act on — and every such tile shares the -1 pid sentinel, so letting an
    /// action through would hit *all* of them (or, for hide-others, hide the entire session).
    private func perform(_ action: SwitcherAction) {
        guard model.selected?.isLaunchable == false else { return }
        // Off the tap callback: every one of these reaches Accessibility or NSWorkspace, and
        // `hideOthers` walks the whole running-application list. See the type's doc comment.
        DispatchQueue.main.async { [weak self] in
            guard let self, self.isVisible else { return }
            self.execute(action)
        }
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
        case .moveDesktopPrev: model.selected?.moveToSpace(-1)
        case .moveDesktopNext: model.selected?.moveToSpace(1)
        case .moveDisplayPrev: moveSelectedWindow(acrossDisplays: -1)
        case .moveDisplayNext: moveSelectedWindow(acrossDisplays: 1)
        }
    }

    /// Force-terminates the selected app.
    private func forceQuitSelected() {
        guard let target = model.selected else { return }
        target.forceQuitApp()
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
    private func moveSelectedWindow(acrossDisplays delta: Int) {
        model.selected?.moveWindow(
            acrossDisplays: delta, screenFramesCG: TargetProvider.screenCGFrames())
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
        // Clicking a tile is a statement about the *app*, so it has to drop any steered window
        // selection first — `commit()` prefers a steered thumbnail, and would otherwise focus a
        // window of the app the drill came from rather than the one just clicked.
        preview.endSteering()
        model.selection = index
        commit()
    }

}
