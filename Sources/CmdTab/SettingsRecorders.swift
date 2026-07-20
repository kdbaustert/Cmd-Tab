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
        .frame(width: 220)
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
            stop()
            apply(candidate)
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
    @State private var recording = false
    @State private var monitor: Any?

    private var current: ActionShortcut {
        store.shortcuts.bindings[action] ?? action.defaultShortcut
    }

    var body: some View {
        Button(recording ? "Press keys…" : current.displayString) {
            recording ? stop() : start()
        }
        .frame(width: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc aborts without binding
            let extras = Self.extras(from: event.modifierFlags)
            guard extras.contains(.maskAlternate) || extras.contains(.maskControl) else { return nil }
            store.set(
                ActionShortcut(keyCode: Int(event.keyCode), modifierRaw: extras.rawValue),
                for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func extras(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }
}

