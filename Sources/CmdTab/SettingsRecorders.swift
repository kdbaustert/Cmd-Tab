import AppKit
import SwiftUI

/// Click, then press a combination to rebind the trigger. A modifier (⌘/⌥/⌃) is required, since the
/// switcher stays open only while that modifier is held.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : hotkey.displayString) {
            recording ? stop() : start()
        }
        // Narrower than before: these sit two rows to a line now, and one of them shares its cell
        // with an enable checkbox.
        .frame(width: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags
            // Ignore Escape so there is a way to abort without binding it.
            if event.keyCode == 53 { stop(); return nil }
            let mods = Self.cgFlags(from: flags)
            // A hold-to-open hotkey needs a non-Shift modifier to hold.
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            // Off the handler: `stop()` removes the monitor currently executing this block, and
            // `apply` may raise a modal. Neither belongs inside event dispatch.
            DispatchQueue.main.async {
                stop()
                apply(candidate)
            }
            return nil
        }
    }

    /// Applies a recorded trigger, refusing one that would make action shortcuts unreachable.
    ///
    /// Nothing is silently remapped: either the trigger is rejected, or the user explicitly agrees
    /// to move the affected bindings. Letting it through would break the actions *and* misroute
    /// their keys into type-to-filter, with no visible cause.
    private func apply(_ candidate: Hotkey) {
        let store = SwitcherShortcutsStore.shared
        let shadowed = store.shortcuts.actionsShadowed(by: candidate)
        guard !shadowed.isEmpty else {
            hotkey = candidate
            return
        }

        let claimed = Self.name(for: SwitcherShortcuts.modifiersClaimed(by: candidate))
        let plural = shadowed.count == 1 ? "" : "s"
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "\(candidate.displayString) would disable \(shadowed.count) shortcut\(plural)"
        alert.informativeText = """
            This trigger holds \(claimed) for as long as the switcher is open, and \
            \(shadowed.count) action\(plural) need\(shadowed.count == 1 ? "s" : "") it as an extra \
            modifier. The keyboard reports one \(claimed) either way, so those shortcuts would type \
            into the filter instead of running.

            Affected: \(shadowed.map(\.title).joined(separator: ", ")).
            """

        let free = SwitcherShortcuts.freeModifier(under: candidate)
        if let free {
            alert.addButton(withTitle: "Rebind to \(Self.name(for: free))")
        }
        alert.addButton(withTitle: "Cancel")

        let response = alert.runModal()
        guard let free, response == .alertFirstButtonReturn else { return }
        store.replaceAll(with: store.shortcuts.rebindingShadowed(by: candidate, to: free))
        hotkey = candidate
    }

    private static func name(for flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        return parts.isEmpty ? "no modifier" : parts.joined(separator: " and ")
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }
}

/// Records a binding for one in-switcher action: a key plus *extra* modifiers (⌘ is the held
/// trigger, so it is neither recorded nor required). At least ⌥ or ⌃ is required so the binding
/// can't be swallowed by type-to-filter.
struct ActionShortcutRecorder: View {
    let action: SwitcherAction
    @ObservedObject var store: SwitcherShortcutsStore

    private var current: ActionShortcut {
        store.shortcuts.bindings[action] ?? action.defaultShortcut
    }

    /// Derived from the store rather than held locally, so arming one recorder visibly disarms the
    /// rest instead of leaving a row of buttons all claiming to be listening.
    private var isRecording: Bool { store.recordingAction == action }

    var body: some View {
        Button(isRecording ? "Press keys…" : current.displayString) {
            isRecording ? store.stopRecording() : store.beginRecording(action, validate: validate)
        }
        .frame(width: 120)
        .onDisappear { if isRecording { store.stopRecording() } }
    }

    /// Rejects a binding built on a modifier the current trigger already holds.
    ///
    /// The trigger recorder has always checked this from its side, but the check has to exist on
    /// both: recording ⌥W here while the trigger is ⌘⌥-Tab produced a binding that can never match,
    /// because the trigger's ⌥ is subtracted before matching. The key then falls through to
    /// type-to-filter and types "w" instead of closing the window — the exact silent failure the
    /// conflict alert was introduced to make impossible.
    private func validate(keyCode: Int, extras: CGEventFlags) -> Bool {
        let trigger = BehaviorStore.shared.hotkey
        let claimed = SwitcherShortcuts.modifiersClaimed(by: trigger).intersection(extras)
        guard claimed.isEmpty else {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That shortcut can't fire while \(trigger.displayString) opens the switcher"
            alert.informativeText = """
                The trigger holds \(Self.name(for: claimed)) for the whole session, so a binding that \
                also needs it is indistinguishable from typing — this would filter the list instead \
                of running "\(action.title)".

                \(Self.remedy(under: trigger))
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
        return true
    }

    private static func name(for flags: CGEventFlags) -> String {
        var parts: [String] = []
        if flags.contains(.maskControl) { parts.append("⌃") }
        if flags.contains(.maskAlternate) { parts.append("⌥") }
        return parts.isEmpty ? "no modifier" : parts.joined(separator: " and ")
    }

    /// What to actually do about the conflict. A trigger holding *both* ⌥ and ⌃ leaves nothing to
    /// rebind onto, so naming a modifier there would name one this same check rejects — a dialog
    /// telling the user to do the thing that just failed, with no way out of the loop.
    private static func remedy(under trigger: Hotkey) -> String {
        guard let free = SwitcherShortcuts.freeModifier(under: trigger) else {
            return """
                This trigger holds both ⌥ and ⌃, so no action shortcut can work alongside it — \
                change the trigger before binding actions.
                """
        }
        return "Use a combination built on \(name(for: free)) instead."
    }
}

