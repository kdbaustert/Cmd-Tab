import AppKit
import ApplicationServices
import CoreGraphics

// Window tiling: global hotkeys that snap the focused window to a half, a corner, the whole screen
// or the centre, whether or not the switcher is open.
//
// Deliberately separate from `SwitcherAction`, which acts on the *selected tile* while the panel is
// up and is matched against the modifiers held on top of the trigger. These are ordinary global
// chords matched when nothing is open, and they act on whatever window the user is looking at.

/// One arrangement the focused window can be snapped to.
enum WindowArrangement: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, center, restore
    case previousDisplay, nextDisplay

    var id: String { rawValue }

    var title: String {
        switch self {
        case .leftHalf: return "Left half"
        case .rightHalf: return "Right half"
        case .topHalf: return "Top half"
        case .bottomHalf: return "Bottom half"
        case .topLeft: return "Top-left corner"
        case .topRight: return "Top-right corner"
        case .bottomLeft: return "Bottom-left corner"
        case .bottomRight: return "Bottom-right corner"
        case .leftThird: return "Left third"
        case .centerThird: return "Middle third"
        case .rightThird: return "Right third"
        case .maximize: return "Maximize"
        case .center: return "Center"
        case .restore: return "Restore previous size"
        case .previousDisplay: return "Move to previous display"
        case .nextDisplay: return "Move to next display"
        }
    }

    /// Defaults sit on ⌃⌘, which macOS itself leaves almost entirely free. Pre-filled but inert —
    /// nothing is claimed until tiling is switched on, so an install that never wants this never
    /// has a global chord taken from it.
    var defaultHotkey: Hotkey {
        let mods = CGEventFlags.maskControl.union(.maskCommand).rawValue
        switch self {
        case .leftHalf: return Hotkey(keyCode: 123, modifierRaw: mods)  // ←
        case .rightHalf: return Hotkey(keyCode: 124, modifierRaw: mods)  // →
        case .topHalf: return Hotkey(keyCode: 126, modifierRaw: mods)  // ↑
        case .bottomHalf: return Hotkey(keyCode: 125, modifierRaw: mods)  // ↓
        case .topLeft: return Hotkey(keyCode: 32, modifierRaw: mods)  // U
        case .topRight: return Hotkey(keyCode: 34, modifierRaw: mods)  // I
        case .bottomLeft: return Hotkey(keyCode: 38, modifierRaw: mods)  // J
        case .bottomRight: return Hotkey(keyCode: 40, modifierRaw: mods)  // K
        // The thirds sit on the number row under the halves' arrows, which is where every window
        // manager that has them puts them.
        case .leftThird: return Hotkey(keyCode: 18, modifierRaw: mods)  // 1
        case .centerThird: return Hotkey(keyCode: 19, modifierRaw: mods)  // 2
        case .rightThird: return Hotkey(keyCode: 20, modifierRaw: mods)  // 3
        case .maximize: return Hotkey(keyCode: 36, modifierRaw: mods)  // ↩
        case .center: return Hotkey(keyCode: 8, modifierRaw: mods)  // C
        case .restore: return Hotkey(keyCode: 6, modifierRaw: mods)  // Z
        // ⇧ on top of the halves' arrows: same key, "throw it further".
        case .previousDisplay:
            return Hotkey(
                keyCode: 123, modifierRaw: CGEventFlags(rawValue: mods).union(.maskShift).rawValue)
        case .nextDisplay:
            return Hotkey(
                keyCode: 124, modifierRaw: CGEventFlags(rawValue: mods).union(.maskShift).rawValue)
        }
    }

    /// How far this moves a window between displays, or nil if it does not.
    var displayStep: Int? {
        switch self {
        case .previousDisplay: return -1
        case .nextDisplay: return 1
        default: return nil
        }
    }

    /// Whether repeated presses step the window through ½ → ⅔ → ⅓ of the screen. Only the four
    /// half-screen arrangements cycle: a corner is already a quarter, a third is already a third,
    /// and there is no second size for "maximize" to mean.
    var cycles: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf: return true
        default: return false
        }
    }

    /// The fractions a cycling arrangement steps through, in order.
    static let cycleFractions: [CGFloat] = [1.0 / 2, 2.0 / 3, 1.0 / 3]

    /// Where this arrangement puts a window of `current` size inside `area`.
    ///
    /// `area` is a visible frame in Accessibility coordinates — top-left origin, menu bar and Dock
    /// already excluded. `fraction` is how much of the screen a half takes on this press; it is
    /// ignored by everything that does not cycle.
    ///
    /// Returns nil for `.restore` and the two display moves, none of which are computed from the
    /// current screen — the caller substitutes a saved frame, or re-runs against another display.
    func frame(in area: CGRect, current: CGRect, fraction: CGFloat) -> CGRect? {
        let half = CGSize(width: area.width / 2, height: area.height / 2)
        switch self {
        case .leftHalf:
            return CGRect(x: area.minX, y: area.minY, width: area.width * fraction, height: area.height)
        case .rightHalf:
            let width = area.width * fraction
            return CGRect(x: area.maxX - width, y: area.minY, width: width, height: area.height)
        case .topHalf:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height * fraction)
        case .bottomHalf:
            let height = area.height * fraction
            return CGRect(x: area.minX, y: area.maxY - height, width: area.width, height: height)
        case .topLeft:
            return CGRect(origin: CGPoint(x: area.minX, y: area.minY), size: half)
        case .topRight:
            return CGRect(origin: CGPoint(x: area.midX, y: area.minY), size: half)
        case .bottomLeft:
            return CGRect(origin: CGPoint(x: area.minX, y: area.midY), size: half)
        case .bottomRight:
            return CGRect(origin: CGPoint(x: area.midX, y: area.midY), size: half)
        case .leftThird:
            return CGRect(x: area.minX, y: area.minY, width: area.width / 3, height: area.height)
        case .centerThird:
            return CGRect(
                x: area.minX + area.width / 3, y: area.minY,
                width: area.width / 3, height: area.height)
        case .rightThird:
            return CGRect(
                x: area.maxX - area.width / 3, y: area.minY,
                width: area.width / 3, height: area.height)
        case .maximize:
            return area
        case .center:
            // Keeps the window's size — centring is a move, not a resize — and clamps so a window
            // bigger than the screen still lands with its top-left on it rather than off the edge.
            let size = CGSize(
                width: min(current.width, area.width), height: min(current.height, area.height))
            return CGRect(
                x: area.minX + (area.width - size.width) / 2,
                y: area.minY + (area.height - size.height) / 2,
                width: size.width, height: size.height)
        case .restore, .previousDisplay, .nextDisplay:
            return nil
        }
    }
}

