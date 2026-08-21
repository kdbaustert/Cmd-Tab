import AppKit
import SwiftUI

/// The one armed key recorder in Settings, whichever kind it is.
///
/// Every recorder installs an `NSEvent` local monitor that returns nil for keys it does not want,
/// which discards them app-wide. Two armed at once is therefore not cosmetic: the stray one keeps
/// swallowing every plain keystroke in the window, so the sidebar search field and the per-app Name
/// field stop accepting typing until the user notices a second button still reading "Press keys…"
/// and clicks it.
///
/// The four store-owned recorders open `beginRecording` with `stopRecording()` and so never
/// collided with *their own kind*. `HotkeyRecorder` and `ModifierChordRecorder` keep `recording`
/// and their monitor in view-local `@State`, where nothing outside the view can reach them — and
/// two of each are rendered side by side (the switcher and app-cycle triggers; the Move and Resize
/// chords). Clicking the second is a mouse event the first one's `.keyDown` monitor ignores, so
/// nothing told it to stand down.
///
/// One arbiter rather than moving both views' state into stores: what has to hold is "at most one
/// monitor is installed", which is a single fact about the process, not a property of any store.
/// Routing the store-owned recorders through it too is what makes that true across kinds, so
/// arming a trigger recorder disarms an armed action recorder and vice versa.
@MainActor
enum KeyRecorder {
    private static var nextToken = 0
    private static var armed: (token: Int, disarm: () -> Void)?

    /// Stops whatever was armed, then arms `disarm`. The returned token is what `stop()` hands back
    /// so a recorder can only ever clear *itself*.
    @discardableResult
    static func arm(_ disarm: @escaping () -> Void) -> Int {
        stopCurrent()
        nextToken += 1
        armed = (nextToken, disarm)
        return nextToken
    }

    /// Clears the record if `token` still names the armed recorder.
    ///
    /// The token is what makes this safe to call unconditionally from every `stop()`. The recorder
    /// `arm` just stopped calls its own `stop()` on the way out, holding a token that no longer
    /// names anyone — without the check it would clear the recorder that had just replaced it.
    static func disarmed(_ token: Int) {
        if armed?.token == token { armed = nil }
    }

    /// Stops whatever is armed, if anything.
    static func stopCurrent() {
        guard let current = armed else { return }
        armed = nil
        current.disarm()
    }
}

/// Click, then press a combination to rebind the trigger. A modifier (⌘/⌥/⌃) is required, since the
/// switcher stays open only while that modifier is held.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?
    /// This recorder's claim on `KeyRecorder`, so `stop()` can only ever release its own.
    @State private var token: Int?

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
        // Disarms any other recorder first — see `KeyRecorder`.
        token = KeyRecorder.arm(stop)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags
            // Ignore Escape so there is a way to abort without binding it.
            if event.keyCode == 53 { stop(); return nil }
            let mods = Hotkey.flags(from: flags)
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
    ///
    /// Both recorders using this type are triggers that hold their modifier for the whole session,
    /// so both need the check — there is no caller for which it is merely noise.
    private func apply(_ candidate: Hotkey) {
        let store = SwitcherShortcutsStore.shared
        let shadowed = store.isEnabled ? store.shortcuts.actionsShadowed(by: candidate) : []
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
        if let token { KeyRecorder.disarmed(token) }
        token = nil
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
        .frame(width: 130)
        .onDisappear { if isRecording { store.stopRecording() } }
    }

    /// Rejects a binding built on a modifier an opening chord already holds.
    ///
    /// The trigger recorder has always checked this from its side, but the check has to exist on
    /// both: recording ⌥W here while the trigger is ⌘⌥-Tab produced a binding that can never match,
    /// because the trigger's ⌥ is subtracted before matching. The key then falls through to
    /// type-to-filter and types "w" instead of closing the window — the exact silent failure the
    /// conflict alert was introduced to make impossible.
    ///
    /// Every opening chord, not just `BehaviorStore.hotkey`: a scoped trigger holds its modifiers
    /// for its session in exactly the same way. See `SwitcherShortcuts.openingChords()`.
    private func validate(keyCode: Int, extras: CGEventFlags) -> Bool {
        guard let (trigger, claimed) = SwitcherShortcuts.chordShadowing(extras) else { return true }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText =
            "That shortcut can't fire while \(trigger.displayString) opens the switcher"
        alert.informativeText = """
            The trigger holds \(Self.name(for: claimed)) for the whole session, so a binding \
            that also needs it is indistinguishable from typing — this would filter the list \
            instead of running "\(action.title)".

            \(Self.remedy(under: trigger))
            """
        alert.addButton(withTitle: "OK")
        alert.runModal()
        return false
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
