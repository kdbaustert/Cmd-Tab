import CoreGraphics
import XCTest

@testable import CmdTab

/// The modifier-drag maths: everything the gesture decides before it touches a window.
///
/// Frames are in Accessibility coordinates — top-left origin, y growing downward — so "top" is the
/// lower y, and a drag *down* is a positive height delta.
final class MouseWindowDragTests: XCTestCase {
    private let frame = CGRect(x: 200, y: 100, width: 800, height: 600)

    // MARK: - Move

    func testMoveTranslatesWithoutResizing() {
        let moved = MouseDragGeometry.moved(frame, by: CGSize(width: 40, height: -25))
        XCTAssertEqual(moved, CGRect(x: 240, y: 75, width: 800, height: 600))
        XCTAssertEqual(moved.size, frame.size)
    }

    /// A window may be dragged off-screen and back; nothing here clamps, because the cursor is the
    /// clamp — you cannot drag further than the pointer can go.
    func testMoveDoesNotClamp() {
        let moved = MouseDragGeometry.moved(frame, by: CGSize(width: -5000, height: -5000))
        XCTAssertEqual(moved.origin, CGPoint(x: -4800, y: -4900))
    }

    // MARK: - Corner selection

    func testEachQuadrantPicksItsOwnCorner() {
        let cases: [(CGPoint, ResizeCorner)] = [
            (CGPoint(x: 250, y: 150), .topLeft),
            (CGPoint(x: 950, y: 150), .topRight),
            (CGPoint(x: 250, y: 650), .bottomLeft),
            (CGPoint(x: 950, y: 650), .bottomRight),
        ]
        for (point, expected) in cases {
            XCTAssertEqual(
                MouseDragGeometry.corner(for: point, in: frame), expected,
                "\(point) should resize from \(expected)")
        }
    }

    /// The exact centre has to resolve somewhere; it lands bottom-right, and the only thing that
    /// matters is that it is deterministic rather than depending on a rounding accident.
    func testTheCentreResolvesToOneCorner() {
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        XCTAssertEqual(MouseDragGeometry.corner(for: centre, in: frame), .bottomRight)
    }

    // MARK: - Resize

    func testBottomRightResizeKeepsTheOriginPinned() {
        let resized = MouseDragGeometry.resized(
            frame, corner: .bottomRight, by: CGSize(width: 100, height: 50))
        XCTAssertEqual(resized.origin, frame.origin)
        XCTAssertEqual(resized.size, CGSize(width: 900, height: 650))
    }

    func testTopLeftResizeMovesTheOriginAndKeepsTheFarCornerPinned() {
        let resized = MouseDragGeometry.resized(
            frame, corner: .topLeft, by: CGSize(width: 50, height: 30))
        XCTAssertEqual(resized.origin, CGPoint(x: 250, y: 130))
        XCTAssertEqual(resized.maxX, frame.maxX)
        XCTAssertEqual(resized.maxY, frame.maxY)
    }

    func testTopRightResizePinsTheBottomLeft() {
        let resized = MouseDragGeometry.resized(
            frame, corner: .topRight, by: CGSize(width: -100, height: 40))
        XCTAssertEqual(resized.minX, frame.minX)
        XCTAssertEqual(resized.maxY, frame.maxY)
        XCTAssertEqual(resized.size, CGSize(width: 700, height: 560))
    }

    func testBottomLeftResizePinsTheTopRight() {
        let resized = MouseDragGeometry.resized(
            frame, corner: .bottomLeft, by: CGSize(width: 60, height: -80))
        XCTAssertEqual(resized.maxX, frame.maxX)
        XCTAssertEqual(resized.minY, frame.minY)
        XCTAssertEqual(resized.size, CGSize(width: 740, height: 520))
    }