/// The bindings, matched against a keypress by the controller. A value type so the tap thread reads
/// a snapshot rather than reaching into the store.
///
/// A missing entry means *deliberately unassigned*, not "use the default": someone who wants only
/// the two halves bound should be able to leave the other nine chords with the apps they came from.
struct WindowTilingBindings: Equatable {
    var isEnabled: Bool = false
    var cycleWidths: Bool = true
    /// Drag a window to a screen edge to tile it there. Independent of `isEnabled`: someone may want
    /// the mouse gesture and no global chords at all, or the reverse.
    var dragSnap: Bool = false
    var bindings: [WindowArrangement: Hotkey]

    static let defaults = WindowTilingBindings(
        bindings: Dictionary(
            uniqueKeysWithValues: WindowArrangement.allCases.map { ($0, $0.defaultHotkey) }))

    /// Whether `hotkey` can never fire because a switcher trigger claims it first.
    ///
    /// The tap matches both triggers *before* tiling, using `TriggerModifiers.opens` — an exact
    /// match on ⌘/⌥/⌃ with ⇧ ignored, since Shift only ever means "go backwards". A tiling chord
    /// that satisfies that test opens the switcher instead, every time, with nothing to show the
    /// user why their binding is dead. Static so the settings pane can ask the same question of a
    /// binding that has already been stored — changing the trigger can strand one after the fact.
    @MainActor
    static func triggerClaiming(_ hotkey: Hotkey, in behavior: BehaviorStore) -> String? {
        let held = hotkey.heldModifiers
        if hotkey.keyCode == behavior.hotkey.keyCode,
            TriggerModifiers.opens(held, held: behavior.hotkey.heldModifiers) {
            return "the switcher shortcut"
        }
        if behavior.sameAppCycle, hotkey.keyCode == behavior.sameAppHotkey.keyCode,
            TriggerModifiers.opens(held, held: behavior.sameAppHotkey.heldModifiers) {
            return "the app-window cycle shortcut"
        }
        return nil
    }

