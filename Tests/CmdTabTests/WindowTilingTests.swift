import CoreGraphics
import XCTest

@testable import CmdTab

/// The tiling geometry, which is the part of window tiling that can be checked without a window.
///
/// Every frame here is in Accessibility coordinates — top-left origin, y growing downward — which
/// is the one thing about this maths that is easy to get backwards: "top half" is the *lower* y.
final class WindowTilingTests: XCTestCase {
    /// A 1600×1000 usable area starting 25pt down, as a menu bar would leave it.
    private let area = CGRect(x: 0, y: 25, width: 1600, height: 1000)
    private let window = CGRect(x: 400, y: 300, width: 800, height: 600)

    private func frame(_ arrangement: WindowArrangement, fraction: CGFloat = 0.5) -> CGRect? {
        arrangement.frame(in: area, current: window, fraction: fraction)
    }

    /// The arrangements that ship with a chord.
    ///
    /// Three families deliberately ship unbound — focus, swap and the nudges — because there is no
    /// arrow combination left to give them; see `WindowArrangement.defaultHotkey`. Every test below
    /// that asks a question about "the default chords" means these, and asking it of an arrangement
    /// that has none would be asserting against a `nil` nobody promised anything about.
    private var bound: [(WindowArrangement, Hotkey)] {
        WindowArrangement.allCases.compactMap { a in a.defaultHotkey.map { (a, $0) } }
    }

    // MARK: - Halves

    func testLeftHalfTakesTheLeadingEdgeAndFullHeight() {
        XCTAssertEqual(frame(.leftHalf), CGRect(x: 0, y: 25, width: 800, height: 1000))
    }

    func testRightHalfIsFlushWithTheTrailingEdge() {
        XCTAssertEqual(frame(.rightHalf), CGRect(x: 800, y: 25, width: 800, height: 1000))
    }

    /// The half that hugs the *top* of the screen is the one at the area's minimum y — the trap in
    /// a flipped coordinate space.
    func testTopHalfStartsAtTheTopOfTheUsableArea() {
        XCTAssertEqual(frame(.topHalf), CGRect(x: 0, y: 25, width: 1600, height: 500))
    }

    func testBottomHalfIsFlushWithTheBottomEdge() {
        XCTAssertEqual(frame(.bottomHalf), CGRect(x: 0, y: 525, width: 1600, height: 500))
        XCTAssertEqual(frame(.bottomHalf)?.maxY, area.maxY)
    }

    // MARK: - Width cycling

    func testATwoThirdsRightHalfStaysFlushWithTheTrailingEdge() {
        let two3 = WindowArrangement.cycleFractions[1]
        let frame = frame(.rightHalf, fraction: two3)
        XCTAssertEqual(frame?.maxX, area.maxX)
        XCTAssertEqual(frame?.width ?? 0, area.width * two3, accuracy: 0.001)
    }

    func testCycleFractionsStartAtAHalfAndCoverThirds() {
        XCTAssertEqual(WindowArrangement.cycleFractions.first, 0.5)
        XCTAssertEqual(Set(WindowArrangement.cycleFractions).count, 3)
    }

    func testOnlyHalvesCycle() {
        let cycling = WindowArrangement.allCases.filter(\.cycles)
        XCTAssertEqual(Set(cycling), Set([.leftHalf, .rightHalf, .topHalf, .bottomHalf]))
    }

    // MARK: - Corners

    func testCornersQuarterTheAreaAndMeetInTheMiddle() {
        XCTAssertEqual(frame(.topLeft), CGRect(x: 0, y: 25, width: 800, height: 500))
        XCTAssertEqual(frame(.topRight), CGRect(x: 800, y: 25, width: 800, height: 500))
        XCTAssertEqual(frame(.bottomLeft), CGRect(x: 0, y: 525, width: 800, height: 500))
        XCTAssertEqual(frame(.bottomRight), CGRect(x: 800, y: 525, width: 800, height: 500))
    }

    // MARK: - Maximize, centre, restore

    func testMaximizeFillsTheUsableAreaRatherThanTheWholeScreen() {
        XCTAssertEqual(frame(.maximize), area)
    }

    func testCenterKeepsTheWindowSize() {
        let centred = frame(.center)
        XCTAssertEqual(centred?.size, window.size)
        XCTAssertEqual(centred?.midX, area.midX)
        XCTAssertEqual(centred?.midY, area.midY)
    }

    /// A window larger than the screen is clamped rather than centred off both edges.
    func testCenterClampsAWindowBiggerThanTheScreen() {
        let huge = CGRect(x: -200, y: -200, width: 3000, height: 2000)
        let centred = WindowArrangement.center.frame(in: area, current: huge, fraction: 0.5)
        XCTAssertEqual(centred, area)
    }

    /// Restore is not computed from the screen — the caller substitutes the saved frame.
    func testRestoreHasNoComputedFrame() {
        XCTAssertNil(frame(.restore))
    }

    // MARK: - Gaps

    /// The whole gap against a screen edge, half of it at a seam — so two neighbours end up exactly
    /// one gap apart, the same distance as each is from the outside.
    func testTwoHalvesEndUpOneGapApart() {
        let gap: CGFloat = 20
        let left = TilingGap.inset(frame(.leftHalf)!, in: area, gap: gap)
        let right = TilingGap.inset(frame(.rightHalf)!, in: area, gap: gap)
        XCTAssertEqual(right.minX - left.maxX, gap, accuracy: 0.001)
        XCTAssertEqual(left.minX - area.minX, gap, accuracy: 0.001)
        XCTAssertEqual(area.maxX - right.maxX, gap, accuracy: 0.001)
    }

    func testMaximizeTakesTheFullGapOnEveryEdge() {
        let gap: CGFloat = 16
        let maximized = TilingGap.inset(frame(.maximize)!, in: area, gap: gap)
        XCTAssertEqual(maximized.minX - area.minX, gap, accuracy: 0.001)
        XCTAssertEqual(maximized.minY - area.minY, gap, accuracy: 0.001)
        XCTAssertEqual(area.maxX - maximized.maxX, gap, accuracy: 0.001)
        XCTAssertEqual(area.maxY - maximized.maxY, gap, accuracy: 0.001)
    }

    /// A corner has two outside edges and two seams, and has to tell them apart.
    func testACornerTakesFullGapOutsideAndHalfAtItsSeams() {
        let gap: CGFloat = 24
        let corner = TilingGap.inset(frame(.topLeft)!, in: area, gap: gap)
        XCTAssertEqual(corner.minX - area.minX, gap, accuracy: 0.001)
        XCTAssertEqual(corner.minY - area.minY, gap, accuracy: 0.001)
        XCTAssertEqual(frame(.topLeft)!.maxX - corner.maxX, gap / 2, accuracy: 0.001)
        XCTAssertEqual(frame(.topLeft)!.maxY - corner.maxY, gap / 2, accuracy: 0.001)
    }

    /// The thirds are computed by division and land a hair off the exact edge; without the slack in
    /// `TilingGap` the right third would take an inner gap on the side against the screen.
    func testTheOuterThirdsStillReadAsScreenEdges() {
        let gap: CGFloat = 18
        let left = TilingGap.inset(frame(.leftThird)!, in: area, gap: gap)
        let right = TilingGap.inset(frame(.rightThird)!, in: area, gap: gap)
        XCTAssertEqual(left.minX - area.minX, gap, accuracy: 0.001)
        XCTAssertEqual(area.maxX - right.maxX, gap, accuracy: 0.001)
    }

