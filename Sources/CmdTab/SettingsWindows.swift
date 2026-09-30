import AppKit
import SwiftUI

// The window-management tabs: Tiling, Displays & Desktops, and Mouse & Focus. One tab of sixteen
// cards outgrew itself the same way the old toolbar window did — the page's subtitle only ever
// described tiling, and the desktop moves, the mouse gestures and focus-follows-mouse all lived
// under a heading that promised none of them. The three panes share one store and one row
// vocabulary, which is why they share this file: every shortcut row is a `TilingShortcutRecorder`,
// and the subtitle logic they all use sits in the `WindowTilingStore` extension at the bottom.
//
// Separate from the Shortcuts tab, which is about the switcher — these fire with nothing open and
// act on whatever window you are looking at, so grouping them with the in-switcher action keys
// would put two quite different kinds of binding under one heading.

/// Groups share the tiling anchor's prefix, so a search hit on "tile left" lands with the right
/// card scrolled into view whichever of the three tabs it lives on.
private func tilingAnchor(for title: String) -> String {
    "\(SettingsAnchor.tiling).\(title.lowercased())"
}

// MARK: - Tiling

/// The Tiling tab: global hotkeys that snap the focused window to a half, a corner, the whole
/// screen or the centre.
struct TilingSettings: View {
    @ObservedObject var store: WindowTilingStore

    /// The order the rows read in: the four halves, then the thirds, the four corners, and the finer
    /// grids — fourths, sixths, ninths — then the three that are not a fraction of the screen at
    /// all, the two families that are relative to wherever the window already is, and last the two
    /// that arrange every window on the display instead of the focused one.
    ///
    /// Every group here is governed by the tiling switch. The families that are not — the display
    /// and Desktop moves, and the focus chords — have tabs of their own.
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
        (
            "Fourths",
            [
                .firstFourth, .secondFourth, .thirdFourth, .lastFourth, .leftThreeFourths,
                .rightThreeFourths,
            ]
        ),
        (
            "Sixths",
            [
                .topLeftSixth, .topCenterSixth, .topRightSixth,
                .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
            ]
        ),
        (
            "Ninths",
            [
                .topLeftNinth, .topCenterNinth, .topRightNinth,
                .middleLeftNinth, .middleCenterNinth, .middleRightNinth,
                .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth,
            ]
        ),
        (
            "Whole window",
            [.maximize, .maximizeHeight, .maximizeWidth, .almostMaximize, .center, .restore]
        ),
        ("Size", [.larger, .smaller]),
        ("Resize an edge", WindowArrangement.edgeResizes),
        ("Nudge", WindowArrangement.nudges),
        ("Swap", WindowArrangement.swaps),
        ("All windows", [.tileAll, .cascadeAll]),
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

    private var dragSnapTopHalf: Binding<Bool> {
        Binding(get: { store.dragSnapTopHalf }, set: { store.dragSnapTopHalf = $0 })
    }

    private var dragSnapBottomThirds: Binding<Bool> {
        Binding(get: { store.dragSnapBottomThirds }, set: { store.dragSnapBottomThirds = $0 })
    }

    private var gap: Binding<Double> {
        Binding(get: { Double(store.gap) }, set: { store.gap = CGFloat($0) })
    }