    /// Other arrangements bound to the same chord as `arrangement`.
    ///
    /// Nothing stops a user assigning one chord twice — the recorder takes any combination — but
    /// only the first in case order will ever fire, so the settings pane says so rather than
    /// leaving a dead binding that looks bound.
    func conflicts(with arrangement: WindowArrangement) -> [WindowArrangement] {
        guard let hotkey = bindings[arrangement] else { return [] }
        return WindowArrangement.allCases.filter {
            $0 != arrangement && bindings[$0] == hotkey
        }
    }

    /// The arrangement a keypress fires, if any.
    ///
    /// Iterates in declared case order so two arrangements bound to the same chord always resolve
    /// the same way rather than depending on dictionary ordering. Exact modifier match, so ⌃⌘←
    /// stays distinct from ⌃⌥⌘←.
    func arrangement(code: Int, flags: CGEventFlags) -> WindowArrangement? {
        guard isEnabled else { return nil }
        let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return WindowArrangement.allCases.first {
            guard let hotkey = bindings[$0], hotkey.isUsableGlobally else { return false }
            let want = hotkey.modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return hotkey.keyCode == code && want == held
        }
    }
}

/// Persists the tiling bindings and the two switches that go with them.
///
/// Plain `UserDefaults` rather than a `Defaults` key, matching `SwitcherShortcutsStore` — the
/// bindings are a dictionary of pairs, which is the one shape the typed-key table has never
/// carried. The three key names are listed in `BehaviorStore.otherStoreKeys` so export, import and
/// reset cover them.
@MainActor
final class WindowTilingStore: ObservableObject {
    static let shared = WindowTilingStore()

    private enum Key {
        static let enabled = "windowTilingEnabled"
        static let cycleWidths = "windowTilingCycleWidths"
        static let shortcuts = "windowTilingShortcuts"
        static let dragSnap = "windowTilingDragSnap"
    }

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [Key.enabled, Key.cycleWidths, Key.shortcuts, Key.dragSnap]

    @Published private(set) var tiling: WindowTilingBindings = .defaults

    /// The arrangement currently armed for recording, if any.
    ///
    /// The monitor lives here rather than in each recorder view because there is only one keyboard.
    /// Eleven views each holding a local monitor meant clicking a second recorder without pressing a
    /// key left the first still listening; both then received the next keyDown and whichever handler
    /// ran first consumed it, so the combination landed on the wrong arrangement or on none at all.
    /// One owner, one monitor, no race — the same shape `SwitcherShortcutsStore` uses, and for the
    /// same reason.
    @Published private(set) var recordingArrangement: WindowArrangement?
    private var recordingMonitor: Any?

    var onChange: ((WindowTilingBindings) -> Void)?

    var isEnabled: Bool {
        get { tiling.isEnabled }
        set {
            guard newValue != tiling.isEnabled else { return }
            tiling.isEnabled = newValue
            persist()
        }
    }

