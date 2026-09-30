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
/// Two more act on *every* window on the display rather than the focused one — tile all and cascade
/// all — and are dispatched ahead of the tiler the way a swap is.
/// They live here rather than in a store of their own because everything *around* a binding is the
/// same work whatever the binding does: persistence that can tell "cleared" from "never set", a
/// recorder, cross-store conflict detection, the per-app `neverTile` guard and the Overview. A
/// parallel enum would have duplicated all of it to express one extra verb.
/// The left-to-right slots a marked set of windows tiles into, for `SwitcherController`'s ⌥T.
///
/// A free function rather than a method on the controller so the mapping — the one part of ⌥T with
/// real logic in it — is testable without the event tap, the panels or anything else a controller
/// instance drags in. Everything downstream of this (honouring the gap, the never-tile rule, the
/// display) is already `WindowTiler.apply`'s job and stays there.
enum MarkedTiling {
    /// The arrangement for each of `count` marked windows, in the order they tile left to right —
    /// or nil when `count` is not 2, 3 or 4, which is the shape ⌥T refuses rather than guesses at.
    static func arrangements(for count: Int) -> [WindowArrangement]? {
        switch count {
        case 2: return [.leftHalf, .rightHalf]
        case 3: return [.leftThird, .centerThird, .rightThird]
        case 4: return [.topLeft, .topRight, .bottomLeft, .bottomRight]
        default: return nil
        }
    }
}

/// The arithmetic behind "Tile all windows" and "Cascade all windows", kept out of the controller
/// and the tiler for the reason `MarkedTiling` is: the layout is the part with real logic in it, and
/// as a pure function of a count, a size and an area it is testable without a window on screen.
///
/// Everything around it — which windows, the never-tile rules, the Accessibility writes, the restore
/// points — is `SwitcherController.arrangeAllWindows` and `WindowTiler.arrange`'s job.
enum ArrangeAll {
    /// The most windows either verb touches; the frontmost ones, and the rest are left where they
    /// are. A grid of twelve is already four columns of windows a few hundred points wide on a
    /// laptop, and a cascade of twelve spends a third of the screen on titlebars. Past that the
    /// layout stops being something anyone arranged on purpose and starts being a way to lose a
    /// window under the ones that moved — and every window is a round trip to another process.
    static let limit = 12

    /// One cell per window, frontmost first, filled row by row from the top-left.
    ///
    /// `ceil(sqrt(count))` columns — the squarest grid that holds them — and as many rows as that
    /// needs. The last row is usually short, and its windows widen to share the row's full width
    /// rather than leaving a hole beside them: each row is cut into as many columns as it has
    /// windows. `gap` is applied per cell by `TilingGap.inset`, so the seams and the screen edges
    /// come out as they do for any other tile; a single window is the maximize frame.
    static func grid(count: Int, in area: CGRect, gap: CGFloat) -> [CGRect] {
        guard count > 0 else { return [] }
        let columns = Int(Double(count).squareRoot().rounded(.up))
        let rows = (count + columns - 1) / columns
        return (0..<count).map { index in
            let row = index / columns
            let inRow = row == rows - 1 ? count - columns * (rows - 1) : columns
            let frame = WindowArrangement.cell(index % columns, of: inRow, row, of: rows, in: area)
            return TilingGap.inset(frame, in: area, gap: gap)
        }
    }

    /// One frame per window, frontmost first, stacked so the frontmost sits at the largest offset.
    ///
    /// `sizes` are the windows' own, and each is kept — only shrunk where the whole stack would
    /// otherwise run past `area`, which is what stops the last titlebar ending up off the screen.
    /// The windows are already stacked front to back, so handing the back one the top-left corner
    /// and each one nearer the front a titlebar further down and across puts every titlebar in
    /// view and needs no raise. The step shrinks on an axis too short for the stack, so the
    /// windows never have to be squeezed below `minimumSize` to make room.
    static func cascade(sizes: [CGSize], in area: CGRect) -> [CGRect] {
        guard !sizes.isEmpty else { return [] }
        let steps = CGFloat(sizes.count - 1)
        let stepX = steps > 0
            ? min(WindowTiler.titlebarHeight, max(0, area.width - WindowArrangement.minimumSize) / steps)
            : 0
        let stepY = steps > 0
            ? min(WindowTiler.titlebarHeight, max(0, area.height - WindowArrangement.minimumSize) / steps)
            : 0
        return sizes.enumerated().map { index, size in
            let depth = CGFloat(sizes.count - 1 - index)
            return CGRect(
                x: area.minX + depth * stepX, y: area.minY + depth * stepY,
                width: min(size.width, area.width - steps * stepX),
                height: min(size.height, area.height - steps * stepY))
        }
    }
}

// `Sendable` is stated so the App Intents conformance (`AppIntents.swift`), which implies it, can
// live in its own file — a retroactive `Sendable` must be declared where the enum is.
enum WindowArrangement: String, CaseIterable, Identifiable, Sendable {
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
    case desktop1, desktop2, desktop3, desktop4, desktop5
    case desktop6, desktop7, desktop8, desktop9
    case focusLeft, focusRight, focusUp, focusDown
    case swapLeft, swapRight, swapUp, swapDown
    case firstFourth, secondFourth, thirdFourth, lastFourth, leftThreeFourths, rightThreeFourths
    case topLeftSixth, topCenterSixth, topRightSixth
    case bottomLeftSixth, bottomCenterSixth, bottomRightSixth
    case topLeftNinth, topCenterNinth, topRightNinth
    case middleLeftNinth, middleCenterNinth, middleRightNinth
    case bottomLeftNinth, bottomCenterNinth, bottomRightNinth
    case tileAll, cascadeAll

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
        // Numbered the way Mission Control's own bar reads, and the way the tiles' Space badges
        // count — the Nth Desktop of the display the window is on.
        case .desktop1: return "Move to desktop 1"
        case .desktop2: return "Move to desktop 2"
        case .desktop3: return "Move to desktop 3"
        case .desktop4: return "Move to desktop 4"
        case .desktop5: return "Move to desktop 5"
        case .desktop6: return "Move to desktop 6"
        case .desktop7: return "Move to desktop 7"
        case .desktop8: return "Move to desktop 8"
        case .desktop9: return "Move to desktop 9"
        case .focusLeft: return "Focus window to the left"
        case .focusRight: return "Focus window to the right"
        case .focusUp: return "Focus window above"
        case .focusDown: return "Focus window below"
        case .swapLeft: return "Swap with window to the left"
        case .swapRight: return "Swap with window to the right"
        case .swapUp: return "Swap with window above"
        case .swapDown: return "Swap with window below"
        case .firstFourth: return "First fourth"
        case .secondFourth: return "Second fourth"
        case .thirdFourth: return "Third fourth"
        case .lastFourth: return "Last fourth"
        case .leftThreeFourths: return "Left three-fourths"
        case .rightThreeFourths: return "Right three-fourths"
        case .topLeftSixth: return "Top-left sixth"
        case .topCenterSixth: return "Top-middle sixth"
        case .topRightSixth: return "Top-right sixth"
        case .bottomLeftSixth: return "Bottom-left sixth"
        case .bottomCenterSixth: return "Bottom-middle sixth"
        case .bottomRightSixth: return "Bottom-right sixth"
        case .topLeftNinth: return "Top-left ninth"
        case .topCenterNinth: return "Top-middle ninth"
        case .topRightNinth: return "Top-right ninth"
        case .middleLeftNinth: return "Middle-left ninth"
        case .middleCenterNinth: return "Center ninth"
        case .middleRightNinth: return "Middle-right ninth"
        case .bottomLeftNinth: return "Bottom-left ninth"
        case .bottomCenterNinth: return "Bottom-middle ninth"
        case .bottomRightNinth: return "Bottom-right ninth"
        case .tileAll: return "Tile all windows"
        case .cascadeAll: return "Cascade all windows"
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
    /// The fourths, sixths and ninths are unbound for the opposite reason: there are twenty-one of
    /// them, and no key cluster on the machine has room for twenty-one chords that a finger could
    /// learn. They are for someone who has a layout in mind and wants to bind the two or three
    /// cells of it. Tile all and cascade all are unbound because they are the only verbs here that
    /// move windows the user did not point at, which is not something to arm with a default chord.
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
        case .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
            .leftThreeFourths, .rightThreeFourths:
            return nil
        case .topLeftSixth, .topCenterSixth, .topRightSixth,
            .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth:
            return nil
        case .topLeftNinth, .topCenterNinth, .topRightNinth,
            .middleLeftNinth, .middleCenterNinth, .middleRightNinth,
            .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth:
            return nil
        case .tileAll, .cascadeAll: return nil
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
        // Absolute Desktop targets, unbound on the same argument — how many mean anything depends
        // on how many Desktops the desk has, and the rows shown are filtered the same way.
        case .desktop1, .desktop2, .desktop3, .desktop4, .desktop5,
            .desktop6, .desktop7, .desktop8, .desktop9:
            return nil
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