    /// Every space between and around the thirds is one gap — which is what the eye reads — and the
    /// two outer thirds match each other.
    ///
    /// The middle third comes out half a gap *wider*, because it spends a half gap on each of its
    /// two seams where its neighbours spend a whole one on the screen edge. That is not an accident
    /// of this implementation: Rectangle's `GapCalculation.applyGaps` insets by the full gap and
    /// hands back half on each shared edge, which is the same arithmetic, so a window landing here
    /// lands where someone coming from Rectangle expects it to.
    func testThirdsAreEvenlySpacedAndTheOutersMatch() {
        let gap: CGFloat = 12
        let thirds = [WindowArrangement.leftThird, .centerThird, .rightThird]
            .map { TilingGap.inset(frame($0)!, in: area, gap: gap) }
        XCTAssertEqual(thirds[0].minX - area.minX, gap, accuracy: 0.001)
        XCTAssertEqual(thirds[1].minX - thirds[0].maxX, gap, accuracy: 0.001)
        XCTAssertEqual(thirds[2].minX - thirds[1].maxX, gap, accuracy: 0.001)
        XCTAssertEqual(area.maxX - thirds[2].maxX, gap, accuracy: 0.001)
        XCTAssertEqual(thirds[0].width, thirds[2].width, accuracy: 0.001)
        XCTAssertEqual(thirds[1].width - thirds[0].width, gap / 2, accuracy: 0.001)
    }

    func testZeroGapChangesNothing() {
        for arrangement in WindowArrangement.tilingArrangements {
            guard let plain = frame(arrangement) else { continue }
            XCTAssertEqual(TilingGap.inset(plain, in: area, gap: 0), plain)
        }
    }

    /// Every tile, spelled out against the rule rather than checked edge by edge: whole gap on a
    /// screen edge, half at a seam. This is also Rectangle's `GapCalculation` arithmetic, so a
    /// window lands where someone coming from Rectangle expects it to.
    func testEveryTileFollowsWholeOutsideHalfAtSeam() {
        let g: CGFloat = 20
        for arrangement in WindowArrangement.tilingArrangements {
            guard let plain = frame(arrangement) else { continue }
            let l = plain.minX - area.minX <= 1 ? g : g / 2
            let r = area.maxX - plain.maxX <= 1 ? g : g / 2
            let t = plain.minY - area.minY <= 1 ? g : g / 2
            let b = area.maxY - plain.maxY <= 1 ? g : g / 2
            XCTAssertEqual(
                TilingGap.inset(plain, in: area, gap: g),
                CGRect(
                    x: plain.minX + l, y: plain.minY + t,
                    width: plain.width - l - r, height: plain.height - t - b),
                "\(arrangement.rawValue)")
        }
    }

    /// A hand-edited defaults entry cannot ask for more than the slider offers.
    func testTheStoredGapIsHeldInsideTheSliderRange() {
        XCTAssertEqual(TilingGap.clamp(-10), 0)
        XCTAssertEqual(TilingGap.clamp(0), 0)
        XCTAssertEqual(TilingGap.clamp(24), 24)
        XCTAssertEqual(TilingGap.clamp(TilingGap.maximum + 200), TilingGap.maximum)
    }

    /// A gap wider than the tile would invert the frame; the tile is left alone instead.
    func testAnAbsurdGapIsRefusedRatherThanInverting() {
        let tiny = CGRect(x: area.minX, y: area.minY, width: 40, height: 30)
        XCTAssertEqual(TilingGap.inset(tiny, in: area, gap: 60), tiny)
        for arrangement in WindowArrangement.tilingArrangements {
            guard let plain = frame(arrangement) else { continue }
            let inset = TilingGap.inset(
                plain, in: area, gap: TilingGap.maximum)
            XCTAssertGreaterThan(inset.width, 0, "\(arrangement.rawValue) inverted")
            XCTAssertGreaterThan(inset.height, 0, "\(arrangement.rawValue) inverted")
        }
    }

    /// Centre keeps the window's own size and restore puts back a frame the user chose, so neither
    /// takes a gap — nor do the moves, which change no geometry at all.
    func testOnlyTilingArrangementsTakeAGap() {
        XCTAssertFalse(WindowArrangement.center.takesGap)
        XCTAssertFalse(WindowArrangement.restore.takesGap)
        XCTAssertFalse(WindowArrangement.previousDisplay.takesGap)
        XCTAssertFalse(WindowArrangement.nextDisplay.takesGap)
        XCTAssertFalse(WindowArrangement.previousDesktop.takesGap)
        XCTAssertFalse(WindowArrangement.nextDesktop.takesGap)
        // The families that keep the size the user pressed their way to. Insetting one of these
        // would make every "make larger" grow the window and then take some of it back.
        for arrangement in [WindowArrangement.larger, .smaller] + WindowArrangement.nudges
            + WindowArrangement.focusMoves + WindowArrangement.swaps
        {
            XCTAssertFalse(arrangement.takesGap, "\(arrangement.rawValue) should take no gap")
        }
        // The new fractions-of-the-screen tiles do take one, like every other tile.
        for arrangement in [WindowArrangement.topThird, .bottomThird, .leftTwoThirds, .rightTwoThirds] {
            XCTAssertTrue(arrangement.takesGap, "\(arrangement.rawValue) should take a gap")
        }
        for arrangement in [WindowArrangement.leftHalf, .topRight, .centerThird, .maximize] {
            XCTAssertTrue(arrangement.takesGap, "\(arrangement.rawValue) should take a gap")
        }
    }

    // MARK: - Bindings

