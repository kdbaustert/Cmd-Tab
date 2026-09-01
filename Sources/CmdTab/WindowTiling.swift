import SwiftUI
import AppKit
import ApplicationServices
import CoreGraphics

// Window tiling: global hotkeys that snap the focused window to a half, a corner, the whole screen
// or the centre, whether or not the switcher is open.
//
// Ordinary global chords, matched when nothing is open: they act on whatever window the user is
// looking at, not on anything the switcher has selected.

/// One thing a global window chord can do.
///
/// It began as "an arrangement the focused window can be snapped to", and the name still says so,
/// but three families have since joined that do not resize anything: the display and Desktop moves,
/// the four nudges, and — since focus and swap arrived — two that do not even act on geometry alone.
/// They live here rather than in a store of their own because everything *around* a binding is the
/// same work whatever the binding does: persistence that can tell "cleared" from "never set", a
/// recorder, cross-store conflict detection, the per-app `neverTile` guard and the Overview. A
/// parallel enum would have duplicated all of it to express one extra verb.
enum WindowArrangement: String, CaseIterable, Identifiable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case leftThird, centerThird, rightThird
    case topThird, bottomThird
    case leftTwoThirds, rightTwoThirds
    case topLeft, topRight, bottomLeft, bottomRight
    case maximize, maximizeHeight, maximizeWidth, almostMaximize, center, restore
    case larger, smaller
    case growLeft, growRight, growUp, growDown
    case shrinkLeft, shrinkRight, shrinkUp, shrinkDown
    case nudgeLeft, nudgeRight, nudgeUp, nudgeDown
    case previousDisplay, nextDisplay
    case display1, display2, display3, display4
    case previousDesktop, nextDesktop
    case focusLeft, focusRight, focusUp, focusDown
    case swapLeft, swapRight, swapUp, swapDown

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
        case .topThird: return "Top third"
        case .bottomThird: return "Bottom third"
        case .leftTwoThirds: return "Left two-thirds"
        case .rightTwoThirds: return "Right two-thirds"
        case .maximize: return "Maximize"
        case .maximizeHeight: return "Maximize height"
        case .maximizeWidth: return "Maximize width"
        case .almostMaximize: return "Almost maximize"
        case .center: return "Center"
        case .restore: return "Restore previous size"
        case .larger: return "Make larger"
        case .smaller: return "Make smaller"
        case .growLeft: return "Grow left edge"
        case .growRight: return "Grow right edge"
        case .growUp: return "Grow top edge"
        case .growDown: return "Grow bottom edge"
        case .shrinkLeft: return "Shrink left edge"
        case .shrinkRight: return "Shrink right edge"
        case .shrinkUp: return "Shrink top edge"
        case .shrinkDown: return "Shrink bottom edge"
        case .nudgeLeft: return "Nudge left"
        case .nudgeRight: return "Nudge right"
        case .nudgeUp: return "Nudge up"
        case .nudgeDown: return "Nudge down"
        case .previousDisplay: return "Move to previous display"
        case .nextDisplay: return "Move to next display"
        // Numbered the way the tiles' own display badges are — both count `NSScreen.screens`, so
        // "move to display 2" names the display a window tile already labels 2.
        case .display1: return "Move to display 1"
        case .display2: return "Move to display 2"
        case .display3: return "Move to display 3"
        case .display4: return "Move to display 4"
        case .previousDesktop: return "Move to previous desktop"
        case .nextDesktop: return "Move to next desktop"
        case .focusLeft: return "Focus window to the left"
        case .focusRight: return "Focus window to the right"
        case .focusUp: return "Focus window above"
        case .focusDown: return "Focus window below"
        case .swapLeft: return "Swap with window to the left"
        case .swapRight: return "Swap with window to the right"
        case .swapUp: return "Swap with window above"
        case .swapDown: return "Swap with window below"
        }
    }

    /// Defaults sit on ⌃⌘, which macOS itself leaves almost entirely free. Pre-filled but inert —
    /// nothing is claimed until tiling is switched on, so an install that never wants this never
    /// has a global chord taken from it.
    ///
    /// **nil means shipped unbound**, which is a different statement from every other absence in
    /// this file: `WindowTilingBindings.load` reads a *missing stored key* as "this install predates
    /// the binding" and takes the default, so an arrangement with no default is one that stays
    /// unbound until someone records a chord for it. Three families are in that state and each for
    /// the same reason — there is no key left that means them.
    ///
    /// The arrow space is exhausted. ⌃⌘-arrow is the halves, ⌃⇧⌘-arrow the display moves and
    /// ⌃⌥⌘-arrow the Desktop moves, which leaves the four-modifier ⌃⌥⇧⌘ as the only free arrow
    /// combination on the machine — and claiming *that* on someone's behalf, for a feature they have
    /// not asked for, is the guess `GlobalActions` declines to make for exactly the same reason. So
    /// focus, swap and the nudges arrive as rows with a recorder and no chord, one click from being
    /// bound, and nobody who does not want them pays a keystroke for them.
    ///
    /// The two thirds pairs are unbound on a second argument as well: the width cycle already
    /// reaches them. Pressing ⌃⌘← twice gives the left two-thirds and three times the left third, so
    /// a direct binding is a convenience for anyone who wants one press and a known destination
    /// rather than a position in a cycle — worth offering, not worth a chord by default.
    var defaultHotkey: Hotkey? {
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
        // The one pair with a key everyone already knows: = grows and - shrinks, the convention
        // every application that has a zoom level uses, and both are free on ⌃⌘.
        case .larger: return Hotkey(keyCode: 24, modifierRaw: mods)  // =
        case .smaller: return Hotkey(keyCode: 27, modifierRaw: mods)  // -
        // Unbound — see the note above. Stated case by case rather than swept up in a `default`, so
        // adding an arrangement forces a decision about its chord instead of silently taking none.
        case .topThird, .bottomThird, .leftTwoThirds, .rightTwoThirds: return nil
        case .nudgeLeft, .nudgeRight, .nudgeUp, .nudgeDown: return nil
        case .focusLeft, .focusRight, .focusUp, .focusDown: return nil
        case .swapLeft, .swapRight, .swapUp, .swapDown: return nil
        // The three whole-window variants. ⌃⌘↩ is maximize and there is no second key that reads as
        // "maximize, but only this way" — so they arrive as rows with a recorder, and reachable by
        // URL without spending a chord at all.
        case .maximizeHeight, .maximizeWidth, .almostMaximize: return nil
        // Eight rows, and the arrow space they would want is the one ⌃⌘/⌃⇧⌘/⌃⌥⌘ have already taken
        // three times over. `larger`/`smaller` on ⌃⌘=/− are the two-edge version of these and are
        // bound; the per-edge ones are for anyone who wants to tune one edge against its neighbour.
        case .growLeft, .growRight, .growUp, .growDown: return nil
        case .shrinkLeft, .shrinkRight, .shrinkUp, .shrinkDown: return nil
        // Absolute display targets. Unbound because how many of them *mean* anything depends on how
        // many displays are plugged in — see `SettingsWindows.displayTargetGroup`, which shows only
        // the rows that name a display that exists.
        case .display1, .display2, .display3, .display4: return nil
        // ⇧ on top of the halves' arrows: same key, "throw it further".
        case .previousDisplay:
            return Hotkey(
                keyCode: 123, modifierRaw: CGEventFlags(rawValue: mods).union(.maskShift).rawValue)
        case .nextDisplay:
            return Hotkey(
                keyCode: 124, modifierRaw: CGEventFlags(rawValue: mods).union(.maskShift).rawValue)
        // ⌥ on top of the halves' arrows, one row along from the display moves' ⇧. Same key again,
        // "throw it further still" — and ⌃⌥⌘-arrow is free on macOS, which ⌃⌥-arrow is not.
        case .previousDesktop:
            return Hotkey(
                keyCode: 123,
                modifierRaw: CGEventFlags(rawValue: mods).union(.maskAlternate).rawValue)
        case .nextDesktop:
            return Hotkey(
                keyCode: 124,
                modifierRaw: CGEventFlags(rawValue: mods).union(.maskAlternate).rawValue)
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

    /// The display this sends the window to outright, 0-based, or nil if it names no display.
    ///
    /// The relative pair above answers "one along from here", which is the right verb on two
    /// displays and a guess on three: reaching the left-hand monitor from the right-hand one means
    /// counting, and counting wrong means the window is on the third screen instead. This names the
    /// destination, so it is the same press wherever the window starts.
    ///
    /// Numbered against `NSScreen.screens`, which is what `WindowTiler.visibleAreas()` is built from
    /// and what the tiles' display badges count — so the number here, the number on the badge and
    /// the index the move lands on are one number rather than three that happen to agree.
    ///
    /// Four of them. A fifth display is a real thing and this would not reach it, which is the cost
    /// of the raw values being a fixed grammar; four covers what a desk plausibly has, and the
    /// relative moves still walk to anything beyond it.
    var displayIndex: Int? {
        switch self {
        case .display1: return 0
        case .display2: return 1
        case .display3: return 2
        case .display4: return 3
        default: return nil
        }
    }

    /// Which edge this moves and which way, or nil if it does not resize by an edge.
    ///
    /// The direction names the *edge*, and the sign says whether that edge moves outward (grow) or
    /// inward (shrink) — so `growLeft` widens the window leftwards while its right edge stays put.
    /// That is the whole difference from `larger`/`smaller`, which move both edges at once around
    /// the window's centre: those keep the window where it is and change its size, these change one
    /// boundary and leave the other three alone, which is what tuning a tile against its neighbour
    /// actually needs.
    var edgeStep: (edge: WindowDirection, sign: CGFloat)? {
        switch self {
        case .growLeft: return (.left, 1)
        case .growRight: return (.right, 1)
        case .growUp: return (.up, 1)
        case .growDown: return (.down, 1)
        case .shrinkLeft: return (.left, -1)
        case .shrinkRight: return (.right, -1)
        case .shrinkUp: return (.up, -1)
        case .shrinkDown: return (.down, -1)
        default: return nil
        }
    }

    /// How far this moves a window between Desktops (Spaces), or nil if it does not.
    var desktopStep: Int? {
        switch self {
        case .previousDesktop: return -1
        case .nextDesktop: return 1
        default: return nil
        }
    }

    /// Which way this moves *focus*, or nil if it does not move focus.
    var focusStep: WindowDirection? {
        switch self {
        case .focusLeft: return .left
        case .focusRight: return .right
        case .focusUp: return .up
        case .focusDown: return .down
        default: return nil
        }
    }

    /// Which way this exchanges the focused window with its neighbour, or nil if it does not.
    var swapStep: WindowDirection? {
        switch self {
        case .swapLeft: return .left
        case .swapRight: return .right
        case .swapUp: return .up
        case .swapDown: return .down
        default: return nil
        }
    }

    /// Which way this nudges the window, or nil if it does not nudge.
    var nudgeStep: WindowDirection? {
        switch self {
        case .nudgeLeft: return .left
        case .nudgeRight: return .right
        case .nudgeUp: return .up
        case .nudgeDown: return .down
        default: return nil
        }
    }

    /// How this changes the window's size, as a multiple of `sizeStepFraction`, or nil.
    var sizeStep: CGFloat? {
        switch self {
        case .larger: return 1
        case .smaller: return -1
        default: return nil
        }
    }

    /// How far one `larger`, `smaller` or nudge press moves things, as a fraction of the display.
    ///
    /// Measured against the screen rather than the window, which is what makes a press feel the same
    /// size whatever it is aimed at: five per cent of a 200pt palette is two points, and a chord that
    /// visibly does nothing on small windows reads as broken. It also means the step is the same
    /// distance in both directions, where a percentage of the window shrinks by less than it grew.
    ///
    /// A twentieth: twenty presses cross the screen, four take a window from half to nearly full.
    static let sizeStepFraction: CGFloat = 0.05

    /// Whether this sends the window somewhere else rather than resizing it where it is.
    ///
    /// Two families now, and the note that used to sit here said the Desktop half could not be
    /// built. That was true of every route it named — the SkyLight calls are gated on window
    /// ownership and silently ignore a window this process does not own, which is re-measured in
    /// `SpaceMover`'s header. It was not true of the problem. `DesktopMover` performs the gesture a
    /// person performs, and that works; its header records the three cheaper routes that do not.
    ///
    /// The moves are *not* gated on the tiling switch: they take nothing away from the window's own
    /// layout, so "I don't want Cmd-Tab resizing my windows" is not a reason to lose them.
    /// Everything else is tiling proper, off until asked for. See
    /// `WindowTilingBindings.arrangement(code:flags:)`, which is where that split is enforced. The
    /// Desktop moves carry a second switch of their own on top — see `desktopMoves` there.
    var isMove: Bool { displayStep != nil || desktopStep != nil || displayIndex != nil }

    /// Whether this carries the window to another display, however it names the destination.
    ///
    /// One predicate for the relative pair and the four absolute targets, so the pointer warp and
    /// the "this is a move, not a tile" rules cannot end up applying to one and not the other.
    var movesAcrossDisplays: Bool { displayStep != nil || displayIndex != nil }

    /// Whether this only moves the keyboard focus, changing no window's geometry at all.
    var isFocus: Bool { focusStep != nil }

    /// Whether the tiling switch governs this arrangement. See `ungated` for the argument.
    ///
    /// A computed property rather than a lookup in `ungated`, because it is asked on the event-tap
    /// callback for every keystroke on the machine — see `WindowTilingBindings.fires`.
    var isUngated: Bool { isMove || isFocus }

    /// The moves, in the order the Windows tab lists them.
    static let moves: [WindowArrangement] = allCases.filter(\.isMove)

    /// The focus chords, in the order the Windows tab lists them.
    static let focusMoves: [WindowArrangement] = allCases.filter(\.isFocus)

    /// The swaps, likewise.
    static let swaps: [WindowArrangement] = allCases.filter { $0.swapStep != nil }

    /// The nudges, likewise.
    static let nudges: [WindowArrangement] = allCases.filter { $0.nudgeStep != nil }

    /// The eight per-edge resizes, in declared order — grow before shrink, and each in the order
    /// the arrows read.
    static let edgeResizes: [WindowArrangement] = allCases.filter { $0.edgeStep != nil }

    /// The absolute display targets, in display order.
    static let displayTargets: [WindowArrangement] = allCases.filter { $0.displayIndex != nil }

    /// Everything the tiling switch does **not** govern.
    ///
    /// Two families, on one argument: neither resizes anything. A move carries a window to another
    /// display or Desktop at exactly the size it already had, and a focus chord touches no window's
    /// frame whatsoever — so "I don't want Cmd-Tab resizing my windows" is not a reason to lose
    /// either, and a chord that silently did nothing because of a checkbox captioned about tiling is
    /// the failure this split exists to avoid.
    ///
    /// A **swap** is deliberately on the other side of the line. It moves two windows into each
    /// other's frames, which is a layout change however you describe it, so it waits on the switch
    /// with the rest of the tiler.
    static let ungated: [WindowArrangement] = allCases.filter(\.isUngated)

    /// Everything gated on the tiling switch.
    static let tilingArrangements: [WindowArrangement] = allCases.filter { !$0.isUngated }

    /// The arrangements a window can be given the moment it opens (`AppRule.launchArrangement`).
    ///
    /// The display moves are excluded because they are relative — "one display along from where it
    /// is" is not a placement for a window that has only just appeared. `.restore` goes too: its
    /// whole definition is the frame the window had before it was first tiled, and a window on its
    /// first frame has no such history, so it would silently do nothing.
    ///
    /// The nudges, the two size steps and the swaps go for the first of those reasons: every one of
    /// them is defined against where the window already is, and a window that has only just appeared
    /// is wherever its app put it — so "a little bigger than that" is not a placement anyone can
    /// have meant. A swap has a second disqualification on top, which is that it needs a neighbour
    /// to swap with and a launching window has no established place among its neighbours yet.
    static let launchable: [WindowArrangement] = tilingArrangements.filter {
        $0 != .restore && $0.sizeStep == nil && $0.nudgeStep == nil && $0.swapStep == nil
            && $0.edgeStep == nil
    }

    /// Whether a gap applies. Only the arrangements that *tile* — the ones whose frame is a
    /// fraction of the screen — take one. `.center` keeps the window's own size and `.restore` puts
    /// back a frame the user chose themselves, so insetting either would be Cmd-Tab second-guessing
    /// a size it did not pick; the moves change no geometry at all.
    ///
    /// The nudges and the two size steps join `.center` on the same reasoning, and it is worth
    /// spelling out because the opposite looks plausible: they *do* resize and reposition, so a gap
    /// could be applied — but the size they produce is the one the user arrived at by pressing the
    /// key, not a fraction of the screen this app chose. Insetting it would mean every press of
    /// "make larger" grew the window and then quietly took some of it back, and holding the key
    /// would walk the window off its own anchor a gap at a time.
    var takesGap: Bool {
        switch self {
        case .center, .restore, .previousDisplay, .nextDisplay, .previousDesktop,
            .nextDesktop, .display1, .display2, .display3, .display4:
            return false
        // The two half-maximizes keep one axis of the window exactly as the user left it, and
        // `TilingGap.inset` insets all four edges — so a gap would quietly move the two edges this
        // arrangement promised not to touch. `.center` is excluded for the same sentence.
        //
        // `almostMaximize` is excluded on the opposite argument: its margin *is* the point of it, so
        // a gap on top would inset a frame that has already been inset and make the setting mean
        // two different things depending on which key produced the window.
        case .maximizeHeight, .maximizeWidth, .almostMaximize:
            return false
        default:
            return sizeStep == nil && nudgeStep == nil && focusStep == nil && swapStep == nil
                && edgeStep == nil
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
        // The thirds turned on their side: full width, a third of the height. Written as
        // `maxY - height` rather than `minY + 2 * height` for the trailing one, exactly as the right
        // third is, so it lands flush against the bottom edge whatever the division rounds to.
        case .topThird:
            return CGRect(x: area.minX, y: area.minY, width: area.width, height: area.height / 3)
        case .bottomThird:
            return CGRect(
                x: area.minX, y: area.maxY - area.height / 3,
                width: area.width, height: area.height / 3)
        case .leftTwoThirds:
            return CGRect(
                x: area.minX, y: area.minY, width: area.width * 2 / 3, height: area.height)
        case .rightTwoThirds:
            return CGRect(
                x: area.maxX - area.width * 2 / 3, y: area.minY,
                width: area.width * 2 / 3, height: area.height)
        case .larger, .smaller:
            return resized(current, in: area)
        case .growLeft, .growRight, .growUp, .growDown,
            .shrinkLeft, .shrinkRight, .shrinkUp, .shrinkDown:
            return edgeResized(current, in: area)
        case .nudgeLeft, .nudgeRight, .nudgeUp, .nudgeDown:
            return nudged(current, in: area)
        case .maximize:
            return area
        // Full height at the width the window already has, and the mirror of it. The preserved axis
        // is copied straight from `current` rather than recomputed, which is what makes pressing
        // both in turn equal `maximize` exactly.
        case .maximizeHeight:
            return CGRect(x: current.minX, y: area.minY, width: current.width, height: area.height)
        case .maximizeWidth:
            return CGRect(x: area.minX, y: current.minY, width: area.width, height: current.height)
        // Maximize with the screen left visible around it — the size you want for one window you
        // are working in without losing the fact that there is a desktop behind it. Centred, so the
        // margin is the same on all four sides.
        case .almostMaximize:
            let size = CGSize(
                width: area.width * Self.almostMaximizeFraction,
                height: area.height * Self.almostMaximizeFraction)
            return CGRect(
                x: area.minX + (area.width - size.width) / 2,
                y: area.minY + (area.height - size.height) / 2,
                width: size.width, height: size.height)
        case .center:
            // Keeps the window's size — centring is a move, not a resize — and clamps so a window
            // bigger than the screen still lands with its top-left on it rather than off the edge.
            let size = CGSize(
                width: min(current.width, area.width), height: min(current.height, area.height))
            return CGRect(
                x: area.minX + (area.width - size.width) / 2,
                y: area.minY + (area.height - size.height) / 2,
                width: size.width, height: size.height)
        // The absolute display targets join the relative pair: their destination is another
        // display's area, which `apply` substitutes, not a rectangle on this one.
        case .restore, .previousDisplay, .nextDisplay, .previousDesktop, .nextDesktop,
            .display1, .display2, .display3, .display4:
            return nil
        // Focus moves no window, and a swap needs a second window this function has never been told
        // about. Both are dispatched before the tiler is ever reached — see
        // `SwitcherController.applyTiling` — and answer nil here for the same reason `.restore` does:
        // there is no frame computable from this screen alone.
        case .focusLeft, .focusRight, .focusUp, .focusDown,
            .swapLeft, .swapRight, .swapUp, .swapDown:
            return nil
        }
    }

    /// `current` grown or shrunk by one step, anchored on its own centre and held inside `area`.
    ///
    /// Anchored on the centre rather than the top-left, because the alternative is a window that
    /// walks: growing from a fixed origin pushes the far edge out and shrinking pulls it back, so a
    /// press of each does not return you to where you started. From the centre it does.
    ///
    /// Then clamped, which does two things at once — a window grown past the screen stops at the
    /// screen, and one grown near an edge is pushed back on rather than left hanging off it. The
    /// floor is what stops repeated shrinking from ending at a window nobody can grab: at the point
    /// where a further press would take it under `minimumSize`, the press does nothing instead.
    private func resized(_ current: CGRect, in area: CGRect) -> CGRect? {
        guard let step = sizeStep else { return nil }
        let dx = area.width * Self.sizeStepFraction * step
        let dy = area.height * Self.sizeStepFraction * step
        let size = CGSize(
            width: min(current.width + dx, area.width),
            height: min(current.height + dy, area.height))
        guard size.width >= Self.minimumSize, size.height >= Self.minimumSize else { return nil }
        let grown = CGRect(
            x: current.midX - size.width / 2, y: current.midY - size.height / 2,
            width: size.width, height: size.height)
        return WindowTiler.clamp(grown, into: area)
    }

    /// `current` with one edge moved by a step, the opposite edge pinned, held inside `area`.
    ///
    /// Where `resized` moves both edges around the centre, this moves exactly one — so a window
    /// tiled to the left half can have its right edge pushed out over the neighbour without its
    /// left edge leaving the screen edge it was snapped to.
    ///
    /// Two guards, and they are the two ways this can go wrong. Growing is clamped to `area`, so an
    /// edge pushed repeatedly stops at the screen instead of walking the window off it — the same
    /// argument `nudged` makes for itself. Shrinking stops at `minimumSize`, so a chord held down
    /// cannot end at a window too small to grab; at that point the press does nothing rather than
    /// producing a sliver.
    ///
    /// `WindowTiler.clamp` is deliberately *not* used: it preserves the size and slides the frame
    /// back onto the screen, which for a one-edge resize would move the edge that was supposed to
    /// stay pinned. Clamping the edge itself is what keeps the promise.
    private func edgeResized(_ current: CGRect, in area: CGRect) -> CGRect? {
        guard let (edge, sign) = edgeStep else { return nil }
        let dx = area.width * Self.sizeStepFraction * sign
        let dy = area.height * Self.sizeStepFraction * sign
        var frame = current
        switch edge {
        case .left:
            // Top-left origin: the left edge grows by moving to a smaller x, and the width has to
            // grow with it or the whole window would slide instead of stretching.
            let minX = min(max(current.minX - dx, area.minX), current.maxX - Self.minimumSize)
            frame = CGRect(
                x: minX, y: current.minY, width: current.maxX - minX, height: current.height)
        case .right:
            let maxX = max(min(current.maxX + dx, area.maxX), current.minX + Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: current.minY, width: maxX - current.minX,
                height: current.height)
        case .up:
            let minY = min(max(current.minY - dy, area.minY), current.maxY - Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: minY, width: current.width, height: current.maxY - minY)
        case .down:
            let maxY = max(min(current.maxY + dy, area.maxY), current.minY + Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: current.minY, width: current.width,
                height: maxY - current.minY)
        }
        // An edge already against the screen (growing) or already at the floor (shrinking) leaves
        // the frame untouched. Returning nil rather than the identity means `apply` writes nothing
        // at all, which is one fewer Accessibility round-trip per press of a held-down chord.
        return frame == current ? nil : frame
    }

    /// How much of the usable area `almostMaximize` fills. Nine tenths, centred: enough of the
    /// screen left showing at each edge to see what is behind, without the window reading as merely
    /// badly maximized.
    static let almostMaximizeFraction: CGFloat = 0.9

    /// `current` moved one step in the nudge's direction, keeping its size, held inside `area`.
    ///
    /// Clamped rather than allowed off the edge, which is the one debatable call here: someone may
    /// genuinely want a window half off screen, and a plain drag lets them have it. A *chord* is a
    /// different thing — it is pressed repeatedly and without looking, so an unclamped nudge held
    /// down walks a window off the display and leaves no titlebar to drag it back with. The gesture
    /// that can lose a window should be the one where you can see it going.
    private func nudged(_ current: CGRect, in area: CGRect) -> CGRect? {
        guard let direction = nudgeStep else { return nil }
        let dx = area.width * Self.sizeStepFraction
        let dy = area.height * Self.sizeStepFraction
        let moved: CGRect
        switch direction {
        case .left: moved = current.offsetBy(dx: -dx, dy: 0)
        case .right: moved = current.offsetBy(dx: dx, dy: 0)
        // Top-left origin: "up" is toward the smaller y. See `WindowDirection.isAhead`.
        case .up: moved = current.offsetBy(dx: 0, dy: -dy)
        case .down: moved = current.offsetBy(dx: 0, dy: dy)
        }
        return WindowTiler.clamp(moved, into: area)
    }

    /// The smallest a window may be shrunk to. Roughly a titlebar's worth in each direction — enough
    /// to still carry the traffic lights and be grabbed with a cursor.
    private static let minimumSize: CGFloat = 120
}

