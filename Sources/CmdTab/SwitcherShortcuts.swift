import AppKit
import SwiftUI

/// The window actions available while the switcher is open. Each is bound to a key plus *extra*
/// modifiers — the trigger modifier (⌘ by default) is always held, so a binding only records what
/// is pressed on top of it. An extra modifier is required (⌥ or ⌃) so an action key can't be
/// mistaken for type-to-filter input.
///
/// Moving a window to another **Space** is deliberately absent, and is the one action of this family
/// that cannot come back: see `SpaceMover`'s header — every private call for it is accepted and then
/// silently does nothing for a window this process does not own. It shipped here once and reported
/// success into the log on every press while moving nothing.
enum SwitcherAction: String, CaseIterable, Identifiable {
    case quit, forceQuit, close, hide, hideOthers, minimize, zoom
    case moveDisplayPrev, moveDisplayNext

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quit: return "Quit app"
        case .forceQuit: return "Force-quit app"
        case .close: return "Close window"
        case .hide: return "Hide app"
        case .hideOthers: return "Hide other apps"
        case .minimize: return "Minimize window"
        case .zoom: return "Zoom window"
        case .moveDisplayPrev: return "Move to previous display"
        case .moveDisplayNext: return "Move to next display"
        }
    }

    /// What the row explains under its title in Settings.
    var detail: String {
        switch self {
        case .quit: return "Quits the highlighted app and drops it from the list."
        case .forceQuit: return "Force-terminates it, for an app that has stopped responding."
        case .close:
            return "Closes the highlighted window, or the frontmost window of the highlighted app."
        case .hide: return "Hides the app and takes its tiles out of the list."
        case .hideOthers: return "Hides every other app, leaving this one up."
        case .minimize: return "Minimizes the window into the Dock. The tile stays."
        case .zoom: return "The green button: maximize, or restore a zoomed window."
        case .moveDisplayPrev, .moveDisplayNext:
            return "Sends the window to the next display along, keeping its relative position."
        }
    }

    /// The pair the destructive-confirmation setting covers. Both end a process rather than a
    /// window, and both are one keystroke away from the key that merely closes a window.
    var isDestructive: Bool { self == .quit || self == .forceQuit }

    /// Default binding. Display move is on ⌥←/→, which the arrow keys are free to take here: the
    /// navigation switch below them only sees an arrow that carried no extra modifier.
    var defaultShortcut: ActionShortcut {
        let option = CGEventFlags.maskAlternate.rawValue
        let optionShift = (CGEventFlags.maskAlternate.union(.maskShift)).rawValue
        switch self {
        case .quit: return ActionShortcut(keyCode: 12, modifierRaw: option)  // Q
        case .forceQuit: return ActionShortcut(keyCode: 12, modifierRaw: optionShift)
        case .close: return ActionShortcut(keyCode: 13, modifierRaw: option)  // W
        case .hide: return ActionShortcut(keyCode: 4, modifierRaw: option)  // H
        case .hideOthers: return ActionShortcut(keyCode: 4, modifierRaw: optionShift)
        case .minimize: return ActionShortcut(keyCode: 46, modifierRaw: option)  // M
        case .zoom: return ActionShortcut(keyCode: 3, modifierRaw: option)  // F
        case .moveDisplayPrev: return ActionShortcut(keyCode: 123, modifierRaw: option)  // ←
        case .moveDisplayNext: return ActionShortcut(keyCode: 124, modifierRaw: option)  // →
        }
    }
}

/// A key plus the extra modifiers held on top of the trigger. Reuses `Hotkey`'s key names.
struct ActionShortcut: Equatable {
    var keyCode: Int
    var modifierRaw: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRaw) }

    /// The extra modifiers only, normalised to the three that matter.
    var extras: CGEventFlags { modifiers.intersection([.maskAlternate, .maskShift, .maskControl]) }

    /// Whether a keypress (its keycode and *extra* modifiers) triggers this binding.
    func matches(code: Int, extra: CGEventFlags) -> Bool { code == keyCode && extra == extras }

    /// Shown with a leading ⌘ because the trigger is always held while the switcher is open.
    var displayString: String {
        var parts = "⌘"
        if modifiers.contains(.maskControl) { parts += "⌃" }
        if modifiers.contains(.maskAlternate) { parts += "⌥" }
        if modifiers.contains(.maskShift) { parts += "⇧" }
        parts += Hotkey.keyName(for: keyCode)
        return parts
    }
}

