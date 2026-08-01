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

    /// The defaults must not collide with the in-switcher action keys, which are matched with the
    /// trigger held — a shared chord there would be ambiguous to explain even though the two are
    /// matched in different states.
    func testDefaultChordsAreAllControlCommand() {
        let expected = CGEventFlags.maskControl.union(.maskCommand)
        for arrangement in WindowArrangement.allCases {
            XCTAssertEqual(
                arrangement.defaultHotkey.modifiers, expected,
                "\(arrangement.rawValue) should default to ⌃⌘")
        }
    }
}