    func testDisabledTilingMatchesNoGeometry() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        for arrangement in WindowArrangement.tilingArrangements {
            guard let chord = arrangement.defaultHotkey else { continue }
            XCTAssertNil(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers),
                "\(arrangement.rawValue) should be inert while tiling is off")
        }
    }

    /// The switch is about resizing. A move changes no layout, so it fires either way — the whole
    /// point of splitting the two families in `arrangement(code:flags:)`.
    func testDisabledTilingStillMatchesTheMoves() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        tiling.desktopMoves = true
        for arrangement in WindowArrangement.moves {
            let chord = try XCTUnwrap(arrangement.defaultHotkey)
            XCTAssertEqual(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers), arrangement,
                "\(arrangement.rawValue) should fire with tiling off")
        }
    }

    /// A cleared move is still cleared: ungating them is not a licence to revive a binding the user
    /// has handed back.
    func testAClearedMoveDoesNotFireWithTilingOff() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        let chord = try XCTUnwrap(WindowArrangement.nextDisplay.defaultHotkey)
        tiling.bindings[.nextDisplay] = nil
        XCTAssertNil(tiling.arrangement(code: chord.keyCode, flags: chord.modifiers))
    }

    /// The Desktop moves answer to a switch of their own on top of the tiling one, because the
    /// gesture behind them takes the pointer and opens Mission Control — see `DesktopMover`.
    func testDesktopMovesAreInertUntilSwitchedOn() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        tiling.desktopMoves = false
        for arrangement in [WindowArrangement.previousDesktop, .nextDesktop] {
            let chord = try XCTUnwrap(arrangement.defaultHotkey)
            XCTAssertNil(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers),
                "\(arrangement.rawValue) should not fire with the Desktop switch off")
        }
    }

    /// The switch is specific to its own family: turning it off must not take the display moves —
    /// or anything else — down with it.
    func testTheDesktopSwitchLeavesTheOtherArrangementsAlone() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        tiling.desktopMoves = false
        let next = try XCTUnwrap(WindowArrangement.nextDisplay.defaultHotkey)
        XCTAssertEqual(
            tiling.arrangement(code: next.keyCode, flags: next.modifiers), .nextDisplay)
        let left = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        XCTAssertEqual(tiling.arrangement(code: left.keyCode, flags: left.modifiers), .leftHalf)
    }

    func testDesktopMovesFireWithTilingOffOnceSwitchedOn() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        tiling.desktopMoves = true
        for arrangement in [WindowArrangement.previousDesktop, .nextDesktop] {
            let chord = try XCTUnwrap(arrangement.defaultHotkey)
            XCTAssertEqual(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers), arrangement,
                "\(arrangement.rawValue) should fire with tiling off but its own switch on")
        }
    }

    /// Following defaults to on, and is a *stored* default rather than a fallback: the loader has to
    /// tell "absent" from "explicitly false", because `bool(forKey:)` reports false for both and
    /// would ship the opposite of what is documented.
    func testFollowingADesktopMoveDefaultsToOn() {
        XCTAssertTrue(WindowTilingBindings.defaults.followsDesktopMove)
        XCTAssertFalse(WindowTilingBindings.defaults.desktopMoves)
    }

    /// The follow switch is about what happens *after* a move; it must not decide whether the move
    /// happens at all. Turning it off still leaves the chords firing.
    func testTurningFollowingOffStillFiresTheMove() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.desktopMoves = true
        tiling.followsDesktopMove = false
        for arrangement in [WindowArrangement.previousDesktop, .nextDesktop] {
            let chord = try XCTUnwrap(arrangement.defaultHotkey)
            XCTAssertEqual(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers), arrangement,
                "\(arrangement.rawValue) should still fire with following off")
        }
    }

    /// The Desktop chords are ordinary bindings: whatever the user records replaces the default,
    /// and the default stops firing. Nothing about the family is special-cased in the recorder — it
    /// is `TilingShortcutRecorder` over `WindowArrangement`, like every other row on the pane.
    func testACustomDesktopChordReplacesTheDefault() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.desktopMoves = true
        let custom = Hotkey(
            keyCode: 46,  // M
            modifierRaw: CGEventFlags.maskControl.union(.maskAlternate).union(.maskCommand).rawValue)
        tiling.bindings[.nextDesktop] = custom
        XCTAssertEqual(
            tiling.arrangement(code: custom.keyCode, flags: custom.modifiers), .nextDesktop)
        let old = try XCTUnwrap(WindowArrangement.nextDesktop.defaultHotkey)
        XCTAssertNil(
            tiling.arrangement(code: old.keyCode, flags: old.modifiers),
            "the replaced default must stop firing")
    }

    /// Cleared means handed back to whatever app wants the chord, not "fall back to the default".
    func testAClearedDesktopChordFiresNothing() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.desktopMoves = true
        let chord = try XCTUnwrap(WindowArrangement.previousDesktop.defaultHotkey)
        tiling.bindings[.previousDesktop] = nil
        XCTAssertNil(tiling.arrangement(code: chord.keyCode, flags: chord.modifiers))
    }

    /// Each family steps one the right way, and the two families are disjoint — nothing is both a
    /// display move and a Desktop move.
    func testEachMoveFamilyStepsInBothDirections() {
        XCTAssertEqual(WindowArrangement.previousDesktop.desktopStep, -1)
        XCTAssertEqual(WindowArrangement.nextDesktop.desktopStep, 1)
        XCTAssertNil(WindowArrangement.previousDisplay.desktopStep)
        XCTAssertNil(WindowArrangement.nextDisplay.desktopStep)
        XCTAssertNil(WindowArrangement.previousDesktop.displayStep)
        XCTAssertNil(WindowArrangement.nextDesktop.displayStep)
        XCTAssertNil(WindowArrangement.leftHalf.desktopStep)
    }

    /// The four move chords have to be four distinct combinations, or one of them silently shadows
    /// another — the arrows are shared and only the modifiers tell them apart.
    func testTheMoveChordsDoNotCollide() throws {
        let moves = WindowArrangement.moves
        for (index, arrangement) in moves.enumerated() {
            for other in moves[moves.index(after: index)...] {
                XCTAssertNotEqual(
                    arrangement.defaultHotkey, other.defaultHotkey,
                    "\(arrangement.rawValue) and \(other.rawValue) share a default chord")
            }
        }
        for arrangement in WindowArrangement.moves {
            XCTAssertTrue(
                try XCTUnwrap(arrangement.defaultHotkey).isUsableGlobally,
                "\(arrangement.rawValue) needs a globally usable default")
        }
    }

    /// The gated and ungated sets partition the arrangements, and the ungated one is exactly the
    /// moves plus the focus chords.
    ///
    /// A **swap** is on the gated side and that is the assertion worth having here: it is the one
    /// new family that could plausibly have gone either way, since it does not resize a window —
    /// but it does move two of them into each other's frames, which is a layout change, so it waits
    /// on the switch captioned about layout.
    func testTheGatedAndUngatedSetsPartitionTheArrangements() {
        XCTAssertEqual(
            Set(WindowArrangement.ungated).union(WindowArrangement.tilingArrangements),
            Set(WindowArrangement.allCases))
        XCTAssertTrue(
            Set(WindowArrangement.ungated).isDisjoint(with: WindowArrangement.tilingArrangements))
        XCTAssertEqual(
            Set(WindowArrangement.moves),
            Set([.previousDisplay, .nextDisplay, .previousDesktop, .nextDesktop]))
        XCTAssertEqual(
            Set(WindowArrangement.ungated),
            Set(WindowArrangement.moves).union(WindowArrangement.focusMoves))
        for swap in WindowArrangement.swaps {
            XCTAssertTrue(
                WindowArrangement.tilingArrangements.contains(swap),
                "a swap rearranges windows, so it waits on the tiling switch")
        }
    }

    func testEnabledTilingMatchesItsOwnChord() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        XCTAssertEqual(tiling.arrangement(code: left.keyCode, flags: left.modifiers), .leftHalf)
    }

    /// Exact match: an extra modifier on top of the binding is a different chord, and must fall
    /// through to whatever app is in front rather than tiling.
    func testAnExtraModifierDoesNotMatch() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        XCTAssertNil(
            tiling.arrangement(
                code: left.keyCode, flags: left.modifiers.union(.maskAlternate)))
    }

    /// A cleared binding hands its chord back: nothing matches it, and the arrangement is not
    /// silently revived from its default.
    func testAClearedBindingMatchesNothing() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        tiling.bindings[.leftHalf] = nil
        XCTAssertNil(tiling.arrangement(code: left.keyCode, flags: left.modifiers))
    }

    func testClearingOneBindingLeavesTheRestAlone() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        tiling.bindings[.leftHalf] = nil
        let right = try XCTUnwrap(WindowArrangement.rightHalf.defaultHotkey)
        XCTAssertEqual(tiling.arrangement(code: right.keyCode, flags: right.modifiers), .rightHalf)
    }

    func testDefaultsHaveNoConflicts() {
        let tiling = WindowTilingBindings.defaults
        for arrangement in WindowArrangement.allCases {
            XCTAssertEqual(tiling.conflicts(with: arrangement), [])
        }
    }

    func testTwoArrangementsOnOneChordReportEachOther() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.bindings[.center] = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        XCTAssertEqual(tiling.conflicts(with: .leftHalf), [.center])
        XCTAssertEqual(tiling.conflicts(with: .center), [.leftHalf])
    }

    /// An unassigned arrangement conflicts with nothing, however many others are also unassigned —
    /// "both cleared" is not a clash.
    func testClearedBindingsDoNotConflictWithEachOther() {
        var tiling = WindowTilingBindings.defaults
        tiling.bindings[.center] = nil
        tiling.bindings[.restore] = nil
        XCTAssertEqual(tiling.conflicts(with: .center), [])
    }

    // MARK: - Trigger collisions

    /// A chord the switcher trigger claims can never reach the tiling branch — the tap matches the
    /// trigger first — so the recorder has to refuse it rather than store a binding that looks set.
    @MainActor
    func testAChordMatchingTheSwitcherTriggerIsReported() {
        let behavior = BehaviorStore.shared
        let trigger = behavior.hotkey
        XCTAssertNotNil(WindowTilingBindings.triggerClaiming(trigger, in: behavior))
    }

    /// Shift is the reverse-direction modifier, not part of the trigger's identity, so ⇧ on top of
    /// the trigger's chord is still the trigger.
    @MainActor
    func testShiftDoesNotRescueAChordFromTheTrigger() {
        let behavior = BehaviorStore.shared
        let trigger = behavior.hotkey
        let shifted = Hotkey(
            keyCode: trigger.keyCode,
            modifierRaw: trigger.modifiers.union(.maskShift).rawValue)
        XCTAssertNotNil(WindowTilingBindings.triggerClaiming(shifted, in: behavior))
    }

    @MainActor
    func testDefaultTilingChordsAreClearOfTheTrigger() {
        let behavior = BehaviorStore.shared
        for (arrangement, chord) in bound {
            XCTAssertNil(
                WindowTilingBindings.triggerClaiming(chord, in: behavior),
                "\(arrangement.rawValue) collides with a switcher trigger")
        }
    }

    /// Every arrangement that ships bound holds a chord no other bound one holds.
    ///
    /// Restricted to the bound ones, and that is not a weakening of the invariant — it is the whole
    /// of it. Three families ship with no chord at all, and "they all share the absence of one" is
    /// not a collision: nothing fires, so nothing can shadow anything.
    func testEveryBoundArrangementHasADistinctDefaultChord() {
        let chords = bound.map { "\($0.1.keyCode):\($0.1.modifierRaw)" }
        XCTAssertEqual(Set(chords).count, bound.count)
        // A guard on the guard: if every arrangement somehow lost its default, the assertion above
        // would pass over an empty list.
        XCTAssertGreaterThan(bound.count, 10)
    }

    /// The three unbound families are unbound *on purpose* — see `defaultHotkey`. Asserted rather
    /// than left implicit, because the failure it prevents is silent in both directions: a chord
    /// added here claims a system-wide combination on every install that has tiling on, and one
    /// removed from a bound family leaves a documented default that does not exist.
    func testFocusSwapAndNudgeShipUnbound() {
        for arrangement in WindowArrangement.focusMoves + WindowArrangement.swaps
            + WindowArrangement.nudges
        {
            XCTAssertNil(
                arrangement.defaultHotkey, "\(arrangement.rawValue) should ship unbound")
        }
        for arrangement in [WindowArrangement.topThird, .bottomThird, .leftTwoThirds, .rightTwoThirds] {
            XCTAssertNil(arrangement.defaultHotkey, "\(arrangement.rawValue) should ship unbound")
        }
        XCTAssertNotNil(WindowArrangement.larger.defaultHotkey)
        XCTAssertNotNil(WindowArrangement.smaller.defaultHotkey)
    }

    /// Every default is anchored on ⌃⌘, the combination macOS leaves almost entirely free.
    ///
    /// Containment rather than equality, because the arrows carry three families that share a key
    /// and are told apart by what is stacked on top: the halves are bare ⌃⌘, the display moves add
    /// ⇧ ("throw it further"), and the Desktop moves add ⌥ ("further still"). ⇧ never reaches
    /// `heldModifiers` at all — it is masked there, since Shift only ever means "backwards" — so
    /// before the Desktop moves existed equality and containment could not be told apart, and
    /// equality was the tighter-looking way to write it. ⌥ is a real held modifier, so they part
    /// company here. The invariant that matters is the anchor, not the absence of qualifiers.
    func testDefaultChordsAllHoldControlCommand() {
        let anchor = CGEventFlags.maskControl.union(.maskCommand)
        for (arrangement, chord) in bound {
            XCTAssertTrue(
                chord.heldModifiers.isSuperset(of: anchor),
                "\(arrangement.rawValue) should be anchored on ⌃⌘")
        }
    }

    /// The qualifier stacking above, asserted directly: bare ⌃⌘ tiles, ⌥ on top moves a Desktop.
    /// Without this the containment test would pass just as happily if every Desktop default
    /// quietly became a bare ⌃⌘ chord and started shadowing a half.
    func testDesktopMovesQualifyTheAnchorWithOption() throws {
        for arrangement in [WindowArrangement.previousDesktop, .nextDesktop] {
            XCTAssertTrue(
                try XCTUnwrap(arrangement.defaultHotkey).heldModifiers.contains(.maskAlternate),
                "\(arrangement.rawValue) should add ⌥ to the anchor")
        }
        XCTAssertFalse(
            try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey).heldModifiers
                .contains(.maskAlternate))
    }

    /// The shifted display moves must stay distinct from the unshifted halves they share a key with,
    /// or throwing a window to the next display would just tile it right.
    func testDisplayMovesAreDistinctFromTheHalvesTheyShareAKeyWith() throws {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let half = try XCTUnwrap(WindowArrangement.leftHalf.defaultHotkey)
        let move = try XCTUnwrap(WindowArrangement.previousDisplay.defaultHotkey)
        XCTAssertEqual(half.keyCode, move.keyCode)
        XCTAssertEqual(tiling.arrangement(code: half.keyCode, flags: half.modifiers), .leftHalf)
        XCTAssertEqual(
            tiling.arrangement(code: move.keyCode, flags: move.modifiers), .previousDisplay)
    }

    // MARK: - Thirds

    /// Edges meet to within floating-point noise. The right third is measured back from the area's
    /// trailing edge rather than forward from two widths, so the two meet at a value that differs in
    /// the last bits — a gap of about 2×10⁻¹³ points, which is not a seam anyone can see.
    func testThirdsSpanTheAreaWithoutGaps() {
        XCTAssertEqual(frame(.leftThird)?.minX, area.minX)
        XCTAssertEqual(frame(.leftThird)?.maxX ?? 0, frame(.centerThird)?.minX ?? 0, accuracy: 0.001)
        XCTAssertEqual(frame(.centerThird)?.maxX ?? 0, frame(.rightThird)?.minX ?? 0, accuracy: 0.001)
        XCTAssertEqual(frame(.rightThird)?.maxX, area.maxX)
    }

    func testThirdsAreFullHeight() {
        for arrangement in [WindowArrangement.leftThird, .centerThird, .rightThird] {
            XCTAssertEqual(frame(arrangement)?.height, area.height)
            XCTAssertEqual(frame(arrangement)?.width ?? 0, area.width / 3, accuracy: 0.001)
        }
    }

    /// A third is already a third — pressing it twice must not start resizing it.
    func testThirdsDoNotCycle() {
        for arrangement in [WindowArrangement.leftThird, .centerThird, .rightThird] {
            XCTAssertFalse(arrangement.cycles)
        }
    }

    // MARK: - Display moves

    /// Not computed from the current screen: the caller re-runs them against the destination.
    func testDisplayMovesHaveNoComputedFrame() {
        XCTAssertNil(frame(.previousDisplay))
        XCTAssertNil(frame(.nextDisplay))
    }

    func testOnlyDisplayMovesCarryAStep() {
        XCTAssertEqual(WindowArrangement.previousDisplay.displayStep, -1)
        XCTAssertEqual(WindowArrangement.nextDisplay.displayStep, 1)
        for arrangement in WindowArrangement.allCases
        where arrangement != .previousDisplay && arrangement != .nextDisplay {
            XCTAssertNil(arrangement.displayStep, "\(arrangement.rawValue) is not a display move")
        }
    }

    // MARK: - Rows, and two-thirds

    /// The thirds turned on their side: full width, a third of the height, and the bottom one flush
    /// with the bottom edge rather than two heights down from the top.
    func testRowThirdsSpanTheWidthAndSitFlush() throws {
        let top = try XCTUnwrap(frame(.topThird))
        XCTAssertEqual(top.origin, CGPoint(x: 0, y: 25))
        XCTAssertEqual(top.width, area.width)
        XCTAssertEqual(top.height, area.height / 3, accuracy: 0.001)
        let bottom = try XCTUnwrap(frame(.bottomThird))
        XCTAssertEqual(bottom.maxY, area.maxY)
        XCTAssertEqual(bottom.width, area.width)
        XCTAssertEqual(bottom.height, area.height / 3, accuracy: 0.001)
    }

    func testTwoThirdsTakeTwoThirdsOfTheWidthOnTheRightSide() throws {
        let left = try XCTUnwrap(frame(.leftTwoThirds))
        XCTAssertEqual(left.origin, CGPoint(x: 0, y: 25))
        XCTAssertEqual(left.height, area.height)
        XCTAssertEqual(left.width, area.width * 2 / 3, accuracy: 0.001)
        let right = try XCTUnwrap(frame(.rightTwoThirds))
        XCTAssertEqual(right.maxX, area.maxX)
        XCTAssertEqual(right.width, area.width * 2 / 3, accuracy: 0.001)
    }

    /// A two-thirds tile and the matching third have to add up to the screen, or the pair they exist
    /// to make leaves a stripe of desktop between them.
    func testTwoThirdsAndTheOppositeThirdMeet() throws {
        let left = try XCTUnwrap(frame(.leftTwoThirds))
        let right = try XCTUnwrap(frame(.rightThird))
        XCTAssertEqual(left.maxX, right.minX, accuracy: 0.001)
    }

    // MARK: - Larger and smaller

    /// Growing and shrinking are anchored on the window's own centre, so a press of each returns it
    /// to where it started. Anchored on the origin instead, the window walks across the screen.
    func testGrowingThenShrinkingReturnsTheWindowToItsCentre() throws {
        let grown = try XCTUnwrap(frame(.larger))
        XCTAssertEqual(grown.midX, window.midX, accuracy: 0.001)
        XCTAssertEqual(grown.midY, window.midY, accuracy: 0.001)
        XCTAssertEqual(
            grown.width, window.width + area.width * WindowArrangement.sizeStepFraction,
            accuracy: 0.001)
        let shrunk = WindowArrangement.smaller.frame(in: area, current: grown, fraction: 0.5)
        XCTAssertEqual(shrunk?.width ?? 0, window.width, accuracy: 0.001)
        XCTAssertEqual(shrunk?.height ?? 0, window.height, accuracy: 0.001)
    }

    /// The step is a fraction of the *screen*, not of the window, so it is the same distance however
    /// small the window is — five per cent of a 200pt palette would be ten points, and a chord that
    /// visibly does nothing reads as broken.
    func testTheSizeStepIsMeasuredAgainstTheScreen() throws {
        let small = CGRect(x: 100, y: 100, width: 200, height: 150)
        let grown = try XCTUnwrap(
            WindowArrangement.larger.frame(in: area, current: small, fraction: 0.5))
        XCTAssertEqual(
            grown.width - small.width, area.width * WindowArrangement.sizeStepFraction,
            accuracy: 0.001)
    }

    func testGrowingStopsAtTheScreenAndStaysOnIt() throws {
        let huge = CGRect(x: 0, y: 25, width: 1590, height: 995)
        let grown = try XCTUnwrap(
            WindowArrangement.larger.frame(in: area, current: huge, fraction: 0.5))
        XCTAssertLessThanOrEqual(grown.width, area.width)
        XCTAssertLessThanOrEqual(grown.height, area.height)
        XCTAssertGreaterThanOrEqual(grown.minX, area.minX)
        XCTAssertLessThanOrEqual(grown.maxY, area.maxY)
    }

    /// Shrinking has a floor, so holding the key cannot end at a window too small to grab.
    func testShrinkingRefusesToGoBelowTheFloor() {
        let tiny = CGRect(x: 700, y: 500, width: 130, height: 130)
        XCTAssertNil(
            WindowArrangement.smaller.frame(in: area, current: tiny, fraction: 0.5),
            "a press that would take the window under the floor should do nothing")
    }

    // MARK: - Nudges

    func testEachNudgeMovesItsOwnWayAndKeepsTheSize() throws {
        for arrangement in WindowArrangement.nudges {
            let moved = try XCTUnwrap(frame(arrangement))
            XCTAssertEqual(moved.size, window.size, "\(arrangement.rawValue) resized the window")
        }
        let dx = area.width * WindowArrangement.sizeStepFraction
        let dy = area.height * WindowArrangement.sizeStepFraction
        XCTAssertEqual(frame(.nudgeRight)?.minX ?? 0, window.minX + dx, accuracy: 0.001)
        XCTAssertEqual(frame(.nudgeLeft)?.minX ?? 0, window.minX - dx, accuracy: 0.001)
        // Top-left origin: up is the smaller y.
        XCTAssertEqual(frame(.nudgeUp)?.minY ?? 0, window.minY - dy, accuracy: 0.001)
        XCTAssertEqual(frame(.nudgeDown)?.minY ?? 0, window.minY + dy, accuracy: 0.001)
    }

    /// A nudge stops at the edge rather than walking the window off the display — a chord pressed
    /// repeatedly and without looking must not be able to lose a window.
    func testANudgeStopsAtTheScreenEdge() throws {
        let atEdge = CGRect(x: 0, y: 25, width: 400, height: 300)
        let pushed = try XCTUnwrap(
            WindowArrangement.nudgeLeft.frame(in: area, current: atEdge, fraction: 0.5))
        XCTAssertEqual(pushed, atEdge)
        let up = try XCTUnwrap(
            WindowArrangement.nudgeUp.frame(in: area, current: atEdge, fraction: 0.5))
        XCTAssertEqual(up, atEdge)
    }

    // MARK: - Focus and swap carry no frame

    /// Both are dispatched before the tiler is reached, and neither has a frame computable from one
    /// screen — focus moves no window, and a swap needs a second window this function never sees.
    func testFocusAndSwapHaveNoComputedFrame() {
        for arrangement in WindowArrangement.focusMoves + WindowArrangement.swaps {
            XCTAssertNil(frame(arrangement), "\(arrangement.rawValue) should compute no frame")
        }
    }

    func testEachDirectionalFamilyStepsAllFourWays() {
        XCTAssertEqual(WindowArrangement.focusLeft.focusStep, .left)
        XCTAssertEqual(WindowArrangement.focusDown.focusStep, .down)
        XCTAssertEqual(WindowArrangement.swapRight.swapStep, .right)
        XCTAssertEqual(WindowArrangement.nudgeUp.nudgeStep, .up)
        // Disjoint: nothing is two of these at once, or the controller's branch order would decide
        // what a chord means.
        for arrangement in WindowArrangement.allCases {
            let kinds = [
                arrangement.focusStep != nil, arrangement.swapStep != nil,
                arrangement.nudgeStep != nil, arrangement.sizeStep != nil,
                arrangement.displayStep != nil, arrangement.desktopStep != nil,
            ].filter { $0 }
            XCTAssertLessThanOrEqual(
                kinds.count, 1, "\(arrangement.rawValue) belongs to two families")
        }
    }

    /// The relative families cannot be a launch arrangement: every one of them is defined against
    /// where the window already is, and a window that has only just appeared is wherever its app put
    /// it — so "a little bigger than that" is not a placement anyone can have meant.
    func testTheRelativeFamiliesAreNotLaunchable() {
        for arrangement in WindowArrangement.nudges + WindowArrangement.swaps
            + [WindowArrangement.larger, .smaller]
        {
            XCTAssertFalse(
                WindowArrangement.launchable.contains(arrangement),
                "\(arrangement.rawValue) should not be offered as a launch arrangement")
        }
        XCTAssertTrue(WindowArrangement.launchable.contains(.leftHalf))
        XCTAssertTrue(WindowArrangement.launchable.contains(.topThird))
    }
}

