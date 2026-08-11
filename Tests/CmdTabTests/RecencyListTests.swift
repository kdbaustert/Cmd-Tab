import XCTest

@testable import CmdTab

/// The MRU ordering behind both "Recently used" lists — apps and, within an app, windows.
///
/// This is what the switcher's default order *is*, and until it was lifted out of `TargetProvider`
/// it lived inside methods that also did Accessibility IPC and workspace-notification handling,
/// where nothing could reach it.
final class RecencyListTests: XCTestCase {

    func testTouchingPutsAnElementAtTheFront() {
        var list = RecencyList<Int>(limit: 10)
        list.touch(1)
        list.touch(2)
        list.touch(3)
        XCTAssertEqual(list.entries, [3, 2, 1])
    }

    /// The bug this rule prevents: insert-without-remove leaves the same id at two ranks, and the
    /// older one wins every `min`-uniqued lookup — so an app sorts by the position it held several
    /// switches ago rather than the one it holds now.
    func testRetouchingMovesRatherThanDuplicates() {
        var list = RecencyList<Int>(limit: 10)
        list.touch(1)
        list.touch(2)
        list.touch(3)
        list.touch(1)
        XCTAssertEqual(list.entries, [1, 3, 2])
        XCTAssertEqual(list.entries.count, 3, "no duplicate left behind")
    }

    func testTouchingTheFrontElementChangesNothing() {
        var list = RecencyList<Int>(limit: 10)
        list.touch(1)
        list.touch(2)
        list.touch(2)
        XCTAssertEqual(list.entries, [2, 1])
    }

    /// The cap drops the oldest. Trimming the head would evict the app the user is looking at.
    func testTheCapDropsTheOldestEntries() {
        var list = RecencyList<Int>(limit: 3)
        for value in 1...5 { list.touch(value) }
        XCTAssertEqual(list.entries, [5, 4, 3])
    }

    func testTheCapIsAppliedOnEveryTouchNotJustAtTheEnd() {
        var list = RecencyList<Int>(limit: 2)
        list.touch(1)
        list.touch(2)
        XCTAssertEqual(list.entries.count, 2)
        list.touch(3)
        XCTAssertEqual(list.entries, [3, 2])
    }

    /// A terminated app is dropped outright rather than left to age out — the cap is the backstop,
    /// not the mechanism.
    func testRemoveDropsAnElementWithoutDisturbingTheRest() {
        var list = RecencyList<Int>(limit: 10)
        list.touch(1)
        list.touch(2)
        list.touch(3)
        list.remove(2)
        XCTAssertEqual(list.entries, [3, 1])
    }

    func testRemovingSomethingAbsentIsHarmless() {
        var list = RecencyList<Int>(limit: 10)
        list.touch(1)
        list.remove(99)
        XCTAssertEqual(list.entries, [1])
    }

    func testRanksAreZeroBasedFromMostRecent() {
        var list = RecencyList<String>(limit: 10)
        list.touch("c")
        list.touch("b")
        list.touch("a")
        XCTAssertEqual(list.ranks(), ["a": 0, "b": 1, "c": 2])
    }

    func testRanksOfAnEmptyListAreEmpty() {
        XCTAssertTrue(RecencyList<Int>(limit: 10).ranks().isEmpty)
    }
}
