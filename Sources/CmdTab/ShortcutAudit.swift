import AppKit
import CoreGraphics

// Every key binding the app owns, gathered into one list so collisions across *different* stores
// can be seen at all.
//
// Each pane warns about clashes within its own store — two tiling arrangements on one chord, two
// direct activations on one chord — but nothing could see across them, and the kinds of binding are
// spread over several stores. Binding ⌃⌘← to both a tiling arrangement and a direct activation
// produced no warning anywhere, because neither store knew the other existed.

/// One binding, flattened out of whichever store owns it.
struct ShortcutEntry: Identifiable {
    /// Which family a binding belongs to. The declaration order **is** the order
    /// `SwitcherController.handle` matches them in, which is what decides who wins a collision.
    enum Kind: Int, CaseIterable, Comparable {
        case switcherTrigger
        case appWindowCycle
        case scopedTrigger
        case directActivation
        case allWindows
        case tiling
        /// Matched in a separate namespace entirely — with the trigger held, against the *extra*
        /// modifiers — so these can never collide with anything above them, only with each other.
        case inSwitcherAction

        static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

        var title: String {
            switch self {
            case .switcherTrigger: return "Switcher"
            case .appWindowCycle: return "App-window cycle"
            case .scopedTrigger: return "Scoped shortcut"
            case .directActivation: return "Direct activation"
            case .allWindows: return "All windows"
            case .tiling: return "Window tiling"
            case .inSwitcherAction: return "Window action"
            }
        }

        /// Where in Settings this binding is edited.
        var location: String {
            switch self {
            case .switcherTrigger, .appWindowCycle, .scopedTrigger, .inSwitcherAction:
                return "Shortcuts"
            case .directActivation: return "Apps"
            case .allWindows, .tiling: return "Windows"
            }
        }

        /// Whether these are matched globally. In-switcher actions are not — they only exist while
        /// the panel is up.
        var isGlobal: Bool { self != .inSwitcherAction }
    }

    let id: String
    let kind: Kind
    /// What this binding does, in the words the settings pane uses.
    let label: String
    let display: String
    /// The chord, normalised for comparison. Nil for an unbound entry, which is listed but inert.
    let chord: Chord?
    /// False when the whole family is switched off — tiling with its master switch off, say. Listed,
    /// but it cannot collide with anything because it never fires.
    let isActive: Bool

    /// A comparable chord. Shift is dropped for global bindings, where it only ever means "go
    /// backwards", but kept for in-switcher actions, where ⌥Q and ⌥⇧Q are two different actions.
    struct Chord: Hashable {
        let keyCode: Int
        let modifiers: CGEventFlags

        init(keyCode: Int, modifiers: CGEventFlags, keepsShift: Bool = false) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection(
                keepsShift
                    ? [.maskCommand, .maskAlternate, .maskControl, .maskShift]
                    : [.maskCommand, .maskAlternate, .maskControl])
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(keyCode)
            hasher.combine(modifiers.rawValue)
        }

        static func == (lhs: Self, rhs: Self) -> Bool {
            lhs.keyCode == rhs.keyCode && lhs.modifiers == rhs.modifiers
        }
    }
}

/// A collision between two or more bindings, and which of them actually fires.
struct ShortcutCollision: Identifiable {
    let chord: ShortcutEntry.Chord
    let display: String
    /// In match order, so the first is the one that wins.
    let entries: [ShortcutEntry]

    var id: String { "\(chord.keyCode):\(chord.modifiers.rawValue)" }
    var winner: ShortcutEntry? { entries.first }
    var losers: [ShortcutEntry] { Array(entries.dropFirst()) }
}