    var cycleWidths: Bool {
        get { tiling.cycleWidths }
        set {
            guard newValue != tiling.cycleWidths else { return }
            tiling.cycleWidths = newValue
            persist()
        }
    }

    var dragSnap: Bool {
        get { tiling.dragSnap }
        set {
            guard newValue != tiling.dragSnap else { return }
            tiling.dragSnap = newValue
            persist()
        }
    }

    private init() { tiling = Self.load() }

    /// The chord bound to `arrangement`, or nil when the user has cleared it.
    func hotkey(for arrangement: WindowArrangement) -> Hotkey? {
        tiling.bindings[arrangement]
    }

    func set(_ hotkey: Hotkey, for arrangement: WindowArrangement) {
        tiling.bindings[arrangement] = hotkey
        persist()
    }

    /// Unassigns an arrangement, handing its chord back to whatever app wants it.
    func clear(_ arrangement: WindowArrangement) {
        guard tiling.bindings[arrangement] != nil else { return }
        tiling.bindings[arrangement] = nil
        persist()
    }

    // MARK: - Recording

    /// Arms `arrangement` for recording, disarming whatever was armed before.
    ///
    /// `validate` returns false to reject the combination; the caller shows its own explanation.
    func beginRecording(
        _ arrangement: WindowArrangement, validate: @escaping (Hotkey) -> Bool
    ) {
        stopRecording()
        recordingArrangement = arrangement
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:  // ⎋ aborts, leaving the binding alone
                self.stopRecording()
                return nil
            case 51:  // ⌫ unassigns
                self.stopRecording()
                DispatchQueue.main.async { self.clear(arrangement) }
                return nil
            default:
                break
            }
            let mods = Self.cgFlags(from: event.modifierFlags)
            // A global chord needs a real modifier: a bare key would fire on every keystroke in
            // every app on the machine.
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            self.stopRecording()
            // Hop off the handler before doing anything else: this tears down the very monitor that
            // is running, and `validate` may raise a modal — neither belongs inside event dispatch.
            DispatchQueue.main.async {
                guard validate(candidate) else { return }
                self.set(candidate, for: arrangement)
            }
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingArrangement = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    /// Restores the default *chords*, and nothing else.
    ///
    /// Both switches are carried over rather than just `isEnabled`: the button sits under the
    /// shortcut rows and is captioned about shortcuts, so someone who turned the width cycle off
    /// because it annoyed them should not find it back on after undoing a key change.
    func resetToDefaults() {
        tiling.bindings = WindowTilingBindings.defaults.bindings
        persist()
    }

    func reload() {
        tiling = Self.load()
        onChange?(tiling)
    }

    /// Stored as `{ arrangementRawValue: [keyCode, modifierRaw] }`, which is plist-safe.
    ///
    /// A cleared arrangement is written as an **empty array** rather than left out. The two have to
    /// be told apart: an absent key means "this install predates the binding", which takes the
    /// default, while an empty one means the user removed it — and a cleared chord that came back
    /// as its default on the next launch would be a setting that does not stick.
    private static func load() -> WindowTilingBindings {
        let defaults = UserDefaults.standard
        var result = WindowTilingBindings.defaults
        result.isEnabled = defaults.bool(forKey: Key.enabled)
        // Absent means "never set", which for this one is on — the cycle is the useful default and
        // `bool(forKey:)` reports false for a missing key.
        result.cycleWidths =
            defaults.object(forKey: Key.cycleWidths) != nil
            ? defaults.bool(forKey: Key.cycleWidths) : true
        result.dragSnap = defaults.bool(forKey: Key.dragSnap)
        if let raw = defaults.dictionary(forKey: Key.shortcuts) {
            for arrangement in WindowArrangement.allCases {
                guard let pair = raw[arrangement.rawValue] as? [Int] else { continue }
                guard pair.count == 2 else {
                    result.bindings[arrangement] = nil  // explicitly cleared
                    continue
                }
                result.bindings[arrangement] = Hotkey(
                    keyCode: pair[0], modifierRaw: UInt64(bitPattern: Int64(pair[1])))
            }
        }
        return result
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(tiling.isEnabled, forKey: Key.enabled)
        defaults.set(tiling.cycleWidths, forKey: Key.cycleWidths)
        defaults.set(tiling.dragSnap, forKey: Key.dragSnap)
        // Every arrangement is written, so a cleared one is recorded as cleared rather than simply
        // missing — see `load()`.
        var raw: [String: [Int]] = [:]
        for arrangement in WindowArrangement.allCases {
            guard let hotkey = tiling.bindings[arrangement] else {
                raw[arrangement.rawValue] = []
                continue
            }
            raw[arrangement.rawValue] = [hotkey.keyCode, Int(bitPattern: UInt(hotkey.modifierRaw))]
        }
        defaults.set(raw, forKey: Key.shortcuts)
        onChange?(tiling)
    }
}

