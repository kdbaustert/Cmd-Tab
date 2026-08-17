import CoreGraphics
import XCTest

@testable import CmdTab

/// Whether a pick that reported success actually left its window in front of the user.
///
/// `zRank` is the only check that reads the result rather than the calls that produced it, and it is
/// consulted twice: once as the gate on the re-raise in `verifyFront`, and once in the
/// `after activation` line that is the whole record of how a switch ended. A rank it gets wrong is
/// therefore both a wasted round of AX work and a log that reports a healthy switch as a failure.
///
/// The cases below are drawn from a day of real logs. A raw position in the z-order — what this used
/// to return — got all four of them wrong in one direction or the other.
final class ZRankTests: XCTestCase {
    private func window(
        _ id: CGWindowID, pid: pid_t, _ owner: String = "App",
        _ frame: CGRect = CGRect(x: 0, y: 0, width: 2024, height: 1258)
    ) -> SwitchTarget.StackedWindow {
        SwitchTarget.StackedWindow(id: id, pid: pid, owner: owner, frame: frame)
    }

    /// The reported case. Chrome floats a 347×22 link-preview bubble over its own window, so a pick
    /// that landed perfectly logged `zrank=1` and spent a re-raise on a stack that was already right.
    func testAnAppsOwnHelperSurfaceDoesNotBuryIt() {
        let bubble = window(
            32382, pid: 53446, "Google Chrome", CGRect(x: 0, y: 1236, width: 347, height: 22))
        let real = window(26677, pid: 53446, "Google Chrome")
        XCTAssertEqual(SwitchTarget.zRank(of: 26677, in: [bubble, real]), 0)
    }

    /// The failure the check exists for, and it has to survive the filtering above: another app's
    /// window over ours is exactly the Messages-behind-Ghostty case `verifyFront` documents.
    func testAnotherAppsWindowOnTopStillCounts() {
        let ghostty = window(
            26829, pid: 58938, "Ghostty", CGRect(x: 0, y: 0, width: 2056, height: 1290))
        let messages = window(28691, pid: 68942, "Messages")
        XCTAssertEqual(SwitchTarget.zRank(of: 28691, in: [ghostty, messages]), 1)
    }

    /// Every display is in one list, so a window genuinely frontmost on its own monitor used to rank
    /// behind whatever happened to be frontmost on another one — a permanent false failure for
    /// anyone with two screens.
    func testAWindowOnAnotherDisplayDoesNotBuryIt() {
        let other = window(
            100, pid: 1, "Elsewhere", CGRect(x: 3000, y: 0, width: 1920, height: 1080))
        let here = window(200, pid: 2, "Here")
        XCTAssertEqual(SwitchTarget.zRank(of: 200, in: [other, here]), 0)
    }

    /// Overlap, not display identity, is what the filter turns on — so a foreign window that only
    /// clips a corner of ours does obscure it, and does count.
    func testAPartialOverlapCounts() {
        let overlapping = window(
            100, pid: 1, "Overlapping", CGRect(x: 1900, y: 1200, width: 400, height: 400))
        let here = window(200, pid: 2, "Here")
        XCTAssertEqual(SwitchTarget.zRank(of: 200, in: [overlapping, here]), 1)
    }

    /// Only what is *ahead* of the target counts. Windows behind it are what a successful pick
    /// leaves behind it.
    func testWindowsBehindTheTargetAreNotCounted() {
        let here = window(200, pid: 2, "Here")
        let behind = window(300, pid: 3, "Behind")
        XCTAssertEqual(SwitchTarget.zRank(of: 200, in: [here, behind]), 0)
    }

    /// A window the on-screen list does not carry is on another Desktop or minimized, which is not a
    /// rank at all — and must not read as rank 0, the value that means "in front".
    func testAWindowThatIsNotOnScreenHasNoRank() {
        XCTAssertEqual(SwitchTarget.zRank(of: 999, in: [window(200, pid: 2)]), -1)
    }
}
