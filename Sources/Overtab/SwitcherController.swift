import AppKit
import CoreGraphics

private enum Key {
    static let tab = 48
    static let escape = 53
    static let leftArrow = 123
    static let rightArrow = 124
    static let q = 12

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
        let disabled = SystemSwitcher.setNativeEnabled(false)
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

    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let command = event.flags.contains(.maskCommand)

        // Modifier events are never swallowed — other apps need to track modifier state, and
        // this is also the escape hatch that guarantees the panel can always be dismissed.
        if type == .flagsChanged {
            if isVisible && !command { commit() }
            return false
        }

        // Anything that reaches us with Command already up means we missed the release.
        guard command else {
            if isVisible { commit() }
            return false
        }

        let code = Int(event.getIntegerValueField(.keyboardEventKeycode))

        if type == .keyUp {
            return isVisible
        }

        if code == Key.tab {
            let backwards = event.flags.contains(.maskShift)
            if isVisible {
                model.step(backwards ? -1 : 1)
                panel.layout()
                return true
            }
            // Only swallow if we actually put something on screen. Swallowing a ⌘-Tab that
            // opens nothing would leave the user with no switcher at all.
            let shown = show(backwards: backwards)
            Log.tap.notice("cmd-tab: shown=\(shown) targets=\(self.model.targets.count)")
            return shown
        }

        guard isVisible else { return false }

        if let digit = Key.digits[code] {
            jump(to: digit)
            return true
        }

        switch code {
        case Key.escape:
            cancel()
        case Key.rightArrow:
            model.step(1)
            panel.layout()
        case Key.leftArrow:
            model.step(-1)
            panel.layout()
        case Key.q:
            quitSelected()
        default:
            break
        }

        // While the panel is up it owns the keyboard, exactly like the system switcher. Command
        // is held down, so passing keys through would fire shortcuts in the app behind us.
        return true
    }

    // MARK: - Actions

    @discardableResult
    private func show(backwards: Bool) -> Bool {
        let targets = provider.snapshot()
        guard !targets.isEmpty else {
            Log.targets.error("cmd-tab with an empty target list; cache not warm?")
            return false
        }

        model.mode = provider.mode
        model.targets = targets
        // The frontmost app is index 0, so a plain ⌘-Tab lands on the previous one.
        model.selection = backwards ? targets.count - 1 : min(1, targets.count - 1)

        isVisible = true
        panel.show()
        Log.general.notice(
            "panel shown: frame=\(NSStringFromRect(self.panel.frame)) visible=\(self.panel.isVisible)")

        // The cache can be a moment stale; fold in a fresh list without disturbing the highlight.
        provider.refresh { [weak self] fresh in
            guard let self, self.isVisible else { return }
            self.model.update(targets: fresh)
            if self.model.isEmpty { self.cancel() } else { self.panel.layout() }
        }
        return true
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

    private func cancel() {
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
}
