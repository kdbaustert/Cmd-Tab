import AppKit
import CoreGraphics
import SwiftUI

private enum Key {
    static let tab = 48
    static let escape = 53
    static let leftArrow = 123
    static let rightArrow = 124
    static let q = 12
    static let w = 13
    static let h = 4

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
@MainActor
final class SwitcherController {
    private let model = SwitcherModel()
    private let provider = TargetProvider()
    private lazy var panel = SwitcherPanel(model: model)
    private var tap: EventTap?
    private var isVisible = false

    // Quick-switch arming: between a trigger press and the show-delay firing, the panel is not yet
    // on screen. Releasing the modifier in that window switches straight to the previous target.
    private var armed = false
    private var armedBackwards = false
    private var armedTargets: [SwitchTarget] = []
    private var armWorkItem: DispatchWorkItem?
    /// Modifiers of whichever hotkey opened the current session; releasing them ends it.
    private var activeHeld: CGEventFlags = [.maskCommand]

    var mode: SwitcherMode {
        get { provider.mode }
        set {
            provider.mode = newValue
            model.mode = newValue
            provider.refresh()
        }
    }

    /// Relayouts immediately when the panel is already up, so dragging a slider in settings
    /// resizes a visible switcher live.
    var metrics: Metrics {
        get { model.metrics }
        set {
            guard newValue != model.metrics else { return }
            model.metrics = newValue
            if isVisible { panel.layout() }
        }
    }

    var excludedBundleIDs: Set<String> {
        get { provider.excludedBundleIDs }
        set {
            provider.excludedBundleIDs = newValue
            provider.refresh()
        }
    }

    var sortOrder: SortOrder {
        get { provider.sortOrder }
        set {
            provider.sortOrder = newValue
            provider.refresh()
        }
    }

    var skipMinimized: Bool {
        get { provider.skipMinimized }
        set {
            provider.skipMinimized = newValue
            provider.refresh()
        }
    }

    var windowScope: WindowScope {
        get { provider.windowScope }
        set {
            provider.windowScope = newValue
            provider.refresh()
        }
    }

    var hideEmptyApps: Bool {
        get { provider.hideEmptyApps }
        set {
            provider.hideEmptyApps = newValue
            provider.refresh()
        }
    }

    var panelAppearance: PanelAppearance {
        get { panel.appearanceMode }
        set {
            panel.appearanceMode = newValue
            if isVisible { panel.layout() }
        }
    }

    var panelPosition: PanelPosition {
        get { panel.positionMode }
        set {
            panel.positionMode = newValue
            if isVisible { panel.layout() }
        }
    }

    var highlightColor: Color {
        get { model.highlightColor }
        set { model.highlightColor = newValue }
    }

    var showNumbers: Bool {
        get { model.showNumbers }
        set { model.showNumbers = newValue }
    }

    var alwaysShowTitles: Bool {
        get { model.alwaysShowTitles }
        set {
            guard newValue != model.alwaysShowTitles else { return }
            model.alwaysShowTitles = newValue
            if isVisible { panel.layout() }
        }
    }

    var tileCorner: CGFloat {
        get { model.tileCorner }
        set { model.tileCorner = newValue }
    }

    var titleFontSize: CGFloat {
        get { model.titleFontSize }
        set {
            guard newValue != model.titleFontSize else { return }
            model.titleFontSize = newValue
            if isVisible { panel.layout() }
        }
    }

    var titleWeight: Font.Weight {
        get { model.titleWeight }
        set { model.titleWeight = newValue }
    }

    var fade: Bool {
        get { panel.fade }
        set { panel.fade = newValue }
    }

    var panelMaterial: PanelMaterial {
        get { model.material }
        set { model.material = newValue }
    }

    var panelOpacity: Double {
        get { model.opacity }
        set { model.opacity = newValue }
    }

    /// nil = the material's built-in blur; a value overrides it. Relayout so an open panel reflects
    /// the change (the view is rebuilt from scratch on layout).
    var panelBlur: Double? {
        get { model.blurRadius }
        set {
            guard newValue != model.blurRadius else { return }
            model.blurRadius = newValue
            if isVisible { panel.layout() }
        }
    }

    var maxColumns: Int {
        get { panel.maxColumns }
        set {
            guard newValue != panel.maxColumns else { return }
            panel.maxColumns = newValue
            if isVisible { panel.layout() }
        }
    }

    /// A tap that opens the switcher waits this long before drawing; released sooner, it switches
    /// straight to the previous target with no panel flash. 0 keeps the panel instant.
    var showDelay: TimeInterval = 0

