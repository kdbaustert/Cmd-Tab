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

    // MARK: - Bindings

    func testDisabledTilingMatchesNothing() {
        var tiling = WindowTilingBindings.defaults
        tiling.isEnabled = false
        let left = WindowArrangement.leftHalf.defaultHotkey
        XCTAssertNil(tiling.arrangement(code: left.keyCode, flags: left.modifiers))
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

    func testMiddleOfTheScreenSnapsToNothing() {
        XCTAssertNil(zone(800, 500))
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
}