    /// Dragging a corner past its anchor stops at the minimum instead of inverting the frame — a
    /// negative width is a rect Accessibility accepts and no app can draw.
    func testResizeNeverInvertsTheFrame() {
        for corner in ResizeCorner.allCases {
            let resized = MouseDragGeometry.resized(
                frame, corner: corner, by: CGSize(width: -3000, height: -3000))
            XCTAssertGreaterThanOrEqual(resized.width, MouseDragGeometry.minimumSize.width)
            XCTAssertGreaterThanOrEqual(resized.height, MouseDragGeometry.minimumSize.height)
            let opposite = MouseDragGeometry.resized(
                frame, corner: corner, by: CGSize(width: 3000, height: 3000))
            XCTAssertGreaterThanOrEqual(opposite.width, MouseDragGeometry.minimumSize.width)
            XCTAssertGreaterThanOrEqual(opposite.height, MouseDragGeometry.minimumSize.height)
        }
    }

    /// A window that is *already* smaller than the minimum must not be inflated to reach it.
    ///
    /// The clamp is a "do not cross the anchor" rule, not a size policy. Read as an absolute floor
    /// it moved a window nobody had asked to resize: a 360x40 mini player resized from the top-left
    /// by nothing at all computed `top = min(40 + 0, 40 - 90)` and threw its top edge 50pt upward.
    func testResizeDoesNotInflateAWindowStartingUnderTheMinimum() {
        let small = CGRect(x: 0, y: 40, width: 360, height: 40)
        for corner in ResizeCorner.allCases {
            XCTAssertEqual(
                MouseDragGeometry.resized(small, corner: corner, by: .zero), small,
                "\(corner) moved a window that was not being resized")
        }
        // And it still tracks the cursor from there rather than snapping to the minimum.
        let taller = MouseDragGeometry.resized(
            small, corner: .bottomRight, by: CGSize(width: 0, height: 10))
        XCTAssertEqual(taller.height, 50)
    }

    /// Each axis clamps on its own: squashing the height to nothing must not also freeze the width.
    func testTheAxesClampIndependently() {
        let resized = MouseDragGeometry.resized(
            frame, corner: .bottomRight, by: CGSize(width: 200, height: -3000))
        XCTAssertEqual(resized.width, 1000)
        XCTAssertEqual(resized.height, MouseDragGeometry.minimumSize.height)
    }

    // MARK: - Modifier matching

    func testDisabledMatchesNothing() {
        let settings = MouseDragSettings(isEnabled: false)
        XCTAssertNil(settings.action(for: [.maskControl, .maskAlternate]))
    }

    func testTheTwoDefaultChordsPickTheirOwnAction() {
        let settings = MouseDragSettings(isEnabled: true)
        XCTAssertEqual(settings.action(for: [.maskControl, .maskAlternate]), .move)
        XCTAssertEqual(settings.action(for: [.maskControl, .maskCommand]), .resize)
    }

    /// Exact match on all four bindable modifiers: a superset is a different chord, or ⌃⌥ would
    /// also fire whenever ⌃⌥⌘ was held and one binding could never be told from the other.
    func testASupersetOrSubsetDoesNotMatch() {
        let settings = MouseDragSettings(isEnabled: true)
        XCTAssertNil(settings.action(for: [.maskControl, .maskAlternate, .maskCommand]))
        XCTAssertNil(settings.action(for: [.maskControl, .maskAlternate, .maskShift]))
        XCTAssertNil(settings.action(for: [.maskControl]))
    }

    func testAnUnmodifiedDragIsNeverOurs() {
        let settings = MouseDragSettings(isEnabled: true)
        XCTAssertNil(settings.action(for: []))
    }

    /// Device flags ride along on real events — a numeric-pad or function bit is set for whole
    /// classes of key — and must not stop a recorded chord matching.
    func testDeviceFlagsAreIgnored() {
        let settings = MouseDragSettings(isEnabled: true)
        let noisy: CGEventFlags = [.maskControl, .maskAlternate, .maskNumericPad, .maskSecondaryFn]
        XCTAssertEqual(settings.action(for: noisy), .move)
    }

    /// A recorded chord can be anything; ⇧ is bindable as a qualifier on top of a real modifier.
    func testAShiftQualifiedChordIsBindableAndMatchesExactly() {
        var settings = MouseDragSettings(isEnabled: true)
        settings.set(ModifierChord([.maskControl, .maskAlternate, .maskShift]), for: .move)
        XCTAssertEqual(settings.action(for: [.maskControl, .maskAlternate, .maskShift]), .move)
        XCTAssertNil(settings.action(for: [.maskControl, .maskAlternate]))
    }