/// The cross-display carry: the arithmetic behind both the ⌃⇧⌘-←/→ chord and the in-switcher
/// move. It was written out twice, identically, each copy documenting that it had to agree with the
/// other, and neither covered by a test — so the promise that a window thrown either way lands in
/// the same place rested on nobody editing one of them.
final class CarriedFrameTests: XCTestCase {
    /// A 1600x1000 laptop at the origin, and a 1000x800 external to its right.
    private let laptop = CGRect(x: 0, y: 0, width: 1600, height: 1000)
    private let external = CGRect(x: 1600, y: 0, width: 1000, height: 800)

    func testFractionalPositionIsPreserved() {
        // A quarter across and a fifth down, 400x200.
        let window = CGRect(x: 400, y: 200, width: 400, height: 200)
        let moved = WindowTiler.carried(window, from: laptop, to: external)
        XCTAssertEqual(moved.minX, external.minX + 250, accuracy: 0.001)
        XCTAssertEqual(moved.minY, external.minY + 160, accuracy: 0.001)
        XCTAssertEqual(moved.size, window.size)
    }

    /// The retrofit that had already drifted once: without it a window filling a 4K external
    /// arrives on a laptop screen at 4K, pinned top-left with most of it off the bottom and right.
    func testAWindowTooLargeForTheDestinationIsShrunkToFit() {
        let window = CGRect(x: 0, y: 0, width: 1600, height: 1000)
        let moved = WindowTiler.carried(window, from: laptop, to: external)
        XCTAssertEqual(moved.size, external.size)
    }