    var body: some View {
        SettingsPage(
            title: "Tiling",
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
                SettingsToggle(
                    title: "Top edge snaps to the top half",
                    subtitle: "Dragging to the top edge tiles the top half instead of maximizing. "
                        + "The middle of the screen still maximizes, and the top corners still "
                        + "take the top quarters.",
                    isOn: dragSnapTopHalf)
                SettingsToggle(
                    title: "Split the bottom edge into thirds",
                    subtitle: "Dragging to the bottom edge tiles the left, middle or right third, "
                        + "by where along it you let go, instead of the bottom half. The bottom "
                        + "corners still take the bottom quarters.",
                    isOn: dragSnapBottomThirds)
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

            // Deliberately *not* disabled while tiling is off. Setting the keys up before switching
            // the feature on is the natural order to do this in, and a pane of dead recorders is
            // exactly the shape of "you cannot define these".
            ForEach(Self.groups, id: \.title) { group in
                SettingsSection(title: group.title, anchor: tilingAnchor(for: group.title)) {
                    ForEach(group.arrangements) { arrangement in
                        SettingsRow(
                            title: arrangement.title,
                            subtitle: store.arrangementSubtitle(for: arrangement),
                            controlWidth: 168
                        ) {
                            TilingShortcutRecorder(arrangement: arrangement, store: store)
                        }
                    }
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
}

// MARK: - Displays & Desktops

/// The Displays & Desktops tab: sending a window somewhere else — another display or another
/// Desktop — and what happens around a display change.
struct DisplaysDesktopsSettings: View {
    @ObservedObject var store: WindowTilingStore
    @ObservedObject private var globals = GlobalActionsStore.shared

    /// How many displays are plugged in, which decides how many of the absolute display targets
    /// are worth showing.
    ///
    /// Held in state and refreshed from the screen-parameters notification rather than read inline:
    /// SwiftUI has no reason to re-render this view when a monitor is plugged in, so a bare
    /// `NSScreen.screens.count` in the body would leave the rows describing the desk as it was when
    /// Settings opened — and this is the one tab someone opens *because* they have just plugged
    /// something in.
    @State private var displayCount = NSScreen.screens.count
    /// How many Desktops the desk has (the most on any one display), for the numbered rows below.
    /// One window-server round trip, paid when the pane is built and on the notifications that can
    /// change the answer — never on the key path.
    @State private var desktopCount = SpaceMover.maxUserSpaceCount()

    /// The absolute display targets, one row per display that is actually plugged in.
    ///
    /// Filtered rather than listed in full, because a row captioned "Move to display 3" on a laptop
    /// with no external monitor is a control that cannot do anything — and the enum has to carry a
    /// fixed four of them for the raw values to be a stable URL grammar. On a single display the
    /// whole card is dropped: "move it to the display it is already on" is the one arrangement here
    /// with nothing to offer at all.
    private static func displayTargets(count: Int) -> [WindowArrangement] {
        guard count > 1 else { return [] }
        return WindowArrangement.displayTargets.filter { ($0.displayIndex ?? 0) < count }
    }

    /// The absolute Desktop targets, one row per Desktop that actually exists — the same filter as
    /// the display rows, for the same reason: a row captioned "Move to desktop 7" on a machine with
    /// three Desktops is a control that cannot do anything. With one Desktop there is nowhere else
    /// to send a window, so no rows at all.
    private static func desktopTargets(count: Int) -> [WindowArrangement] {
        guard count > 1 else { return [] }
        return WindowArrangement.desktopTargets.filter { ($0.desktopIndex ?? 0) < count }
    }

    /// The send-it-elsewhere group. Ungoverned by the tiling switch, and the footer has to say so.
    private static let moveGroup = ("Displays", [WindowArrangement.previousDisplay, .nextDisplay])

    /// The Desktop moves: the one family with a switch of its own, and the footer has to explain
    /// what that switch is protecting the user from.
    private static let desktopGroup = (
        "Desktops", [WindowArrangement.previousDesktop, .nextDesktop]
    )

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

    private var restoresDesktopAssignments: Binding<Bool> {
        Binding(
            get: { store.restoresDesktopAssignments },
            set: { store.restoresDesktopAssignments = $0 })
    }

    private var restoresLayoutOnDisplayChange: Binding<Bool> {
        Binding(
            get: { store.restoresLayoutOnDisplayChange },
            set: { store.restoresLayoutOnDisplayChange = $0 })
    }

    var body: some View {
        SettingsPage(
            title: "Displays & Desktops",
            subtitle: "Send a window to another display or Desktop, and put things back when "
                + "displays come and go."
        ) {
            SettingsSection(
                title: Self.moveGroup.0, anchor: tilingAnchor(for: Self.moveGroup.0),
                footer: "The two moves keep the window's size and its relative position on the new "
                    + "display, and are live whether or not tiling is on: a move changes no layout, "
                    + "so the tiling switch does not govern it, and a bound chord is claimed "
                    + "system-wide. The two switches below them are about what happens around a "
                    + "display change rather than about the chords."
            ) {
                ForEach(Self.moveGroup.1) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: store.arrangementSubtitle(for: arrangement),
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
                SettingsToggle(
                    title: "Put assigned apps back on their desktop",
                    subtitle: "Unplugging a display moves its windows onto whichever desktop is in "
                        + "front, ignoring any app you have assigned to a desktop in the Dock "
                        + "(right-click the icon, Options, Assign To). This puts those apps back "
                        + "where you assigned them once the displays settle. Only apps carrying an "
                        + "assignment are touched, and only the front window of each. For each "
                        + "one it switches to the desktop the window landed on, opens Mission "
                        + "Control and moves the pointer for a moment, then switches back, because "
                        + "macOS allows no quieter way to move another app's window between "
                        + "desktops.",
                    isOn: restoresDesktopAssignments)
            }

            // Only when there is more than one display — see `displayTargets(count:)`.
            if !Self.displayTargets(count: displayCount).isEmpty {
                SettingsSection(
                    title: "Send to a display", anchor: tilingAnchor(for: "Send to a display"),
                    footer: "Names the destination instead of counting to it: on three displays "
                        + "\"next display\" is two presses and a guess about which way round they "
                        + "are, where these land on the same screen every time. The numbers are the "
                        + "ones on the window tiles' own display badges. Unbound, and ungoverned by "
                        + "the tiling switch for the same reason the two moves above are. Rows "
                        + "appear for the displays you actually have."
                ) {
                    ForEach(Self.displayTargets(count: displayCount)) { arrangement in
                        SettingsRow(
                            title: arrangement.title,
                            subtitle: store.arrangementSubtitle(for: arrangement),
                            controlWidth: 168
                        ) {
                            TilingShortcutRecorder(arrangement: arrangement, store: store)
                        }
                    }
                }
            }

            // The only move behind a switch, and the footer says why rather than leaving someone to
            // discover the Mission Control flash by pressing the key.
            SettingsSection(
                title: Self.desktopGroup.0, anchor: tilingAnchor(for: Self.desktopGroup.0),
                footer: "macOS has no way to move another app's window between desktops, so this "
                    + "performs the gesture instead: it picks the window up, opens Mission Control "
                    + "for a moment and drops it on the destination's thumbnail. That means it "
                    + "takes over the pointer for about half a second, which is why it is off by "
                    + "default. The relative pair stops at the first and last desktop rather than "
                    + "wrapping around; the numbered rows name the destination outright, count the "
                    + "way Mission Control's own bar reads, and appear for as many desktops as you "
                    + "actually have."
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
                        subtitle: store.arrangementSubtitle(for: arrangement),
                        controlWidth: 168
                    ) {
                        TilingShortcutRecorder(arrangement: arrangement, store: store)
                    }
                }
                // The named destinations, under the same switch as the relative pair — one
                // gesture, however the Desktop is spelled. Rows appear for the Desktops you
                // actually have, like the display rows above.
                ForEach(Self.desktopTargets(count: desktopCount)) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: store.arrangementSubtitle(for: arrangement),
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

            Text("Click a shortcut and press a new combination. ⌫ clears it, ⎋ cancels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        // The desk changing under an open Settings window is the case the display rows exist for.
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didChangeScreenParametersNotification)
        ) { _ in
            displayCount = NSScreen.screens.count
            desktopCount = SpaceMover.maxUserSpaceCount()
        }
        // Adding or removing a Desktop posts no notification of its own, but doing either takes a
        // trip through Mission Control that all but always ends in a Space switch — so this is the
        // moment the numbered rows are most likely to be stale, and the read is one round trip.
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.activeSpaceDidChangeNotification)
        ) { _ in
            desktopCount = SpaceMover.maxUserSpaceCount()
        }
    }
}

// MARK: - Mouse & Focus

/// The Mouse & Focus tab: the pointer-driven gestures — drag to move, resize or snap — and the two
/// ways of moving focus without clicking, by resting the pointer or by a directional chord.
struct MouseFocusSettings: View {
    @ObservedObject var store: WindowTilingStore

