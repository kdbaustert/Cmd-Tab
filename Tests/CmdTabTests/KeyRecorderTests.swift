import XCTest

@testable import CmdTab

@MainActor
final class KeyRecorderTests: XCTestCase {
    /// Closing Settings calls `stopCurrent` because `.onDisappear` does not fire on window close;
    /// this pins what that call has to do — run the recorder's own teardown and clear the flag.
    func testStopCurrentDisarmsTheArmedRecorder() {
        var disarmed = false
        KeyRecorder.arm { disarmed = true }
        XCTAssertTrue(KeyRecorder.isArmed)
        KeyRecorder.stopCurrent()
        XCTAssertTrue(disarmed)
        XCTAssertFalse(KeyRecorder.isArmed)
    }
}