/// Insets a tiled frame so windows do not touch the screen edges or each other.
///
/// One number does both jobs, the way every window manager that has gaps does it: the full gap at
/// a screen edge, half of it at a seam — so two windows sharing a seam end up exactly one gap
/// apart, the same distance as each is from the outside. Which edges are which is read off the
/// frame itself rather than tracked per arrangement: an edge sitting on the usable area's boundary
/// is an outside edge, anything else meets another tile.
enum TilingGap {
    /// The widest gap the settings slider offers. Generous on purpose — on a large display a gap
    /// this wide is a deliberate look rather than a mistake — and safe at the top end because
    /// `inset` refuses outright any gap that would eat more than three quarters of its tile, so the
    /// extreme of the slider degrades to "no gap" on a tile too small for it instead of inverting.
    static let maximum: CGFloat = 100

    /// A point of slack when deciding whether an edge is on the boundary. The thirds are computed
    /// by division and land a hair off the exact edge — `area.maxX - area.width / 3` is not bitwise
    /// `area.minX + 2 * area.width / 3` — and without the slack a right third would take an inner
    /// gap on the side that is actually against the screen.
    private static let epsilon: CGFloat = 1

    /// `gap` held inside the range the settings offer, so a hand-edited defaults entry cannot
    /// produce a window narrower than the tiling maths expects.
    static func clamp(_ gap: CGFloat) -> CGFloat { min(max(gap, 0), maximum) }

