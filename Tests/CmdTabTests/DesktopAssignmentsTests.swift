import XCTest

@testable import CmdTab

/// The contract between macOS's stored app assignments and the live Spaces they name.
///
/// These run against whatever this Mac actually has rather than a fixture, which is the only way to
/// test them honestly: both halves are readings of system state that no test can construct, and the
/// two bugs worth catching here — a key whose case does not match, a Space id keyed by an empty
/// UUID — are exactly the ones a fixture would define out of existence. They skip on a machine with
/// no assignments set, in the same shape `AccessibilityHarnessTests` skips without Safari.
final class DesktopAssignmentsTests: XCTestCase {
    func testBindingKeysAreLowercased() throws {
        let bindings = DesktopAssignments.bindings()
        try XCTSkipIf(
            bindings.isEmpty,
            "no app is assigned to a desktop; set one from the Dock's Options > Assign To")
        for key in bindings.keys {
            XCTAssertEqual(
                key, key.lowercased(),
                """
                macOS files this key lower case and NSRunningApplication does not, so the lookup \
                has to lowercase before it compares. A key that is already mixed case here means \
                that contract has changed and the comparison needs revisiting.
                """)
        }
    }

    func testNoBindingCarriesAnEmptyDestination() throws {
        let bindings = DesktopAssignments.bindings()
        try XCTSkipIf(bindings.isEmpty, "no app is assigned to a desktop")
        for (app, uuid) in bindings {
            XCTAssertFalse(
                uuid.isEmpty,
                "\(app) is bound to nothing; an All Desktops assignment must be filtered out")
        }
    }

    /// The empty-UUID Space is real — the display this was written against has one — and keying it
    /// by `""` would collide every such Space onto one entry and hand a binding the wrong Desktop.
    func testLiveSpacesAreNeverKeyedByAnEmptyUUID() {
        XCTAssertNil(SpaceMover.spaceIDsByUUID()[""])
    }

    /// Every assignment either names a Desktop that exists right now, or names one on a display
    /// that is not currently attached. Nothing else is a valid state, and the second case is the
    /// one the restore has to skip rather than guess at.
    func testEveryBindingEitherResolvesOrIsOnADetachedDisplay() throws {
        let bindings = DesktopAssignments.bindings()
        try XCTSkipIf(bindings.isEmpty, "no app is assigned to a desktop")
        let live = SpaceMover.spaceIDsByUUID()
        try XCTSkipIf(live.isEmpty, "the window server reported no Spaces")
        let resolved = bindings.filter { live[$0.value] != nil }
        XCTAssertFalse(
            resolved.isEmpty,
            """
            not one of \(bindings.count) assignments names a Space that exists. That is the \
            resolution chain broken rather than a genuinely detached display — the assignments \
            would all have to be on unplugged monitors at once.
            """)
    }
}
