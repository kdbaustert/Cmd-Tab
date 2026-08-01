import AppKit
import SwiftUI

/// The Windows tab: global hotkeys that snap the focused window to a half, a corner, the whole
/// screen or the centre.
///
/// Separate from the Shortcuts tab, which is about the switcher — these fire with nothing open and
/// act on whatever window you are looking at, so grouping them with the in-switcher action keys
/// would put two quite different kinds of binding under one heading.
struct WindowSettings: View {
    @ObservedObject var store: WindowTilingStore
    @ObservedObject private var globals = GlobalActionsStore.shared

    /// The order the rows read in: the four halves, then the four corners, then the three that are
    /// not a fraction of the screen at all.
    private static let groups: [(title: String, arrangements: [WindowArrangement])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        ("Thirds", [.leftThird, .centerThird, .rightThird]),
        ("Corners", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Whole window", [.maximize, .center, .restore]),
        ("Displays", [.previousDisplay, .nextDisplay]),
    ]

    private var isEnabled: Binding<Bool> {
        Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 })
    }

    private var cycleWidths: Binding<Bool> {
        Binding(get: { store.cycleWidths }, set: { store.cycleWidths = $0 })
    }

    private var dragSnap: Binding<Bool> {
        Binding(get: { store.dragSnap }, set: { store.dragSnap = $0 })
    }

    var body: some View {
        SettingsPage(
            title: "Windows",
            subtitle: "Snap the focused window without reaching for its edges. These work "
                + "system-wide, whether or not the switcher is open."
        ) {
            SettingsSection(
                title: "Window tiling", anchor: SettingsAnchor.tiling,
                footer: "Off by default. Each binding is a real global hotkey — while tiling is on, "
                    + "Cmd-Tab takes those combinations from whatever app is in front, so nothing "
                    + "is claimed until you ask for it."
            ) {
                SettingsToggle(
                    title: "Enable window tiling",
                    subtitle: "Defaults sit on ⌃⌘, which macOS leaves almost entirely free.",
                    isOn: isEnabled)
                SettingsToggle(
                    title: "Snap by dragging",
                    subtitle: "Drag a window's title bar to a screen edge or corner to tile it "
                        + "there. Independent of the shortcuts below — you can have either, or both.",
                    isOn: dragSnap)
                SettingsToggle(
                    title: "Cycle widths",
                    subtitle: "Press the same half twice to step the window through ½ → ⅔ → ⅓ of "
                        + "the screen on that side.",
                    isOn: cycleWidths)
            }

            // Deliberately *not* disabled while tiling is off. Setting the keys up before switching
            // the feature on is the natural order to do this in, and a pane of dead recorders is
            // exactly the shape of "you cannot define these".
            ForEach(Self.groups, id: \.title) { group in
                SettingsSection(title: group.title, anchor: anchor(for: group.title)) {
                    ForEach(group.arrangements) { arrangement in
                        SettingsRow(
                            title: arrangement.title,
                            subtitle: subtitle(for: arrangement),
                            controlWidth: 168
                        ) {
                            TilingShortcutRecorder(arrangement: arrangement, store: store)
                        }
                    }
                }
            }

            SettingsSection(
                title: "All windows", anchor: SettingsAnchor.allWindows,
                footer: "Unbound by default: these act system-wide and have no natural home key, so "
                    + "the combination is yours to pick rather than ours to claim."
            ) {
                SettingsRow(
                    title: "Hide all windows",
                    subtitle: "Hide every app to clear the screen to the desktop.",
                    controlWidth: 168
                ) {
                    GlobalShortcutRecorder(
                        id: "allWindows.hide", hotkey: globals.allWindows.hideAll,
                        assign: globals.setHideAll, store: globals)
                }
                SettingsRow(
                    title: "Show all windows",
                    subtitle: "Bring back exactly what Hide all hid — apps you hid yourself stay "
                        + "hidden.",
                    controlWidth: 168
                ) {
                    GlobalShortcutRecorder(
                        id: "allWindows.show", hotkey: globals.allWindows.showAll,
                        assign: globals.setShowAll, store: globals)
                }
            }

            HStack(spacing: 8) {
                Text("Click a shortcut and press a new combination. ⌫ clears it, ⎋ cancels.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Restore defaults", action: store.resetToDefaults)
            }
        }
    }

    /// The row's explanation, or a warning when the binding cannot do what it looks like it does.
    ///
    /// A trigger collision is checked on every render, not only at record time: changing the
    /// switcher shortcut later can strand a tiling chord that was perfectly good when it was set.
    private func subtitle(for arrangement: WindowArrangement) -> String? {
        if let hotkey = store.hotkey(for: arrangement),
            let claimer = WindowTilingBindings.triggerClaiming(hotkey, in: .shared) {
            return "\(hotkey.displayString) opens \(claimer) — this will never fire."
        }
        let clashes = store.tiling.conflicts(with: arrangement)
        if !clashes.isEmpty {
            let names = clashes.map(\.title).joined(separator: ", ")
            // Which one actually wins is `WindowArrangement.allCases` order, and saying so is more
            // use than a bare "conflict".
            let winner = WindowArrangement.allCases.first { $0 == arrangement || clashes.contains($0) }
            return "Same shortcut as \(names) — only \(winner?.title ?? arrangement.title) will fire."
        }
        switch arrangement {
        case .center: return "Keeps the window's size and centres it."
        case .restore: return "Back to where the window was before you first tiled it."
        case .previousDisplay, .nextDisplay:
            return "Keeps the window's size and its relative position on the new display."
        default: return nil
        }
    }

    /// Groups share the tiling anchor's prefix, so a search hit on "tile left" lands on the tiling
    /// card with the three groups scrolled into view underneath it.
    private func anchor(for title: String) -> String {
        "\(SettingsAnchor.tiling).\(title.lowercased())"
    }
}