    /// The Desktop this sends the window to outright, 0-based, or nil if it names no Desktop.
    ///
    /// The same argument as `displayIndex`, and stronger: the relative pair is one press and no
    /// guess on two Desktops, and Desktops routinely run to five or more, where "three along from
    /// here" is arithmetic nobody does mid-thought. Numbered against the window's own display's
    /// Spaces Bar — Mission Control draws one per display, so "desktop 3" can only mean the third
    /// of the bar this window's drag can travel. Nine of them, for the same fixed-grammar reason
    /// there are four displays; the relative moves still walk to anything beyond.
    var desktopIndex: Int? {
        switch self {
        case .desktop1: return 0
        case .desktop2: return 1
        case .desktop3: return 2
        case .desktop4: return 3
        case .desktop5: return 4
        case .desktop6: return 5
        case .desktop7: return 6
        case .desktop8: return 7
        case .desktop9: return 8
        default: return nil
        }
    }

    /// Whether this carries the window to another Desktop, however it names the destination — the
    /// one family behind the Desktop-moves switch, so the gate and the URL guard cannot cover one
    /// spelling of the move and miss the other.
    var isDesktopMove: Bool { desktopStep != nil || desktopIndex != nil }

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
    var isMove: Bool { displayStep != nil || displayIndex != nil || isDesktopMove }

    /// Whether this carries the window to another display, however it names the destination.
    ///
    /// One predicate for the relative pair and the four absolute targets, so the pointer warp and
    /// the "this is a move, not a tile" rules cannot end up applying to one and not the other.
    var movesAcrossDisplays: Bool { displayStep != nil || displayIndex != nil }

    /// Whether this only moves the keyboard focus, changing no window's geometry at all.
    var isFocus: Bool { focusStep != nil }

    /// Whether this acts on every window on the display rather than one — tile all and cascade all.
    ///
    /// They have no frame of their own: the layout depends on how many windows there are, so they
    /// are dispatched ahead of the tiler (see `SwitcherController.arrangeAllWindows`) and answer
    /// nil from `frame`, exactly as a swap does.
    var arrangesAll: Bool { self == .tileAll || self == .cascadeAll }

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

    /// The absolute Desktop targets, in Desktop order.
    static let desktopTargets: [WindowArrangement] = allCases.filter { $0.desktopIndex != nil }