    /// Both rows can be pointed at one chord — swapping the two needs a colliding step — and move
    /// is tested first, so which one fires is fixed rather than incidental.
    func testMoveWinsWhenBothArePointedAtOneChord() {
        var settings = MouseDragSettings(isEnabled: true)
        settings.set(settings.move, for: .resize)
        XCTAssertEqual(settings.action(for: settings.move.flags), .move)
    }

    /// A chord with no ⌃/⌥/⌘ in it can be *stored* but never fires: bound to nothing, or to ⇧
    /// alone, every drag on the machine would become a window drag.
    func testAnUnusableChordNeverFires() {
        var settings = MouseDragSettings(isEnabled: true)
        settings.set(ModifierChord([]), for: .move)
        XCTAssertFalse(settings.move.isUsable)
        XCTAssertNil(settings.action(for: []))

        settings.set(ModifierChord([.maskShift]), for: .move)
        XCTAssertFalse(settings.move.isUsable)
        XCTAssertNil(settings.action(for: [.maskShift]))
    }

    // MARK: - Chords

    func testAChordKeepsOnlyTheFourBindableModifiers() {
        let chord = ModifierChord([.maskControl, .maskNumericPad, .maskSecondaryFn, .maskAlphaShift])
        XCTAssertEqual(chord.flags, CGEventFlags.maskControl)
        XCTAssertEqual(ModifierChord(rawValue: chord.rawValue), chord)
    }

    /// Menu order, the order macOS itself shows a shortcut in.
    func testDisplayStringIsInMenuOrder() {
        let all = ModifierChord([.maskCommand, .maskShift, .maskAlternate, .maskControl])
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘")
        XCTAssertEqual(ModifierChord([.maskControl, .maskCommand]).displayString, "⌃⌘")
        XCTAssertEqual(ModifierChord([]).displayString, "Not set")
    }

    func testDefaultsAreTheDeclaredActionDefaults() {
        let settings = MouseDragSettings()
        XCTAssertEqual(settings.move, MouseDragAction.move.defaultChord)
        XCTAssertEqual(settings.resize, MouseDragAction.resize.defaultChord)
        XCTAssertTrue(settings.move.isUsable)
        XCTAssertTrue(settings.resize.isUsable)
        XCTAssertNotEqual(settings.move, settings.resize)
    }