    static func inset(_ frame: CGRect, in area: CGRect, gap: CGFloat) -> CGRect {
        guard gap > 0 else { return frame }
        // A tile edge lying against the screen takes the whole gap; an edge where two tiles meet
        // takes half of it, so the seam between a pair of tiles adds up to one gap's worth of space
        // and neighbours sit exactly as far apart as each does from the outside.
        let seam = gap / 2
        let left = frame.minX - area.minX <= epsilon ? gap : seam
        let right = area.maxX - frame.maxX <= epsilon ? gap : seam
        let top = frame.minY - area.minY <= epsilon ? gap : seam
        let bottom = area.maxY - frame.maxY <= epsilon ? gap : seam

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
    /// Whether the two Desktop moves fire. Off by default, and the only *move* with a switch in
    /// front of it.
    ///
    /// The display moves are pure Accessibility geometry — a frame written to a window, invisible
    /// and instant — so shipping them live costs nothing. A Desktop move is not that. There is no
    /// API for it (see `DesktopMover`), so it performs the gesture instead: it takes the pointer,
    /// opens Mission Control for a moment and drops the window on a thumbnail. Claiming a
    /// system-wide chord that does *that* on someone's behalf, on an update they did not ask for,
    /// is not a guess worth making — the same reasoning `GlobalActions` gives for shipping no
    /// default bindings at all. The chords are pre-filled so turning it on is one click, and inert
    /// until then.
    var desktopMoves: Bool = false
    /// Whether a Desktop move takes you with it. On by default — the whole reason to throw a window
    /// to the next Desktop is usually to go and work on it there, and a move you do not follow
    /// leaves you looking at the space the window just vacated.
    ///
    /// Its own setting rather than always-on because the opposite is a real workflow: parking
    /// something out of the way — a build log, a chat window — is a *throw*, and following it would
    /// undo the point of the gesture. Only meaningful while `desktopMoves` is on.
    var followsDesktopMove: Bool = true
    /// Whether a *display* move warps the pointer onto the window it just carried across.
    ///
    /// The Desktop equivalent above is on by default and this one is off, which looks inconsistent
    /// until you notice they are answering different questions. Following a Desktop move is about
    /// *what you can see*: without it you are left looking at the space the window has just left, so
    /// the default has to be the one where the gesture has a visible result. Every display is on
    /// screen at once, so a display move is already visible wherever the pointer is — this setting
    /// only decides whether the cursor is moved for you, and moving someone's pointer is a liberty
    /// worth asking for. Off by default for the same reason `DesktopMover` is: this app takes the
    /// pointer only when told to.
    var pointerFollowsDisplayMove: Bool = false
    /// Put the windows back where they were the last time this set of displays was attached.
    ///
    /// Off by default, on the plainest possible argument: it moves windows the user did not ask it
    /// to move, at a moment they are not looking at the screen — a laptop being docked is usually a
    /// laptop being carried. Everything else in this app that rearranges something waits to be
    /// asked, and this one rearranges the most at once. See `DisplayLayouts`.
    var restoresLayoutOnDisplayChange: Bool = false
    /// Pixels of space left around a tiled window: the whole gap against a screen edge, half of it
    /// where two tiles meet. 0 keeps windows flush, which is what tiling has always done.
    var gap: CGFloat = 0
    var bindings: [WindowArrangement: Hotkey]

    /// `compactMap` rather than `map`: an arrangement with no `defaultHotkey` is one that ships
    /// unbound, and leaving it out of this table is what expresses that — `load()` then finds no
    /// stored chord and no default, and the row appears with a recorder and nothing in it.
    static let defaults = WindowTilingBindings(
        bindings: Dictionary(
            uniqueKeysWithValues: WindowArrangement.allCases.compactMap { arrangement in
                arrangement.defaultHotkey.map { (arrangement, $0) }
            }))

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

    /// Whether `arrangement` can fire at all under the current switches, before any chord is
    /// considered.
    ///
    /// **The one definition of that question.** It used to be spelled out twice — once as the
    /// candidate list in `arrangement(code:flags:)` and once as the `active:` argument in
    /// `ShortcutAudit.entries` — and the two disagreed the moment the focus chords arrived: the
    /// matcher fires them with tiling switched off, and the audit reported them inert, so the
    /// Overview stopped seeing collisions involving a focus chord on any install that had tiling
    /// off. That is precisely the failure the Overview exists to catch, so the rule now lives in one
    /// place and both callers read it.
    ///
    /// With tiling switched off the geometry arrangements are skipped but the **moves** and the
    /// **focus** chords still match. The switch is about Cmd-Tab resizing windows; sending a window
    /// to the next display or Desktop changes no layout, moving focus changes no window at all, and
    /// gating either behind a checkbox captioned about tiling made a bound chord do nothing with no
    /// visible cause. The cost is that those chords are claimed system-wide as soon as they are
    /// bound, tiling on or off — which is what the pane says.
    ///
    /// The Desktop moves answer to their own switch on top, so with it off their chords go back to
    /// whatever app wants them rather than being claimed and doing nothing.
    func fires(_ arrangement: WindowArrangement) -> Bool {
        if arrangement.desktopStep != nil { return desktopMoves }
        return isEnabled || arrangement.isUngated
    }

    /// The arrangement a keypress fires, if any.
    ///
    /// Iterates in declared case order so two arrangements bound to the same chord always resolve
    /// the same way rather than depending on dictionary ordering. Exact modifier match, so ⌃⌘←
    /// stays distinct from ⌃⌥⌘←.
    ///
    /// One pass, allocating nothing. This runs inside the event-tap callback for **every keystroke
    /// on the machine**, and the `filter` it used to build first allocated an array of arrangements
    /// each time — cheap, but it grew with the enum, and the enum has just doubled.
    func arrangement(code: Int, flags: CGEventFlags) -> WindowArrangement? {
        let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return WindowArrangement.allCases.first {
            guard fires($0), let hotkey = bindings[$0], hotkey.isUsableGlobally else { return false }
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
        static let desktopMoves = "windowTilingDesktopMoves"
        static let followsDesktopMove = "windowTilingFollowsDesktopMove"
        static let pointerFollowsDisplay = "windowTilingPointerFollowsDisplay"
        static let gap = "windowTilingGap"
        /// The four per-edge gaps, from the version that split this setting in four. Read once to
        /// migrate back to a single value, never written. See `load`.
        static let gapTop = "windowTilingGapTop"
        static let gapBottom = "windowTilingGapBottom"
        static let gapLeft = "windowTilingGapLeft"
        static let gapRight = "windowTilingGapRight"
        static let dotHex = "windowSnapDotColorHex"
        static let outlineHex = "windowSnapOutlineColorHex"
        static let landingHex = "windowSnapLandingColorHex"
        static let mouseDrag = "windowMouseDragEnabled"
        static let mouseMove = "windowMouseDragMoveModifiers"
        static let mouseResize = "windowMouseDragResizeModifiers"
        static let focusFollows = "focusFollowsMouseEnabled"
        static let focusFollowsDelay = "focusFollowsMouseDelay"
        static let restoreOnDisplayChange = "restoreLayoutOnDisplayChange"
    }

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [
        Key.enabled, Key.cycleWidths, Key.shortcuts, Key.dragSnap, Key.desktopMoves,
        Key.followsDesktopMove, Key.pointerFollowsDisplay,
        Key.gap, Key.gapTop, Key.gapBottom, Key.gapLeft, Key.gapRight,
        Key.dotHex, Key.outlineHex, Key.landingHex,
        Key.mouseDrag, Key.mouseMove, Key.mouseResize,
        Key.focusFollows, Key.focusFollowsDelay, Key.restoreOnDisplayChange,
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
    /// This store's claim on `KeyRecorder`.
    private var recordingToken: Int?

    var onChange: ((WindowTilingBindings) -> Void)?
    /// Separate from `onChange` because the two go to different taps — the key tap takes the
    /// bindings, the mouse tap takes these — and pushing one through the other's channel would
    /// rebuild a tap on every unrelated edit.
    var onMouseDragChange: ((MouseDragSettings) -> Void)?
    /// Same arrangement again, and a third channel rather than a second field on `MouseDragSettings`:
    /// that value is read by a live `CGEventTap` which is torn down and rebuilt when it changes, and
    /// this one is read by an `NSEvent` monitor that is not.
    var onFocusFollowsChange: ((FocusFollowsMouseSettings) -> Void)?

    /// Modifier-drag to move or resize. Its own value rather than a field on
    /// `WindowTilingBindings`: the bindings struct is the snapshot the *key* tap reads on every
    /// keystroke, and this is only ever read by the mouse tap.
    @Published private(set) var mouseDrag = MouseDragSettings()

    /// Focus follows the pointer. Its own value and its own channel for the same reason `mouseDrag`
    /// is separate from the bindings: it is read by an object the key tap never touches, and pushing
    /// it through the bindings' callback would rebuild the keyboard tap on every unrelated edit.
    @Published private(set) var focusFollows = FocusFollowsMouseSettings()

    var focusFollowsMouse: Bool {
        get { focusFollows.isEnabled }
        set {
            guard newValue != focusFollows.isEnabled else { return }
            focusFollows.isEnabled = newValue
            persist()
        }
    }

    var focusFollowsMouseDelay: Double {
        get { focusFollows.delay }
        set {
            let clamped = min(
                max(newValue, FocusFollowsMouseSettings.minimumDelay),
                FocusFollowsMouseSettings.maximumDelay)
            guard clamped != focusFollows.delay else { return }
            focusFollows.delay = clamped
            persist()
        }
    }

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

    // The three colours the snap overlays are drawn in. Kept here rather than in `AppearanceStore`,
    // which is about the switcher panel: these are Windows-tab settings that only exist while a snap
    // gesture is in flight.
    //
    // Three settings rather than one, because the overlays say three different things — which
    // window, where it will land, and what the direction is measured from — and someone who wants to
    // tell them apart at a glance needs them to differ. They share a default so the untouched case
    // still reads as one system.

    /// The border drawn around the window a gesture is about to act on.
    @Published var outlineColor: Color = SnapAppearance.defaultOutline {
        didSet {
            guard outlineColor != oldValue, !isReloading else { return }
            persist(outlineColor, forKey: Key.outlineHex)
            SnapAppearance.shared.apply(outline: outlineColor)
        }
    }

    /// The block showing where the window will land. Drawn as a full-strength border with the fill
    /// washed to `SnapAppearance.blockAlpha`, so one colour covers both.
    @Published var landingColor: Color = SnapAppearance.defaultLanding {
        didSet {
            guard landingColor != oldValue, !isReloading else { return }
            persist(landingColor, forKey: Key.landingHex)
            SnapAppearance.shared.apply(landing: landingColor)
        }
    }

    /// The anchor dot the hold-and-point gesture measures its direction from.
    @Published var dotColor: Color = SnapAppearance.defaultDot {
        didSet {
            guard dotColor != oldValue, !isReloading else { return }
            persist(dotColor, forKey: Key.dotHex)
            SnapAppearance.shared.apply(dot: dotColor)
        }
    }

    /// Writes a colour as hex, skipping the write when it has none.
    ///
    /// The macOS colour panel can hand back a pattern or catalog colour, which has no RGB to encode.
    /// The stored value is then left exactly as it was rather than overwritten with a substitute —
    /// a silently-wrong colour on the next launch is worse than one that did not take.
    private func persist(_ color: Color, forKey key: String) {
        guard let hex = color.hexString else { return }
        UserDefaults.standard.set(hex, forKey: key)
    }

    private static func loadColor(_ key: String, default fallback: Color) -> Color {
        UserDefaults.standard.string(forKey: key).flatMap(Color.init(hex:)) ?? fallback
    }

    var gap: CGFloat {
        get { tiling.gap }
        set {
            let clamped = TilingGap.clamp(newValue)
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

    var desktopMoves: Bool {
        get { tiling.desktopMoves }
        set {
            guard newValue != tiling.desktopMoves else { return }
            tiling.desktopMoves = newValue
            persist()
        }
    }

    var followsDesktopMove: Bool {
        get { tiling.followsDesktopMove }
        set {
            guard newValue != tiling.followsDesktopMove else { return }
            tiling.followsDesktopMove = newValue
            persist()
        }
    }

    var pointerFollowsDisplayMove: Bool {
        get { tiling.pointerFollowsDisplayMove }
        set {
            guard newValue != tiling.pointerFollowsDisplayMove else { return }
            tiling.pointerFollowsDisplayMove = newValue
            persist()
        }
    }

    var restoresLayoutOnDisplayChange: Bool {
        get { tiling.restoresLayoutOnDisplayChange }
        set {
            guard newValue != tiling.restoresLayoutOnDisplayChange else { return }
            tiling.restoresLayoutOnDisplayChange = newValue
            persist()
        }
    }

    private init() {
        tiling = Self.load()
        mouseDrag = Self.loadMouseDrag()
        focusFollows = Self.loadFocusFollows()
        loadSnapColors()
    }

    /// Reads the three snap colours and pushes them into `SnapAppearance` in one go.
    ///
    /// The `didSet`s **do** run here, and the note that used to sit in this spot said the opposite.
    /// Swift skips property observers only for assignments written inside `init` itself; this is a
    /// *method* that `init` calls, on a `self` that is fully initialised by the time it can be
    /// called at all, so each assignment below fires its observer like any other. Verified rather
    /// than reasoned about — a three-line script assigning from `init` and again from a method
    /// called by `init` prints one `didSet`, not none.
    ///
    /// The note that used to end here said nothing goes wrong as a result. That is true of the
    /// `init` path, where the value assigned equals the one just read, and false of the reload
    /// path: after `resetAll()` the three keys are *absent*, `loadColor` falls through to the
    /// built-in default, and the observer writes that default back as though it had been chosen —
    /// re-creating keys that should have stayed absent and pinning this build's colours against
    /// any future change to them. `isReloading` is the same guard `BehaviorStore` carries, for the
    /// same reason. The single `apply` is kept: it is the one push guaranteed to happen, since an
    /// observer guarded on `!= oldValue` stays silent when the stored colour already equals the
    /// default, and it keeps the load and reload paths identical.
    private func loadSnapColors() {
        let outline = Self.loadColor(Key.outlineHex, default: SnapAppearance.defaultOutline)
        let landing = Self.loadColor(Key.landingHex, default: SnapAppearance.defaultLanding)
        let dot = Self.loadColor(Key.dotHex, default: SnapAppearance.defaultDot)
        isReloading = true
        outlineColor = outline
        landingColor = landing
        dotColor = dot
        isReloading = false
        SnapAppearance.shared.apply(outline: outline, landing: landing, dot: dot)
    }

    /// Suppresses the write half of the snap-colour observers while `loadSnapColors` runs. See
    /// that method.
    private var isReloading = false

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
        // Across kinds too, not just this store's own rows — see `KeyRecorder`.
        recordingToken = KeyRecorder.arm { [weak self] in self?.stopRecording() }
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
            let mods = Hotkey.flags(from: event.modifierFlags)
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
        if let recordingToken { KeyRecorder.disarmed(recordingToken) }
        recordingToken = nil
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
        focusFollows = Self.loadFocusFollows()
        loadSnapColors()
        onChange?(tiling)
        onMouseDragChange?(mouseDrag)
        onFocusFollowsChange?(focusFollows)
    }

    /// The two focus-follows keys. An absent delay takes the built-in default rather than zero, and
    /// a stored one is clamped on read — a hand-edited config asking for no delay at all would make
    /// every sweep of the pointer across the desk a focus change, which is the one setting of this
    /// value that is never what anyone wanted.
    private static func loadFocusFollows() -> FocusFollowsMouseSettings {
        let defaults = UserDefaults.standard
        var result = FocusFollowsMouseSettings()
        result.isEnabled = defaults.bool(forKey: Key.focusFollows)
        if defaults.object(forKey: Key.focusFollowsDelay) != nil {
            result.delay = min(
                max(defaults.double(forKey: Key.focusFollowsDelay),
                    FocusFollowsMouseSettings.minimumDelay),
                FocusFollowsMouseSettings.maximumDelay)
        }
        return result
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
        result.desktopMoves = defaults.bool(forKey: Key.desktopMoves)
        // Defaults to *true*, so absent has to be told from false — `bool(forKey:)` reports false
        // for both, which would silently ship the opposite of the documented default. Same shape as
        // `cycleWidths` above, and for the same reason.
        result.followsDesktopMove =
            defaults.object(forKey: Key.followsDesktopMove) != nil
            ? defaults.bool(forKey: Key.followsDesktopMove) : true
        // Defaults to false, so absent and false mean the same thing and `bool(forKey:)` answers
        // both correctly — no telling apart needed, unlike the two above it.
        result.pointerFollowsDisplayMove = defaults.bool(forKey: Key.pointerFollowsDisplay)
        result.restoresLayoutOnDisplayChange = defaults.bool(forKey: Key.restoreOnDisplayChange)
        // Absent means never set, which is 0 — `double(forKey:)` already reports 0 for a missing
        // key, so the two cases need no telling apart here.
        //
        // A setting made while the gap was four per-edge values collapses to the widest of them:
        // the gap is one number again, and the largest is the only choice that never tightens a
        // spacing someone had deliberately opened up. Those keys are read, never written — the
        // single value below is written on the first change, and it wins from then on.
        var gap = CGFloat(defaults.double(forKey: Key.gap))
        if defaults.object(forKey: Key.gap) == nil {
            let perEdge = [Key.gapTop, Key.gapBottom, Key.gapLeft, Key.gapRight]
                .compactMap { defaults.object(forKey: $0) as? Double }
            if let widest = perEdge.max() { gap = CGFloat(widest) }
        }
        result.gap = TilingGap.clamp(gap)
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
        defaults.set(focusFollows.isEnabled, forKey: Key.focusFollows)
        defaults.set(focusFollows.delay, forKey: Key.focusFollowsDelay)
        onFocusFollowsChange?(focusFollows)
        defaults.set(tiling.isEnabled, forKey: Key.enabled)
        defaults.set(tiling.cycleWidths, forKey: Key.cycleWidths)
        defaults.set(tiling.dragSnap, forKey: Key.dragSnap)
        defaults.set(tiling.desktopMoves, forKey: Key.desktopMoves)
        defaults.set(tiling.followsDesktopMove, forKey: Key.followsDesktopMove)
        defaults.set(tiling.pointerFollowsDisplayMove, forKey: Key.pointerFollowsDisplay)
        defaults.set(tiling.restoresLayoutOnDisplayChange, forKey: Key.restoreOnDisplayChange)
        defaults.set(Double(tiling.gap), forKey: Key.gap)
        // The four per-edge keys are deliberately not written back. They are a migration source
        // only — see `load()` — and left where they are, so a downgrade finds what it wrote.
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

    /// Which window an arrangement acts on.
    ///
    /// Absent means the app's frontmost window, which is right for the keyboard chords and the
    /// launch arrangement: both act on whatever the app itself considers current, and neither has a
    /// particular window in mind. Every *mouse* gesture names one, because each is pointed at a
    /// specific window and the focused one is not reliably it — the modifier-drag swallows its own
    /// mouse-down so the click never reaches the app, the hold-and-point gesture involves no click
    /// at all, and even the plain drag-to-edge can move a window of an already-frontmost app
    /// without changing which of its windows has focus. Handed a pid alone, the tiler re-resolved
    /// to the focused window and snapped the wrong one on any app with more than one window open.
    /// `@unchecked Sendable` because `.element` carries an `AXUIElement`, which is an opaque CF
    /// handle and so not checkable. Crossing onto the tiler's queue is exactly what this type is
    /// for: `resolve` runs the Accessibility walk there rather than on the main thread, which is the
    /// same rule every other Accessibility call in this app follows.
    enum Target: @unchecked Sendable {
        /// A window already resolved over Accessibility — the modifier-drag, which has been writing
        /// frames to this very element for the length of the gesture.
        case element(AXUIElement)
        /// The window whose frame matches these bounds. For a gesture that never moved the window,
        /// the frame it was pointed at is still its frame, and resolving here rather than at the call
        /// site keeps the Accessibility walk on this queue instead of the main thread.
        case bounds(CGRect)
    }

    /// The window `apply` should act on.
    ///
    /// Falls back to the frontmost window whenever there is nothing better: a bounds match can miss
    /// on hosts whose Accessibility frames drift from the window server's (Electron, Catalyst), and
    /// snapping nothing at all there would be a worse failure than the imprecision it replaces.
    private static func resolve(_ target: Target?, pid: pid_t) -> AXUIElement? {
        switch target {
        case .element(let window):
            return window
        case .bounds(let bounds):
            return AX.window(ofApplication: pid, matching: bounds)
                ?? AX.frontWindow(ofApplication: pid)
        case nil:
            return AX.frontWindow(ofApplication: pid)
        }
    }

    /// A window's frame carried from one display to another: the same fractional position, shrunk
    /// to fit if the destination is smaller, then clamped so it stays fully on it.
    ///
    /// One copy, called from both places that move a window across displays — `apply`'s
    /// `displayStep` branch, which is the ⌃⇧⌘-←/→ chord, and
    /// `SwitchTarget.moveWindow(acrossDisplays:)`, which is the in-switcher move. They were
    /// identical expressions written out twice, each with a comment promising it agreed with the
    /// other and neither covered by a test. The drift had already happened once: the shrink-to-fit
    /// had to be retrofitted into the switcher path after the chord already had it.
    ///
    /// `from` and `to` are *visible* areas, not full display frames — measuring against the full
    /// frame puts the window's top edge under the destination's menu bar.
    static func carried(_ frame: CGRect, from: CGRect, to: CGRect) -> CGRect {
        let size = CGSize(width: min(frame.width, to.width), height: min(frame.height, to.height))
        let relX = from.width > 0 ? (frame.minX - from.minX) / from.width : 0
        let relY = from.height > 0 ? (frame.minY - from.minY) / from.height : 0
        return CGRect(
            x: min(max(to.minX + relX * to.width, to.minX), max(to.minX, to.maxX - size.width)),
            y: min(max(to.minY + relY * to.height, to.minY), max(to.minY, to.maxY - size.height)),
            width: size.width, height: size.height)
    }

    /// `destination` overrides which display the arrangement is measured against.
    ///
    /// The three pointer gestures know the display the user was *shown* a preview on, and it is not
    /// always the one `homeDisplay` picks: a window grabbed near its right edge and nudged a little
    /// further right puts the cursor on the next display while the window's centre stays behind, so
    /// the preview painted one monitor and the drop tiled the other — with the gap inset computed
    /// against the wrong area too. Keyboard chords pass nothing and keep the `homeDisplay` answer;
    /// they have no cursor to consult.
    static func apply(
        _ arrangement: WindowArrangement, pid: pid_t, areas: [CGRect], cycleWidths: Bool,
        gap: CGFloat = 0, target: Target? = nil, destination: CGRect? = nil,
        warpsPointer: Bool = false
    ) {
        guard !areas.isEmpty else { return }
        queue.async {
            guard let window = resolve(target, pid: pid), let current = AX.frame(window)
            else { return }
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
            let area = destination ?? areas[home]

            let target: CGRect
            if let step = arrangement.displayStep {
                // A move, unlike a tile, is relative: without a display to count from there is no
                // "next" one, and counting from the fallback would throw the window off a display it
                // was never on.
                guard resolved != nil else { return }
                // `carried` is the shared arithmetic, and `SwitchTarget.moveWindow(acrossDisplays:)`
                // calls the same function — which is what actually keeps the promise that a window
                // thrown either way lands in the same place. Measured from `areas[home]` rather
                // than `area`: a move counts from the display the window is on, and `destination`
                // is a pointer gesture's answer, which this branch never has.
                guard areas.count > 1 else { return }
                let to = areas[((home + step) % areas.count + areas.count) % areas.count]
                target = carried(current, from: areas[home], to: to)
                // A move is not a tile: it must not consume the restore point, and the width cycle
                // has to start over on the new display.
                cycle = nil
            } else if let index = arrangement.displayIndex {
                // Same arithmetic as the relative move, and deliberately the same `carried` call —
                // a window thrown to display 2 has to land exactly where "next display" would have
                // put it when display 2 is the next one along.
                //
                // Two ways this is a no-op rather than a mistake: a display that is not plugged in
                // (the row is hidden in Settings, but a URL or a chord bound while it *was* plugged
                // in can still name it), and the window's own display, where the move has nothing to
                // do. Both return before anything is written, so the frame is untouched rather than
                // rewritten to the value it already had.
                guard resolved != nil, areas.indices.contains(index), index != home else { return }
                target = carried(current, from: areas[home], to: areas[index])
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
            //
            // One call rather than three, so tiling this app's own settings window takes a single
            // hop onto the main thread instead of three — see `AX.onOwningThread`.
            AX.setFrame(window, target, sizing: true, repositionAfterSizing: true)

            // Only the display moves offer this, and only when asked. Warped *after* the frame is
            // written rather than alongside it: the cursor is being sent to where the window now is,
            // and on the two hosts whose Accessibility writes land late it would otherwise be sent
            // to where the window was about to be.
            //
            // `CGWarpMouseCursorPosition` takes the global display space, which shares its origin
            // and its downward y with the Accessibility coordinates `target` is already in — so the
            // centre needs no flip. The same call, in the same space, that `DesktopMover` uses to
            // put the pointer on a window before it drags one.
            if warpsPointer, arrangement.movesAcrossDisplays {
                CGWarpMouseCursorPosition(CGPoint(x: target.midX, y: target.midY))
                // Without this the pointer is *drawn* at the new place while the window server keeps
                // feeding mouse deltas relative to the old one, so the next flick of the trackpad
                // snaps it back across the desk. Re-associating is what makes a warp stick.
                CGAssociateMouseAndMouseCursorPosition(1)
            }
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
        return clamp(saved, into: home)
    }

    /// Keeps a frame on its display. A restore point captured on a monitor that has since gone would
    /// otherwise come back proportionally further off a smaller screen, which is how "put it back"
    /// loses a window on a laptop.
    ///
    /// Internal for the same reason `reachable` is: testable without a second monitor to unplug.
    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(
            x: min(max(frame.minX, area.minX), area.maxX - size.width),
            y: min(max(frame.minY, area.minY), area.maxY - size.height),
            width: size.width, height: size.height)
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
        // still had an answer, so a caller looking for the primary to fall back to found none and
        // took `displays[0]` instead — the wrong-monitor outcome the fallback exists to prevent.
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