    func testTheResultNeverHangsOffTheDestination() {
        // Hard against the laptop's bottom-right corner.
        let window = CGRect(x: 1200, y: 800, width: 400, height: 200)
        let moved = WindowTiler.carried(window, from: laptop, to: external)
        XCTAssertGreaterThanOrEqual(moved.minX, external.minX)
        XCTAssertGreaterThanOrEqual(moved.minY, external.minY)
        XCTAssertLessThanOrEqual(moved.maxX, external.maxX)
        XCTAssertLessThanOrEqual(moved.maxY, external.maxY)
    }

    /// A zero-width source would divide by zero. It cannot happen with real displays, and the guard
    /// is one line, so it is asserted rather than argued about.
    func testAZeroSizedSourceDoesNotProduceNaN() {
        let empty = CGRect(x: 0, y: 0, width: 0, height: 0)
        let moved = WindowTiler.carried(CGRect(x: 0, y: 0, width: 100, height: 100),
                                        from: empty, to: external)
        XCTAssertEqual(moved.origin, external.origin)
        XCTAssertFalse(moved.minX.isNaN || moved.minY.isNaN)
    }

    /// A round trip is not required to be the identity — the destination can be too small to give
    /// the size back — but between two displays of the same size it must be.
    func testARoundTripBetweenEqualDisplaysIsTheIdentity() {
        let twin = CGRect(x: 1600, y: 0, width: 1600, height: 1000)
        let window = CGRect(x: 400, y: 200, width: 400, height: 200)
        let there = WindowTiler.carried(window, from: laptop, to: twin)
        let back = WindowTiler.carried(there, from: twin, to: laptop)
        XCTAssertEqual(back.minX, window.minX, accuracy: 0.001)
        XCTAssertEqual(back.minY, window.minY, accuracy: 0.001)
        XCTAssertEqual(back.size, window.size)
    }
}

