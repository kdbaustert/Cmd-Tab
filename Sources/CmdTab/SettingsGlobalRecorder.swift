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