/// Records one tiling chord.
///
/// Its own recorder rather than `HotkeyRecorder` because the semantics differ: a tiling binding may
/// be **unset** (the chord goes back to whatever app wants it), and it is never checked for
/// shadowing in-switcher actions, since it is matched only when nothing is open and holds nothing
/// for the duration of anything.
///
/// The recording state and the keyboard monitor belong to the store, not to this view — see
/// `WindowTilingStore.beginRecording`. Eleven of these share one pane and one keyboard.
struct TilingShortcutRecorder: View {
    let arrangement: WindowArrangement
    @ObservedObject var store: WindowTilingStore

    private var hotkey: Hotkey? { store.hotkey(for: arrangement) }
    private var isRecording: Bool { store.recordingArrangement == arrangement }

    var body: some View {
        HStack(spacing: 4) {
            Button(label) {
                isRecording ? store.stopRecording() : start()
            }
            .frame(width: 128)
            // A binding that cannot fire is still shown — flagged rather than hidden, with the row
            // subtitle saying why.
            .foregroundStyle(isBroken ? Color.orange : Color.primary)

            Button {
                store.clear(arrangement)
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
        // Only the armed recorder tears the monitor down, so a redraw of the other ten cannot
        // disarm the one the user is actually using.
        .onDisappear { if isRecording { store.stopRecording() } }
    }

    private var label: String {
        if isRecording { return "Press keys…" }
        return hotkey?.displayString ?? "Not set"
    }

    private var isBroken: Bool {
        if let hotkey, WindowTilingBindings.triggerClaiming(hotkey, in: .shared) != nil { return true }
        return !store.tiling.conflicts(with: arrangement).isEmpty
    }

    /// Arms the store's single monitor, refusing a chord a switcher trigger would swallow first.
    ///
    /// Refused rather than merely flagged, unlike a duplicate between two arrangements: swapping a
    /// pair of tiling chords needs an intermediate state where they collide, but there is no
    /// workflow in which binding the trigger's own chord is a step towards anything.
    private func start() {
        store.beginRecording(arrangement) { candidate in
            guard let claimer = WindowTilingBindings.triggerClaiming(candidate, in: .shared) else {
                return true
            }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(candidate.displayString) is already \(claimer)"
            alert.informativeText =
                "The switcher is matched before window tiling, so this combination would open it "
                + "rather than move a window — the binding would look set and never fire.\n\n"
                + "Pick a different combination, or change the shortcut in Settings → Shortcuts."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }
}
