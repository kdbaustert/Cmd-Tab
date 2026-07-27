import AppKit

/// The right-click menu on a tile.
///
/// Every item is one of the `SwitcherAction`s the keyboard bindings already fire, so the mouse and
/// the keyboard reach the same handlers — the menu is a second door onto them, not a second
/// implementation. It carries the closing actions only: quit, force-quit, close, minimize and hide.
/// The move-to-desktop/display bindings are navigation rather than closing, and a menu you have to
/// reopen between each nudge is a poor way to drive them, so they stay on the keyboard.
///
/// A class rather than a free function because `NSMenuItem.target` is weak: something has to own the
/// object the items point at for as long as the menu is up. The controller holds one of these for
/// its lifetime and reuses it.
@MainActor
final class TileMenu: NSObject {
    /// The actions offered, in menu order.
    private static let actions: [SwitcherAction] = [.quit, .forceQuit, .close, .minimize, .hide]
    /// Where the separator goes — after the two that end the process, before the ones that only
    /// tidy a window away.
    private static let separatorAfter: SwitcherAction = .forceQuit

    /// What an item carries: the action, and the id of the tile the menu was opened on. The id is the
    /// point — by the time an item fires, the cursor is sitting wherever it was clicked, which is over
    /// a different tile as often as not, so "the selected tile" is no longer a safe way to say which
    /// app this menu was about.
    private struct Item {
        let action: SwitcherAction
        let targetID: String
    }

    private let perform: (SwitcherAction, String) -> Void

    /// `perform` receives the action and the id of the tile the menu belongs to.
    init(perform: @escaping (SwitcherAction, String) -> Void) {
        self.perform = perform
    }

    /// Builds the menu for `target`. `shortcuts` and `trigger` are only used to label the items with
    /// the combination that does the same thing from the keyboard.
    func menu(for target: SwitchTarget, shortcuts: SwitcherShortcuts, trigger: Hotkey) -> NSMenu {
        let menu = NSMenu()
        // Our target responds to the item action, which is enough for AppKit to enable an item on
        // its own — but only by accident of the validation rules. Owning the state explicitly keeps
        // it from turning on whether an item is clickable at all.
        menu.autoenablesItems = false
        for action in Self.actions {
            let item = NSMenuItem(
                title: Self.title(action, appName: target.appName), action: #selector(fire(_:)),
                keyEquivalent: "")
            item.target = self
            item.representedObject = Item(action: action, targetID: target.id)
            if let (key, mask) = Self.equivalent(for: shortcuts.bindings[action], trigger: trigger) {
                item.keyEquivalent = key
                item.keyEquivalentModifierMask = mask
            }
            menu.addItem(item)
            if action == Self.separatorAfter { menu.addItem(.separator()) }
        }
        return menu
    }

    @objc private func fire(_ sender: NSMenuItem) {
        guard let item = sender.representedObject as? Item else { return }
        perform(item.action, item.targetID)
    }

    /// Names the app in the items that act on the whole process, the way the Dock's own menu does —
    /// the tile under the cursor and the app about to be quit had better be unmistakably the same one.
    /// The window items are left generic: the window they act on is the tile's front one, and naming
    /// its title here would only ever be right in window mode.
    ///
    /// Title-cased rather than reusing `SwitcherAction.title` throughout, which is written for the
    /// sentence-cased settings rows ("Close window") rather than a menu.
    private static func title(_ action: SwitcherAction, appName: String) -> String {
        switch action {
        case .quit: return "Quit \(appName)"
        case .forceQuit: return "Force Quit \(appName)"
        case .hide: return "Hide \(appName)"
        case .close: return "Close Window"
        case .minimize: return "Minimize Window"
        default: return action.title
        }
    }

    /// The shortcut to show beside an item: the trigger's own modifiers (held for as long as the
    /// switcher is up, so the user really does press them) plus the binding's extras.
    ///
    /// Only for bindings on a plain letter. `Hotkey.keyName` answers `"Key 33"` for anything outside
    /// its table, and an item labelled with a shortcut that isn't the one bound is worse than an item
    /// labelled with none. The item still works either way — this is a hint, not the wiring.
    private static func equivalent(
        for shortcut: ActionShortcut?, trigger: Hotkey
    ) -> (String, NSEvent.ModifierFlags)? {
        guard let shortcut else { return nil }
        let name = Hotkey.keyName(for: shortcut.keyCode)
        guard name.count == 1, let scalar = name.unicodeScalars.first,
            CharacterSet.letters.contains(scalar)
        else { return nil }
        return (
            name.lowercased(),
            modifierFlags(trigger.heldModifiers).union(modifierFlags(shortcut.extras))
        )
    }

    private static func modifierFlags(_ flags: CGEventFlags) -> NSEvent.ModifierFlags {
        var out: NSEvent.ModifierFlags = []
        if flags.contains(.maskCommand) { out.insert(.command) }
        if flags.contains(.maskAlternate) { out.insert(.option) }
        if flags.contains(.maskControl) { out.insert(.control) }
        if flags.contains(.maskShift) { out.insert(.shift) }
        return out
    }
}
