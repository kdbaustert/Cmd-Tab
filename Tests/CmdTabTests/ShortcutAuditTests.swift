import CoreGraphics
import XCTest

@testable import CmdTab

/// Which bindings the audit says are fighting over a chord.
///
/// The rule it encodes is not "equal chords collide", because the families do not all match the
/// same way: the three openers compare ⌘/⌥/⌃ and ignore Shift, everything else compares all four
/// modifiers exactly. Read as one rule it gets the *shipping defaults* wrong — ⌃⌘← is Left half and
/// ⌃⌘⇧← is Move to previous display, so a single Shift-blind key made the two look like a conflict
/// and the Overview warned that one of them could never fire.
///
/// Entries are built by hand here rather than through `ShortcutAudit.entries()`, which reads five
/// singleton stores and the running application list. The comparison is the part with the bug in it.
final class ShortcutAuditTests: XCTestCase {
    private let ctrlCmd: CGEventFlags = [.maskControl, .maskCommand]
    private let ctrlCmdShift: CGEventFlags = [.maskControl, .maskCommand, .maskShift]
    private let leftArrow = 123

    private func entry(
        _ kind: ShortcutEntry.Kind, _ id: String, key: Int, _ modifiers: CGEventFlags,
        active: Bool = true
    ) -> ShortcutEntry {
        ShortcutEntry(
            id: id, kind: kind, label: id, display: id,
            chord: ShortcutEntry.Chord(keyCode: key, modifiers: modifiers), isActive: active)
    }

    // MARK: - Exact matchers keep Shift

    /// The regression. Both of these are bound out of the box and both work.
    func testTilingHalfAndDisplayMoveOnTheSameKeyDoNotCollide() {
        let entries = [
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
            entry(.tiling, "previousDisplay", key: leftArrow, ctrlCmdShift),
        ]
        XCTAssertTrue(ShortcutAudit.collisions(in: entries).isEmpty)
    }

    /// The shipping defaults, through the real binding table: nothing to warn about.
    ///
    /// `compactMap`, because the table no longer holds an entry for every arrangement: three
    /// families ship unbound and are absent from it entirely, which is how `defaults` expresses
    /// "no chord" — see `WindowArrangement.defaultHotkey`. An unbound arrangement contributes no
    /// entry here for the same reason `ShortcutAudit.entries` gives it a nil chord: it cannot
    /// collide with anything, because it never fires.
    func testDefaultTilingBindingsAreConflictFree() {
        let defaults = WindowTilingBindings.defaults
        let entries = WindowArrangement.allCases.compactMap { arrangement -> ShortcutEntry? in
            guard let hotkey = defaults.bindings[arrangement] else { return nil }
            return entry(
                .tiling, "tiling.\(arrangement.rawValue)", key: hotkey.keyCode,
                hotkey.modifiers)
        }
        XCTAssertEqual(ShortcutAudit.collisions(in: entries).map(\.display), [])
    }

    /// Shift still separates the *in-switcher* actions, which is what it always did: ⌥Q quits and
    /// ⌥⇧Q force-quits.
    func testActionsDifferingOnlyByShiftDoNotCollide() {
        let option = CGEventFlags.maskAlternate
        let entries = [
            entry(.inSwitcherAction, "quit", key: 12, option),
            entry(.inSwitcherAction, "forceQuit", key: 12, [option, .maskShift]),
        ]
        XCTAssertTrue(ShortcutAudit.collisions(in: entries).isEmpty)
    }

    /// Two exact bindings on the identical combination are still a collision, whichever families
    /// they come from — the cross-store case the audit exists for.
    func testIdenticalChordsInDifferentFamiliesCollide() {
        let entries = [
            entry(.directActivation, "activate.ghostty", key: leftArrow, ctrlCmd),
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
        ]
        let collisions = ShortcutAudit.collisions(in: entries)
        XCTAssertEqual(collisions.count, 1)
        XCTAssertEqual(collisions.first?.winner?.id, "activate.ghostty")
        XCTAssertEqual(collisions.first?.losers.map(\.id), ["leftHalf"])
    }

    /// A pool can hold two separate collisions: the Shift-blind key pools all four, and the exact
    /// comparison splits them back into two pairs rather than reporting one four-way clash.
    func testTwoShiftVariantsEachCollideSeparately() {
        let entries = [
            entry(.directActivation, "activate.a", key: leftArrow, ctrlCmd),
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
            entry(.directActivation, "activate.b", key: leftArrow, ctrlCmdShift),
            entry(.tiling, "previousDisplay", key: leftArrow, ctrlCmdShift),
        ]
        let collisions = ShortcutAudit.collisions(in: entries)
        XCTAssertEqual(collisions.count, 2)
        XCTAssertEqual(
            Set(collisions.map { Set($0.entries.map(\.id)) }),
            [["activate.a", "leftHalf"], ["activate.b", "previousDisplay"]])
    }