    /// The shipped resize chord and the shipped chord for all four tiling halves are the *same*
    /// modifiers, so holding ⌃⌘ to press an arrow arms the pointing gesture as a side effect of
    /// firing the tile. That overlap is what makes standing the gesture down on a claimed keystroke
    /// load-bearing rather than tidy: without it the chord coming up completed a gesture whose
    /// cursor had never left its dot, and a zero offset is `.maximize` — so every half, third and
    /// corner tiled correctly and was then replaced by a full-screen window.
    ///
    /// Two facts, pinned together because the bug needs both: moving either chord off the other
    /// would end the collision, and this test should be the thing that notices.
    func testTheTilingHalvesChordAlsoArmsAMouseGesture() throws {
        let settings = MouseDragSettings(isEnabled: true)
        for arrangement in [WindowArrangement.leftHalf, .rightHalf, .topHalf, .bottomHalf] {
            let chord = try XCTUnwrap(arrangement.defaultHotkey)
            let held = chord.modifiers.intersection(ModifierChord.allowed)
            XCTAssertEqual(
                settings.action(for: held), .resize,
                "\(arrangement.title) no longer shares the resize chord")
        }
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 0, height: 0)), .maximize)
    }

    /// The keystrokes that hold the resize chord and are **not** this app's, which is the set the
    /// stand-down has to cover and the set a `decision.swallows` gate could never see.
    ///
    /// `SwitcherController.handle` stands the pointing gesture down on every key-down, and this is
    /// the reason it cannot go back to standing down only on a keystroke Cmd-Tab claims. Two shapes
    /// prove it, and both are `.swallows == false`:
    ///
    /// * `.pass` — macOS binds ⌃⌘ combinations of its own (⌃⌘Space is Emoji & Symbols, ⌃⌘F is Enter
    ///   Full Screen, ⌃⌘Q is Lock Screen) and this app claims none of them. Under the old gate the
    ///   gesture stayed armed through one, and the chord coming up maximized whatever the
    ///   cursor was resting on.
    /// * `.tilingInert` — a tiling chord pressed while our own settings window is frontmost, which
    ///   deliberately swallows nothing so the shortcut recorder can see the keystroke. So
    ///   *recording* a ⌃⌘ combination maximized the Settings window the moment the chord came up.
    ///
    /// Pinned as a precondition rather than as an assertion about `handle`, exactly as
    /// `testTheTilingHalvesChordAlsoArmsAMouseGesture` above is: the stand-down itself is one line
    /// inside a `@MainActor` handler behind a live event tap, and what a test can hold still is the
    /// arithmetic that made the narrow gate wrong.
    func testKeystrokesOnTheResizeChordAreOftenNotOursToSwallow() {
        let settings = MouseDragSettings(isEnabled: true)
        let chord = MouseDragAction.resize.defaultChord
        XCTAssertEqual(settings.action(for: chord.flags), .resize, "⌃⌘ still arms the gesture")

        let space = 49  // ⌃⌘Space — Emoji & Symbols
        let unclaimed = TapRouting.idle(
            TapRouting.Event(type: .keyDown, keyCode: space, flags: chord.flags),
            bindings: TapRouting.Bindings(), isAppActive: false)
        XCTAssertEqual(unclaimed, .pass)
        XCTAssertFalse(unclaimed.swallows, "a system chord we do not claim swallows nothing")

        let left = 123  // ⌃⌘← — Left half, pressed while Settings has focus
        let inert = TapRouting.idle(
            TapRouting.Event(type: .keyDown, keyCode: left, flags: chord.flags),
            bindings: TapRouting.Bindings(tilingMatch: { _, _ in .leftHalf }), isAppActive: true)
        XCTAssertEqual(inert, .tilingInert(.leftHalf))
        XCTAssertFalse(inert.swallows, "an inert tiling chord swallows nothing either")
    }

    // MARK: - Hold-and-point directions

    /// Staying put is the one "direction" with nowhere to point, and it takes the whole screen.
    func testStayingNearTheAnchorMaximizes() {
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 0, height: 0)), .maximize)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 20, height: -15)), .maximize)
    }

    /// Cocoa's y-up space: pointing *up* is a positive height.
    func testTheFourCardinalDirections() {
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 300, height: 0)), .rightHalf)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: -300, height: 0)), .leftHalf)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 0, height: 300)), .topHalf)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 0, height: -300)), .bottomHalf)
    }

    func testTheFourDiagonals() {
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 200, height: 200)), .topRight)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: -200, height: 200)), .topLeft)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: -200, height: -200)), .bottomLeft)
        XCTAssertEqual(PointDirection.zone(for: CGSize(width: 200, height: -200)), .bottomRight)
    }

    /// The sectors meet cleanly: every angle resolves to exactly one zone, and stepping round the
    /// circle passes through all eight in order without a gap or a repeat.
    func testEveryAngleResolvesAndAllEightAreReachable() {
        var seen: [WindowArrangement] = []
        for degrees in stride(from: 0, to: 360, by: 1) {
            let radians = CGFloat(degrees) * .pi / 180
            let zone = PointDirection.zone(
                for: CGSize(width: cos(radians) * 200, height: sin(radians) * 200))
            if seen.last != zone { seen.append(zone) }
        }
        // The walk starts mid-sector for "right", so it reappears at the end of the circle.
        XCTAssertEqual(Set(seen).count, 8)
        XCTAssertFalse(seen.contains(.maximize), "a long offset is never the dead zone")
    }

    /// The dead zone is measured as a radius, not per axis — a diagonal nudge is still a nudge.
    func testTheDeadZoneIsARadius() {
        let justInside = CGSize(width: 30, height: 30)   // 42.4pt
        let justOutside = CGSize(width: 34, height: 34)  // 48.1pt
        XCTAssertEqual(PointDirection.zone(for: justInside), .maximize)
        XCTAssertEqual(PointDirection.zone(for: justOutside), .topRight)
    }
}
