import CoreGraphics
import XCTest

@testable import CmdTab

/// Which window lies in a given direction from another.
///
/// Every rectangle here is in Accessibility coordinates — top-left origin, y growing *downward* —
/// which is the one thing about this maths that is easy to get backwards: "above" is the smaller y.
final class WindowNavigationTests: XCTestCase {
    /// A 1600×1000 usable area starting 25pt down, as a menu bar would leave it.
    private let area = CGRect(x: 0, y: 25, width: 1600, height: 1000)

    /// The four quarters of `area`, which is the layout the whole feature exists for.
    private var topLeft: CGRect { CGRect(x: 0, y: 25, width: 800, height: 500) }
    private var topRight: CGRect { CGRect(x: 800, y: 25, width: 800, height: 500) }
    private var bottomLeft: CGRect { CGRect(x: 0, y: 525, width: 800, height: 500) }
    private var bottomRight: CGRect { CGRect(x: 800, y: 525, width: 800, height: 500) }

    private func pick(
        from origin: CGRect, _ direction: WindowDirection, among frames: [CGRect]
    ) -> CGRect? {
        WindowNeighbors.pick(from: origin, among: frames, direction: direction)
            .map { frames[$0] }
    }

    // MARK: - The four quarters

    func testEachQuarterReachesItsNeighbours() {
        let others = [topRight, bottomLeft, bottomRight]
        XCTAssertEqual(pick(from: topLeft, .right, among: others), topRight)
        XCTAssertEqual(pick(from: topLeft, .down, among: others), bottomLeft)
        XCTAssertEqual(pick(from: bottomRight, .left, among: [topLeft, bottomLeft]), bottomLeft)
        XCTAssertEqual(pick(from: bottomRight, .up, among: [topLeft, topRight]), topRight)
    }

    /// The trap of a flipped coordinate space, asserted directly: `up` must not walk downward.
    func testUpIsTowardTheSmallerY() {
        XCTAssertEqual(pick(from: bottomLeft, .up, among: [topLeft, bottomRight]), topLeft)
        XCTAssertEqual(pick(from: topLeft, .down, among: [bottomLeft, topRight]), bottomLeft)
    }

    func testNothingInADirectionAnswersNil() {
        XCTAssertNil(pick(from: topLeft, .left, among: [topRight, bottomRight]))
        XCTAssertNil(pick(from: topLeft, .up, among: [bottomLeft, bottomRight]))
    }

    func testAnEmptyDeskAnswersNil() {
        XCTAssertNil(pick(from: topLeft, .right, among: []))
    }

    // MARK: - Edges, not centres

    /// The case that decided how "nearest" is measured, and it is not by centre.
    ///
    /// A full-height window on the left, a half-screen window filling the right, and a small palette
    /// floating just inside the right window's leading edge. The palette's centre is far nearer than
    /// the right window's, so a nearest-centre rule sends ⌃⌘→ to the palette — while the *gap
    /// between facing edges* is zero for the window that is genuinely adjacent and 20pt for the
    /// palette sitting behind it. Both candidates share the origin's vertical band, so rule 1 cannot
    /// separate them; this is entirely rule 2's job.
    func testTheAdjacentWindowBeatsANearerCentreBehindIt() {
        let left = CGRect(x: 0, y: 25, width: 800, height: 1000)
        let palette = CGRect(x: 820, y: 800, width: 200, height: 150)
        let right = CGRect(x: 800, y: 25, width: 800, height: 1000)
        XCTAssertLessThan(
            hypot(palette.midX - left.midX, palette.midY - left.midY),
            hypot(right.midX - left.midX, right.midY - left.midY),
            "the premise: by centre distance the palette really is nearer")
        XCTAssertEqual(pick(from: left, .right, among: [palette, right]), right)
    }

    /// Overlapping candidates tie on the gap rather than competing on how deeply they overlap, or
    /// the *most* buried window would read as the nearest.
    func testDeeperOverlapDoesNotReadAsNearer() {
        let origin = CGRect(x: 0, y: 25, width: 1600, height: 1000)
        let nearer = CGRect(x: 900, y: 400, width: 200, height: 200)
        let further = CGRect(x: 1350, y: 400, width: 200, height: 200)
        // Both are inside the origin, so both have a negative edge gap — and `further` overlaps it
        // less. Floored at zero they tie, and the centre distance across the axis, which is equal
        // here, leaves z-order to decide. What must not happen is `further` winning on the strength
        // of being less buried.
        XCTAssertEqual(pick(from: origin, .right, among: [nearer, further]), nearer)
    }

