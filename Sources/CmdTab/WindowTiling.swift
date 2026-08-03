import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

// Window tiling: global hotkeys that snap the focused window to a half, a corner, the whole screen
// or the centre, whether or not the switcher is open.
//
// Ordinary global chords, matched when nothing is open: they act on whatever window the user is
// looking at, not on anything the switcher has selected.

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

    /// Whether this sends the window to another display rather than resizing it where it is.
    ///
    /// A family of one, kept as a family: moving a window to another **Desktop** belongs here too
    /// and cannot be built. macOS only lets a Space-managing connection move another app's window
    /// between Spaces, so every SkyLight route (`CGS`/`SLSMoveWindowsToManagedSpace`, and the
    /// remove-then-add pair) is accepted and silently ignored from an ordinary process. The tools
    /// that manage it inject into Dock, which needs SIP partially disabled.
    ///
    /// The moves are *not* gated on the tiling switch: they take nothing away from the window's own
    /// layout, so "I don't want Cmd-Tab resizing my windows" is not a reason to lose them.
    /// Everything else is tiling proper, off until asked for. See
    /// `WindowTilingBindings.arrangement(code:flags:)`, which is where that split is enforced.
    var isMove: Bool { displayStep != nil }

    /// The moves, in the order the Windows tab lists them.
    static let moves: [WindowArrangement] = allCases.filter(\.isMove)

    /// Everything gated on the tiling switch.
    static let tilingArrangements: [WindowArrangement] = allCases.filter { !$0.isMove }

    /// The arrangements a window can be given the moment it opens (`AppRule.launchArrangement`).
    ///
    /// The display moves are excluded because they are relative — "one display along from where it
    /// is" is not a placement for a window that has only just appeared. `.restore` goes too: its
    /// whole definition is the frame the window had before it was first tiled, and a window on its
    /// first frame has no such history, so it would silently do nothing.
    static let launchable: [WindowArrangement] = tilingArrangements.filter { $0 != .restore }

    /// Whether a gap applies. Only the arrangements that *tile* — the ones whose frame is a
    /// fraction of the screen — take one. `.center` keeps the window's own size and `.restore` puts
    /// back a frame the user chose themselves, so insetting either would be Cmd-Tab second-guessing
    /// a size it did not pick; the moves change no geometry at all.
    var takesGap: Bool {
        switch self {
        case .center, .restore, .previousDisplay, .nextDisplay: return false
        default: return true
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

/// Insets a tiled frame so windows do not touch the screen edges or each other.
///
/// One number does both jobs, the way every window manager that has gaps does it: the full gap at
/// a screen edge, half of it at a seam — so two windows sharing a seam end up exactly one gap
/// apart, the same distance as each is from the outside. Which edges are which is read off the
/// frame itself rather than tracked per arrangement: an edge sitting on the usable area's boundary
/// is an outside edge, anything else meets another tile.
enum TilingGap {
    /// The widest gap the settings slider offers. Past this a half is more gap than window on a
    /// laptop display.
    static let maximum: CGFloat = 60

    /// A point of slack when deciding whether an edge is on the boundary. The thirds are computed
    /// by division and land a hair off the exact edge — `area.maxX - area.width / 3` is not bitwise
    /// `area.minX + 2 * area.width / 3` — and without the slack a right third would take an inner
    /// gap on the side that is actually against the screen.
    private static let epsilon: CGFloat = 1

    static func inset(_ frame: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return frame }
        let left = frame.minX - area.minX <= epsilon ? gap : gap / 2
        let right = area.maxX - frame.maxX <= epsilon ? gap : gap / 2
        let top = frame.minY - area.minY <= epsilon ? gap : gap / 2
        let bottom = area.maxY - frame.maxY <= epsilon ? gap : gap / 2

        let width = frame.width - left - right
        let height = frame.height - top - bottom
        // A gap wider than the tile would invert the frame. Nothing here can produce a window
        // narrower than a quarter of its tile, however the slider is set.
        guard width > frame.width / 4, height > frame.height / 4 else { return frame }
        return CGRect(x: frame.minX + left, y: frame.minY + top, width: width, height: height)
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
    /// Points of space left around a tiled window: the whole gap against a screen edge, half of it
    /// where two tiles meet. 0 keeps windows flush, which is what tiling has always done.
    var gap: CGFloat = 0
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
    ///
    /// With tiling switched off the geometry arrangements are skipped but the **moves** still
    /// match. The switch is about Cmd-Tab resizing windows; sending one to the next display or
    /// Desktop changes no layout, and gating it behind a checkbox captioned about tiling made a
    /// bound chord do nothing with no visible cause. The cost is that these four chords are claimed
    /// system-wide as soon as they are bound, tiling on or off — which is what the pane says.
    func arrangement(code: Int, flags: CGEventFlags) -> WindowArrangement? {
        let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        let candidates = isEnabled ? WindowArrangement.allCases : WindowArrangement.moves
        return candidates.first {
            guard let hotkey = bindings[$0], hotkey.isUsableGlobally else { return false }
            let want = hotkey.modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return hotkey.keyCode == code && want == held
        }
    }
}

/// Persists the tiling bindings and the two switches that go with them.
///
/// Plain `UserDefaults` rather than a `Defaults` key: the bindings are a dictionary of pairs, which
/// is the one shape the typed-key table has never carried. The key names are listed in
/// `WindowTilingStore.defaultsKeys` so export, import and reset cover them.
@MainActor
final class WindowTilingStore: ObservableObject {
    static let shared = WindowTilingStore()

    private enum Key {
        static let enabled = "windowTilingEnabled"
        static let cycleWidths = "windowTilingCycleWidths"
        static let shortcuts = "windowTilingShortcuts"
        static let dragSnap = "windowTilingDragSnap"
        static let gap = "windowTilingGap"
        static let dotHex = "windowSnapDotColorHex"
        static let mouseDrag = "windowMouseDragEnabled"
        static let mouseMove = "windowMouseDragMoveModifiers"
        static let mouseResize = "windowMouseDragResizeModifiers"
    }

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [
        Key.enabled, Key.cycleWidths, Key.shortcuts, Key.dragSnap, Key.gap,
        Key.dotHex,
        Key.mouseDrag, Key.mouseMove, Key.mouseResize,
    ]

    @Published private(set) var tiling: WindowTilingBindings = .defaults

    /// The arrangement currently armed for recording, if any.
    ///
    /// The monitor lives here rather than in each recorder view because there is only one keyboard.
    /// Eleven views each holding a local monitor meant clicking a second recorder without pressing a
    /// key left the first still listening; both then received the next keyDown and whichever handler
    /// ran first consumed it, so the combination landed on the wrong arrangement or on none at all.
    /// One owner, one monitor, no race.
    @Published private(set) var recordingArrangement: WindowArrangement?
    private var recordingMonitor: Any?

    var onChange: ((WindowTilingBindings) -> Void)?
    /// Separate from `onChange` because the two go to different taps — the key tap takes the
    /// bindings, the mouse tap takes these — and pushing one through the other's channel would
    /// rebuild a tap on every unrelated edit.
    var onMouseDragChange: ((MouseDragSettings) -> Void)?

    /// Modifier-drag to move or resize. Its own value rather than a field on
    /// `WindowTilingBindings`: the bindings struct is the snapshot the *key* tap reads on every
    /// keystroke, and this is only ever read by the mouse tap.
    @Published private(set) var mouseDrag = MouseDragSettings()

    var mouseDragEnabled: Bool {
        get { mouseDrag.isEnabled }
        set {
            guard newValue != mouseDrag.isEnabled else { return }
            mouseDrag.isEnabled = newValue
            persist()
        }
    }

    func setMouseChord(_ chord: ModifierChord, for action: MouseDragAction) {
        guard mouseDrag.chord(for: action) != chord else { return }
        mouseDrag.set(chord, for: action)
        persist()
    }

    func mouseChord(for action: MouseDragAction) -> ModifierChord {
        mouseDrag.chord(for: action)
    }

    /// The colour of the anchor dot the hold-and-point gesture starts from. Kept here rather than
    /// in `AppearanceStore`, which is about the switcher panel: this is a Windows-tab setting that
    /// only exists while a snap gesture is in flight.
    ///
    /// The dot alone. The outline and the destination block stay on the system accent — they are
    /// large, translucent, and read as the system's own highlighting; the dot is 14pt of solid
    /// colour and the one mark here worth making yours.
    @Published var dotColor: Color = SnapAppearance.defaultDot {
        didSet {
            guard dotColor != oldValue else { return }
            // Nil for a pattern or catalog colour the macOS panel can hand back; the stored value
            // is left as it was rather than overwritten with a substitute.
            if let hex = dotColor.hexString {
                UserDefaults.standard.set(hex, forKey: Key.dotHex)
            }
            SnapAppearance.shared.apply(dot: dotColor)
        }
    }

    private static func loadDotColor() -> Color {
        UserDefaults.standard.string(forKey: Key.dotHex).flatMap(Color.init(hex:))
            ?? SnapAppearance.defaultDot
    }

    var gap: CGFloat {
        get { tiling.gap }
        set {
            let clamped = min(max(newValue, 0), TilingGap.maximum)
            guard clamped != tiling.gap else { return }
            tiling.gap = clamped
            persist()
        }
    }

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

    private init() {
        tiling = Self.load()
        mouseDrag = Self.loadMouseDrag()
        let dot = Self.loadDotColor()
        dotColor = dot
        SnapAppearance.shared.apply(dot: dot)
    }

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
        mouseDrag = Self.loadMouseDrag()
        let dot = Self.loadDotColor()
        dotColor = dot
        SnapAppearance.shared.apply(dot: dot)
        onChange?(tiling)
        onMouseDragChange?(mouseDrag)
    }

    /// Stored as the two chords' raw modifier bits plus a switch.
    ///
    /// An absent key takes the default; a stored chord with no usable modifier in it — a
    /// hand-edited config, or a recording that somehow got through — is dropped back to the default
    /// rather than kept, since binding the gesture to "no modifier" would make every drag on the
    /// machine a window drag.
    private static func loadMouseDrag() -> MouseDragSettings {
        let defaults = UserDefaults.standard
        var result = MouseDragSettings()
        result.isEnabled = defaults.bool(forKey: Key.mouseDrag)
        for (key, action) in [(Key.mouseMove, MouseDragAction.move), (Key.mouseResize, .resize)] {
            guard let raw = defaults.object(forKey: key) as? Int else { continue }
            let chord = ModifierChord(rawValue: UInt64(bitPattern: Int64(raw)))
            guard chord.isUsable else { continue }
            result.set(chord, for: action)
        }
        return result
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
        // Absent means never set, which is 0 — `double(forKey:)` already reports 0 for a missing
        // key, so the two cases need no telling apart here.
        result.gap = min(max(CGFloat(defaults.double(forKey: Key.gap)), 0), TilingGap.maximum)
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
        defaults.set(mouseDrag.isEnabled, forKey: Key.mouseDrag)
        defaults.set(Int(bitPattern: UInt(mouseDrag.move.rawValue)), forKey: Key.mouseMove)
        defaults.set(Int(bitPattern: UInt(mouseDrag.resize.rawValue)), forKey: Key.mouseResize)
        onMouseDragChange?(mouseDrag)
        defaults.set(tiling.isEnabled, forKey: Key.enabled)
        defaults.set(tiling.cycleWidths, forKey: Key.cycleWidths)
        defaults.set(tiling.dragSnap, forKey: Key.dragSnap)
        defaults.set(Double(tiling.gap), forKey: Key.gap)
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
    ///
    /// The desk the frame was recorded against is kept with it. Restore promises the exact
    /// rectangle back, and a rescue that tidies a window onto the nearest display breaks that
    /// promise for anyone who deliberately parked one half off an edge — so the rescue has to be
    /// able to tell "the display this was saved on is gone" from "this is where the user put it".
    /// Comparing the areas is enough: the rescue only exists for a desk that has changed.
    private nonisolated(unsafe) static var restorePoints: [WindowKey: (frame: CGRect, desk: [CGRect])] = [:]
    private nonisolated(unsafe) static var restoreOrder: [WindowKey] = []
    /// Where the last cycling arrangement left off: the window it applied to, which arrangement,
    /// and how far through `cycleFractions` it had got.
    private nonisolated(unsafe) static var cycle: (key: WindowKey, arrangement: WindowArrangement, step: Int)?

    /// Bounded so a long session cannot accumulate a restore frame for every window ever tiled.
    /// Well past any plausible working set; this is a backstop, not a policy.
    private static let restoreLimit = 128

    static func apply(
        _ arrangement: WindowArrangement, pid: pid_t, areas: [CGRect], cycleWidths: Bool,
        gap: CGFloat = 0
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
            //
            // Resolved as an *index* and kept as one. Looking the rectangle back up by equality
            // meant two displays showing the same frame — a mirrored pair, or two panels the user
            // has stacked at the same coordinates — both answered with the first of them, so a
            // move-to-next-display computed its destination as the display it started on and did
            // nothing, with no log line saying why.
            let resolved = homeDisplay(of: current, in: areas)
            // Tiling still has to put the window *somewhere*, so it keeps a fallback; a window on no
            // display at all gets tiled onto the first one rather than left where it is.
            let home = resolved ?? areas.startIndex
            let area = areas[home]

            let target: CGRect
            if let step = arrangement.displayStep {
                // A move, unlike a tile, is relative: without a display to count from there is no
                // "next" one, and counting from the fallback would throw the window off a display it
                // was never on.
                guard resolved != nil else { return }
                // Same fractional position on the destination display, then clamped onto it — the
                // treatment `SwitchTarget.moveWindow(acrossDisplays:)` gives the in-switcher move,
                // so a window thrown either way lands in the same place. Both are handed *visible*
                // areas, which is what keeps that promise: measuring against full display frames
                // instead puts the window's top edge under the destination's menu bar.
                guard areas.count > 1 else { return }
                let to = areas[((home + step) % areas.count + areas.count) % areas.count]
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
                target = restoreTarget(
                    saved.frame, savedOn: saved.desk, desk: areas, fallback: area)
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
                    restorePoints[key] = (frame: current, desk: areas)
                    restoreOrder.append(key)
                }
                let fraction = nextFraction(
                    for: arrangement, key: key, cycleWidths: cycleWidths)
                guard let frame = arrangement.frame(
                    in: area, current: current, fraction: fraction) else { return }
                // Applied last, to the finished tile: the gap is about where a window ends up, not
                // about how the arrangement divides the screen, so the fraction maths above stays
                // exactly as it is at any gap.
                target = arrangement.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame
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

    /// Where `.restore` should put a window: the frame it saved, rescued only if the desk moved
    /// under it.
    ///
    /// Restore's promise is the exact rectangle back. `reachable` breaks that promise for anyone who
    /// deliberately parked a window mostly off an edge — it reads a placement the user chose as a
    /// window that needs tidying, and there is nothing in the rectangle alone to tell the two apart.
    /// The desk the frame was recorded against is what tells them apart: the rescue exists for a
    /// display that has gone away, so it only runs when one has.
    ///
    /// Internal rather than private for the same reason `reachable` is — the desk-changed cases can
    /// then be tested without a monitor to unplug.
    static func restoreTarget(
        _ saved: CGRect, savedOn: [CGRect], desk: [CGRect], fallback: CGRect
    ) -> CGRect {
        savedOn == desk ? saved : reachable(saved, in: desk, fallback: fallback)
    }

    /// A saved restore frame, made reachable again on today's desk.
    ///
    /// A restore point is recorded against the displays as they were, and nothing invalidates it
    /// when they change: tile a window on an external monitor, unplug the monitor, press the restore
    /// chord, and the saved frame names coordinates no display covers. The window is written there
    /// all the same, with no titlebar left on screen to drag it back — the one way this feature can
    /// lose a window outright.
    ///
    /// Left exactly as saved whenever it is still reachable, so a window the user deliberately left
    /// hanging off an edge comes back hanging off the same edge.
    ///
    /// Internal rather than private so the desk-changed cases can be tested without a second monitor
    /// to unplug.
    static func reachable(_ saved: CGRect, in areas: [CGRect], fallback: CGRect) -> CGRect {
        // Reachable means "enough of the titlebar is on a display to aim at", which is neither of
        // the two obvious tests. Asking whether the *frame* overlaps a display calls a window
        // reachable when a corner of its bottom-right is showing, which is as lost as being off
        // screen entirely; asking whether a single point of the top edge is on one calls a window
        // unreachable when it is merely hanging half off an edge, which is a placement people choose
        // deliberately and the restore point exists to give back.
        //
        // Width from one display rather than summed across them: two displays can only both
        // contribute to one titlebar if they are adjacent, and the conservative answer is the right
        // way to be wrong here.
        let titlebar = CGRect(
            x: saved.minX, y: saved.minY,
            width: saved.width, height: min(saved.height, titlebarHeight))
        let grabbable =
            areas.map { $0.intersection(titlebar) }
            .filter { !$0.isNull && $0.height > 0 }
            .map(\.width).max() ?? 0
        // A window narrower than the threshold only has to be fully on screen to qualify.
        if grabbable >= min(minimumGrab, saved.width) { return saved }
        // Whichever display it still overlaps most, or — if the desk has changed enough that it
        // overlaps none — the one the window is on now.
        let home = areas.filter { $0.intersection(saved).area > 0 }.max { a, b in
            a.intersection(saved).area < b.intersection(saved).area
        } ?? fallback
        return LayoutGeometry.clamp(saved, into: home)
    }

    /// The strip along the top of a window that can be dragged. macOS's own titlebar height; nothing
    /// here depends on it being exact, only on it being the top edge rather than the whole frame.
    private static let titlebarHeight: CGFloat = 28
    /// How much of that strip has to be on a display for the window to count as grabbable. About the
    /// width of the traffic lights — enough to put a cursor on without hunting for it.
    private static let minimumGrab: CGFloat = 60

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
    static func visibleAreas() -> [CGRect] { visibleDisplays().map(\.area) }

    /// A display's usable area together with an identity that survives unplugging it.
    ///
    /// The UUID comes from the display hardware, so the same monitor is the same id across a
    /// reconnect, a reboot and a resolution change — which is what lets a saved layout say "this
    /// window was on *that* monitor" rather than "this window was at x=2400", a statement that stops
    /// being true the moment the desk changes.
    struct DisplayArea: Equatable {
        /// nil when the UUID can't be read. Such a display still takes part in tiling, which only
        /// needs the rectangle; only layouts need the identity.
        let id: String?
        /// The full frame in Cocoa's bottom-up space — `NSScreen.frame` verbatim, menu bar and Dock
        /// included. Carried alongside `area` so a caller that needs both coordinate spaces gets
        /// them from one read of `NSScreen.screens` rather than pairing two by index.
        var frame: CGRect = .zero
        /// The usable area in Accessibility's top-left space.
        let area: CGRect
        /// Whether this is the display with the menu bar.
        ///
        /// Carried rather than derived: `area` is a *visible* frame, so the primary's does not start
        /// at the origin and there is nothing in the rectangle alone to tell it apart from any other
        /// display's.
        var isPrimary: Bool = false
    }

    /// Which of `areas` a window belongs to: the one containing its centre, else the one it overlaps
    /// most. nil when it overlaps none of them.
    ///
    /// One rule, shared by everything that has to answer "which display is this window on" — the
    /// switcher's display badge, the in-switcher move, the tiling chords and layout capture. Those
    /// had drifted into answering it three different ways on two different rectangle sets, so the
    /// switcher could badge a window on one display while the move chord treated it as being on
    /// another and threw it onto the display it was already labelled as being on.
    ///
    /// Centre first, because that is what "which display is this window on" means to someone looking
    /// at it. Largest overlap only as the tiebreak, for a window whose centre falls in a gap — under
    /// the menu bar, inside the Dock strip, or in the seam between two monitors.
    ///
    /// nil rather than a default index. `max(by:)` keeps the first element on ties, so a window
    /// overlapping *nothing* compared 0 < 0 all the way down and came back as display 0 — which is
    /// how a move chord picked up a window that was never on display 0 and moved it off it. Callers
    /// that must have an answer say so themselves; callers that would rather do nothing now can.
    static func homeDisplay(of frame: CGRect, in areas: [CGRect]) -> Int? {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let index = areas.firstIndex(where: { $0.contains(centre) }) { return index }
        return areas.indices
            .filter { areas[$0].intersection(frame).area > 0 }
            .max { areas[$0].intersection(frame).area < areas[$1].intersection(frame).area }
    }

    @MainActor
    static func visibleDisplays() -> [DisplayArea] {
        // Resolved once, and every use below answers from *this* screen rather than re-deriving it.
        // `NSScreen.primary` falls back to `main ?? screens.first` when nothing sits at the origin,
        // which a display reconfiguration can transiently produce — so deriving `isPrimary` from
        // `frame.origin == .zero` separately marked no display primary at all while `primaryHeight`
        // still had an answer. `LayoutGeometry.absolute` then found no primary to fall back to and
        // dropped a restored layout onto `displays[0]`, which is the wrong-monitor outcome its own
        // fallback exists to prevent.
        let primary = NSScreen.primary
        let primaryHeight = primary?.frame.height ?? 0
        return NSScreen.screens.map { screen in
            let visible = screen.visibleFrame
            return DisplayArea(
                id: displayUUID(of: screen),
                frame: screen.frame,
                // Cocoa's bottom-left origin flipped into Accessibility's top-left one, against the
                // *primary* display's height — the origin both coordinate spaces share.
                area: CGRect(
                    x: visible.origin.x,
                    y: primaryHeight - visible.origin.y - visible.height,
                    width: visible.width, height: visible.height),
                isPrimary: screen == primary)
        }
    }

    private static func displayUUID(of screen: NSScreen) -> String? {
        guard
            let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")]
                as? NSNumber,
            let uuid = CGDisplayCreateUUIDFromDisplayID(CGDirectDisplayID(number.uint32Value))?
                .takeRetainedValue()
        else { return nil }
        return CFUUIDCreateString(nil, uuid) as String
    }
}

extension CGRect {
    /// Zero for a null rect, which `intersection` returns when two frames do not overlap at all —
    /// `CGRect.null` has an infinite size, so its `width * height` is not a number you can compare.
    ///
    /// Module-wide rather than per-file: four places pick "the display a window is mostly on" this
    /// way, and three private copies of the same two lines is three chances for one of them to
    /// answer differently.
    var area: CGFloat { isNull || isEmpty ? 0 : width * height }
}
