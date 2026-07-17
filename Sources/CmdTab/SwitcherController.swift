import AppKit
import CoreGraphics
import SwiftUI

private enum Key {
    static let tab = 48
    static let escape = 53
    static let delete = 51
    static let leftArrow = 123
    static let rightArrow = 124

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
    private lazy var previewPanel = WindowPreviewPanel()
    private var previewWork: DispatchWorkItem?
    private var previewTask: Task<Void, Never>?
    /// Grace-period teardown of the preview, cancelled if the cursor reaches the preview or a tile.
    private var previewDismissWork: DispatchWorkItem?
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

    var favoriteBundleIDs: [String] {
        get { provider.favoriteBundleIDs }
        set {
            provider.favoriteBundleIDs = newValue
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

    /// App mode: float live window thumbnails when a tile is hovered.
    var windowPreview: Bool {
        get { panel.windowPreviewEnabled }
        set { panel.windowPreviewEnabled = newValue }
    }

    /// User-configurable key bindings for the in-switcher window actions.
    var shortcuts: SwitcherShortcuts = .defaults

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
            self.advance(step)
        }
        panel.onPreviewHover = { [weak self] target in self?.previewHover(target) }
        panel.isOverPreview = { [weak self] point in self?.previewPanel.isShowing(point) ?? false }
        previewPanel.onPick = { [weak self] thumb in
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
            return handleVisibleKey(code, flags, event)
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

    /// Moves the highlight and keeps the keyboard-selected preview in step with it.
    private func advance(_ delta: Int) {
        model.step(delta)
        panel.layout()
        panel.previewSelectedTile()
    }

    private func handleVisibleKey(_ code: Int, _ flags: CGEventFlags, _ event: CGEvent) -> Bool {
        // The trigger advances the selection.
        if code == hotkey.keyCode {
            advance(flags.contains(.maskShift) ? -1 : 1)
            return true
        }
        // Configurable window actions. Each is bound to a key plus *extra* modifiers on top of the
        // held trigger; ⌥/⌃ keep the action keys clear of the type-to-filter query. Subtract the
        // trigger's own modifiers so a trigger that itself uses ⌥/⌃ (e.g. ⌘⌥-Tab) doesn't make every
        // key look like an action and swallow the query.
        let extra = flags.intersection([.maskAlternate, .maskShift, .maskControl])
            .subtracting(activeHeld)
        if !extra.isEmpty, let action = shortcuts.action(code: code, extra: extra) {
            perform(action)
            return true
        }
        // Navigation and editing keys.
        switch code {
        case Key.escape:
            // Backing out of a query first, then out of the switcher — like a search field.
            if model.query.isEmpty { cancel() } else { setQuery("") }
            return true
        case Key.rightArrow: advance(1); return true
        case Key.leftArrow: advance(-1); return true
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
        panel.layout()
        panel.refreshHoverPreview()
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
        model.begin(targets)
        // The frontmost app/window is index 0, so a plain tap lands on the previous one.
        model.selection = backwards ? targets.count - 1 : min(1, targets.count - 1)

        isVisible = true
        panel.show()
        Log.general.notice("panel shown: frame=\(NSStringFromRect(self.panel.frame))")

        // The cache can be a moment stale; fold in a fresh list without disturbing the highlight.
        let fold: ([SwitchTarget]) -> Void = { [weak self] fresh in
            guard let self, self.isVisible else { return }
            self.model.update(targets: fresh)
            self.finishListMutation()
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
            panel.layout()
            panel.refreshHoverPreview()
        }
    }

    /// Dispatches a bound window action to its handler. A not-running favourite (launch tile) has no
    /// window or process to act on — and every such tile shares the -1 pid sentinel, so letting an
    /// action through would hit *all* of them (or, for hide-others, hide the entire session).
    private func perform(_ action: SwitcherAction) {
        guard model.selected?.isLaunchable == false else { return }
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
        panel.layout()
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
        model.selection = index
        commit()
    }

    // MARK: - Window preview

    /// Reacts to what the cursor points at. A tile (re)captures its preview after a short debounce;
    /// sitting on the preview cancels any teardown so its thumbnails can be clicked; leaving both
    /// schedules a *grace-delayed* dismissal so the cursor can cross the gap from tile to preview
    /// without the strip vanishing mid-move.
    private func previewHover(_ target: PreviewHoverTarget) {
        previewDismissWork?.cancel()
        previewDismissWork = nil
        switch target {
        case .tile(let pid, let rect):
            previewWork?.cancel()
            previewWork = nil
            previewTask?.cancel()
            previewTask = nil
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.capturePreview(pid: pid, tileRect: rect) }
            }
            previewWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
        case .overPreview:
            // Keep what's shown; just stop any pending new capture.
            previewWork?.cancel()
            previewWork = nil
        case .away:
            previewWork?.cancel()
            previewWork = nil
            previewTask?.cancel()
            previewTask = nil
            let work = DispatchWorkItem { [weak self] in self?.previewPanel.dismiss() }
            previewDismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
        }
    }

    /// Captures the app's windows off the main thread, then floats them if the switcher is still up
    /// and the capture was not superseded. Empty (no permission, or nothing to show) hides the strip.
    private func capturePreview(pid: pid_t, tileRect: NSRect) {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        previewTask = Task { [weak self] in
            let thumbs = await WindowCapture.shared.thumbnails(for: pid)
            guard !Task.isCancelled, let self, self.isVisible else { return }
            if thumbs.isEmpty {
                self.previewPanel.dismiss()
            } else {
                self.previewPanel.present(
                    thumbs: thumbs, appName: appName, over: tileRect,
                    appearance: self.panel.effectiveAppearance)
            }
        }
    }
}
