import AppKit
import SwiftUI

/// The window actions available while the switcher is open. Each is bound to a key plus *extra*
/// modifiers — the trigger modifier (⌘ by default) is always held, so a binding only records what
/// is pressed on top of it. An extra modifier is required (⌥ or ⌃) so an action key can't be
/// mistaken for type-to-filter input.
enum SwitcherAction: String, CaseIterable, Identifiable {
    case quit, forceQuit, close, hide, hideOthers, minimize, zoom
    case moveDesktopPrev, moveDesktopNext, moveDisplayPrev, moveDisplayNext

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
        case .moveDesktopPrev: return "Move to previous desktop"
        case .moveDesktopNext: return "Move to next desktop"
        case .moveDisplayPrev: return "Move to previous display"
        case .moveDisplayNext: return "Move to next display"
        }
    }

    /// Default binding. Desktop (Space) move is on ⌥←/→; display move on ⌥⇧←/→ so the two don't
    /// collide on the arrow keys.
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
        case .moveDesktopPrev: return ActionShortcut(keyCode: 123, modifierRaw: option)  // ←
        case .moveDesktopNext: return ActionShortcut(keyCode: 124, modifierRaw: option)  // →
        case .moveDisplayPrev: return ActionShortcut(keyCode: 123, modifierRaw: optionShift)  // ⇧←
        case .moveDisplayNext: return ActionShortcut(keyCode: 124, modifierRaw: optionShift)  // ⇧→
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
        bindings: Dictionary(uniqueKeysWithValues: SwitcherAction.allCases.map { ($0, $0.defaultShortcut) }))

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

    static let defaultsKey = "switcherShortcuts"

    @Published private(set) var shortcuts: SwitcherShortcuts = .defaults

    var onChange: ((SwitcherShortcuts) -> Void)?

    private init() { shortcuts = Self.load() }

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

    func reload() {
        shortcuts = Self.load()
        onChange?(shortcuts)
    }

    /// Stored as `{ actionRawValue: [keyCode, modifierRaw] }`, which is plist-safe.
    private static func load() -> SwitcherShortcuts {
        var result = SwitcherShortcuts.defaults
        guard let raw = UserDefaults.standard.dictionary(forKey: defaultsKey) else { return result }
        // A config saved before the desktop move existed has move-to-display at its old ⌥←/→ default,
        // which now collides with move-to-desktop. Drop those stale display bindings so they take the
        // new ⌥⇧←/→ default instead of shadowing the desktop move.
        let preDesktop = raw["moveDesktopNext"] == nil && raw["moveDesktopPrev"] == nil
        for action in SwitcherAction.allCases {
            if preDesktop, action == .moveDisplayPrev || action == .moveDisplayNext { continue }
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
        UserDefaults.standard.set(raw, forKey: Self.defaultsKey)
        onChange?(shortcuts)
    }
}
