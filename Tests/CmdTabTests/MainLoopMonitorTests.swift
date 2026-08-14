import XCTest

@testable import CmdTab

/// The attribution half of the main-loop monitor.
///
/// The duration half is measured by the run loop and needs a real stall to provoke, which is half a
/// second of wall clock for a number the observer is not in doubt about. What *is* worth pinning
/// down is which labelled work a crossing is allowed to name: `lastMark` is deliberately never
/// cleared — the report is written long after the marked work returned — so the only thing standing
/// between a useful line and a misleading one is the timestamp comparison below.
@MainActor
final class MainLoopMonitorTests: XCTestCase {

    func testMarkingReturnsTheWorkValue() {
        XCTAssertEqual(MainLoopMonitor.marking("test") { 41 + 1 }, 42)
    }

    func testAStallNamesTheWorkThatRanInsideIt() {
        let turnStart = DispatchTime.now().uptimeNanoseconds
        MainLoopMonitor.marking("panel layout") {}
        XCTAssertEqual(MainLoopMonitor.suspect(since: turnStart), "panel layout")
    }

    /// The guard that keeps the line honest. A stall in unlabelled code must not inherit the name of
    /// the last marked work to have run — that would send whoever reads it after the one path that
    /// demonstrably was not involved, which is worse than admitting there is nothing to say.
    func testAStallDoesNotInheritAnEarlierTurnsLabel() {
        MainLoopMonitor.marking("panel layout") {}
        let laterTurnStart = DispatchTime.now().uptimeNanoseconds
        XCTAssertEqual(MainLoopMonitor.suspect(since: laterTurnStart), "unlabelled work")
    }

    /// Nesting is expected — `switchableApps` is marked and runs inside a marked refresh — and the
    /// innermost mark is the more specific answer, so it is the one that should survive.
    func testTheInnermostMarkWins() {
        let turnStart = DispatchTime.now().uptimeNanoseconds
        MainLoopMonitor.marking("outer") {
            MainLoopMonitor.marking("app enumeration") {}
        }
        XCTAssertEqual(MainLoopMonitor.suspect(since: turnStart), "app enumeration")
    }
}