    /// Everything the tiling switch does **not** govern.
    ///
    /// Two families, on one argument: neither resizes anything of its own accord. A move carries a
    /// window to another display or Desktop at the size it already had — or, for a window still
    /// where a tile left it, as that same tile there, a shape the user already asked for — and a
    /// focus chord touches no window's frame whatsoever — so "I don't want Cmd-Tab resizing my windows" is not a reason to lose
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
    ///
    /// Tile all and cascade all go too, on the plainest ground: a rule's arrangement is where *one*
    /// window opens, and these rearrange every window on the display.
    static let launchable: [WindowArrangement] = tilingArrangements.filter {
        $0 != .restore && $0.sizeStep == nil && $0.nudgeStep == nil && $0.swapStep == nil
            && $0.edgeStep == nil && !$0.arrangesAll
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
        // Cascading is not tiling: the windows overlap on purpose and keep their own sizes, so there
        // is no seam for a gap to widen. Tile all *does* take one, but `ArrangeAll.grid` applies it
        // itself — it is the only place that knows which row a cell is in.
        case .cascadeAll:
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

    /// Whether the frame is nothing but a fraction of the area it is applied to — the window's own
    /// frame takes no part in it, so the same arrangement on another display is the same tile there.
    ///
    /// That is what lets a window still sitting where such a tile left it be *re-tiled* when it is
    /// moved across displays, instead of carried at its absolute size. `.center`, the two
    /// half-maximizes, the size steps, the edge resizes and the nudges are all defined against the
    /// window as it is, so they are out, and so are tile all and cascade all, whose cell depends on
    /// how many windows were on the display. An arrangement that later adds another fraction opts
    /// in by adding its case here and nowhere else.
    var isPureFraction: Bool {
        switch self {
        case .leftHalf, .rightHalf, .topHalf, .bottomHalf,
            .leftThird, .centerThird, .rightThird, .topThird, .bottomThird,
            .leftTwoThirds, .rightTwoThirds,
            .topLeft, .topRight, .bottomLeft, .bottomRight,
            .firstFourth, .secondFourth, .thirdFourth, .lastFourth,
            .leftThreeFourths, .rightThreeFourths,
            .topLeftSixth, .topCenterSixth, .topRightSixth,
            .bottomLeftSixth, .bottomCenterSixth, .bottomRightSixth,
            .topLeftNinth, .topCenterNinth, .topRightNinth,
            .middleLeftNinth, .middleCenterNinth, .middleRightNinth,
            .bottomLeftNinth, .bottomCenterNinth, .bottomRightNinth,
            .maximize, .almostMaximize:
            return true
        default:
            return false
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
        // Fourths, sixths and ninths are cells of one grid, and `cell` is what keeps the trailing
        // ones flush: the last column and row are written as `max - size`, as the right third is.
        // Sixths are three columns by two rows and no more — a portrait display gets the same
        // landscape layout, not a transposed one.
        case .firstFourth: return Self.cell(0, of: 4, in: area)
        case .secondFourth: return Self.cell(1, of: 4, in: area)
        case .thirdFourth: return Self.cell(2, of: 4, in: area)
        case .lastFourth: return Self.cell(3, of: 4, in: area)
        case .leftThreeFourths:
            return CGRect(
                x: area.minX, y: area.minY, width: area.width * 3 / 4, height: area.height)
        case .rightThreeFourths:
            return CGRect(
                x: area.maxX - area.width * 3 / 4, y: area.minY,
                width: area.width * 3 / 4, height: area.height)
        case .topLeftSixth: return Self.cell(0, of: 3, 0, of: 2, in: area)
        case .topCenterSixth: return Self.cell(1, of: 3, 0, of: 2, in: area)
        case .topRightSixth: return Self.cell(2, of: 3, 0, of: 2, in: area)
        case .bottomLeftSixth: return Self.cell(0, of: 3, 1, of: 2, in: area)
        case .bottomCenterSixth: return Self.cell(1, of: 3, 1, of: 2, in: area)
        case .bottomRightSixth: return Self.cell(2, of: 3, 1, of: 2, in: area)
        case .topLeftNinth: return Self.cell(0, of: 3, 0, of: 3, in: area)
        case .topCenterNinth: return Self.cell(1, of: 3, 0, of: 3, in: area)
        case .topRightNinth: return Self.cell(2, of: 3, 0, of: 3, in: area)
        case .middleLeftNinth: return Self.cell(0, of: 3, 1, of: 3, in: area)
        case .middleCenterNinth: return Self.cell(1, of: 3, 1, of: 3, in: area)
        case .middleRightNinth: return Self.cell(2, of: 3, 1, of: 3, in: area)
        case .bottomLeftNinth: return Self.cell(0, of: 3, 2, of: 3, in: area)
        case .bottomCenterNinth: return Self.cell(1, of: 3, 2, of: 3, in: area)
        case .bottomRightNinth: return Self.cell(2, of: 3, 2, of: 3, in: area)
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
        // The absolute display and Desktop targets join the relative pairs: their destination is
        // another display's area or another Desktop, which `apply` or `DesktopMover` substitutes,
        // not a rectangle on this one.
        case .restore, .previousDisplay, .nextDisplay, .previousDesktop, .nextDesktop,
            .display1, .display2, .display3, .display4,
            .desktop1, .desktop2, .desktop3, .desktop4, .desktop5,
            .desktop6, .desktop7, .desktop8, .desktop9:
            return nil
        // Focus moves no window, and a swap needs a second window this function has never been told
        // about. Both are dispatched before the tiler is ever reached — see
        // `SwitcherController.applyTiling` — and answer nil here for the same reason `.restore` does:
        // there is no frame computable from this screen alone. Tile all and cascade all join them:
        // their layout is a function of how many windows there are, which this never hears.
        case .focusLeft, .focusRight, .focusUp, .focusDown,
            .swapLeft, .swapRight, .swapUp, .swapDown, .tileAll, .cascadeAll:
            return nil
        }
    }

    /// The cell at `column` of `columns` and `row` of `rows` in `area`, the last of each written as
    /// `max - size` so it lands flush against the far edge whatever the division rounds to.
    fileprivate static func cell(
        _ column: Int, of columns: Int, _ row: Int = 0, of rows: Int = 1, in area: CGRect
    ) -> CGRect {
        let width = area.width / CGFloat(columns)
        let height = area.height / CGFloat(rows)
        return CGRect(
            x: column == columns - 1 ? area.maxX - width : area.minX + CGFloat(column) * width,
            y: row == rows - 1 ? area.maxY - height : area.minY + CGFloat(row) * height,
            width: width, height: height)
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
    ///
    /// Except on an axis the window *already* overflows — a window reaching down under the Dock is
    /// the ordinary case. Clamped there, "larger" cut the window back to the screen and was the
    /// press that shrank it; growing leaves that axis exactly as it was, and grows the other one.
    /// Shrinking still takes it, which is at least the direction the press asked for.
    private func resized(_ current: CGRect, in area: CGRect) -> CGRect? {
        guard let step = sizeStep else { return nil }
        let dx = area.width * Self.sizeStepFraction * step
        let dy = area.height * Self.sizeStepFraction * step
        let keepsWidth = step > 0 && current.width > area.width
        let keepsHeight = step > 0 && current.height > area.height
        let size = CGSize(
            width: keepsWidth ? current.width : min(current.width + dx, area.width),
            height: keepsHeight ? current.height : min(current.height + dy, area.height))
        // A floor on shrinking only. A window already under it is not one "larger" should refuse.
        guard step > 0 || (size.width >= Self.minimumSize && size.height >= Self.minimumSize)
        else { return nil }
        let grown = CGRect(
            x: current.midX - size.width / 2, y: current.midY - size.height / 2,
            width: size.width, height: size.height)
        var frame = WindowTiler.clamp(grown, into: area)
        if keepsWidth { (frame.origin.x, frame.size.width) = (current.minX, current.width) }
        if keepsHeight { (frame.origin.y, frame.size.height) = (current.minY, current.height) }
        return frame
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
    ///
    /// And the edge only ever moves the way the press says. Clamping it to a limit it is already
    /// beyond drags it back *across* that limit: a window reaching under the Dock took "grow bottom
    /// edge" as a cut back to the screen, and one already under `minimumSize` took "shrink" as a
    /// stretch up to it. See `stepped`.
    private func edgeResized(_ current: CGRect, in area: CGRect) -> CGRect? {
        guard let (edge, sign) = edgeStep else { return nil }
        let dx = area.width * Self.sizeStepFraction * sign
        let dy = area.height * Self.sizeStepFraction * sign
        let grows = sign > 0
        var frame = current
        switch edge {
        case .left:
            // Top-left origin: the left edge grows by moving to a smaller x, and the width has to
            // grow with it or the whole window would slide instead of stretching.
            let minX = Self.stepped(
                current.minX, by: -dx,
                stoppingAt: grows ? area.minX : current.maxX - Self.minimumSize)
            frame = CGRect(
                x: minX, y: current.minY, width: current.maxX - minX, height: current.height)
        case .right:
            let maxX = Self.stepped(
                current.maxX, by: dx,
                stoppingAt: grows ? area.maxX : current.minX + Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: current.minY, width: maxX - current.minX,
                height: current.height)
        case .up:
            let minY = Self.stepped(
                current.minY, by: -dy,
                stoppingAt: grows ? area.minY : current.maxY - Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: minY, width: current.width, height: current.maxY - minY)
        case .down:
            let maxY = Self.stepped(
                current.maxY, by: dy,
                stoppingAt: grows ? area.maxY : current.minY + Self.minimumSize)
            frame = CGRect(
                x: current.minX, y: current.minY, width: current.width,
                height: maxY - current.minY)
        }
        // An edge already against the screen (growing) or already at the floor (shrinking) leaves
        // the frame untouched. Returning nil rather than the identity means `apply` writes nothing
        // at all, which is one fewer Accessibility round-trip per press of a held-down chord.
        return frame == current ? nil : frame
    }

    /// `value` moved by `delta`, stopping at `limit` — and never moved the other way. A value
    /// already past `limit` stays where it is rather than being pulled back to it.
    private static func stepped(
        _ value: CGFloat, by delta: CGFloat, stoppingAt limit: CGFloat
    ) -> CGFloat {
        delta < 0 ? min(value, max(value + delta, limit)) : max(value, min(value + delta, limit))
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
    ///
    /// Not private: `ArrangeAll.cascade` stops stepping windows down the stack at the same floor.
    static let minimumSize: CGFloat = 120
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
    /// Whether dragging to the top edge tiles the top half rather than maximizing. Off by default,
    /// which is the gesture every other platform's edge-snap has taught. See `DragSnap.EdgeOptions`.
    var dragSnapTopHalf: Bool = false
    /// Whether dragging to the bottom edge tiles a third of the screen's width rather than the
    /// bottom half. Off by default, so nobody's bottom-edge drop changes on an update.
    var dragSnapBottomThirds: Bool = false
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
    /// Put an assigned app back on its Desktop after the displays change.
    ///
    /// Off by default, on the same argument as the setting above and one of its own. The same:
    /// it moves windows the user did not ask it to move, at a moment they are often not watching.
    /// Its own: the move is `DesktopMover`'s gesture, so it drives the pointer and opens Mission
    /// Control — which is already why `desktopMoves` is a switch rather than always-on, and that
    /// one at least runs because a key was pressed. See `DesktopAssignments`.
    var restoresDesktopAssignments: Bool = false
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
        if arrangement.isDesktopMove { return desktopMoves }
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
        static let dragSnapTopHalf = "windowTilingDragSnapTopHalf"
        static let dragSnapBottomThirds = "windowTilingDragSnapBottomThirds"
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
        static let restoreDesktopAssignments = "restoreDesktopAssignments"
    }

    /// Every key this store owns, for export/import/reset.
    static let defaultsKeys = [
        Key.enabled, Key.cycleWidths, Key.shortcuts, Key.dragSnap, Key.desktopMoves,
        Key.dragSnapTopHalf, Key.dragSnapBottomThirds,
        Key.followsDesktopMove, Key.pointerFollowsDisplay,
        Key.gap, Key.gapTop, Key.gapBottom, Key.gapLeft, Key.gapRight,
        Key.dotHex, Key.outlineHex, Key.landingHex,
        Key.mouseDrag, Key.mouseMove, Key.mouseResize,
        Key.focusFollows, Key.focusFollowsDelay, Key.restoreOnDisplayChange,
        Key.restoreDesktopAssignments,
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

    var dragSnapTopHalf: Bool {
        get { tiling.dragSnapTopHalf }
        set {
            guard newValue != tiling.dragSnapTopHalf else { return }
            tiling.dragSnapTopHalf = newValue
            persist()
        }
    }

    var dragSnapBottomThirds: Bool {
        get { tiling.dragSnapBottomThirds }
        set {
            guard newValue != tiling.dragSnapBottomThirds else { return }
            tiling.dragSnapBottomThirds = newValue
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

    var restoresDesktopAssignments: Bool {
        get { tiling.restoresDesktopAssignments }
        set {
            guard newValue != tiling.restoresDesktopAssignments else { return }
            tiling.restoresDesktopAssignments = newValue
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
            // A run-loop block rather than a dispatch one, so the modal cannot freeze the main queue:
            // see `MainRunLoop`.
            MainRunLoop.perform {
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

    /// Every key is read the same way: absent means "at its default", whether because it was never
    /// set or because it was set back — see `persist`, which removes a key rather than writing the
    /// default into it.
    private static func load() -> WindowTilingBindings {
        let defaults = UserDefaults.standard
        var result = WindowTilingBindings.defaults
        result.isEnabled = defaults.bool(forKey: Key.enabled)
        // Absent means the default, which for this one is on — the cycle is the useful default and
        // `bool(forKey:)` reports false for a missing key.
        result.cycleWidths =
            defaults.object(forKey: Key.cycleWidths) != nil
            ? defaults.bool(forKey: Key.cycleWidths) : true
        result.dragSnap = defaults.bool(forKey: Key.dragSnap)
        result.dragSnapTopHalf = defaults.bool(forKey: Key.dragSnapTopHalf)
        result.dragSnapBottomThirds = defaults.bool(forKey: Key.dragSnapBottomThirds)
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
        result.restoresDesktopAssignments = defaults.bool(forKey: Key.restoreDesktopAssignments)
        // Absent means 0, the default — `double(forKey:)` already reports 0 for a missing key, so
        // the two cases need no telling apart here.
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
        result.bindings = bindings(stored: defaults.dictionary(forKey: Key.shortcuts))
        return result
    }

    /// The chords as stored: `{ arrangementRawValue: [keyCode, modifierRaw] }`, which is
    /// plist-safe, holding **only the arrangements that differ from the chord they ship with**.
    ///
    /// Two absences have to be told apart, and this is how. An arrangement missing from the table
    /// is at its default, and takes whatever default the running build has — so a chord this app
    /// later changes reaches everyone who never changed it, instead of the one they happened to
    /// have when they last touched any setting. A *cleared* arrangement whose default is a chord is
    /// written as an **empty array**, because leaving it out would read back as that default — a
    /// cleared chord that returned on the next launch would be a setting that does not stick.
    nonisolated static func storedBindings(
        _ bindings: [WindowArrangement: Hotkey]
    ) -> [String: [Int]] {
        var raw: [String: [Int]] = [:]
        for arrangement in WindowArrangement.allCases {
            let hotkey = bindings[arrangement]
            guard hotkey != arrangement.defaultHotkey else { continue }
            raw[arrangement.rawValue] =
                hotkey.map { [$0.keyCode, Int(bitPattern: UInt($0.modifierRaw))] } ?? []
        }
        return raw
    }

    /// The inverse of `storedBindings`, read over the defaults.
    nonisolated static func bindings(stored raw: [String: Any]?) -> [WindowArrangement: Hotkey] {
        var result = WindowTilingBindings.defaults.bindings
        guard let raw else { return result }
        for arrangement in WindowArrangement.allCases {
            guard let pair = raw[arrangement.rawValue] as? [Int] else { continue }
            guard pair.count == 2 else {
                result[arrangement] = nil  // explicitly cleared
                continue
            }
            result[arrangement] = Hotkey(
                keyCode: pair[0], modifierRaw: UInt64(bitPattern: Int64(pair[1])))
        }
        return result
    }

    /// Writes what differs from the defaults and removes what does not.
    ///
    /// It used to write every key on every change — all two dozen switches and every chord in the
    /// table, the defaults included — so touching any one setting pinned this build's defaults for
    /// all the others, and no later change to a default could reach that install again. The same
    /// trap `BehaviorStore.isReloading` and `AppearanceStore` document; `load` reads an absent key
    /// as the default, so removing one is how a setting goes back to following it.
    private func persist() {
        let defaults = UserDefaults.standard
        let mouse = MouseDragSettings()
        let focus = FocusFollowsMouseSettings()
        let base = WindowTilingBindings.defaults
        Self.store(mouseDrag.isEnabled, default: mouse.isEnabled, at: Key.mouseDrag)
        Self.store(
            Int(bitPattern: UInt(mouseDrag.move.rawValue)),
            default: Int(bitPattern: UInt(mouse.move.rawValue)), at: Key.mouseMove)
        Self.store(
            Int(bitPattern: UInt(mouseDrag.resize.rawValue)),
            default: Int(bitPattern: UInt(mouse.resize.rawValue)), at: Key.mouseResize)
        onMouseDragChange?(mouseDrag)
        Self.store(focusFollows.isEnabled, default: focus.isEnabled, at: Key.focusFollows)
        Self.store(focusFollows.delay, default: focus.delay, at: Key.focusFollowsDelay)
        onFocusFollowsChange?(focusFollows)
        Self.store(tiling.isEnabled, default: base.isEnabled, at: Key.enabled)
        Self.store(tiling.cycleWidths, default: base.cycleWidths, at: Key.cycleWidths)
        Self.store(tiling.dragSnap, default: base.dragSnap, at: Key.dragSnap)
        Self.store(
            tiling.dragSnapTopHalf, default: base.dragSnapTopHalf, at: Key.dragSnapTopHalf)
        Self.store(
            tiling.dragSnapBottomThirds, default: base.dragSnapBottomThirds,
            at: Key.dragSnapBottomThirds)
        Self.store(tiling.desktopMoves, default: base.desktopMoves, at: Key.desktopMoves)
        Self.store(
            tiling.followsDesktopMove, default: base.followsDesktopMove,
            at: Key.followsDesktopMove)
        Self.store(
            tiling.pointerFollowsDisplayMove, default: base.pointerFollowsDisplayMove,
            at: Key.pointerFollowsDisplay)
        Self.store(
            tiling.restoresLayoutOnDisplayChange, default: base.restoresLayoutOnDisplayChange,
            at: Key.restoreOnDisplayChange)
        Self.store(
            tiling.restoresDesktopAssignments, default: base.restoresDesktopAssignments,
            at: Key.restoreDesktopAssignments)
        // The four per-edge keys are deliberately not written back. They are a migration source
        // only — see `load()` — and left where they are, so a downgrade finds what it wrote.
        //
        // Which is also why the gap is the one key that cannot always be removed at its default:
        // `load` reads an absent gap as "migrate from the per-edge keys", so while any of them is
        // still there, a gap set back to 0 has to be written as 0 or the old spacing comes back.
        let migrates = [Key.gapTop, Key.gapBottom, Key.gapLeft, Key.gapRight]
            .contains { defaults.object(forKey: $0) != nil }
        if migrates {
            defaults.set(Double(tiling.gap), forKey: Key.gap)
        } else {
            Self.store(Double(tiling.gap), default: Double(base.gap), at: Key.gap)
        }
        let raw = Self.storedBindings(tiling.bindings)
        if raw.isEmpty {
            defaults.removeObject(forKey: Key.shortcuts)
        } else {
            defaults.set(raw, forKey: Key.shortcuts)
        }
        onChange?(tiling)
    }

    /// Writes `value`, or removes the key when it equals `fallback` — see `persist`.
    private static func store<Value: Equatable>(
        _ value: Value, default fallback: Value, at key: String
    ) {
        if value == fallback {
            UserDefaults.standard.removeObject(forKey: key)
        } else {
            UserDefaults.standard.set(value, forKey: key)
        }
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
    /// to, and the order those frames were last touched in so the oldest can be dropped first.
    ///
    /// Touched only on `queue`, which is what keeps them safe without a lock.
    ///
    /// One entry per window and one level of undo, which is what makes the answer unambiguous. See
    /// `RestorePoint` for which presses write to it and why.
    private nonisolated(unsafe) static var restorePoints: [WindowKey: RestorePoint] = [:]
    private nonisolated(unsafe) static var restoreOrder: [WindowKey] = []
    /// Where the last cycling arrangement left off: the window it applied to, which arrangement,
    /// how far through `cycleFractions` it had got, and the frame that step left the window at —
    /// see `continuesCycle`.
    private nonisolated(unsafe) static var cycle:
        (key: WindowKey, arrangement: WindowArrangement, step: Int, left: [CGRect])?

    /// One window's restore slot: a frame to go back to, and what kind of frame it is.
    ///
    /// Normally it is the **anchor** — the frame the window had before any tiling started. A tile
    /// writes it only when there is nothing recorded, or when the window has been moved by hand
    /// since the last write (see `tiled`), so it stays the pre-tiling frame rather than creeping
    /// forward a tile at a time. `.restore` swaps in the frame it is about to replace,
    /// which is what makes restore a toggle rather than a one-shot.
    ///
    /// The swap is why `isRedo` exists. After a restore the slot holds the tile that was undone,
    /// not an anchor — and "record only when empty" then kept it: tile left from F, restore to F,
    /// maximize, and the next restore brought back the *left half*, not F. So a restore marks
    /// what it writes, the next restore flips it back, and a tile that finds a redo entry knows the
    /// window is sitting at its anchor now and records that instead.
    ///
    /// The desk the frame was recorded against is kept with it. Restore promises the exact
    /// rectangle back, and a rescue that tidies a window onto the nearest display breaks that
    /// promise for anyone who deliberately parked one half off an edge — so the rescue has to be
    /// able to tell "the display this was saved on is gone" from "this is where the user put it".
    /// Comparing the areas is enough: the rescue only exists for a desk that has changed.
    ///
    /// Pure and internal so the sequences can be tested without a window; `apply` holds the table.
    struct RestorePoint: Equatable {
        var frame: CGRect
        var desk: [CGRect]
        /// True when `frame` is a tile a restore undid, rather than the pre-tiling anchor.
        var isRedo = false
        /// Where the last write by the tiler left the window: the frame asked for and the frame
        /// read back, for the reason `cycle.left` keeps both. Empty until that write has happened.
        ///
        /// What makes "the anchor is kept" conditional. Tile, resize by hand, tile again, and the
        /// anchor kept from before the first tile sent restore to a frame the user had long since
        /// left; a window that is no longer where the tiler put it has been moved by someone, and
        /// the frame it is at now is the one to come back to.
        var tiled: [CGRect] = []
        /// The arrangement and width that produced `tiled`, when that was a pure fraction of the
        /// screen — what a display move re-applies on the destination. nil after anything whose
        /// frame depended on the window's own (see `WindowArrangement.isPureFraction`).
        var placement: Placement?

        struct Placement: Equatable {
            let arrangement: WindowArrangement
            let fraction: CGFloat
        }

        /// Whether a window at `frame` is still where the tiler last left it.
        func isAtTile(_ frame: CGRect) -> Bool {
            WindowTiler.continuesCycle(left: tiled, current: frame)
        }

        /// The slot once a tile — anything but `.restore` — has been applied to a window that was
        /// at `current` before it. An anchor is kept while the window is still where the tiler left
        /// it; nothing, a redo entry, or a window someone has moved since is replaced by `current`.
        static func afterTile(_ slot: Self?, current: CGRect, desk: [CGRect]) -> Self {
            if let slot, !slot.isRedo, slot.isAtTile(current) { return slot }
            return Self(frame: current, desk: desk)
        }

        /// The slot once `.restore` has sent a window at `current` back to `slot.frame`: the frame
        /// it replaced, flagged the opposite way. Undoing a tile leaves the tile as a redo; redoing
        /// it leaves the frame it came back from as the anchor again.
        static func afterRestore(_ slot: Self, current: CGRect, desk: [CGRect]) -> Self {
            Self(frame: current, desk: desk, isRedo: !slot.isRedo)
        }
    }

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
    /// One copy, used by `displayMoveTarget` for every display move — the ⌃⇧⌘-←/→ chord, the
    /// numbered targets and, through `apply`, `SwitchTarget.moveWindow(acrossDisplays:)`, which used
    /// to keep a second copy of it. The drift had already happened once: the shrink-to-fit had to
    /// be retrofitted into the switcher path after the chord already had it.
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

    /// Where a window lands when it is moved from `from` to `to`: re-tiled if it is still exactly
    /// where a tile left it, carried at its own size otherwise.
    ///
    /// A right half on a 2560-wide display carried to a 1512-wide laptop at its absolute size is a
    /// 1280-wide window floating off-centre, which is not what anyone who had just tiled it wanted.
    /// Keeping the size is still right for a window the user sized by hand — that is the promise
    /// `carried` makes — so the test is whether the tiler's own last write still describes it.
    /// `gap` is applied as a tile applies it, since what comes out is a tile.
    static func displayMoveTarget(
        current: CGRect, from: CGRect, to: CGRect, slot: RestorePoint?, gap: CGFloat
    ) -> CGRect {
        guard let slot, slot.isAtTile(current), let placed = slot.placement,
            let frame = placed.arrangement.frame(in: to, current: current, fraction: placed.fraction)
        else { return carried(current, from: from, to: to) }
        return placed.arrangement.takesGap ? TilingGap.inset(frame, in: to, gap: gap) : frame
    }

    /// Where to move a window that came back smaller or larger than it was told to be, or nil to
    /// leave it.
    ///
    /// Hosts refuse sizes — a minimum width, a fixed size, a terminal's character grid — and the
    /// origin written for the size asked for then leaves the window short of the edge it was meant
    /// to touch, or spilling past the one it was meant to stop at. Per axis that differs in size,
    /// the edge the tile was anchored on is kept: the max edge when the target sits against the
    /// area's far side and not the near one (right half, bottom third), the min edge when it sits
    /// against the near side (including both, full height), and otherwise — a centred tile — the
    /// centre. Then the window is kept inside `area`, pinned to its min edge if it is bigger than
    /// the area outright.
    ///
    /// nil whenever `actual`'s *origin* is not `target`'s. Hosts that apply Accessibility writes
    /// late (Electron, Chromium) still report the old frame at this point, and correcting against
    /// it would move a window that is about to land correctly to somewhere derived from a frame it
    /// is no longer in. Two points of slack, as `continuesCycle` allows, and `gap` widens what
    /// counts as "against the edge" because a tile with a gap sits that far from it.
    static func corrected(target: CGRect, actual: CGRect, area: CGRect, gap: CGFloat) -> CGPoint? {
        let slack: CGFloat = 2
        guard abs(actual.minX - target.minX) <= slack, abs(actual.minY - target.minY) <= slack
        else { return nil }
        let x = correctedOrigin(
            target: target.minX...target.maxX, size: actual.width, area: area.minX...area.maxX,
            gap: gap)
        let y = correctedOrigin(
            target: target.minY...target.maxY, size: actual.height, area: area.minY...area.maxY,
            gap: gap)
        guard abs(x - actual.minX) > slack || abs(y - actual.minY) > slack else { return nil }
        return CGPoint(x: x, y: y)
    }

    private static func correctedOrigin(
        target: ClosedRange<CGFloat>, size: CGFloat, area: ClosedRange<CGFloat>, gap: CGFloat
    ) -> CGFloat {
        let slack: CGFloat = 2
        // An axis that came back the right size is left exactly as the host placed it.
        guard abs(size - (target.upperBound - target.lowerBound)) > slack else {
            return target.lowerBound
        }
        let edge = gap + 1
        let atMin = abs(target.lowerBound - area.lowerBound) <= edge
        let atMax = abs(area.upperBound - target.upperBound) <= edge
        let origin: CGFloat
        if atMax && !atMin {
            origin = target.upperBound - size
        } else if atMin {
            origin = target.lowerBound
        } else {
            origin = (target.lowerBound + target.upperBound) / 2 - size / 2
        }
        return max(area.lowerBound, min(origin, area.upperBound - size))
    }

    /// `destination` overrides which display the arrangement is measured against.
    ///
    /// The three pointer gestures know the display the user was *shown* a preview on, and it is not
    /// always the one `homeDisplay` picks: a window grabbed near its right edge and nudged a little
    /// further right puts the cursor on the next display while the window's centre stays behind, so
    /// the preview painted one monitor and the drop tiled the other — with the gap inset computed
    /// against the wrong area too. Keyboard chords pass nothing and keep the `homeDisplay` answer;
    /// they have no cursor to consult.
    ///
    /// The launch arrangement passes one too — the display an app rule names — and that is how a
    /// window lands on another display at all: the arrangement is computed against the destination
    /// and written once. It used to be a separate move queued first, with this re-reading the
    /// window's frame on the assumption the move had landed; on the hosts that apply Accessibility
    /// writes late it had not, and "display 2, left half" tiled onto display 1.
    ///
    /// `anchor` is the frame the window had before the *gesture* that is tiling it, for the two
    /// that move the window first. A drag drops the window wherever the cursor hit the edge, often
    /// half off it, so the frame read here is the drop position — recording that made restore put
    /// a window back hanging off the screen rather than where it was picked up. Keyboard chords
    /// move nothing first and pass none.
    ///
    /// `completion` runs after the window has been written, on the tiler's queue, and not at all
    /// when nothing was — the in-switcher display move raises and focuses the window once it has
    /// landed.
    static func apply(
        _ arrangement: WindowArrangement, pid: pid_t, areas: [CGRect], cycleWidths: Bool,
        gap: CGFloat = 0, target: Target? = nil, destination: CGRect? = nil,
        anchor: CGRect? = nil, warpsPointer: Bool = false, completion: (@Sendable () -> Void)? = nil
    ) {
        guard !areas.isEmpty else { return }
        queue.async {
            guard let window = resolve(target, pid: pid), let current = AX.frame(window) else {
                // Said, because the chord otherwise does nothing with no trace of why: an app that
                // publishes no Accessibility window, or one too wedged to report a frame in time.
                Log.general.notice(
                    """
                    tiling: no window with a readable frame for pid \(pid, privacy: .public); \
                    \(arrangement.rawValue, privacy: .public) not applied
                    """)
                return
            }
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
            // The frame the arrangement is measured from. The window's own, unless `destination`
            // is another display — then it is carried there first, so the arrangements that keep
            // part of the window (`.center`'s size, the two half-maximizes' preserved axis) keep it
            // on the destination rather than mixing one display's x with another's y.
            var measured = current
            if let destination, destination != areas[home] {
                measured = carried(current, from: areas[home], to: destination)
            }

            let target: CGRect
            // What to do with the read-back once the write is in: the area the landing is checked
            // against (nil where a refused size is the right answer — see below), the gap that
            // area's tile carries, and what to record in the window's restore slot.
            var fitArea: CGRect?
            var fitGap: CGFloat = 0
            var remember: ((inout RestorePoint, [CGRect]) -> Void)?
            if let step = arrangement.displayStep {
                // A move, unlike a tile, is relative: without a display to count from there is no
                // "next" one, and counting from the fallback would throw the window off a display it
                // was never on.
                guard resolved != nil else { return }
                // `displayMoveTarget` is the shared arithmetic, and
                // `SwitchTarget.moveWindow(acrossDisplays:)` runs through this very branch — which
                // is what actually keeps the promise that a window thrown either way lands in the
                // same place. Measured from `areas[home]` rather than `area`: a move counts from
                // the display the window is on, and `destination` is a pointer gesture's answer,
                // which this branch never has.
                guard areas.count > 1 else { return }
                let to = areas[displayStepTarget(from: home, step: step, in: areas)]
                target = displayMoveTarget(
                    current: current, from: areas[home], to: to, slot: restorePoints[key], gap: gap)
                (fitArea, fitGap, remember) = displayMoveBookkeeping(
                    current: current, to: to, slot: restorePoints[key], gap: gap)
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
                target = displayMoveTarget(
                    current: current, from: areas[home], to: areas[index],
                    slot: restorePoints[key], gap: gap)
                (fitArea, fitGap, remember) = displayMoveBookkeeping(
                    current: current, to: areas[index], slot: restorePoints[key], gap: gap)
                cycle = nil
            } else if arrangement == .restore {
                guard let saved = restorePoints[key] else { return }
                // Swapped rather than consumed, which is what makes restore a toggle: the frame it
                // is about to replace becomes the new restore point, so a second press comes back
                // to the tile the first press undid. Consuming the entry instead left the chord
                // doing nothing at all on its second press, with no way back to a layout someone
                // had undone by accident — and "undo" that cannot be undone is the one shape of
                // this feature nobody expects.
                //
                // Restore is the only arrangement that overwrites an *anchor*. Every other keeps
                // it (see the branch below), so it stays the frame the window had before any of
                // this started rather than creeping forward one tile at a time — and replaces only
                // the redo entry a restore leaves behind. See `RestorePoint`.
                restorePoints[key] = RestorePoint.afterRestore(saved, current: current, desk: areas)
                // Not fitted: the frame going back is one this window has held itself, so there is
                // no size it could refuse. What it leaves behind is a redo or an anchor, neither of
                // which is a tile a display move could re-apply.
                remember = { slot, landed in (slot.tiled, slot.placement) = (landed, nil) }
                // Back to the end of the queue: a window being restored is one the user is working
                // with, and eviction is oldest-*touched* first, not oldest-recorded.
                restoreOrder.removeAll { $0 == key }
                restoreOrder.append(key)
                cycle = nil
                target = restoreTarget(
                    saved.frame, savedOn: saved.desk, desk: areas, fallback: area)
            } else {
                let fraction = nextFraction(
                    for: arrangement, key: key, cycleWidths: cycleWidths, current: current,
                    area: area, gap: gap)
                guard let frame = arrangement.frame(
                    in: area, current: measured, fraction: fraction) else { return }
                // Recorded only once there is a frame to write — a press that changes nothing (an
                // edge already against the screen) has nothing to undo, and must not spend a redo
                // entry on the way to finding that out.
                //
                // Saved once per window and not overwritten by later tiles, so restore goes back to
                // where the window was before any of this started rather than to the previous tile
                // — unless the window has been moved by hand since the last one, in which case the
                // frame it is being tiled *from* is the one to come back to.
                rememberAnchor(key, current: anchor ?? current, desk: areas)
                // Applied last, to the finished tile: the gap is about where a window ends up, not
                // about how the arrangement divides the screen, so the fraction maths above stays
                // exactly as it is at any gap.
                target = arrangement.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame
                // The size steps and edge resizes are relative to the window's own size, so a
                // window that will not take the new one has already answered; "correcting" it
                // would throw a window that cannot grow to the far edge because the press said to.
                if arrangement.sizeStep == nil, arrangement.edgeStep == nil {
                    (fitArea, fitGap) = (area, arrangement.takesGap ? gap : 0)
                }
                let placement = arrangement.isPureFraction
                    ? RestorePoint.Placement(arrangement: arrangement, fraction: fraction) : nil
                remember = { slot, landed in (slot.tiled, slot.placement) = (landed, placement) }
            }

            // Written, read back and remembered in one place — see `write`.
            let landed = write(
                window, key: key, target: target, fitArea: fitArea, fitGap: fitGap,
                remember: remember)
            if let last = cycle, last.key == key, last.arrangement == arrangement {
                cycle?.left = landed
            }

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
            completion?()
        }
    }

    /// Where a tiled window lands when it is dragged out of its tile: the size it had before it was
    /// tiled, with the point the user took hold of it by still under the cursor.
    ///
    /// `current` is the window's frame now, `pickedUp` its frame at the press, and `grab` the press
    /// point, all in Accessibility's top-left space. The grab is reduced to how far *across* the
    /// picked-up window it was, and that fraction is what is kept: hold a tile by its far right end
    /// and the smaller window comes out with its far right end under the cursor, not with the
    /// cursor stranded in empty desktop beyond it. The fraction is taken against the picked-up frame
    /// because that is the only frame the press point was ever measured on — `current` has already
    /// followed the cursor some distance.
    ///
    /// The window having followed the cursor rigidly, its current left edge already sits one grab
    /// offset behind the cursor, so the new edge is that one moved by the width the window gained
    /// or lost *at the grab's fraction*. That is also why the cursor's position now is not needed:
    /// the window is wherever the cursor took it, and only the size changes under it. `y` is kept —
    /// the title bar is being held, and it has not moved relative to the cursor.
    ///
    /// Pure and internal so the geometry can be tested without a window.
    static func unsnappedFrame(
        current: CGRect, pickedUp: CGRect, grab: CGPoint, size: CGSize
    ) -> CGRect {
        let across =
            pickedUp.width > 0 ? min(max((grab.x - pickedUp.minX) / pickedUp.width, 0), 1) : 0.5
        return CGRect(
            x: current.minX + across * (current.width - size.width), y: current.minY,
            width: size.width, height: size.height)
    }

    /// Sends a window that has just been dragged out of a tile back to its pre-tile size.
    ///
    /// Called once per drag, when `DragSnap` arms, and does its work on this queue: the restore table
    /// is only ever touched here, and everything below is Accessibility. Acts only when the window
    /// was *still exactly where a tile left it* when it was picked up (`RestorePoint.isAtTile`) and
    /// the slot holds an anchor rather than a redo entry — a window someone sized by hand since, or
    /// one a restore has just put back, has no tile to leave.
    ///
    /// The slot is deliberately left alone. A drop in a zone reaches `apply` with `anchor:
    /// pickedUp`, the tile, so `afterTile` sees a window that was at its tile and keeps the original
    /// anchor: restore still goes back to where the window was before the first tile. A drop in no
    /// zone leaves the window at the anchor's size somewhere new, no longer at its tile, so the
    /// next tile records wherever it is then — the same as any window moved by hand.
    ///
    /// The window is found by its `CGWindowID`, because the one the press landed on is already
    /// moving and its bounds are stale by the time this runs. The front window stands in only when
    /// not one of the app's windows can report an id (Electron and Catalyst hide it) *and* its size
    /// is the picked-up window's — a window that size is the only one that could have been the
    /// dragged one, and the slot check above still has to pass for it. Anything else does nothing:
    /// resizing the wrong window is worse than not un-snapping the right one.
    static func unsnap(pid: pid_t, windowID: CGWindowID, pickedUp: CGRect, grab: CGPoint) {
        queue.async {
            let windows = AX.windows(of: AX.application(pid))
            var window = windows.first { TargetProvider.windowID($0) == windowID }
            if window == nil, !windows.contains(where: { TargetProvider.windowID($0) != nil }),
                let front = AX.frontWindow(ofApplication: pid), let size = AX.size(front),
                abs(size.width - pickedUp.width) < 4, abs(size.height - pickedUp.height) < 4
            {
                window = front
            }
            guard let window, let slot = restorePoints[WindowKey(element: window)],
                !slot.isRedo, slot.isAtTile(pickedUp), let current = AX.frame(window)
            else { return }
            let frame = unsnappedFrame(
                current: current, pickedUp: pickedUp, grab: grab, size: slot.frame.size)
            guard frame.size != current.size else { return }
            AX.setFrame(window, frame, sizing: true, repositionAfterSizing: true)
        }
    }

    /// Files the frame a window is about to be tiled *from* as its restore point, unless the slot
    /// already holds the right one — see `RestorePoint.afterTile` — and keeps the eviction order.
    ///
    /// Shared by `apply` and `arrange`, which record a restore point under the same rules: a window
    /// tiled as one of a set must be as undoable as one tiled alone.
    private static func rememberAnchor(_ key: WindowKey, current: CGRect, desk: [CGRect]) {
        let existing = restorePoints[key]
        let updated = RestorePoint.afterTile(existing, current: current, desk: desk)
        if existing == nil {
            // Evict the *oldest* rather than clearing the table. Wiping it wholesale meant
            // tiling one more window than the cap silently threw away the restore frame of
            // every window the user was still working with, and ⌃⌘Z then did nothing at all.
            while restoreOrder.count >= restoreLimit, let oldest = restoreOrder.first {
                restoreOrder.removeFirst()
                restorePoints.removeValue(forKey: oldest)
            }
            restoreOrder.append(key)
        } else if existing != updated {
            restoreOrder.removeAll { $0 == key }
            restoreOrder.append(key)
        }
        restorePoints[key] = updated
    }

    /// Writes `target` to `window`, reads where it landed, corrects a refused size and records the
    /// result in the window's restore slot. Returns the frames written and read back, which the
    /// caller may also need — `apply` hands them to the width cycle.
    ///
    /// Position, size, position. Some apps clamp a move against their *current* size (so the
    /// first position lands short) and others clamp a resize against the screen edge from
    /// their old origin. Setting position twice around the resize is what makes both land,
    /// and it is what every window manager on this platform ends up doing.
    ///
    /// One call rather than three, so tiling this app's own settings window takes a single
    /// hop onto the main thread instead of three — see `AX.onOwningThread`.
    ///
    /// Where this left the window — the frame written and the frame read back: a host
    /// that sizes to its own increments (a terminal's character cells) lands a few points
    /// off what was asked, and one that applies writes late still reports the old frame
    /// here. Read once per write, and only written to again when the host refused the size:
    /// `corrected` puts the window against the edge the tile was meant to touch, which the
    /// origin written for the size asked for did not. The cycle and the restore slot both
    /// remember where the window *ended up* — see `continuesCycle` and `RestorePoint.tiled`.
    @discardableResult
    private static func write(
        _ window: AXUIElement, key: WindowKey, target: CGRect, fitArea: CGRect?, fitGap: CGFloat,
        remember: ((inout RestorePoint, [CGRect]) -> Void)?
    ) -> [CGRect] {
        AX.setFrame(window, target, sizing: true, repositionAfterSizing: true)
        var landed = [target]
        if var actual = AX.frame(window) {
            if let fitArea,
                let origin = corrected(target: target, actual: actual, area: fitArea, gap: fitGap)
            {
                actual.origin = origin
                AX.setFrame(window, actual, sizing: false)
            }
            landed.append(actual)
        }
        if let remember, var slot = restorePoints[key] {
            remember(&slot, landed)
            restorePoints[key] = slot
        }
        return landed
    }

    /// One window offered to `arrange`: where the window server says it is, and whose it is.
    struct Candidate: Sendable {
        let pid: pid_t
        let bounds: CGRect
        let bundleID: String?
    }

    /// Lays a set of windows out together — the tiler's half of "Tile all windows" and "Cascade all
    /// windows", which are dispatched here ahead of `apply` because no single window's frame can
    /// express them.
    ///
    /// `candidates` are in z-order, frontmost first. Everything Accessibility is done here, on the
    /// queue, for the reason every other such call is: resolving a window is a walk of its app's
    /// window list, and twelve of them on the main thread is the run loop the keyboard tap is
    /// serviced from. That includes the `.neverTile` *title* rules, because a title is only
    /// readable once the window is resolved — a window one of them names is left where it is and
    /// takes no cell, so the rest close up around it. A window that cannot be resolved by its bounds
    /// is left alone the same way, as a swap does: moving part of a set is better than guessing at
    /// which of an app's windows was meant.
    ///
    /// `layout` turns the survivors' current frames, in the same order, into the frames to write.
    /// The survivors are capped at `ArrangeAll.limit` *after* the rules have had their say, so a
    /// protected window does not use up one of the twelve places.
    ///
    /// Each window goes through the same restore-point and read-back machinery as a single tile
    /// (`rememberAnchor`, `write`), so ⌃⌘Z puts any one of them back. The slot records no
    /// `placement`: a cell of a grid of however many windows there were is not an arrangement a
    /// display move could re-apply, and recording one that is not in the enum would be dishonest.
    /// Written back to front, so the frontmost window is the last to be touched.
    ///
    /// `gap` is the tile gap the read-back correction allows for — zero for a cascade, whose
    /// windows are not tiles.
    static func arrange(
        _ candidates: [Candidate], areas: [CGRect], area: CGRect, gap: CGFloat,
        titleRules: [CompiledTitleRule],
        layout: @escaping @Sendable ([CGRect]) -> [CGRect]
    ) {
        queue.async {
            var windows: [(element: AXUIElement, key: WindowKey, current: CGRect)] = []
            var seen = Set<WindowKey>()
            for candidate in candidates {
                guard windows.count < ArrangeAll.limit else { break }
                guard
                    let element = AX.window(ofApplication: candidate.pid, matching: candidate.bounds),
                    let current = AX.frame(element)
                else { continue }
                let key = WindowKey(element: element)
                // Two window-server entries can resolve to one element — a host's phantom backing
                // window at the same bounds — and one window must not take two cells.
                guard seen.insert(key).inserted else { continue }
                if titleRules.mayNeverTile(candidate.bundleID),
                    CompiledTitleRule.matches(
                        titleRules, bundleID: candidate.bundleID,
                        title: AX.copyString(element, kAXTitleAttribute) ?? "", action: .neverTile)
                {
                    continue
                }
                windows.append((element, key, current))
            }
            let frames = layout(windows.map(\.current))
            guard !windows.isEmpty, frames.count == windows.count else {
                Log.general.notice("tiling: nothing to arrange")
                return
            }
            cycle = nil
            for index in windows.indices.reversed() {
                let window = windows[index]
                rememberAnchor(window.key, current: window.current, desk: areas)
                write(
                    window.element, key: window.key, target: frames[index], fitArea: area,
                    fitGap: gap,
                    remember: { slot, landed in (slot.tiled, slot.placement) = (landed, nil) })
            }
            Log.general.notice("tiling: arranged \(windows.count, privacy: .public) window(s)")
        }
    }

    /// What a display move records and checks once it has written — see `apply`.
    ///
    /// Only a window still where the tiler left it has anything to record: its remembered frames
    /// follow it to the destination, so a tile → move → tile → restore chain still ends at the
    /// original rather than treating the move as a hand-made one. A window the user has moved
    /// themselves has no remembered tile to refresh. The landing is checked against the destination
    /// only when a tile was re-applied there; a carried window keeps a size someone chose and has
    /// no edge it was meant to touch.
    private static func displayMoveBookkeeping(
        current: CGRect, to: CGRect, slot: RestorePoint?, gap: CGFloat
    ) -> (CGRect?, CGFloat, ((inout RestorePoint, [CGRect]) -> Void)?) {
        guard let slot, slot.isAtTile(current) else { return (nil, 0, nil) }
        let remember: (inout RestorePoint, [CGRect]) -> Void = { slot, landed in
            slot.tiled = landed
        }
        guard let placed = slot.placement else { return (nil, 0, remember) }
        return (to, placed.arrangement.takesGap ? gap : 0, remember)
    }

    /// The display a previous/next-display move lands on, as an index into `areas`.
    ///
    /// Counted **left to right**, not in `areas`' own order. That order is `NSScreen.screens`,
    /// the order macOS happens to enumerate the displays in — the primary first, the rest as the
    /// hardware reports them — and has nothing to do with where they sit on the desk. Stepping
    /// through it made "move to next display", bound to ⌃⇧⌘→, throw a window *left* on any desk
    /// whose displays were not enumerated in the order they are arranged. Ties on x (displays
    /// stacked one above the other) go top to bottom. Wraps at both ends, as it always has.
    ///
    /// For the relative step only. The numbered targets `display1…4` and the tiles' badges keep
    /// counting `NSScreen.screens`, because a number is a name and names must not reshuffle.
    static func displayStepTarget(from home: Int, step: Int, in areas: [CGRect]) -> Int {
        let order = areas.indices.sorted { a, b in
            (areas[a].minX, areas[a].minY, a) < (areas[b].minX, areas[b].minY, b)
        }
        guard let position = order.firstIndex(of: home) else { return home }
        return order[((position + step) % order.count + order.count) % order.count]
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
    static let titlebarHeight: CGFloat = 28
    /// How much of that strip has to be on a display for the window to count as grabbable. About the
    /// width of the traffic lights — enough to put a cursor on without hunting for it.
    private static let minimumGrab: CGFloat = 60

    /// How much of the screen this press should take, advancing the cycle when the same arrangement
    /// is applied to the same window twice running — and the window is still where the last press
    /// put it.
    ///
    /// A window that has not been cycled but already *is* this arrangement's half — put there by a
    /// drag, ⌥T or a restored layout — starts at ⅔ rather than ½, since ½ would be a press that
    /// visibly does nothing. See `stepMatching`.
    private static func nextFraction(
        for arrangement: WindowArrangement, key: WindowKey, cycleWidths: Bool, current: CGRect,
        area: CGRect, gap: CGFloat
    ) -> CGFloat {
        // The tables above are safe without a lock only while every touch is on `queue`; the
        // comment says so, this makes a caller from anywhere else fail where it stands.
        dispatchPrecondition(condition: .onQueue(queue))
        let fractions = WindowArrangement.cycleFractions
        guard cycleWidths, arrangement.cycles else {
            cycle = nil
            return fractions[0]
        }
        if let cycle, cycle.key == key, cycle.arrangement == arrangement,
            continuesCycle(left: cycle.left, current: current) {
            let step = (cycle.step + 1) % fractions.count
            self.cycle = (key, arrangement, step, [])
            return fractions[step]
        }
        // Only the half skips ahead. A window at ⅔ or ⅓ that nothing has cycled — the two-thirds
        // chord put it there, say — gets the half: a visible change, and what the key is named for.
        let step = stepMatching(arrangement, current: current, area: area, gap: gap) == 0 ? 1 : 0
        cycle = (key, arrangement, step, [])
        return fractions[step]
    }

    /// The index in `cycleFractions` of the width `arrangement` has already given a window at
    /// `current`, or nil when it is at none of them.
    ///
    /// Compared on the frame the tile branch would actually write — the same area, the gap applied
    /// the same way — with the same two points of slack as `continuesCycle`.
    static func stepMatching(
        _ arrangement: WindowArrangement, current: CGRect, area: CGRect, gap: CGFloat
    ) -> Int? {
        WindowArrangement.cycleFractions.indices.first { index in
            guard let frame = arrangement.frame(
                in: area, current: current, fraction: WindowArrangement.cycleFractions[index])
            else { return false }
            let tile = arrangement.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame
            return continuesCycle(left: [tile], current: current)
        }
    }

    /// Whether a window at `current` is still where the last cycle step `left` it.
    ///
    /// The cycle used to advance whenever the same window got the same arrangement, full stop — so
    /// ⌃⌘← on a window the user had since dragged somewhere else, or pressed again the next day,
    /// gave two-thirds or a third where the press plainly meant "the left half". Only a press on a
    /// window that has not been touched since is a *repeat*; anything else starts over at a half.
    ///
    /// Two points of slack, the tolerance the Accessibility harness already allows a real window's
    /// round trip: hosts round frames, and a fractional backing scale lands a half-point off.
    static func continuesCycle(left: [CGRect], current: CGRect) -> Bool {
        let slack: CGFloat = 2
        return left.contains { frame in
            abs(frame.minX - current.minX) <= slack && abs(frame.minY - current.minY) <= slack
                && abs(frame.width - current.width) <= slack
                && abs(frame.height - current.height) <= slack
        }
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

extension Collection where Element == CompiledTitleRule {
    /// Whether any `.neverTile` rule here could apply to a window of `bundleID` at all.
    ///
    /// Asked before a window's title is read, because the title is Accessibility IPC to that app —
    /// and on most installs no rule could use the answer. Every path that honours the title rules
    /// skips the read when this says no.
    func mayNeverTile(_ bundleID: String?) -> Bool {
        contains { $0.action == .neverTile && ($0.bundleID == nil || $0.bundleID == bundleID) }
    }
}