/// Zone detection for drag-to-edge snapping. Screen coordinates here are Cocoa's — bottom-up — so
/// "top" is the maximum y, which is the opposite of everything in the tiling geometry above.
final class DragSnapZoneTests: XCTestCase {
    /// A 1600×1000 display at the origin.
    private let frame = CGRect(x: 0, y: 0, width: 1600, height: 1000)

    private func zone(_ x: CGFloat, _ y: CGFloat) -> WindowArrangement? {
        DragSnap.zone(for: CGPoint(x: x, y: y), in: frame)
    }

    /// The dead ground between the edges and the centre box: most of the screen, and it must stay
    /// dead, or every drop anywhere would tile something.
    func testMostOfTheScreenSnapsToNothing() {
        XCTAssertNil(zone(400, 300))
        XCTAssertNil(zone(1200, 700))
    }

    func testEdgesMapToHalvesAndMaximize() {
        XCTAssertEqual(zone(1, 500), .leftHalf)
        XCTAssertEqual(zone(1599, 500), .rightHalf)
        // Top is maximize, matching the edge-snap gesture every other platform ships.
        XCTAssertEqual(zone(800, 999), .maximize)
        XCTAssertEqual(zone(800, 1), .bottomHalf)
    }

    /// The topmost row of pixels is a real target, not the outside of the screen.
    ///
    /// Cocoa is bottom-up, so that row is `frame.maxY` — and `CGRect.contains` is `minY <= y <
    /// maxY`, which rejects exactly it. Since the cursor *clamps* to that row when it is shoved at
    /// the top of the screen, the three zones people aim at by shoving were the three that could
    /// not be reached.
    func testTheTopRowOfPixelsStillSnaps() {
        XCTAssertEqual(zone(800, 1000), .maximize)
        XCTAssertEqual(zone(1, 1000), .topLeft)
        XCTAssertEqual(zone(1599, 1000), .topRight)
    }

