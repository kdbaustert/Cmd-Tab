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

    /// A gap wider than the tile would invert the frame; the tile is left alone instead.
    func testAnAbsurdGapIsRefusedRatherThanInverting() {
        let tiny = CGRect(x: area.minX, y: area.minY, width: 40, height: 30)
        XCTAssertEqual(TilingGap.inset(tiny, in: area, gap: 60), tiny)
        for arrangement in WindowArrangement.tilingArrangements {
            guard let plain = frame(arrangement) else { continue }
            let inset = TilingGap.inset(plain, in: area, gap: TilingGap.maximum)
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
        for arrangement in [WindowArrangement.leftHalf, .topRight, .centerThird, .maximize] {
            XCTAssertTrue(arrangement.takesGap, "\(arrangement.rawValue) should take a gap")
        }
    }

    // MARK: - Bindings

    func testDisabledTilingMatchesNoGeometry() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        for arrangement in WindowArrangement.tilingArrangements {
            let chord = arrangement.defaultHotkey
            XCTAssertNil(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers),
                "\(arrangement.rawValue) should be inert while tiling is off")
        }
    }

    /// The switch is about resizing. A move changes no layout, so it fires either way — the whole
    /// point of splitting the two families in `arrangement(code:flags:)`.
    func testDisabledTilingStillMatchesTheMoves() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        for arrangement in WindowArrangement.moves {
            let chord = arrangement.defaultHotkey
            XCTAssertEqual(
                tiling.arrangement(code: chord.keyCode, flags: chord.modifiers), arrangement,
                "\(arrangement.rawValue) should fire with tiling off")
        }
    }

    /// A cleared move is still cleared: ungating them is not a licence to revive a binding the user
    /// has handed back.
    func testAClearedMoveDoesNotFireWithTilingOff() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        let chord = WindowArrangement.nextDisplay.defaultHotkey
        tiling.bindings[.nextDisplay] = nil
        XCTAssertNil(tiling.arrangement(code: chord.keyCode, flags: chord.modifiers))
    }

    func testTheTwoFamiliesPartitionTheArrangements() {
        XCTAssertEqual(
            Set(WindowArrangement.moves).union(WindowArrangement.tilingArrangements),
            Set(WindowArrangement.allCases))
        XCTAssertTrue(
            Set(WindowArrangement.moves).isDisjoint(with: WindowArrangement.tilingArrangements))
        XCTAssertEqual(Set(WindowArrangement.moves), Set([.previousDisplay, .nextDisplay]))
    }

    func testEnabledTilingMatchesItsOwnChord() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = WindowArrangement.leftHalf.defaultHotkey
        XCTAssertEqual(tiling.arrangement(code: left.keyCode, flags: left.modifiers), .leftHalf)
    }

    /// Exact match: an extra modifier on top of the binding is a different chord, and must fall
    /// through to whatever app is in front rather than tiling.
    func testAnExtraModifierDoesNotMatch() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = WindowArrangement.leftHalf.defaultHotkey
        XCTAssertNil(
            tiling.arrangement(
                code: left.keyCode, flags: left.modifiers.union(.maskAlternate)))
    }

    /// A cleared binding hands its chord back: nothing matches it, and the arrangement is not
    /// silently revived from its default.
    func testAClearedBindingMatchesNothing() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let left = WindowArrangement.leftHalf.defaultHotkey
        tiling.bindings[.leftHalf] = nil
        XCTAssertNil(tiling.arrangement(code: left.keyCode, flags: left.modifiers))
    }

    func testClearingOneBindingLeavesTheRestAlone() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        tiling.bindings[.leftHalf] = nil
        let right = WindowArrangement.rightHalf.defaultHotkey
        XCTAssertEqual(tiling.arrangement(code: right.keyCode, flags: right.modifiers), .rightHalf)
    }

    func testDefaultsHaveNoConflicts() {
        let tiling = WindowTilingBindings.defaults
        for arrangement in WindowArrangement.allCases {
            XCTAssertEqual(tiling.conflicts(with: arrangement), [])
        }
    }

    func testTwoArrangementsOnOneChordReportEachOther() {
        var tiling = WindowTilingBindings.defaults
        tiling.bindings[.center] = WindowArrangement.leftHalf.defaultHotkey
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
        for arrangement in WindowArrangement.allCases {
            XCTAssertNil(
                WindowTilingBindings.triggerClaiming(arrangement.defaultHotkey, in: behavior),
                "\(arrangement.rawValue) collides with a switcher trigger")
        }
    }

    func testEveryArrangementHasADistinctDefaultChord() {
        let chords = WindowArrangement.allCases.map {
            "\($0.defaultHotkey.keyCode):\($0.defaultHotkey.modifierRaw)"
        }
        XCTAssertEqual(Set(chords).count, WindowArrangement.allCases.count)
    }

    /// Every default holds ⌃⌘. ⇧ is a qualifier on top — the display moves sit on the same arrows
    /// as the halves, "throw it further" — so the invariant is on `heldModifiers`, which masks it.
    func testDefaultChordsAllHoldControlCommand() {
        let expected = CGEventFlags.maskControl.union(.maskCommand)
        for arrangement in WindowArrangement.allCases {
            XCTAssertEqual(
                arrangement.defaultHotkey.heldModifiers, expected,
                "\(arrangement.rawValue) should hold ⌃⌘")
        }
    }

    /// The shifted display moves must stay distinct from the unshifted halves they share a key with,
    /// or throwing a window to the next display would just tile it right.
    func testDisplayMovesAreDistinctFromTheHalvesTheyShareAKeyWith() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = true
        let half = WindowArrangement.leftHalf.defaultHotkey
        let move = WindowArrangement.previousDisplay.defaultHotkey
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