/// Applies an arrangement to the focused window.
///
/// Every Accessibility call here is IPC to another process and can block on a wedged app, so the
/// work runs off the caller's thread — the caller is the event-tap callback, where a stall costs
/// the user every keystroke on the machine. The screen geometry and the frontmost pid are read by
/// the caller (both are main-thread reads) and handed in.
enum WindowTiler {
    private static let queue = DispatchQueue(label: "com.cmdtab.tiling", qos: .userInitiated)

    /// Identity for the restore and cycle tables.
    ///
    /// The `AXUIElement` itself, compared with `CFEqual`, which for an accessibility element means
    /// "the same underlying window" rather than "the same handle". Deliberately *not* the app's
    /// pid: two windows of one app must not share a restore slot, or restoring the second would
    /// move it to a frame the first once had — and it must not be
    /// `TargetProvider.windowID(matching:pid:)` either, which re-reads the window's position and
    /// size over Accessibility and then copies the entire system window list, on every keypress,
    /// only to produce a number. The element is already in hand and costs nothing.
    private struct WindowKey: Hashable {
        let element: AXUIElement

        static func == (lhs: Self, rhs: Self) -> Bool { CFEqual(lhs.element, rhs.element) }
        func hash(into hasher: inout Hasher) { hasher.combine(CFHash(element)) }
    }

    /// The frame each window had before it was first tiled, so `.restore` has something to go back
    /// to, and the order those frames were recorded in so the oldest can be dropped first.
    ///
    /// Touched only on `queue`, which is what keeps them safe without a lock.
    private nonisolated(unsafe) static var restorePoints: [WindowKey: CGRect] = [:]
    private nonisolated(unsafe) static var restoreOrder: [WindowKey] = []
    /// Where the last cycling arrangement left off: the window it applied to, which arrangement,
    /// and how far through `cycleFractions` it had got.
    private nonisolated(unsafe) static var cycle: (key: WindowKey, arrangement: WindowArrangement, step: Int)?

    /// Bounded so a long session cannot accumulate a restore frame for every window ever tiled.
    /// Well past any plausible working set; this is a backstop, not a policy.
    private static let restoreLimit = 128