/// The live set of action bindings, matched against keypresses by the controller.
struct SwitcherShortcuts: Equatable {
    var bindings: [SwitcherAction: ActionShortcut]

    static let defaults = SwitcherShortcuts(
        bindings: Dictionary(
            uniqueKeysWithValues: SwitcherAction.allCases.map { ($0, $0.defaultShortcut) }))

    /// The action a keypress fires, if any. Exact modifier match keeps ⌥Q (quit) distinct from
    /// ⌥⇧Q (force-quit). Iterates in declared case order so that if two actions are bound to the same
    /// combo, the same one wins every time rather than depending on dictionary ordering.
    func action(code: Int, extra: CGEventFlags) -> SwitcherAction? {
        SwitcherAction.allCases.first { bindings[$0]?.matches(code: code, extra: extra) == true }
    }

    // MARK: - Trigger conflicts

    /// The action modifiers a trigger swallows: ⌥ and ⌃ are the two an action binding can be built
    /// from, and a trigger that holds one for its whole session makes it unusable as an *extra*.
    /// ⌘ is never in play — no binding uses it, because it is always held.
    static func modifiersClaimed(by trigger: Hotkey) -> CGEventFlags {
        trigger.heldModifiers.intersection([.maskAlternate, .maskControl])
    }

    /// Actions whose binding cannot fire while `trigger` is the opening chord.
    ///
    /// Bindings are matched against the modifiers held *on top of* the trigger, so a modifier the
    /// trigger already claims can never appear there — an action needing ⌥ is physically unreachable
    /// when ⌥ is what opens the switcher. There is no way to tell the two apart: the hardware
    /// reports one ⌥. And the failure is worse than the action merely going dead, because the
    /// keypress then falls through to type-to-filter — ⌘⌥Q types "q" instead of quitting.
    func actionsShadowed(by trigger: Hotkey) -> [SwitcherAction] {
        let claimed = Self.modifiersClaimed(by: trigger)
        guard !claimed.isEmpty else { return [] }
        return SwitcherAction.allCases.filter {
            !(bindings[$0]?.extras.intersection(claimed).isEmpty ?? true)
        }
    }

    /// Every chord that opens a session, and therefore holds its modifiers for the whole of it.
    ///
    /// The switcher trigger, the same-app cycle when it is on, and every bound scoped trigger.
    /// Scoped triggers belong here and were the family nobody checked: `openScoped` sets
    /// `activeHeld` exactly as the main trigger does, so it shadows in-switcher actions in exactly
    /// the same way — but every shadow check in the app tested `BehaviorStore.hotkey` alone.
    /// Recording ⌘⌥-A as an "all windows" trigger therefore killed ⌥Q and ⌥W silently: no alert, no
    /// orange text, no log line, and the keys fell through to type-to-filter.
    ///
    /// Deduplicated on the held modifiers rather than the whole chord: what shadows an action is
    /// which modifiers a session holds, not which key opened it, so two triggers on ⌘⌥ are one
    /// answer and repeating it would put the same warning up twice.
    @MainActor
    static func openingChords() -> [Hotkey] {
        let behavior = BehaviorStore.shared
        var chords = [behavior.hotkey]
        if behavior.sameAppCycle { chords.append(behavior.sameAppHotkey) }
        chords += ScopedTriggersStore.shared.scoped.triggers.filter(\.isBound).map(\.hotkey)
        var seen: Set<UInt64> = []
        return chords.filter { seen.insert($0.heldModifiers.rawValue).inserted }
    }

