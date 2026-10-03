import XCTest

@testable import CmdTab

/// The contract between macOS's stored app assignments and the live Spaces they name.
///
/// Most of these run against whatever this Mac actually has rather than a fixture, which is the only
/// way to test them honestly: both halves are readings of system state that no test can construct,
/// and the bugs worth catching here — a key whose case does not match, a value misread for what it
/// stores — are exactly the ones a fixture would define out of existence. They skip on a machine
/// with no assignments set, in the same shape `AccessibilityHarnessTests` skips without Safari.
/// The exception is the empty-UUID rule, whose dangerous case needs two displays at once.
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

    func testAllDesktopsIsFilteredOut() throws {
        let bindings = DesktopAssignments.bindings()
        try XCTSkipIf(bindings.isEmpty, "no app is assigned to a desktop")
        for (app, uuid) in bindings {
            XCTAssertNotEqual(
                uuid, "AllSpaces",
                "\(app) is on All Desktops, which is never off its desktop and must be filtered out")
        }
    }

    /// The display's original Desktop has an empty UUID and a binding to it is `""`, so the one
    /// such Space is keyed there — fullscreen Spaces aside, which are not Desktops at all.
    func testTheOnlyBlankUUIDDesktopIsKeyedByTheEmptyString() {
        let live = SpaceMover.spaceIDsByUUID(in: [
            Self.display([(0, "A", 4), (0, "", 1), (4, "", 9)])
        ])
        XCTAssertEqual(live, ["A": 4, "": 1])
    }

    /// Two of them and `""` could mean either; a binding handed the wrong Desktop is worse than
    /// one left unresolved, so neither is keyed and every named Desktop still is.
    func testTwoBlankUUIDDesktopsAreNeitherKeyed() {
        let live = SpaceMover.spaceIDsByUUID(in: [
            Self.display([(0, "", 1), (0, "A", 4)]),
            Self.display([(0, "", 2), (0, "B", 5)]),
        ])
        XCTAssertEqual(live, ["A": 4, "B": 5])
    }

    func testNoBlankUUIDDesktopKeysNothingUnderTheEmptyString() {
        XCTAssertNil(SpaceMover.spaceIDsByUUID(in: [Self.display([(0, "A", 4)])])[""])
    }

    /// The count the sticky-ambiguity rule turns on: an unplug takes the second blank Desktop
    /// away before any restore runs, so `spaceIDsByUUID()` remembers ever having seen two. Only
    /// user Spaces count — a fullscreen Space has no UUID either and is not a Desktop.
    func testBlankUUIDSpacesAreCountedAcrossDisplaysAndFullscreenIsNot() {
        XCTAssertEqual(
            SpaceMover.blankUUIDSpaceCount(in: [
                Self.display([(0, "", 1), (0, "A", 4), (4, "", 9)]),
                Self.display([(0, "", 2), (0, "B", 5)]),
            ]), 2)
        XCTAssertEqual(SpaceMover.blankUUIDSpaceCount(in: [Self.display([(0, "A", 4)])]), 0)
    }

    /// One display's slice of `CGSCopyManagedDisplaySpaces`, as (type, uuid, ManagedSpaceID).
    private static func display(_ spaces: [(Int, String, UInt64)]) -> [String: Any] {
        [
            "Spaces": spaces.map { type, uuid, id -> [String: Any] in
                ["type": type, "uuid": uuid, "ManagedSpaceID": NSNumber(value: id)]
            }
        ]
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