    static func apply(
        _ arrangement: WindowArrangement, pid: pid_t, areas: [CGRect], cycleWidths: Bool
    ) {
        guard !areas.isEmpty else { return }
        queue.async {
            guard let window = AX.frontWindow(ofApplication: pid),
                let origin = AX.position(window), let size = AX.size(window)
            else { return }
            let current = CGRect(origin: origin, size: size)
            let key = WindowKey(element: window)

            // The screen the window is mostly on, rather than the one it merely touches: a window
            // straddling two displays should tile on the one it is actually being used on.
            let area = areas.max { a, b in
                a.intersection(current).area < b.intersection(current).area
            } ?? areas[0]

            let target: CGRect
            if let step = arrangement.displayStep {
                // Same fractional position on the destination display, then clamped onto it — the
                // treatment `SwitchTarget.moveWindow(acrossDisplays:)` gives the in-switcher move,
                // so a window thrown either way lands in the same place.
                guard areas.count > 1, let from = areas.firstIndex(of: area) else { return }
                let to = areas[((from + step) % areas.count + areas.count) % areas.count]
                let relX = area.width > 0 ? (current.minX - area.minX) / area.width : 0
                let relY = area.height > 0 ? (current.minY - area.minY) / area.height : 0
                let size = CGSize(
                    width: min(current.width, to.width), height: min(current.height, to.height))
                target = CGRect(
                    x: min(max(to.minX + relX * to.width, to.minX), to.maxX - size.width),
                    y: min(max(to.minY + relY * to.height, to.minY), to.maxY - size.height),
                    width: size.width, height: size.height)
                // A move is not a tile: it must not consume the restore point, and the width cycle
                // has to start over on the new display.
                cycle = nil
            } else if arrangement == .restore {
                guard let saved = restorePoints.removeValue(forKey: key) else { return }
                restoreOrder.removeAll { $0 == key }
                cycle = nil
                target = saved
            } else {
                // Saved once per window and not overwritten by later tiles, so restore goes back to
                // where the window was before any of this started rather than to the previous tile.
                if restorePoints[key] == nil {
                    // Evict the *oldest* rather than clearing the table. Wiping it wholesale meant
                    // tiling one more window than the cap silently threw away the restore frame of
                    // every window the user was still working with, and ⌃⌘Z then did nothing at all.
                    while restoreOrder.count >= restoreLimit, let oldest = restoreOrder.first {
                        restoreOrder.removeFirst()
                        restorePoints.removeValue(forKey: oldest)
                    }
                    restorePoints[key] = current
                    restoreOrder.append(key)
                }
                let fraction = nextFraction(
                    for: arrangement, key: key, cycleWidths: cycleWidths)
                guard let frame = arrangement.frame(
                    in: area, current: current, fraction: fraction) else { return }
                target = frame
            }

            // Position, size, position. Some apps clamp a move against their *current* size (so the
            // first position lands short) and others clamp a resize against the screen edge from
            // their old origin. Setting position twice around the resize is what makes both land,
            // and it is what every window manager on this platform ends up doing.
            AX.setPosition(window, target.origin)
            AX.setSize(window, target.size)
            AX.setPosition(window, target.origin)
        }
    }

    /// How much of the screen this press should take, advancing the cycle when the same arrangement
    /// is applied to the same window twice running.
    private static func nextFraction(
        for arrangement: WindowArrangement, key: WindowKey, cycleWidths: Bool
    ) -> CGFloat {
        let fractions = WindowArrangement.cycleFractions
        guard cycleWidths, arrangement.cycles else {
            cycle = nil
            return fractions[0]
        }
        if let cycle, cycle.key == key, cycle.arrangement == arrangement {
            let step = (cycle.step + 1) % fractions.count
            self.cycle = (key, arrangement, step)
            return fractions[step]
        }
        cycle = (key, arrangement, 0)
        return fractions[0]
    }

    /// Visible frames — menu bar and Dock excluded — in Accessibility's top-left-origin space.
    ///
    /// `TargetProvider.screenCGFrames` does the same flip for *full* frames; tiling wants the
    /// usable area, or a maximized window would sit under the menu bar.
    @MainActor
    static func visibleAreas() -> [CGRect] {
        let primaryHeight =
            (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return CGRect(
                x: visible.origin.x,
                y: primaryHeight - visible.origin.y - visible.height,
                width: visible.width, height: visible.height)
        }
    }
}

extension CGRect {
    /// Zero for a null rect, which `intersection` returns when two frames do not overlap at all —
    /// `CGRect.null` has an infinite size, so its `width * height` is not a number you can compare.
    fileprivate var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
