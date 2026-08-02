import AppKit
import SwiftUI

/// Records one global chord — a direct-activation jump or an all-windows action.
///
/// The recording state and the keyboard monitor belong to `GlobalActionsStore`, not to the view:
/// there is one keyboard, and a pane can hold a dozen of these. See
/// `WindowTilingStore.beginRecording` for the failure that shape prevents.
///
/// Every global chord is validated against the switcher triggers before it is accepted. The tap
/// matches those first, so a binding that collides could only ever open the switcher — it would sit
/// in the list looking set and never once fire.
struct GlobalShortcutRecorder: View {
    /// Identifies this recorder to the store's single-monitor bookkeeping. A bundle identifier for
    /// a direct activation, or a fixed string for the all-windows rows.
    let id: String
    let hotkey: Hotkey?
    let assign: (Hotkey?) -> Void

    @ObservedObject var store: GlobalActionsStore

    private var isRecording: Bool { store.recordingID == id }

    var body: some View {
        HStack(spacing: 4) {
            Button(label) {
                isRecording ? store.stopRecording() : start()
            }
            .frame(width: 128)
            .foregroundStyle(isBroken ? Color.orange : Color.primary)

            Button {
                assign(nil)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear this shortcut")
            .opacity(hotkey == nil ? 0 : 1)
            .disabled(hotkey == nil)
        }
        .onDisappear { if isRecording { store.stopRecording() } }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return hotkey?.displayString ?? "Not set"
    }

    /// A stored chord can go stale after the fact — changing the switcher trigger is enough — so
    /// this is re-checked on every render rather than only when the chord is recorded.
    private var isBroken: Bool {
        guard let hotkey else { return false }
        return WindowTilingBindings.triggerClaiming(hotkey, in: .shared) != nil
    }

    private func start() {
        store.beginRecording(id) { candidate in
            guard let claimer = WindowTilingBindings.triggerClaiming(candidate, in: .shared) else {
                return true
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(candidate.displayString) is already \(claimer)"
            alert.informativeText =
                "The switcher is matched before global actions, so this combination would open it "
                + "rather than run the action — the binding would look set and never fire.\n\n"
                + "Pick a different combination, or change the shortcut in Settings → Shortcuts."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        } assign: { hotkey in
            assign(hotkey)
        }
    }
}

/// Records the chord that restores one saved layout.
///
/// A sibling of `GlobalShortcutRecorder` rather than a reuse of it: that one is bound to
/// `GlobalActionsStore` for its single-monitor bookkeeping, and layouts keep their own. The two
/// stores each need exactly one armed recorder at a time, and sharing a monitor across both would
/// mean arming a layout silently disarmed a direct activation.
struct LayoutShortcutRecorder: View {
    let layout: WindowLayout
    @ObservedObject var store: WindowLayoutsStore

    private var isRecording: Bool { store.recordingID == layout.id }

    /// Amber when the binding exists but cannot fire — a switcher trigger claims it, or another
    /// layout does. The subtitle says which; this is the at-a-glance half.
    private var isBroken: Bool {
        guard let hotkey = layout.hotkey else { return false }
        return WindowTilingBindings.triggerClaiming(hotkey, in: BehaviorStore.shared) != nil
            || !store.conflicts(with: hotkey, excluding: layout.id).isEmpty
    }

    var body: some View {
        HStack(spacing: 4) {
            Button(isRecording ? "Press keys…" : (layout.hotkey?.displayString ?? "Not set")) {
                isRecording ? store.stopRecording() : store.beginRecording(layout.id)
            }
            .frame(width: 128)
            .foregroundStyle(isBroken ? Color.orange : Color.primary)

            Button {
                store.setHotkey(nil, for: layout.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear this shortcut")
            .opacity(layout.hotkey == nil ? 0 : 1)
            .disabled(layout.hotkey == nil)
        }
        .onDisappear { if isRecording { store.stopRecording() } }
    }
}