    /// The combination that opens the switcher. Changing it re-syncs the system ⌘-Tab: the native
    /// switcher is suppressed only while *our* trigger is exactly ⌘-Tab.
    var hotkey: Hotkey = .commandTab {
        didSet {
            guard hotkey != oldValue, isRunning else { return }
            SystemSwitcher.setNativeEnabled(!hotkey.isCommandTab)
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
        panel.onPick = { [weak self] index in self?.pick(index) }
        panel.onScroll = { [weak self] step in
            guard let self, self.isVisible else { return }
            self.model.step(step)
            self.panel.layout()
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

    func stop() {
        cancel()
        tap?.stop()
        tap = nil
        SystemSwitcher.restoreNativeIfNeeded()
    }

    // MARK: - Event handling

    /// Exact match on the primary modifiers (Shift excluded) — used to decide whether a keypress
    /// is our trigger chord, so ⌘-Tab opens only on exactly ⌘.
    private func modifiersMatch(_ flags: CGEventFlags, _ held: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl]) == held
    }

    /// The opening modifier is *still down*, tolerating extra modifiers the user may add. A session
    /// ends only when the trigger modifier itself is released, not when another one is pressed.
    private func stillHeld(_ flags: CGEventFlags, _ held: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isSuperset(of: held)
    }

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let flags = event.flags

        // Modifier events are never swallowed — other apps need to track modifier state, and this
        // is also the escape hatch that guarantees the panel can always be dismissed.
        if type == .flagsChanged {
            if (isVisible || armed) && !stillHeld(flags, activeHeld) { releaseTrigger() }
            return false
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        // While the panel is up it owns the keyboard, like the system switcher.
        if isVisible {
            if !stillHeld(flags, activeHeld) { commit(); return false }
            if type == .keyUp { return true }
            return handleVisibleKey(code, flags)
        }

        // Armed: a trigger press is waiting out the show-delay. A second press shows immediately.
        if armed {
            if type == .keyUp { return true }
            if !stillHeld(flags, activeHeld) { releaseTrigger(); return true }
            showFromArm()
            if code == hotkey.keyCode {
                model.step(flags.contains(.maskShift) ? -1 : 1)
                panel.layout()
            }
            return true
        }

        // Idle: only a trigger keydown opens anything.
        if type == .keyUp { return false }
        let backwards = flags.contains(.maskShift)
        if code == hotkey.keyCode, modifiersMatch(flags, hotkey.heldModifiers) {
            return open(backwards: backwards)
        }
        return false
    }

    private func handleVisibleKey(_ code: Int, _ flags: CGEventFlags) -> Bool {
        if code == hotkey.keyCode {
            model.step(flags.contains(.maskShift) ? -1 : 1)
            panel.layout()
            return true
        }
        if let digit = Key.digits[code] {
            jump(to: digit)
            return true
        }
        switch code {
        case Key.escape: cancel()
        case Key.rightArrow: model.step(1); panel.layout()
        case Key.leftArrow: model.step(-1); panel.layout()
        case Key.q: quitSelected()
        case Key.w: closeSelectedWindow()
        case Key.h: hideSelected()
        default: break
        }
        // Command is held, so passing keys through would fire shortcuts in the app behind us.
        return true
    }

    // MARK: - Actions

    /// Opens the switcher, or arms a quick-switch if a show-delay is set. Returns false — declining
    /// to swallow — only when there is nothing to show.
    @discardableResult
    private func open(backwards: Bool) -> Bool {
        activeHeld = hotkey.heldModifiers
        let targets = provider.snapshot()
        guard !targets.isEmpty else {
            Log.targets.error("trigger with an empty list; cache not warm?")
            return false
        }
        if showDelay > 0 {
            armed = true
            armedBackwards = backwards
            armedTargets = targets
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.showFromArm() }
            }
            armWorkItem = work
            DispatchQueue.main.asyncAfter(deadline: .now() + showDelay, execute: work)
            return true
        }
        showWith(targets: targets, backwards: backwards)
        return true
    }

    /// The show-delay elapsed (or a re-press arrived) while still held: actually draw the panel.
    private func showFromArm() {
        guard armed else { return }
        armWorkItem?.cancel()
        armWorkItem = nil
        armed = false
        showWith(targets: armedTargets, backwards: armedBackwards)
    }

    private func showWith(targets: [SwitchTarget], backwards: Bool) {
        model.mode = provider.mode
        model.targets = targets
        // The frontmost app/window is index 0, so a plain tap lands on the previous one.
        model.selection = backwards ? targets.count - 1 : min(1, targets.count - 1)

        isVisible = true
        panel.show()
        Log.general.notice("panel shown: frame=\(NSStringFromRect(self.panel.frame))")

        // The cache can be a moment stale; fold in a fresh list without disturbing the highlight.
        let fold: ([SwitchTarget]) -> Void = { [weak self] fresh in
            guard let self, self.isVisible else { return }
            self.model.update(targets: fresh)
            if self.model.isEmpty { self.cancel() } else { self.panel.layout() }
        }
        provider.refresh(then: fold)
    }

    private func hide() {
        isVisible = false
        panel.hide()
    }

    private func commit() {
        guard isVisible else { return }
        let target = model.selected
        hide()
        target?.focus()
    }

    /// Modifier released. In the tap window this is a quick-switch to the previous target with no
    /// panel; once the panel is up it is a normal commit.
    private func releaseTrigger() {
        if armed {
            armWorkItem?.cancel()
            armWorkItem = nil
            armed = false
            let index = armedBackwards ? armedTargets.count - 1 : min(1, armedTargets.count - 1)
            if armedTargets.indices.contains(index) { armedTargets[index].focus() }
            return
        }
        commit()
    }

    private func cancel() {
        armed = false
        armWorkItem?.cancel()
        armWorkItem = nil
        guard isVisible else { return }
        hide()
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
        var remaining = model.targets
        remaining.removeAll { $0.pid == target.pid }
        model.update(targets: remaining)
        if model.isEmpty { cancel() } else { panel.layout() }
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
        var remaining = model.targets
        remaining.removeAll { $0.id == target.id }
        model.update(targets: remaining)
        if model.isEmpty { cancel() } else { panel.layout() }
    }

    /// Hides the highlighted app and takes it (and any of its windows) out of the list.
    private func hideSelected() {
        guard let target = model.selected else { return }
        target.hideApp()
        var remaining = model.targets
        remaining.removeAll { $0.pid == target.pid }
        model.update(targets: remaining)
        if model.isEmpty { cancel() } else { panel.layout() }
    }

    /// A tile was clicked: select and commit it in one go.
    private func pick(_ index: Int) {
        guard isVisible, model.targets.indices.contains(index) else { return }
        model.selection = index
        commit()
    }
}