    // MARK: - Overlap beats distance

    /// A window sharing the origin's band wins over a nearer one that does not, which is the rule
    /// that stops a directional chord wandering diagonally.
    func testAWindowSharingTheBandBeatsANearerOneThatDoesNot() {
        let origin = CGRect(x: 0, y: 400, width: 300, height: 200)
        let abeamButFar = CGRect(x: 1200, y: 420, width: 300, height: 200)
        let closeButDiagonal = CGRect(x: 400, y: 900, width: 300, height: 200)
        XCTAssertLessThan(
            closeButDiagonal.minX - origin.maxX, abeamButFar.minX - origin.maxX,
            "the premise: the diagonal one really is nearer")
        XCTAssertEqual(pick(from: origin, .right, among: [closeButDiagonal, abeamButFar]), abeamButFar)
    }

    /// With nothing in the band at all, the diagonal candidate is better than nothing: refusing to
    /// move because no window is exactly abeam would leave a chord that does nothing on most desks.
    func testADiagonalWindowIsTakenWhenNothingSharesTheBand() {
        let left = CGRect(x: 0, y: 25, width: 400, height: 300)
        let farBelowRight = CGRect(x: 900, y: 700, width: 400, height: 300)
        XCTAssertEqual(pick(from: left, .right, among: [farBelowRight]), farBelowRight)
    }

    // MARK: - Ordering within the band

    /// Nearest along the axis of travel first — the next column, not one two columns over.
    func testTheNearestColumnWinsOverAFurtherOne() {
        let first = CGRect(x: 0, y: 25, width: 500, height: 1000)
        let second = CGRect(x: 500, y: 25, width: 500, height: 1000)
        let third = CGRect(x: 1000, y: 25, width: 600, height: 1000)
        XCTAssertEqual(pick(from: first, .right, among: [third, second]), second)
        XCTAssertEqual(pick(from: third, .left, among: [first, second]), second)
    }

    /// Two candidates equally far along the axis of travel are separated by how far off it they are,
    /// so a stack of two windows in the next column resolves to the one more nearly abeam.
    func testTiesAlongTheAxisAreBrokenAcrossIt() {
        let origin = CGRect(x: 0, y: 400, width: 800, height: 200)
        let aligned = CGRect(x: 800, y: 380, width: 800, height: 200)
        let offset = CGRect(x: 800, y: 25, width: 800, height: 200)
        XCTAssertEqual(
            aligned.midX, offset.midX, "the premise: both are the same distance to the right")
        XCTAssertEqual(pick(from: origin, .right, among: [offset, aligned]), aligned)
    }

    /// Callers hand the list over in z-order, so two equally good candidates resolve to whichever is
    /// nearer the front — the one the user was more recently looking at.
    func testAnExactTieTakesTheFrontmost() {
        let origin = CGRect(x: 0, y: 25, width: 400, height: 1000)
        let front = CGRect(x: 800, y: 25, width: 400, height: 1000)
        let back = CGRect(x: 800, y: 25, width: 400, height: 1000)
        XCTAssertEqual(
            WindowNeighbors.pick(from: origin, among: [front, back], direction: .right), 0)
    }

    // MARK: - Degenerate cases

    /// Two windows stacked exactly on top of each other are in no direction from one another, rather
    /// than each being in every direction from the other. Compared strictly, on centres.
    func testAWindowAtTheSameCentreIsInNoDirection() {
        let origin = CGRect(x: 100, y: 100, width: 400, height: 400)
        let stacked = CGRect(x: 200, y: 200, width: 200, height: 200)
        XCTAssertEqual(origin.midX, stacked.midX)
        XCTAssertEqual(origin.midY, stacked.midY)
        for direction in WindowDirection.allCases {
            XCTAssertNil(pick(from: origin, direction, among: [stacked]), "\(direction.rawValue)")
        }
    }

    /// A window fully contained in the origin still counts if its centre is off to one side, which
    /// is the honest answer: "which way is that window" has one when the centres differ.
    func testAContainedWindowIsStillReachableWhenItsCentreIsOffToOneSide() {
        let origin = CGRect(x: 0, y: 25, width: 1600, height: 1000)
        let inset = CGRect(x: 1000, y: 300, width: 400, height: 300)
        XCTAssertEqual(pick(from: origin, .right, among: [inset]), inset)
    }
}
