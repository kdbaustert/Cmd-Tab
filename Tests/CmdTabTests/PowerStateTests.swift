import XCTest

@testable import CmdTab

/// The poll-interval arithmetic behind `PowerState`.
///
/// Only the pure half is testable — whether *this* machine is on battery is a fact about the room,
/// not about the code — but the arithmetic is the part that decides how often two timers wake the
/// process for the life of it, so it is the part worth pinning down.
final class PowerStateTests: XCTestCase {
    func testPluggedInPollsAtTheBaseRate() {
        XCTAssertEqual(PowerState.interval(5, conserving: false), 5)
    }

    func testConservingStretchesTheInterval() {
        XCTAssertEqual(PowerState.interval(5, conserving: true), 30)
    }

    /// The stretch is a multiplier, so it applies whatever the base — the trust watch and the layout
    /// capture both ride on it and neither has to know the factor.
    func testTheStretchIsProportional() {
        for base in [1.0, 5.0, 60.0] {
            XCTAssertEqual(
                PowerState.interval(base, conserving: true),
                base * PowerState.conservingScale, accuracy: 0.0001)
        }
    }

    /// Slower, never faster. A conserving interval shorter than the plugged-in one would be the
    /// setting doing the opposite of what it says.
    func testConservingIsNeverQuickerThanPluggedIn() {
        XCTAssertGreaterThan(PowerState.conservingScale, 1)
        XCTAssertGreaterThan(
            PowerState.interval(5, conserving: true), PowerState.interval(5, conserving: false))
    }

    /// Whatever this machine reports, it has to be one answer rather than a crash — the call is made
    /// on a timer for the life of the process.
    func testReadingThePowerSourceAnswersRatherThanFailing() {
        XCTAssertEqual(PowerState.isOnBattery, PowerState.isOnBattery)
        XCTAssertGreaterThan(PowerState.interval(5), 0)
    }
}