    /// Corners take priority over the edges they sit on, and get a much wider catchment — a 12pt
    /// box at the exact meeting of two edges is not aimable with a window in hand.
    func testCornersWinOverEdges() {
        XCTAssertEqual(zone(1, 999), .topLeft)
        XCTAssertEqual(zone(1599, 999), .topRight)
        XCTAssertEqual(zone(1, 1), .bottomLeft)
        XCTAssertEqual(zone(1599, 1), .bottomRight)
    }

    func testJustInsideTheEdgeStillArms() {
        XCTAssertEqual(zone(11, 500), .leftHalf)
    }

    func testWellInsideTheEdgeDoesNot() {
        XCTAssertNil(zone(40, 500))
    }

    /// A point on no screen at all — between mismatched displays, or off the end — must not snap.
    func testAPointOffEveryScreenSnapsToNothing() {
        XCTAssertNil(DragSnap.zone(for: CGPoint(x: -5000, y: -5000), in: frame))
    }

    // MARK: - Centre zone

    /// A drop aimed at the middle of the screen takes the whole screen.
    func testTheCentreOfTheScreenMaximizes() {
        XCTAssertEqual(DragSnap.zone(for: CGPoint(x: frame.midX, y: frame.midY), in: frame),
                       .maximize)
    }

    /// The box is small on purpose: a window dropped merely *near* the middle is the ordinary case
    /// and must not be taken over.
    func testJustOutsideTheCentreBoxIsNotAZone() {
        let offset = frame.width * 0.125 / 2 + 20
        XCTAssertNil(DragSnap.zone(for: CGPoint(x: frame.midX + offset, y: frame.midY), in: frame))
        let vertical = frame.height * 0.125 / 2 + 20
        XCTAssertNil(DragSnap.zone(for: CGPoint(x: frame.midX, y: frame.midY + vertical), in: frame))
    }

    /// An edge always wins. On a short screen the centre box could otherwise reach a screen edge and
    /// swallow the half it belongs to.
    func testAnEdgeStillWinsOverTheCentre() {
        let squat = CGRect(x: 0, y: 0, width: 400, height: 200)
        XCTAssertEqual(DragSnap.zone(for: CGPoint(x: 2, y: 100), in: squat), .leftHalf)
        XCTAssertEqual(DragSnap.zone(for: CGPoint(x: 200, y: 199), in: squat), .maximize)
    }

    // MARK: - Restore points against a desk that has changed

    /// The laptop, plus an external monitor to its right — the desk a restore point gets recorded
    /// on and then loses.
    private let laptopArea = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private let externalArea = CGRect(x: 1440, y: 25, width: 2560, height: 1415)

    /// The ordinary case, and the one that must not change: a saved frame still sitting on a
    /// connected display comes back untouched.
    func testAReachableRestorePointIsUsedExactly() {
        let saved = CGRect(x: 200, y: 100, width: 800, height: 600)
        XCTAssertEqual(
            WindowTiler.reachable(saved, in: [laptopArea, externalArea], fallback: laptopArea),
            saved)
    }

    /// Deliberately hanging off an edge is a placement, not a mistake: as long as the titlebar can
    /// still be grabbed, the frame is left alone rather than tidied onto the screen.
    func testAWindowLeftHangingOffAnEdgeComesBackHangingOffIt() {
        let saved = CGRect(x: 1200, y: 100, width: 800, height: 600)  // spills past the laptop
        XCTAssertEqual(WindowTiler.reachable(saved, in: [laptopArea], fallback: laptopArea), saved)
    }

    /// The bug this exists for: tile a window on the external monitor, unplug it, press restore.
    /// The saved frame names coordinates no display covers, and written as-is the window would land
    /// with no titlebar on screen to drag it back.
    func testARestorePointOnAnUnpluggedDisplayIsBroughtBackOnScreen() {
        let saved = CGRect(x: 2000, y: 100, width: 800, height: 600)
        let restored = WindowTiler.reachable(saved, in: [laptopArea], fallback: laptopArea)
        XCTAssertEqual(restored.size, saved.size, "the size the user chose is kept")
        XCTAssertTrue(
            laptopArea.contains(restored), "and the whole frame is on the display that is left")
    }

    /// A corner of the frame overlapping a display is not the same as being reachable. What has to
    /// be on screen is enough of the strip along the *top* edge to aim a cursor at.
    func testAFrameWithBarelyAnyTitlebarShowingIsBroughtBack() {
        // Overlaps the laptop's bottom-right corner by 40pt — a sliver, and none of it grabbable.
        let saved = CGRect(x: 1400, y: 860, width: 800, height: 600)
        let restored = WindowTiler.reachable(saved, in: [laptopArea], fallback: laptopArea)
        XCTAssertTrue(laptopArea.contains(restored))
    }

    /// A frame overlapping nothing at all falls back to the display the window is on now, rather
    /// than to whichever display happens to be first.
    func testAFrameOverlappingNoDisplayLandsOnTheFallback() {
        let saved = CGRect(x: 5000, y: 5000, width: 800, height: 600)
        let restored = WindowTiler.reachable(
            saved, in: [laptopArea, externalArea], fallback: externalArea)
        XCTAssertTrue(externalArea.contains(restored))
    }

    /// A saved frame bigger than every remaining display is shrunk to fit rather than left
    /// overhanging — the same treatment a saved layout gets.
    func testAnOversizedRestorePointIsShrunkOntoTheDisplay() {
        let saved = CGRect(x: 1440, y: 25, width: 2560, height: 1415)  // the whole external monitor
        let restored = WindowTiler.reachable(saved, in: [laptopArea], fallback: laptopArea)
        XCTAssertEqual(restored, laptopArea)
    }

    /// The rescue is for a desk that changed, not for a placement that looks untidy. An unchanged
    /// desk hands the saved rectangle back verbatim without consulting `reachable` at all — which is
    /// what keeps a window the user deliberately parked mostly off an edge exactly where they put it.
    func testAnUnchangedDeskRestoresTheExactFrame() {
        let desk = [laptopArea, externalArea]
        // Barely any grabbable titlebar: `reachable` would tidy this one back onto the display.
        let saved = CGRect(x: 1400, y: 860, width: 800, height: 600)
        XCTAssertNotEqual(
            WindowTiler.reachable(saved, in: [laptopArea], fallback: laptopArea), saved,
            "precondition: this frame is one the rescue would move")
        XCTAssertEqual(
            WindowTiler.restoreTarget(saved, savedOn: desk, desk: desk, fallback: laptopArea),
            saved)
    }

    /// And when the desk *has* changed, the rescue still runs — the unplugged-monitor case the
    /// restore point would otherwise write to coordinates nothing covers.
    func testAChangedDeskStillRescuesTheFrame() {
        let saved = CGRect(x: 2000, y: 100, width: 800, height: 600)  // on the external
        let restored = WindowTiler.restoreTarget(
            saved, savedOn: [laptopArea, externalArea], desk: [laptopArea], fallback: laptopArea)
        XCTAssertTrue(laptopArea.contains(restored))
    }

