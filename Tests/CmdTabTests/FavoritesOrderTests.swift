import XCTest

@testable import CmdTab

/// The reorder behind dragging one favourite onto another. The store around it writes
/// `UserDefaults`, which no test here touches, so this covers the part that decides where an app
/// lands rather than the plist round-trip.
final class FavoritesOrderTests: XCTestCase {

    private let list = ["a", "b", "c", "d"]

    /// Dragging down: the moved app takes the target's index and the ones it passed close up
    /// behind it, rather than landing one short of where it was dropped.
    func testMovingDownTakesTheTargetsPlace() {
        XCTAssertEqual(
            FavoritesStore.reordered(list, moving: "a", toPositionOf: "c"), ["b", "c", "a", "d"])
    }

    func testMovingUpTakesTheTargetsPlace() {
        XCTAssertEqual(
            FavoritesStore.reordered(list, moving: "d", toPositionOf: "b"), ["a", "d", "b", "c"])
    }

    func testDraggingTheLastOntoTheFirstMakesItFirst() {
        XCTAssertEqual(
            FavoritesStore.reordered(list, moving: "d", toPositionOf: "a"), ["d", "a", "b", "c"])
    }

    func testDraggingTheFirstOntoTheLastMakesItLast() {
        XCTAssertEqual(
            FavoritesStore.reordered(list, moving: "a", toPositionOf: "d"), ["b", "c", "d", "a"])
    }

    /// A drop on the row that was picked up is the usual way a drag is abandoned, and it has to
    /// leave the list identical — the store skips the write when nothing moved.
    func testDroppingOnItselfChangesNothing() {
        XCTAssertEqual(FavoritesStore.reordered(list, moving: "b", toPositionOf: "b"), list)
    }

    /// The pane hides excluded favourites, so a drag can step over one. It keeps its stored place
    /// rather than being dragged along or dropped out.
    func testAnUnlistedFavouriteKeepsItsPlaceAcrossAMove() {
        let withHidden = ["a", "hidden", "b", "c"]
        XCTAssertEqual(
            FavoritesStore.reordered(withHidden, moving: "c", toPositionOf: "a"),
            ["c", "a", "hidden", "b"])
    }

    /// Both ends come off a settings list that can be rebuilt while a drag is in flight — an app
    /// that quit, or a star turned off in another window — so neither side is assumed to be there.
    func testUnknownIdentifiersAreLeftAlone() {
        XCTAssertEqual(FavoritesStore.reordered(list, moving: "z", toPositionOf: "b"), list)
        XCTAssertEqual(FavoritesStore.reordered(list, moving: "b", toPositionOf: "z"), list)
    }
}