    // MARK: - Openers ignore Shift

    /// An opener claims the press before anything below it is consulted, and it is matched on
    /// ⌘/⌥/⌃ alone — so it kills the Shift variant too, which an exact comparison would have missed.
    func testAnOpenerClaimsEveryShiftVariantOnItsKey() {
        let entries = [
            entry(.switcherTrigger, "trigger", key: leftArrow, ctrlCmd),
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
            entry(.tiling, "previousDisplay", key: leftArrow, ctrlCmdShift),
        ]
        let collisions = ShortcutAudit.collisions(in: entries)
        XCTAssertEqual(collisions.count, 1)
        XCTAssertEqual(collisions.first?.winner?.id, "trigger")
        XCTAssertEqual(
            Set(collisions.first?.losers.map(\.id) ?? []), ["leftHalf", "previousDisplay"])
    }

    /// Named after the winner. The row is the user's handle on the problem, and pointing them at
    /// ⌃⌘⇧← — a combination that works — is worse than not warning at all.
    func testAnOpenerCollisionIsNamedAfterTheChordThatFires() {
        let entries = [
            entry(.switcherTrigger, "trigger", key: leftArrow, ctrlCmd),
            entry(.tiling, "previousDisplay", key: leftArrow, ctrlCmdShift),
        ]
        XCTAssertEqual(ShortcutAudit.collisions(in: entries).first?.display, "trigger")
    }

    /// Two openers agree on ⌘/⌥/⌃ and disagree on Shift: still one binding, still a collision.
    func testTwoOpenersCollideAcrossShift() {
        let entries = [
            entry(.switcherTrigger, "trigger", key: leftArrow, ctrlCmd),
            entry(.scopedTrigger, "scoped.1", key: leftArrow, ctrlCmdShift),
        ]
        XCTAssertEqual(ShortcutAudit.collisions(in: entries).count, 1)
    }

    // MARK: - The rest of the contract

    /// The two namespaces never meet: an action is matched with the trigger held, in a state where
    /// no global binding is consulted at all.
    func testAGlobalChordAndAnActionChordAreNotInCompetition() {
        let option = CGEventFlags.maskAlternate
        let entries = [
            entry(.tiling, "leftHalf", key: 12, option),
            entry(.inSwitcherAction, "quit", key: 12, option),
        ]
        XCTAssertTrue(ShortcutAudit.collisions(in: entries).isEmpty)
    }

    /// A family switched off cannot take a chord from anyone.
    func testAnInactiveEntryNeverCollides() {
        let entries = [
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd, active: false),
            entry(.directActivation, "activate.a", key: leftArrow, ctrlCmd),
        ]
        XCTAssertTrue(ShortcutAudit.collisions(in: entries).isEmpty)
    }

    /// An unbound entry is listed but has no chord to fight over.
    func testUnboundEntriesNeverCollide() {
        let unbound = ShortcutEntry(
            id: "activate.a", kind: .directActivation, label: "A", display: "Not set",
            chord: nil, isActive: true)
        let entries = [
            unbound,
            ShortcutEntry(
                id: "activate.b", kind: .directActivation, label: "B", display: "Not set",
                chord: nil, isActive: true),
        ]
        XCTAssertTrue(ShortcutAudit.collisions(in: entries).isEmpty)
    }

    /// Every collision needs its own id or the `ForEach` rendering them drops rows.
    func testCollisionIdentifiersAreUnique() {
        let entries = [
            entry(.directActivation, "activate.a", key: leftArrow, ctrlCmd),
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
            entry(.directActivation, "activate.b", key: leftArrow, ctrlCmdShift),
            entry(.tiling, "previousDisplay", key: leftArrow, ctrlCmdShift),
        ]
        let ids = ShortcutAudit.collisions(in: entries).map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count)
    }

    /// Same kind on both sides, so the winner cannot come from the kind order — it comes from the
    /// position in the list, which is the order the matcher walks.
    func testTheWinnerIsTheEarlierEntryWithinOneFamily() {
        let entries = [
            entry(.tiling, "leftHalf", key: leftArrow, ctrlCmd),
            entry(.tiling, "leftThird", key: leftArrow, ctrlCmd),
        ]
        XCTAssertEqual(ShortcutAudit.collisions(in: entries).first?.winner?.id, "leftHalf")
    }
}