@MainActor
enum ShortcutAudit {
    /// Every binding in the app, in match order.
    static func entries() -> [ShortcutEntry] {
        let behavior = BehaviorStore.shared
        var out: [ShortcutEntry] = []

        out.append(
            entry(.switcherTrigger, "trigger", "Open the switcher", behavior.hotkey, active: true))
        out.append(
            entry(
                .appWindowCycle, "sameApp", "Cycle the front app's windows", behavior.sameAppHotkey,
                active: behavior.sameAppCycle))

        for trigger in ScopedTriggersStore.shared.scoped.triggers {
            out.append(
                entry(
                    .scopedTrigger, "scoped.\(trigger.id)", trigger.scope.title,
                    trigger.hotkey, active: true))
        }

        let globals = GlobalActionsStore.shared
        for activation in globals.activations.entries {
            out.append(
                entry(
                    .directActivation, "activate.\(activation.bundleID)",
                    displayName(for: activation.bundleID), activation.hotkey, active: true))
        }
        out.append(
            entry(.allWindows, "hideAll", "Hide all windows", globals.allWindows.hideAll, active: true))
        out.append(
            entry(.allWindows, "showAll", "Show all windows", globals.allWindows.showAll, active: true))

        let tiling = WindowTilingStore.shared
        for arrangement in WindowArrangement.allCases {
            out.append(
                entry(
                    .tiling, "tiling.\(arrangement.rawValue)", arrangement.title,
                    tiling.hotkey(for: arrangement),
                    // The display and Desktop moves do not answer to the tiling switch, so a bound
                    // one can collide with something while the rest of the family is inert.
                    active: tiling.isEnabled || arrangement.isMove))
        }

        let actions = SwitcherShortcutsStore.shared
        for action in SwitcherAction.allCases {
            guard let binding = actions.shortcuts.bindings[action] else { continue }
            out.append(
                ShortcutEntry(
                    id: "action.\(action.rawValue)", kind: .inSwitcherAction, label: action.title,
                    display: binding.displayString,
                    chord: ShortcutEntry.Chord(
                        keyCode: binding.keyCode, modifiers: binding.extras, keepsShift: true),
                    isActive: actions.isEnabled))
        }
        return out
    }

    /// Chords claimed by more than one *active, bound* entry.
    ///
    /// In-switcher actions are pooled separately: they are matched against the extra modifiers held
    /// on top of the trigger, in a state where nothing else is matched at all, so ⌥Q as an action
    /// and ⌥Q as a tiling chord are not in competition.
    static func collisions(in entries: [ShortcutEntry]) -> [ShortcutCollision] {
        var byChord: [ShortcutEntry.Chord: [ShortcutEntry]] = [:]
        for entry in entries where entry.isActive {
            guard let chord = entry.chord else { continue }
            byChord[chord, default: []].append(entry)
        }
        return byChord.compactMap { chord, group -> ShortcutCollision? in
            // Split the two namespaces before deciding anything is a collision.
            let global = group.filter { $0.kind.isGlobal }
            let inPanel = group.filter { !$0.kind.isGlobal }
            let clashing = global.count > 1 ? global : (inPanel.count > 1 ? inPanel : [])
            guard clashing.count > 1 else { return nil }
            return ShortcutCollision(
                chord: chord, display: clashing[0].display,
                entries: clashing.sorted { $0.kind < $1.kind })
        }
        .sorted { $0.display < $1.display }
    }

    private static func entry(
        _ kind: ShortcutEntry.Kind, _ id: String, _ label: String, _ hotkey: Hotkey?, active: Bool
    ) -> ShortcutEntry {
        guard let hotkey, hotkey.isUsableGlobally else {
            return ShortcutEntry(
                id: id, kind: kind, label: label, display: "Not set", chord: nil, isActive: active)
        }
        return ShortcutEntry(
            id: id, kind: kind, label: label, display: hotkey.displayString,
            chord: ShortcutEntry.Chord(keyCode: hotkey.keyCode, modifiers: hotkey.modifiers),
            isActive: active)
    }

    /// Resolved once per call rather than per row — this walks the running apps and can reach
    /// LaunchServices, and the audit view rebuilds on every settings change.
    private static func displayName(for bundleID: String) -> String {
        if let running = NSWorkspace.shared.runningApplications.first(where: {
            $0.bundleIdentifier == bundleID
        }), let name = running.localizedName {
            return name
        }
        return FavoritesStore.appInfo(for: bundleID)?.name ?? bundleID
    }
}
