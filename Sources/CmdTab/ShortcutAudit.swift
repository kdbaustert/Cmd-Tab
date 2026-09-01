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
        /// The two modifier chords the mouse gestures answer to.
        ///
        /// Outside the keyboard match order entirely, which is why it is declared past the end of
        /// it rather than somewhere in the middle: no keystroke reaches these and no chord here
        /// takes a keystroke from anything above. They are listed because the Overview's claim is
        /// *everything this app claims*, and a chord that makes an outline appear over whatever the
        /// cursor is on is claimed as surely as a keypress is — someone hunting for why holding ⌃⌘
        /// draws a box had nothing in this list to find.
        ///
        /// They still collide with **each other**: `MouseDragSettings.action(for:)` tests move
        /// first, so pointing both at one combination leaves resize permanently dead. The Windows
        /// tab says so on the row; this is the same fact in the one place that is supposed to hold
        /// all of them.
        case mouseGesture

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
            case .mouseGesture: return "Mouse gesture"
            }
        }

        /// Where in Settings this binding is edited.
        var location: String {
            switch self {
            case .switcherTrigger, .appWindowCycle, .scopedTrigger, .inSwitcherAction:
                return "Shortcuts"
            case .directActivation: return "Apps"
            case .allWindows, .tiling, .mouseGesture: return "Windows"
            }
        }

        /// Whether these are matched globally. In-switcher actions are not — they only exist while
        /// the panel is up.
        ///
        /// A mouse gesture is global: the chord is watched machine-wide for as long as the feature
        /// is on. Sharing the global namespace costs nothing, because a mouse entry's chord carries
        /// `Chord.noKey` and the pools are keyed on the key code — so it can only ever meet another
        /// mouse entry there. See `Chord.noKey`.
        var isGlobal: Bool { self != .inSwitcherAction }

        /// Whether this family fires on a chord whatever Shift is doing.
        ///
        /// The three openers do: they are matched with `TriggerModifiers.opens`, which compares only
        /// ⌘/⌥/⌃ because Shift on a trigger means "go backwards round the list" rather than a
        /// different binding. Everything else compares all four modifiers exactly — the tiling
        /// matcher, the direct activations and the all-windows pair all test
        /// `want == held` over ⌘/⌥/⌃/⇧, and an in-switcher action's whole point is that ⌥Q and ⌥⇧Q
        /// are two different actions.
        ///
        /// This is the asymmetry `collisions` turns on, and getting it wrong is not academic: read
        /// as "Shift never matters", the *default* tiling bindings collide with themselves, because
        /// ⌃⌘← is Left half and ⌃⌘⇧← is Move to previous display. The Overview then warned that one
        /// of them could never fire, about two bindings that both work.
        ///
        /// Exhaustive rather than `self != …`, so a new kind has to state which rule it follows.
        var ignoresShift: Bool {
            switch self {
            case .switcherTrigger, .appWindowCycle, .scopedTrigger: return true
            case .directActivation, .allWindows, .tiling, .inSwitcherAction, .mouseGesture:
                return false
            }
        }
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

    /// A comparable chord: the combination as it was recorded, narrowed to the four modifiers a
    /// binding can be built from.
    ///
    /// Shift is **kept**. It used to be dropped here for every global binding, on the reasoning that
    /// it only ever means "go backwards" — true of the three openers and of nothing else, and the
    /// families it is not true of are the ones that bind Shift on purpose. See `Kind.ignoresShift`;
    /// the difference between the two rules is expressed at comparison time in `collisions`, because
    /// one normalised key cannot hold both.
    struct Chord: Hashable {
        /// The key code of a binding that has no key: the mouse gestures, which are modifiers and a
        /// mouse button.
        ///
        /// Negative, so it can never be a real key code — those are the window server's, and start
        /// at 0 (which is `A`). That is the whole mechanism keeping a mouse chord out of the
        /// keyboard's collision pools: `clashes(among:)` pools on the *whole* chord, key code
        /// included, so ⌃⌘ on the mouse and ⌃⌘← on the keyboard land in different pools without
        /// `clashes` needing to know either family exists. Two mouse chords on one combination
        /// still meet, which is exactly the collision worth reporting.
        static let noKey = -1

        let keyCode: Int
        let modifiers: CGEventFlags

        init(keyCode: Int, modifiers: CGEventFlags) {
            self.keyCode = keyCode
            self.modifiers = modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift])
        }

        /// The same chord as an opener sees it. Two bindings can only ever compete if these agree,
        /// which is what makes it the pooling key in `collisions`.
        var ignoringShift: Chord {
            Chord(keyCode: keyCode, modifiers: modifiers.subtracting(.maskShift))
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
                    // Asked of the matcher's own rule rather than restated here. The moves and the
                    // focus chords do not answer to the tiling switch, so a bound one can collide
                    // with something while the rest of the family is inert; the Desktop moves have a
                    // second switch on top, and a chord that switch is holding shut is not claimed
                    // from anyone, so reporting it active would invent a collision. This was written
                    // out a second time here once, and it fell behind the matcher — see
                    // `WindowTilingBindings.fires`.
                    active: tiling.tiling.fires(arrangement)))
        }

        let actions = SwitcherShortcutsStore.shared
        for action in SwitcherAction.allCases {
            guard let binding = actions.shortcuts.bindings[action] else { continue }
            out.append(
                ShortcutEntry(
                    id: "action.\(action.rawValue)", kind: .inSwitcherAction, label: action.title,
                    display: binding.displayString,
                    chord: ShortcutEntry.Chord(
                        keyCode: binding.keyCode, modifiers: binding.extras),
                    isActive: actions.isEnabled))
        }

        // Emitted in `MouseDragAction`'s own case order, which is the order
        // `MouseDragSettings.action(for:)` tests them in — so if both are pointed at one
        // combination, the collision names move as the winner because move is the one that fires.
        for action in MouseDragAction.allCases {
            let chord = tiling.mouseChord(for: action)
            out.append(
                ShortcutEntry(
                    id: "mouse.\(action.rawValue)", kind: .mouseGesture,
                    label: "\(action.title) window with the mouse",
                    display: chord.displayString,
                    // An unusable chord — ⇧ alone, or nothing — is listed and inert, exactly as an
                    // unbound keyboard row is. `displayString` already reads "Not set" for one.
                    chord: chord.isUsable
                        ? ShortcutEntry.Chord(
                            keyCode: ShortcutEntry.Chord.noKey, modifiers: chord.flags)
                        : nil,
                    isActive: tiling.mouseDrag.isEnabled))
        }
        return out
    }

    /// Chords claimed by more than one *active, bound* entry.
    ///
    /// Two entries collide when some single keypress would be claimed by both, and that is not the
    /// same as their chords being equal, because the families do not all match the same way — see
    /// `Kind.ignoresShift`. Three cases, and the middle one is the reason this cannot be a dictionary
    /// keyed on one normalised chord:
    ///
    /// * two openers collide when their ⌘/⌥/⌃ agree, Shift or no Shift;
    /// * an opener collides with *every* Shift variant of an exact binding on the same key, since
    ///   the opener claims the press before the exact binding is ever consulted;
    /// * two exact bindings collide only on the identical combination, Shift included.
    ///
    /// So entries are pooled by their Shift-blind chord — the widest thing that could possibly
    /// compete — and each pool is then resolved by whether an opener is in it.
    ///
    /// In-switcher actions are pooled separately: they are matched against the extra modifiers held
    /// on top of the trigger, in a state where nothing else is matched at all, so ⌥Q as an action
    /// and ⌥Q as a tiling chord are not in competition.
    nonisolated static func collisions(in entries: [ShortcutEntry]) -> [ShortcutCollision] {
        // Position in the list *is* match order — `entries()` emits each family in `Kind`'s
        // declaration order and, within a family, in the order its own matcher iterates. Carrying it
        // is what lets a collision name the right winner when two entries share a kind, where
        // sorting on the kind alone leaves the answer to an unstable sort.
        let rank = Dictionary(
            entries.enumerated().map { ($1.id, $0) }, uniquingKeysWith: min)
        let active = entries.filter(\.isActive)
        return (clashes(among: active.filter { $0.kind.isGlobal }, rank: rank)
            + clashes(among: active.filter { !$0.kind.isGlobal }, rank: rank))
            .sorted { $0.display < $1.display }
    }

    /// Collisions within one matching namespace — the global bindings, or the in-switcher actions.
    private nonisolated static func clashes(
        among entries: [ShortcutEntry], rank: [String: Int]
    ) -> [ShortcutCollision] {
        var pools: [ShortcutEntry.Chord: [ShortcutEntry]] = [:]
        for entry in entries {
            guard let chord = entry.chord else { continue }
            pools[chord.ignoringShift, default: []].append(entry)
        }
        return pools.flatMap { key, pool in clashes(in: pool, key: key, rank: rank) }
    }

    /// One pool of entries whose chords agree on everything but Shift.
    private nonisolated static func clashes(
        in pool: [ShortcutEntry], key: ShortcutEntry.Chord, rank: [String: Int]
    ) -> [ShortcutCollision] {
        guard pool.count > 1 else { return [] }
        // An opener ignores Shift, so it claims every variant in the pool and none of the others can
        // fire — one collision covering the lot, named by the Shift-blind chord they share.
        if pool.contains(where: { $0.kind.ignoresShift }) {
            return [collision(pool, chord: key, rank: rank)]
        }
        // Otherwise Shift separates them, so only entries on the identical combination compete — and
        // a pool can hold more than one such group (⌃⌘← twice *and* ⌃⌘⇧← twice).
        return Dictionary(grouping: pool, by: \.chord)
            .compactMap { chord, group in
                guard let chord, group.count > 1 else { return nil }
                return collision(group, chord: chord, rank: rank)
            }
    }

    /// Orders a set of clashing entries so the first is the one that actually fires.
    private nonisolated static func collision(
        _ clashing: [ShortcutEntry], chord: ShortcutEntry.Chord, rank: [String: Int]
    ) -> ShortcutCollision {
        let ordered = clashing.sorted { (rank[$0.id] ?? .max) < (rank[$1.id] ?? .max) }
        // The winner's own spelling, which for an opener pool is not every member's: the losers may
        // carry a Shift the winner does not, and naming the row after one of those would point the
        // user at a combination that works.
        return ShortcutCollision(
            chord: chord, display: ordered[0].display, entries: ordered)
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
