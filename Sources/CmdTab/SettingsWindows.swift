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

    /// Wider than the 168 the recorders use: a `ColorSettingControl` is three controls in a row, not
    /// one, and the hex field is unusable squeezed into a recorder's width.
    private static let colorControlWidth: CGFloat = 250

    /// The rest-delay slider's range, named because the two ends of it do not fit on one line at
    /// the call site and a `...` split across two does not parse.
    private static let restRange =
        FocusFollowsMouseSettings.minimumDelay...FocusFollowsMouseSettings.maximumDelay

    /// The order the rows read in: the four halves, then the thirds, then the four corners, then the
    /// three that are not a fraction of the screen at all, then the two families that are relative
    /// to wherever the window already is.
    ///
    /// Every group here is governed by the tiling switch. The ones that are not have cards of their
    /// own below, because each needs a footer saying why.
    private static let groups: [(title: String, arrangements: [WindowArrangement])] = [
        ("Halves", [.leftHalf, .rightHalf, .topHalf, .bottomHalf]),
        (
            "Thirds",
            [
                .leftThird, .centerThird, .rightThird, .topThird, .bottomThird, .leftTwoThirds,
                .rightTwoThirds,
            ]
        ),
        ("Corners", [.topLeft, .topRight, .bottomLeft, .bottomRight]),
        ("Whole window", [.maximize, .center, .restore]),
        ("Size", [.larger, .smaller]),
        ("Nudge", WindowArrangement.nudges),
        ("Swap", WindowArrangement.swaps),
    ]

    /// The send-it-elsewhere group. Its own card rather than a fifth entry in `groups` because it
    /// is the one the tiling switch does not govern, and the footer has to say so.
    private static let moveGroup = ("Displays", [WindowArrangement.previousDisplay, .nextDisplay])

    /// The focus chords. Outside `groups` on the same argument the display moves are: they are not
    /// governed by the tiling switch, and a card whose rows quietly answered to a checkbox captioned
    /// about resizing would be the confusion that split exists to prevent.
    private static let focusGroup = ("Focus", WindowArrangement.focusMoves)

    /// The Desktop moves. Their own card again, because they are the one family with a switch of
    /// their own and the footer has to explain what that switch is protecting the user from.
    private static let desktopGroup = (
        "Desktops", [WindowArrangement.previousDesktop, .nextDesktop]
    )

    private var isEnabled: Binding<Bool> {
        Binding(get: { store.isEnabled }, set: { store.isEnabled = $0 })
    }

    private var cycleWidths: Binding<Bool> {
        Binding(get: { store.cycleWidths }, set: { store.cycleWidths = $0 })
    }

    private var dragSnap: Binding<Bool> {
        Binding(get: { store.dragSnap }, set: { store.dragSnap = $0 })
    }

    private var gap: Binding<Double> {
        Binding(get: { Double(store.gap) }, set: { store.gap = CGFloat($0) })
    }

    private var mouseDragEnabled: Binding<Bool> {
        Binding(get: { store.mouseDrag.isEnabled }, set: { store.mouseDragEnabled = $0 })
    }

    private var desktopMoves: Binding<Bool> {
        Binding(get: { store.desktopMoves }, set: { store.desktopMoves = $0 })
    }

    private var followsDesktopMove: Binding<Bool> {
        Binding(get: { store.followsDesktopMove }, set: { store.followsDesktopMove = $0 })
    }

    private var pointerFollowsDisplayMove: Binding<Bool> {
        Binding(
            get: { store.pointerFollowsDisplayMove },
            set: { store.pointerFollowsDisplayMove = $0 })
    }

    private var restoresLayoutOnDisplayChange: Binding<Bool> {
        Binding(
            get: { store.restoresLayoutOnDisplayChange },
            set: { store.restoresLayoutOnDisplayChange = $0 })
    }

    private var focusFollowsMouse: Binding<Bool> {
        Binding(get: { store.focusFollowsMouse }, set: { store.focusFollowsMouse = $0 })
    }

    private var focusFollowsMouseDelay: Binding<Double> {
        Binding(
            get: { store.focusFollowsMouseDelay }, set: { store.focusFollowsMouseDelay = $0 })
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
                    + "is claimed until you ask for it. Displays and Focus are the exceptions: "
                    + "moving a window is not resizing it and moving the keyboard is not either, so "
                    + "both stay live whatever this switch says."
            ) {
                SettingsToggle(
                    title: "Enable window tiling",
                    subtitle: "Sizes and positions only — the Displays moves and the Focus chords "
                        + "do not wait on this. Defaults sit on ⌃⌘, which macOS leaves almost "
                        + "entirely free.",
                    isOn: isEnabled)
                SettingsToggle(
                    title: "Snap by dragging",
                    subtitle: "Drag a window's title bar to a screen edge or corner to tile it "
                        + "there. Independent of the shortcuts below — you can have either, or both.",
                    isOn: dragSnap)
                SettingsSlider(
                    title: "Gap",
                    subtitle: "Space left around a tiled window: the full gap against a screen "
                        + "edge, half of it where two windows meet — so neighbours sit exactly one "
                        + "gap apart. 0 keeps them flush.",
                    value: gap,
                    range: 0...Double(TilingGap.maximum),
                    step: 2,
                    format: { $0 == 0 ? "Off" : "\(Int($0)) px" })
                SettingsToggle(
                    title: "Cycle widths",
                    subtitle: "Press the same half twice to step the window through ½ → ⅔ → ⅓ of "
                        + "the screen on that side.",
                    isOn: cycleWidths)
            }

            SettingsSection(
                title: "Mouse", anchor: SettingsAnchor.mouseDrag,
                footer: "While the modifier is held, the drag is Cmd-Tab's and the app underneath "
                    + "never sees it — so a move across a document does not select text on the way. "
                    + "Independent of the tiling switch above, and of Snap by dragging."
            ) {
                SettingsToggle(
                    title: "Move and resize with the mouse",
                    subtitle: "Hold a modifier and drag anywhere in a window — no aiming at the "
                        + "titlebar or a 4px edge. A resize takes the corner of the quarter you "
                        + "press in; the opposite corner stays put. Drag to a screen edge or "
                        + "corner and the snap zone lights up: let go there and the window tiles "
                        + "to it, gaps included.",
                    isOn: mouseDragEnabled)
                ForEach(MouseDragAction.allCases) { action in
                    SettingsRow(
                        title: action.title,
                        subtitle: chordSubtitle(for: action),
                        controlWidth: 168
                    ) {
                        ModifierChordRecorder(action: action, store: store)
                    }
                }
                SettingsRow(
                    title: "Target outline",
                    subtitle: "The border drawn around the window a gesture is about to act on.",
                    controlWidth: Self.colorControlWidth
                ) {
                    ColorSettingControl(
                        color: $store.outlineColor, reset: SnapAppearance.defaultOutline)
                }
                SettingsRow(
                    title: "Landing block",
                    subtitle: "The block showing where the window will end up. Drawn as a solid "
                        + "border with the fill washed back, so one colour covers both.",
                    controlWidth: Self.colorControlWidth
                ) {
                    ColorSettingControl(
                        color: $store.landingColor, reset: SnapAppearance.defaultLanding)
                }
                SettingsRow(
                    title: "Anchor dot",
                    subtitle: "The mark the hold-and-point gesture measures its direction from.",
                    controlWidth: Self.colorControlWidth
                ) {
                    ColorSettingControl(color: $store.dotColor, reset: SnapAppearance.defaultDot)
                }
            }

            SettingsSection(
                title: "Focus follows the pointer", anchor: SettingsAnchor.focusFollows,
                footer: "macOS raises a window as part of focusing it, so the window you rest over "
                    + "comes to the front. Nothing happens while a mouse button or a modifier is "
                    + "held, or while the switcher is open — each of those is a gesture that "
                    + "belongs to the window it started in."
            ) {
                SettingsToggle(
                    title: "Focus the window under the pointer",
                    subtitle: "Rest the cursor over a window and the keyboard goes to it, with no "
                        + "click. Off by default: it changes where every keystroke on the machine "
                        + "lands, which is not a thing to switch on for someone.",
                    isOn: focusFollowsMouse)
                SettingsSlider(
                    title: "Rest for",
                    subtitle: "How long the pointer has to be still first. This is what separates "
                        + "stopping at a window from crossing it on the way somewhere else — "
                        + "shorter is more eager, and too short retargets your typing mid-sentence.",
                    value: focusFollowsMouseDelay,
                    range: Self.restRange,
                    step: 50,
                    format: { "\(Int($0)) ms" })
                    .disabled(!store.focusFollows.isEnabled)
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

            // The one card that does not answer to the switch above.
            SettingsSection(
                title: Self.moveGroup.0, anchor: anchor(for: Self.moveGroup.0),
                footer: "The two moves keep the window's size and its relative position on the new "
                    + "display, and are live whether or not tiling is on: a move changes no layout, "
                    + "so the switch above does not govern it, and a bound chord is claimed "
                    + "system-wide. The two switches below them are about what happens around a "
                    + "display change rather than about the chords."
            ) {
                ForEach(Self.moveGroup.1) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: subtitle(for: arrangement),
                        controlWidth: 168
                    ) {
                        TilingShortcutRecorder(arrangement: arrangement, store: store)
                    }
                }
                SettingsToggle(
                    title: "Take the pointer along",
                    subtitle: "Warp the cursor onto the window after it lands on the other "
                        + "display, so the next click and the next hover are where you are looking. "
                        + "Off leaves the pointer on the display you threw the window from.",
                    isOn: pointerFollowsDisplayMove)
                SettingsToggle(
                    title: "Restore the layout when displays change",
                    subtitle: "Remembers where every window sat under each set of monitors and "
                        + "puts them back when that set returns — the undo macOS has never had for "
                        + "undocking. It has to have seen a desk before it can restore it, so the "
                        + "first plug or unplug after switching this on only learns; the one after "
                        + "that restores. Kept in memory for the session, never written to disk.",
                    isOn: restoresLayoutOnDisplayChange)
            }

            // Unbound out of the box, and the footer says why rather than leaving someone to hunt
            // for a chord that was never claimed.
            SettingsSection(
                title: Self.focusGroup.0, anchor: anchor(for: Self.focusGroup.0),
                footer: "Moves the keyboard to the nearest window in that direction — the other "
                    + "half of tiling, which places windows but never let you walk between them. "
                    + "Live whether or not tiling is on, since focus resizes nothing. Unbound by "
                    + "default: every arrow combination on ⌃⌘ is already spoken for, and the only "
                    + "one left is ⌃⌥⇧⌘, which is not a chord to claim on your behalf."
            ) {
                ForEach(Self.focusGroup.1) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: subtitle(for: arrangement),
                        controlWidth: 168
                    ) {
                        TilingShortcutRecorder(arrangement: arrangement, store: store)
                    }
                }
            }

            // The only move behind a switch, and the footer says why rather than leaving someone to
            // discover the Mission Control flash by pressing the key.
            SettingsSection(
                title: Self.desktopGroup.0, anchor: anchor(for: Self.desktopGroup.0),
                footer: "macOS has no way to move another app's window between desktops, so this "
                    + "performs the gesture instead: it picks the window up, opens Mission Control "
                    + "for a moment and drops it on the next desktop along. That means it takes "
                    + "over the pointer for about half a second, which is why it is off by default. "
                    + "Stops at the first and last desktop rather than wrapping around."
            ) {
                SettingsToggle(
                    title: "Move windows between desktops",
                    subtitle: "Off by default — unlike the display moves, this one drives the "
                        + "mouse and flashes Mission Control, so it is not claimed until you ask.",
                    isOn: desktopMoves)
                SettingsToggle(
                    title: "Follow the window",
                    subtitle: "Switch to the desktop the window landed on, so you arrive with it "
                        + "instead of watching it go. Turn this off to throw a window somewhere and "
                        + "stay where you are.",
                    isOn: followsDesktopMove)
                ForEach(Self.desktopGroup.1) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: subtitle(for: arrangement),
                        controlWidth: 168
                    ) {
                        TilingShortcutRecorder(arrangement: arrangement, store: store)
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
        // Said on the row rather than only in the footer: a recorder showing a chord reads as bound,
        // and "bound but switched off" is exactly the state someone will press the key in.
        if arrangement.desktopStep != nil, !store.desktopMoves {
            return "Switched off above — this will not fire."
        }
        switch arrangement {
        case .center: return "Keeps the window's size and centres it."
        case .restore: return "Back to where the window was before you first tiled it."
        case .larger, .smaller:
            // Said on both rows rather than in the card footer, because the thing worth knowing is
            // the anchor, and someone reading only one of the two rows still needs it.
            return "A twentieth of the screen at a time, from the middle of the window outward, "
                + "stopping at the edges."
        case .leftTwoThirds, .rightTwoThirds, .topThird, .bottomThird:
            return "Also reachable by pressing the matching half twice or three times — this is the "
                + "same place in one press."
        default:
            if arrangement.nudgeStep != nil {
                return "Moves the window without resizing it, a twentieth of the screen a press. "
                    + "Stops at the screen edge rather than walking the window off it."
            }
            if arrangement.swapStep != nil {
                return "The two windows change places, each taking the other's exact frame."
            }
            // The display and focus moves say it once in their card footers instead, rather than
            // twice or four times over in rows that mean the same thing in different directions.
            return nil
        }
    }

    /// What each modifier row says under it — its job, or the reason it cannot do it.
    private func chordSubtitle(for action: MouseDragAction) -> String? {
        let chord = store.mouseChord(for: action)
        if !chord.isUsable {
            return "Needs ⌃, ⌥ or ⌘ — click and hold a combination."
        }
        // Both bound the same way is allowed rather than refused (swapping the two needs a
        // colliding step), but only one of them can ever fire, and the row says which.
        if action == .resize, store.mouseChord(for: .move) == chord {
            return "Same modifiers as Move — only Move will fire."
        }
        return action == .move
            ? "Drag anywhere in the window to move it."
            : "Drag to resize from the corner of the quarter you press in."
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
    var width: CGFloat = 128

    private var hotkey: Hotkey? { store.hotkey(for: arrangement) }
    private var isRecording: Bool { store.recordingArrangement == arrangement }

    var body: some View {
        HStack(spacing: 4) {
            Button(label) {
                isRecording ? store.stopRecording() : start()
            }
            .frame(width: width)
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

/// Records a modifier combination for one mouse gesture.
///
/// No key is involved, so this cannot reuse `HotkeyRecorder`: what is captured is the set of
/// modifiers *held*, and the natural end of that gesture is letting them go. It watches
/// `flagsChanged`, remembers the largest set seen while armed, and commits on release — so pressing
/// ⌃ then adding ⌥ records ⌃⌥ rather than the ⌃ it saw first.
struct ModifierChordRecorder: View {
    let action: MouseDragAction
    @ObservedObject var store: WindowTilingStore

    @State private var recording = false
    @State private var held: CGEventFlags = []
    @State private var monitor: Any?
    /// This recorder's claim on `KeyRecorder`, so `stop()` can only ever release its own.
    @State private var token: Int?

    private var chord: ModifierChord { store.mouseChord(for: action) }

    var body: some View {
        HStack(spacing: 4) {
            Button(label) { recording ? stop() : start() }
                .frame(width: 128)
                .foregroundStyle(chord.isUsable ? Color.primary : Color.orange)

            Button {
                store.setMouseChord(action.defaultChord, for: action)
            } label: {
                Image(systemName: "arrow.uturn.backward.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Back to \(action.defaultChord.displayString)")
            .opacity(chord == action.defaultChord ? 0 : 1)
            .disabled(chord == action.defaultChord)
        }
        .onDisappear(perform: stop)
    }

    private var label: String {
        if recording {
            // Live feedback while the keys are down: without it the button reads "Hold keys…"
            // through the whole gesture and there is no way to tell what has registered.
            return held.isEmpty ? "Hold modifiers…" : ModifierChord(held).displayString
        }
        return chord.displayString
    }

    private func start() {
        recording = true
        held = []
        // Disarms any other recorder first — see `KeyRecorder`.
        token = KeyRecorder.arm(stop)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged, .keyDown]) { event in
            if event.type == .keyDown {
                // ⎋ aborts. Any other key is swallowed rather than typed: this row takes modifiers,
                // and a stray letter should not land in whatever is behind the settings window.
                if event.keyCode == 53 { stop() }
                return nil
            }
            let flags = Hotkey.flags(from: event.modifierFlags)
            if flags.isEmpty {
                // Everything released — the end of the gesture. Commit what was held at its widest.
                let candidate = ModifierChord(held)
                stop()
                if candidate.isUsable {
                    DispatchQueue.main.async { store.setMouseChord(candidate, for: action) }
                }
                return nil
            }
            // Widest set wins, so releasing ⌘ a moment before ⌃ still records ⌃⌘.
            if flags.rawValue.nonzeroBitCount >= held.rawValue.nonzeroBitCount { held = flags }
            return nil
        }
    }

    private func stop() {
        recording = false
        held = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if let token { KeyRecorder.disarmed(token) }
        token = nil
    }

}
