import CoreGraphics
import XCTest

@testable import CmdTab

/// The menu bar's Shortcuts submenu, over a fabricated `[ShortcutEntry]` — no Accessibility, no
/// window server, no stores. What is under test is the pure shaping: which rows appear, which are
/// grouped where, and which are allowed to perform their action when clicked.
final class ShortcutsMenuTests: XCTestCase {
    private func entry(
        _ kind: ShortcutEntry.Kind, _ id: String, bound: Bool = true, active: Bool = true
    ) -> ShortcutEntry {
        ShortcutEntry(
            id: id, kind: kind, label: id, display: id,
            chord: bound ? ShortcutEntry.Chord(keyCode: 0, modifiers: .maskCommand) : nil,
            isActive: active)
    }

    // MARK: - Bound-only, empty groups dropped

    func testUnboundEntriesAreDropped() {
        let entries = [
            entry(.tiling, "tiling.leftHalf"),
            entry(.tiling, "tiling.rightHalf", bound: false),
        ]
        let groups = ShortcutsMenuModel.groups(from: entries)
        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups[0].rows.map(\.label), ["tiling.leftHalf"])
    }

    func testAKindWithNothingBoundProducesNoGroupAtAll() {
        let entries = [
            entry(.tiling, "tiling.leftHalf", bound: false),
            entry(.directActivation, "activate.com.apple.Safari"),
        ]
        let groups = ShortcutsMenuModel.groups(from: entries)
        XCTAssertEqual(groups.map(\.kind), [.directActivation])
    }

    func testGroupsAppearInKindDeclarationOrderRegardlessOfEntryOrder() {
        let entries = [
            entry(.tiling, "tiling.leftHalf"),
            entry(.switcherTrigger, "trigger"),
        ]
        let groups = ShortcutsMenuModel.groups(from: entries)
        XCTAssertEqual(groups.map(\.kind), [.switcherTrigger, .tiling])
    }

    // MARK: - Unsafe kinds are listed but never performing

    func testInSwitcherActionsAndMouseGesturesNeverPerform() {
        let entries = [
            entry(.inSwitcherAction, "action.close"),
            entry(.mouseGesture, "mouse.move"),
        ]
        for group in ShortcutsMenuModel.groups(from: entries) {
            for row in group.rows {
                XCTAssertFalse(row.canPerform, "\(row.label) must not be wired to an action")
                XCTAssertNil(row.command)
            }
        }
    }

    func testTilingDirectActivationAndAllWindowsDoPerform() {
        let entries = [
            entry(.tiling, "tiling.leftHalf"),
            entry(.directActivation, "activate.com.apple.Safari"),
            entry(.allWindows, "hideAll"),
            entry(.allWindows, "showAll"),
        ]
        let rows = ShortcutsMenuModel.groups(from: entries).flatMap(\.rows)
        XCTAssertEqual(rows.count, 4)
        for row in rows {
            XCTAssertTrue(row.canPerform, "\(row.label) should be safe to perform")
        }
    }

    func testCommandsAreRecoveredFromTheEntryID() {
        XCTAssertEqual(
            ShortcutsMenuModel.command(for: entry(.tiling, "tiling.leftHalf")),
            .arrangement(.leftHalf))
        XCTAssertEqual(
            ShortcutsMenuModel.command(for: entry(.directActivation, "activate.com.apple.Safari")),
            .activate(bundleID: "com.apple.Safari"))
        XCTAssertEqual(
            ShortcutsMenuModel.command(for: entry(.allWindows, "hideAll")), .allWindows(.hide))
        XCTAssertEqual(
            ShortcutsMenuModel.command(for: entry(.allWindows, "showAll")), .allWindows(.show))
    }

    func testUnrecognisedIDsProduceNoCommand() {
        XCTAssertNil(ShortcutsMenuModel.command(for: entry(.tiling, "tiling.notAnArrangement")))
        XCTAssertNil(ShortcutsMenuModel.command(for: entry(.allWindows, "somethingElse")))
    }

    // MARK: - Conflict row

    func testConflictCountReflectsCollisionsInTheAudit() {
        let key = 0
        let cmd: CGEventFlags = .maskCommand
        let clashing = [
            ShortcutEntry(
                id: "tiling.leftHalf", kind: .tiling, label: "Left half", display: "⌘0",
                chord: ShortcutEntry.Chord(keyCode: key, modifiers: cmd), isActive: true),
            ShortcutEntry(
                id: "tiling.rightHalf", kind: .tiling, label: "Right half", display: "⌘0",
                chord: ShortcutEntry.Chord(keyCode: key, modifiers: cmd), isActive: true),
        ]
        XCTAssertEqual(ShortcutAudit.collisions(in: clashing).count, 1)

        let clean = [entry(.tiling, "tiling.leftHalf")]
        XCTAssertTrue(ShortcutAudit.collisions(in: clean).isEmpty)
    }
}