    /// The first opening chord that shadows a binding built on `extras`, with the modifiers it
    /// claims. nil when every chord leaves them free.
    @MainActor
    static func chordShadowing(_ extras: CGEventFlags) -> (trigger: Hotkey, claimed: CGEventFlags)? {
        for chord in openingChords() {
            let claimed = modifiersClaimed(by: chord).intersection(extras)
            if !claimed.isEmpty { return (chord, claimed) }
        }
        return nil
    }

    /// The action modifier still free under `trigger`, or nil when it claims both.
    static func freeModifier(under trigger: Hotkey) -> CGEventFlags? {
        let claimed = Self.modifiersClaimed(by: trigger)
        return [CGEventFlags.maskAlternate, .maskControl].first { !claimed.contains($0) }
    }

    /// A copy with every shadowed binding moved onto `replacement`. ⇧ is preserved — it is only ever
    /// a qualifier on top of ⌥/⌃ (⌥Q quit vs ⌥⇧Q force-quit), so dropping it would collapse pairs of
    /// bindings onto each other.
    func rebindingShadowed(by trigger: Hotkey, to replacement: CGEventFlags) -> SwitcherShortcuts {
        let claimed = Self.modifiersClaimed(by: trigger)
        var copy = self
        for action in actionsShadowed(by: trigger) {
            guard let existing = copy.bindings[action] else { continue }
            let kept = existing.extras.subtracting(claimed)
            copy.bindings[action] = ActionShortcut(
                keyCode: existing.keyCode, modifierRaw: kept.union(replacement).rawValue)
        }
        return copy
    }
}

/// Persists the per-action bindings and notifies the switcher when they change.
@MainActor
final class SwitcherShortcutsStore: ObservableObject {
    static let shared = SwitcherShortcutsStore()

    private static let bindingsKey = "switcherShortcuts"
    private static let enabledKey = "switcherActionsEnabled"
    private static let confirmKey = "switcherActionsConfirmDestructive"
    static let defaultsKeys = [bindingsKey, enabledKey, confirmKey]

    @Published private(set) var shortcuts: SwitcherShortcuts = .defaults

    /// The master switch. Off by default: these keys are live only while the panel is up, but they
    /// do take ⌥-letter combinations away from type-to-filter for as long as it is, and quitting an
    /// app is not something a user should discover by mistyping a filter.
    @Published var isEnabled: Bool = UserDefaults.standard.bool(forKey: enabledKey) {
        didSet {
            guard isEnabled != oldValue, !isReloading else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            onChange?(shortcuts)
        }
    }

    /// Ask before quitting or force-quitting. On by default — the difference between ⌥W (close a
    /// window) and ⌥Q (quit the app, losing every window it had) is one key, and only one of them
    /// can be undone.
    @Published var confirmsDestructive: Bool = true {
        didSet {
            guard confirmsDestructive != oldValue, !isReloading else { return }
            UserDefaults.standard.set(confirmsDestructive, forKey: Self.confirmKey)
            onChange?(shortcuts)
        }
    }

    /// The action currently armed for recording, if any.
    @Published private(set) var recordingAction: SwitcherAction?
    private var recordingMonitor: Any?
    /// This store's claim on `KeyRecorder`.
    private var recordingToken: Int?

    var onChange: ((SwitcherShortcuts) -> Void)?

    // MARK: - Recording