    // MARK: - Which display is a window on?

    /// The everyday case, and the one a user would name: the display the window sits inside.
    func testAWindowIsOnTheDisplayItsCentreIsIn() {
        let onExternal = CGRect(x: 2000, y: 300, width: 800, height: 600)
        XCTAssertEqual(
            WindowTiler.homeDisplay(of: onExternal, in: [laptopArea, externalArea]), 1)
        let onLaptop = CGRect(x: 100, y: 100, width: 400, height: 300)
        XCTAssertEqual(
            WindowTiler.homeDisplay(of: onLaptop, in: [laptopArea, externalArea]), 0)
    }

    /// Straddling two monitors, the centre lands in whichever one holds it — and when the centre
    /// falls in the seam, the larger overlap breaks the tie rather than the array order.
    func testAStraddlingWindowGoesToTheDisplayItIsMostlyOn() {
        // Mostly on the external: 100pt on the laptop, 700pt past the boundary at x=1440.
        let mostlyExternal = CGRect(x: 1340, y: 300, width: 800, height: 600)
        XCTAssertEqual(
            WindowTiler.homeDisplay(of: mostlyExternal, in: [laptopArea, externalArea]), 1)
        // Mostly on the laptop: 700pt before the boundary, 100pt past it.
        let mostlyLaptop = CGRect(x: 740, y: 300, width: 800, height: 600)
        XCTAssertEqual(
            WindowTiler.homeDisplay(of: mostlyLaptop, in: [laptopArea, externalArea]), 0)
    }

    /// The regression the shared rule exists for. `max(by:)` keeps the first element when every
    /// comparison is 0 < 0, so a window overlapping nothing used to come back as display 0 — and the
    /// move chord then threw it off a display it had never been on. It is on no display; say so.
    func testAWindowOnNoDisplayAnswersNil() {
        // Entirely inside the menu-bar strip, which no *visible* area covers.
        let inTheMenuBar = CGRect(x: 600, y: 0, width: 200, height: 22)
        XCTAssertNil(WindowTiler.homeDisplay(of: inTheMenuBar, in: [laptopArea, externalArea]))
        // Somewhere no display has ever been.
        let offTheDesk = CGRect(x: 9000, y: 9000, width: 400, height: 300)
        XCTAssertNil(WindowTiler.homeDisplay(of: offTheDesk, in: [laptopArea, externalArea]))
    }

    /// Mirrored displays report the same rectangle. The answer has to be an index into the list the
    /// caller passed, not a rectangle it would have to look back up by equality.
    func testMirroredDisplaysAnswerTheFirstMatchingIndex() {
        XCTAssertEqual(
            WindowTiler.homeDisplay(
                of: CGRect(x: 100, y: 100, width: 400, height: 300),
                in: [laptopArea, laptopArea]),
            0)
    }

    /// No displays at all — every screen asleep, or one mid-reconfiguration.
    func testNoDisplaysAnswersNil() {
        XCTAssertNil(
            WindowTiler.homeDisplay(of: CGRect(x: 100, y: 100, width: 400, height: 300), in: []))
    }

    // MARK: - Is it a window drag?

    /// The origin has to move and the size has to stay put — the pair that tells a window drag from
    /// a text selection (nothing moves) and from a resize (the size changes with it).
    func testOnlyAMoveCountsAsAWindowDrag() {
        let initial = CGRect(x: 100, y: 100, width: 800, height: 600)
        XCTAssertTrue(DragSnap.isMove(from: initial, to: initial.offsetBy(dx: 30, dy: -12)))
        XCTAssertFalse(DragSnap.isMove(from: initial, to: initial))
        let resized = CGRect(x: 100, y: 100, width: 900, height: 600)
        XCTAssertFalse(DragSnap.isMove(from: initial, to: resized))
        // A top-left resize moves the origin *and* changes the size; still not a move.
        let cornerResized = CGRect(x: 80, y: 80, width: 820, height: 620)
        XCTAssertFalse(DragSnap.isMove(from: initial, to: cornerResized))
    }
}

/// The marker that keeps this app's own synthetic drags out of its own gestures.
final class SyntheticEventTests: XCTestCase {
    private func mouseEvent() -> CGEvent? {
        CGEvent(
            mouseEventSource: nil, mouseType: .leftMouseDragged,
            mouseCursorPosition: CGPoint(x: 10, y: 10), mouseButton: .left)
    }

    func testAnUnmarkedEventIsNotOurs() throws {
        let event = try XCTUnwrap(mouseEvent())
        XCTAssertFalse(SyntheticEvent.isOurs(event), "a plain event must read as the user's")
    }

    func testAMarkedEventIsOurs() throws {
        let event = try XCTUnwrap(mouseEvent())
        SyntheticEvent.mark(event)
        XCTAssertTrue(SyntheticEvent.isOurs(event))
    }

    /// The guard is asked about events that may not exist — `NSEvent.cgEvent` is optional — and must
    /// answer "not ours" rather than trapping, or a monitor would crash on the first odd event.
    func testANilEventIsNotOurs() {
        XCTAssertFalse(SyntheticEvent.isOurs(nil))
    }

    /// Marking must not disturb the event otherwise: it rides in a spare field, and the position and
    /// type the drag depends on have to survive it.
    func testMarkingLeavesTheEventOtherwiseIntact() throws {
        let event = try XCTUnwrap(mouseEvent())
        let before = event.location
        SyntheticEvent.mark(event)
        XCTAssertEqual(event.location, before)
        XCTAssertEqual(event.type, .leftMouseDragged)
    }
}

/// The re-entrancy claim behind the Desktop move.
///
/// Worth its own tests because the bug it replaced was invisible in the gesture and obvious in the
/// invariant: the claim used to be taken *inside* the serial queue, where a second block cannot run
/// until the first has finished and already released it — so it never rejected anything, and holding
/// the chord down walked the window across several Desktops.
final class DesktopMoveClaimTests: XCTestCase {
    override func tearDown() {
        DesktopMover.end()
        super.tearDown()
    }

    func testASecondClaimIsRefusedWhileTheFirstIsHeld() {
        XCTAssertTrue(DesktopMover.beginIfIdle())
        XCTAssertFalse(DesktopMover.beginIfIdle(), "a move already running must refuse the next")
        XCTAssertFalse(DesktopMover.beginIfIdle(), "and keep refusing")
    }

    func testTheClaimIsAvailableAgainOnceReleased() {
        XCTAssertTrue(DesktopMover.beginIfIdle())
        DesktopMover.end()
        XCTAssertTrue(DesktopMover.beginIfIdle(), "a finished move must not block the next one")
    }

    /// A burst arriving from several threads at once — key auto-repeat through the tap is the real
    /// case — must still let exactly one through.
    func testConcurrentClaimsLetExactlyOneThrough() {
        let granted = NSCounter()
        let group = DispatchGroup()
        for _ in 0..<32 {
            DispatchQueue.global().async(group: group) {
                if DesktopMover.beginIfIdle() { granted.increment() }
            }
        }
        group.wait()
        XCTAssertEqual(granted.value, 1, "exactly one of a concurrent burst may claim the gesture")
    }
}

/// A counter that is safe to bump from several queues at once.
private final class NSCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }
    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
