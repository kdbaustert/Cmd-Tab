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