    /// Wider than the 168 the recorders use: a `ColorSettingControl` is three controls in a row, not
    /// one, and the hex field is unusable squeezed into a recorder's width.
    private static let colorControlWidth: CGFloat = 250

    /// The rest-delay slider's range, named because the two ends of it do not fit on one line at
    /// the call site and a `...` split across two does not parse.
    private static let restRange =
        FocusFollowsMouseSettings.minimumDelay...FocusFollowsMouseSettings.maximumDelay

    /// The focus chords: not governed by the tiling switch, and a card whose rows quietly answered
    /// to a checkbox captioned about resizing would be the confusion that split exists to prevent.
    private static let focusGroup = ("Focus", WindowArrangement.focusMoves)

    private var mouseDragEnabled: Binding<Bool> {
        Binding(get: { store.mouseDrag.isEnabled }, set: { store.mouseDragEnabled = $0 })
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
            title: "Mouse & Focus",
            subtitle: "Move, resize and focus windows with the pointer — or move focus by "
                + "keyboard."
        ) {
            SettingsSection(
                title: "Mouse", anchor: SettingsAnchor.mouseDrag,
                footer: "While the modifier is held, the drag is Cmd-Tab's and the app underneath "
                    + "never sees it — so a move across a document does not select text on the way. "
                    + "Independent of the tiling switch, and of Snap by dragging."
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
                    subtitle: "The border showing where the window will end up. Drawn as an "
                        + "outline only, so what is underneath stays visible.",
                    controlWidth: Self.colorControlWidth
                ) {
                    ColorSettingControl(
                        color: $store.landingColor, reset: SnapAppearance.defaultLanding)
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

            // Unbound out of the box, and the footer says why rather than leaving someone to hunt
            // for a chord that was never claimed.
            SettingsSection(
                title: Self.focusGroup.0, anchor: tilingAnchor(for: Self.focusGroup.0),
                footer: "Moves the keyboard to the nearest window in that direction — the other "
                    + "half of tiling, which places windows but never let you walk between them. "
                    + "Live whether or not tiling is on, since focus resizes nothing. Unbound by "
                    + "default: every arrow combination on ⌃⌘ is already spoken for, and the only "
                    + "one left is ⌃⌥⇧⌘, which is not a chord to claim on your behalf."
            ) {
                ForEach(Self.focusGroup.1) { arrangement in
                    SettingsRow(
                        title: arrangement.title,
                        subtitle: store.arrangementSubtitle(for: arrangement),
                        controlWidth: 168
                    ) {
                        TilingShortcutRecorder(arrangement: arrangement, store: store)
                    }
                }
            }

            Text("Click a shortcut and press a new combination. ⌫ clears it, ⎋ cancels.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
}

// MARK: - Shared row subtitles

extension WindowTilingStore {
    /// The row's explanation, or a warning when the binding cannot do what it looks like it does.
    ///
    /// On the store rather than any one pane because all three window-management tabs draw
    /// arrangement rows. A trigger collision is checked on every render, not only at record time:
    /// changing the switcher shortcut later can strand a tiling chord that was perfectly good when
    /// it was set.
    fileprivate func arrangementSubtitle(for arrangement: WindowArrangement) -> String? {
        if let hotkey = hotkey(for: arrangement),
            let claimer = WindowTilingBindings.triggerClaiming(hotkey, in: .shared) {
            return "\(hotkey.displayString) opens \(claimer) — this will never fire."
        }
        let clashes = tiling.conflicts(with: arrangement)
        if !clashes.isEmpty {
            let names = clashes.map(\.title).joined(separator: ", ")
            // Which one actually wins is `WindowArrangement.allCases` order, and saying so is more
            // use than a bare "conflict".
            let winner = WindowArrangement.allCases.first { $0 == arrangement || clashes.contains($0) }
            return "Same shortcut as \(names) — only \(winner?.title ?? arrangement.title) will fire."
        }
        // Said on the row rather than only in the footer: a recorder showing a chord reads as bound,
        // and "bound but switched off" is exactly the state someone will press the key in.
        if arrangement.isDesktopMove, !desktopMoves {
            return "Switched off above — this will not fire."
        }
        switch arrangement {
        case .center: return "Keeps the window's size and centres it."
        case .restore:
            return "Back to where the window was before you first tiled it. Press it again to go "
                + "back to the tile you just undid."
        case .larger, .smaller:
            // Said on both rows rather than in the card footer, because the thing worth knowing is
            // the anchor, and someone reading only one of the two rows still needs it.
            return "A twentieth of the screen at a time, from the middle of the window outward, "
                + "stopping at the edges."
        case .leftTwoThirds, .rightTwoThirds, .topThird, .bottomThird:
            return "Also reachable by pressing the matching half twice or three times — this is the "
                + "same place in one press."
        case .tileAll:
            return "Every window on this display, front to back, in a grid starting top-left. "
                + "Windows of apps set to never tile stay where they are."
        case .cascadeAll:
            return "Every window on this display, stacked a title bar apart with the front one "
                + "on top. Each keeps its size unless the stack would not fit."
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