    /// Arms `action`, disarming whatever was armed before.
    ///
    /// The monitor lives here rather than in each recorder view because there is only one keyboard.
    /// Nine views each holding their own local monitor meant clicking a second recorder without
    /// pressing a key left the first still listening; both then received the next keyDown and
    /// whichever handler ran first consumed it, so the combination landed on the wrong action or on
    /// none at all. One owner, one monitor, no race.
    ///
    /// `validate` returns false to reject the combination (the caller shows its own explanation).
    func beginRecording(
        _ action: SwitcherAction, validate: @escaping (Int, CGEventFlags) -> Bool
    ) {
        stopRecording()
        // Across kinds too, not just this store's own rows — see `KeyRecorder`.
        recordingToken = KeyRecorder.arm { [weak self] in self?.stopRecording() }
        recordingAction = action
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53 {  // Esc aborts without binding
                self.stopRecording()
                return nil
            }
            let extras = Self.extras(from: event.modifierFlags)
            // ⌥ or ⌃ is required so the binding can't be mistaken for type-to-filter input.
            guard extras.contains(.maskAlternate) || extras.contains(.maskControl) else {
                return nil
            }

            let keyCode = Int(event.keyCode)
            self.stopRecording()
            // Hop off the handler before doing anything else: this tears down the very monitor that
            // is running, and `validate` may raise a modal — neither belongs inside event dispatch.
            DispatchQueue.main.async {
                guard validate(keyCode, extras) else { return }
                self.set(
                    ActionShortcut(keyCode: keyCode, modifierRaw: extras.rawValue), for: action)
            }
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingAction = nil
        if let recordingToken { KeyRecorder.disarmed(recordingToken) }
        recordingToken = nil
    }

    /// The extra modifiers of a recorded event. ⌘ is excluded — it is the held trigger, so it is
    /// neither recorded nor required.
    static func extras(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    private init() {
        shortcuts = Self.load()
        confirmsDestructive = Self.loadConfirms()
    }

    func set(_ shortcut: ActionShortcut, for action: SwitcherAction) {
        shortcuts.bindings[action] = shortcut
        persist()
    }

    func resetToDefaults() {
        shortcuts = .defaults
        persist()
    }

    /// Replaces every binding at once — used when a new trigger forces the shadowed ones to move.
    func replaceAll(with new: SwitcherShortcuts) {
        shortcuts = new
        persist()
    }

    /// Suppresses the write half of the `didSet` handlers while `reload()` runs. Same guard as
    /// `BehaviorStore.isReloading`, and here for the same reason: every value assigned below was
    /// just read out of its key, so the write is a no-op where the key existed and a fabrication
    /// where it did not. The effect is milder than `AppearanceStore`'s — the values written back
    /// after a reset equal the defaults — but it still re-creates keys that `resetAll()` removed
    /// on purpose, and "absent" is the only state a future default change can reach.
    private var isReloading = false

    func reload() {
        isReloading = true
        shortcuts = Self.load()
        isEnabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        confirmsDestructive = Self.loadConfirms()
        isReloading = false
        onChange?(shortcuts)
    }

    /// Absent means on, so an install that predates the setting gets the confirmation rather than
    /// silently inheriting "never ask" from a `bool(forKey:)` that reads a missing key as false.
    private static func loadConfirms() -> Bool {
        UserDefaults.standard.object(forKey: confirmKey) as? Bool ?? true
    }

    /// Stored as `{ actionRawValue: [keyCode, modifierRaw] }`, which is plist-safe.
    ///
    /// Iterating the live cases rather than the stored keys is what lets a retired action's binding
    /// sit in an old settings file harmlessly — the Space moves were stored here once.
    private static func load() -> SwitcherShortcuts {
        var result = SwitcherShortcuts.defaults
        guard let raw = UserDefaults.standard.dictionary(forKey: bindingsKey) else { return result }
        for action in SwitcherAction.allCases {
            guard let pair = raw[action.rawValue] as? [Int], pair.count == 2 else { continue }
            result.bindings[action] = ActionShortcut(
                keyCode: pair[0], modifierRaw: UInt64(bitPattern: Int64(pair[1])))
        }
        return result
    }

    private func persist() {
        var raw: [String: [Int]] = [:]
        for (action, shortcut) in shortcuts.bindings {
            raw[action.rawValue] = [shortcut.keyCode, Int(bitPattern: UInt(shortcut.modifierRaw))]
        }
        UserDefaults.standard.set(raw, forKey: Self.bindingsKey)
        onChange?(shortcuts)
    }
}
