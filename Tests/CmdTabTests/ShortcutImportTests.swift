import AppKit
import CoreGraphics
import XCTest

@testable import CmdTab

/// `rectangleBindings`, `altTabBindings` and `ShortcutImport.plan` are pure functions over
/// fabricated plist dictionaries and chord sets — nothing here touches Accessibility, the window
/// server, or an actually-installed copy of either app. Verified separately, by hand, against a
/// real Rectangle Pro install (see the PR/handback note); that machine-specific check is not
/// something a portable test suite can repeat.
@MainActor
final class ShortcutImportTests: XCTestCase {

    // MARK: - Rectangle

    private func rectangleDict(keyCode: Int, modifierFlags: Int) -> [String: Any] {
        ["keyCode": keyCode, "modifierFlags": modifierFlags, "type": 0]
    }

    func testRectangleBoundActionImports() {
        // 1572864 = NSEvent.ModifierFlags.command | .option, per the live plist in the spec.
        let plist: [String: Any] = ["leftHalf": rectangleDict(keyCode: 123, modifierFlags: 1_572_864)]
        let result = ShortcutImport.rectangleBindings(from: plist)
        let hotkey = try? XCTUnwrap(result.arrangements[.leftHalf])
        XCTAssertEqual(hotkey?.keyCode, 123)
        XCTAssertEqual(hotkey?.modifiers, [.maskCommand, .maskAlternate])
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.unparsed.isEmpty)
    }

    func testRectangleUnboundActionIsIgnored() {
        let plist: [String: Any] = ["rightHalf": [String: Any]()]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertTrue(result.arrangements.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.unparsed.isEmpty)
    }

    func testRectangleActionWithNoCounterpartIsSkipped() {
        let plist: [String: Any] = ["cascade": rectangleDict(keyCode: 8, modifierFlags: 1_572_864)]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertTrue(result.arrangements.isEmpty)
        XCTAssertEqual(result.skipped, ["cascade"])
    }

    func testRectangleUnknownActionNameIsIgnoredEntirely() {
        // Not in either the mapping table or the known-unmapped set — e.g. a scalar preference
        // like `gapSize`, which is not an action at all and should not show up as skipped noise.
        let plist: [String: Any] = ["gapSize": 8]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertTrue(result.arrangements.isEmpty)
        XCTAssertTrue(result.skipped.isEmpty)
        XCTAssertTrue(result.unparsed.isEmpty)
    }

    func testRectangleRenamedActions() {
        let plist: [String: Any] = [
            "moveLeft": rectangleDict(keyCode: 123, modifierFlags: 1_572_864),
            "firstThird": rectangleDict(keyCode: 18, modifierFlags: 1_572_864),
            "firstTwoThirds": rectangleDict(keyCode: 19, modifierFlags: 1_572_864),
            "lastThird": rectangleDict(keyCode: 20, modifierFlags: 1_572_864),
            "lastTwoThirds": rectangleDict(keyCode: 21, modifierFlags: 1_572_864),
        ]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertEqual(result.arrangements[.nudgeLeft]?.keyCode, 123)
        XCTAssertEqual(result.arrangements[.leftThird]?.keyCode, 18)
        XCTAssertEqual(result.arrangements[.leftTwoThirds]?.keyCode, 19)
        XCTAssertEqual(result.arrangements[.rightThird]?.keyCode, 20)
        XCTAssertEqual(result.arrangements[.rightTwoThirds]?.keyCode, 21)
    }

    /// Rectangle's fourths, sixths, ninths and tile/cascade-all each name an arrangement here, and
    /// the three-fourths pair keeps Cmd-Tab's left/right naming.
    func testRectangleFinerGridsAndArrangeAllAreImported() {
        let names: [String: WindowArrangement] = [
            "firstFourth": .firstFourth, "secondFourth": .secondFourth,
            "thirdFourth": .thirdFourth, "lastFourth": .lastFourth,
            "firstThreeFourths": .leftThreeFourths, "lastThreeFourths": .rightThreeFourths,
            "topLeftSixth": .topLeftSixth, "topCenterSixth": .topCenterSixth,
            "topRightSixth": .topRightSixth, "bottomLeftSixth": .bottomLeftSixth,
            "bottomCenterSixth": .bottomCenterSixth, "bottomRightSixth": .bottomRightSixth,
            "topLeftNinth": .topLeftNinth, "topCenterNinth": .topCenterNinth,
            "topRightNinth": .topRightNinth, "middleLeftNinth": .middleLeftNinth,
            "middleCenterNinth": .middleCenterNinth, "middleRightNinth": .middleRightNinth,
            "bottomLeftNinth": .bottomLeftNinth, "bottomCenterNinth": .bottomCenterNinth,
            "bottomRightNinth": .bottomRightNinth, "tileAll": .tileAll, "cascadeAll": .cascadeAll,
        ]
        var plist: [String: Any] = [:]
        for (index, name) in names.keys.sorted().enumerated() {
            plist[name] = rectangleDict(keyCode: index, modifierFlags: 1_572_864)
        }
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertTrue(result.skipped.isEmpty, "\(result.skipped)")
        for (index, name) in names.keys.sorted().enumerated() {
            XCTAssertEqual(result.arrangements[names[name]!]?.keyCode, index, name)
        }
    }

    /// Rectangle's other cascade/reverse/stash verbs have no counterpart and stay reported as skipped.
    func testRectangleOtherArrangeVerbsStayUnmapped() {
        let plist: [String: Any] = [
            "cascade": rectangleDict(keyCode: 1, modifierFlags: 1_572_864),
            "reverseAll": rectangleDict(keyCode: 2, modifierFlags: 1_572_864),
        ]
        XCTAssertEqual(
            Set(ShortcutImport.rectangleBindings(from: plist).skipped), ["cascade", "reverseAll"])
    }

    func testRectangleModifierConversion() {
        // command+control+shift = (1<<20) | (1<<18) | (1<<17) = 1_179_648 + ... compute explicitly.
        let flags: NSEvent.ModifierFlags = [.command, .control, .shift]
        let plist: [String: Any] = [
            "maximize": rectangleDict(keyCode: 3, modifierFlags: Int(flags.rawValue))
        ]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertEqual(result.arrangements[.maximize]?.modifiers, [.maskCommand, .maskControl, .maskShift])
    }

    func testRectangleMalformedValueIsUnparsed() {
        let plist: [String: Any] = ["leftHalf": "not a dictionary"]
        let result = ShortcutImport.rectangleBindings(from: plist)
        XCTAssertTrue(result.arrangements.isEmpty)
        XCTAssertEqual(result.unparsed, ["leftHalf"])
    }

    // MARK: - AltTab

    func testAltTabHoldShortcutParsesFromReadableStringField() {
        let plist: [String: Any] = [
            "holdShortcut": ["readableString": "⌥⇥", "data": Data([1, 2, 3])]
        ]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertEqual(result.trigger?.keyCode, 48)
        XCTAssertEqual(result.trigger?.modifiers, [.maskAlternate])
    }

    func testAltTabHoldShortcutAcceptsBareString() {
        let plist: [String: Any] = ["holdShortcut": "⌘⇧A"]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertEqual(result.trigger?.keyCode, 0)
        XCTAssertEqual(result.trigger?.modifiers, [.maskCommand, .maskShift])
    }

    func testAltTabUnparseableGlyphStringIsReported() {
        let plist: [String: Any] = ["holdShortcut": ["readableString": "⌥⌃⌘"]]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertNil(result.trigger)
        XCTAssertEqual(result.unparsed.count, 1)
        XCTAssertTrue(result.unparsed[0].hasPrefix("holdShortcut"))
    }

    func testAltTabNextAndPreviousWindowShortcutAreSkippedNotImported() {
        let plist: [String: Any] = [
            "nextWindowShortcut": ["readableString": "⌘⇥"],
            "previousWindowShortcut": ["readableString": "⇧"],
        ]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertNil(result.trigger)
        XCTAssertEqual(Set(result.skipped), ["nextWindowShortcut", "previousWindowShortcut"])
    }

    /// AltTab's trigger in two halves: the held modifier alone in `holdShortcut`, the key in
    /// `nextWindowShortcut`. Read separately, the hold half was "unparsed" and nothing imported.
    func testAltTabModifierOnlyHoldIsJoinedToTheNextWindowKey() {
        let plist: [String: Any] = [
            "holdShortcut": ["readableString": "⌥"],
            "nextWindowShortcut": ["readableString": "⇥"],
            "previousWindowShortcut": ["readableString": "⇧⇥"],
        ]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertEqual(result.trigger?.keyCode, 48)
        XCTAssertEqual(result.trigger?.modifiers, [.maskAlternate])
        XCTAssertTrue(result.unparsed.isEmpty)
        XCTAssertEqual(
            result.skipped, ["previousWindowShortcut"], "the next key was used, not skipped")
    }

    func testAltTabActionsWithNoCounterpartAreSkipped() {
        let plist: [String: Any] = ["quitAppShortcut": ["readableString": "⌘Q"]]
        let result = ShortcutImport.altTabBindings(from: plist)
        XCTAssertEqual(result.skipped, ["quitAppShortcut"])
    }

    // MARK: - Plan / collisions

    private func chord(_ keyCode: Int, _ modifiers: CGEventFlags) -> ShortcutEntry.Chord {
        ShortcutEntry.Chord(keyCode: keyCode, modifiers: modifiers)
    }

    func testPlanAppliesNonCollidingChanges() {
        var result = ImportResult()
        result.arrangements[.leftHalf] = Hotkey(keyCode: 123, modifierRaw: CGEventFlags.maskCommand.rawValue)
        let plan = ShortcutImport.plan(from: result, activeChords: [])
        XCTAssertEqual(plan.toApply.count, 1)
        XCTAssertTrue(plan.droppedForCollision.isEmpty)
    }

    func testPlanDropsChordAlreadyClaimedElsewhere() {
        var result = ImportResult()
        let hotkey = Hotkey(keyCode: 123, modifierRaw: CGEventFlags.maskCommand.rawValue)
        result.arrangements[.leftHalf] = hotkey
        let active: Set<ShortcutEntry.Chord> = [chord(123, .maskCommand)]
        let plan = ShortcutImport.plan(from: result, activeChords: active)
        XCTAssertTrue(plan.toApply.isEmpty)
        XCTAssertEqual(plan.droppedForCollision.count, 1)
        XCTAssertEqual(plan.droppedForCollision.first?.label, WindowArrangement.leftHalf.title)
    }

    /// Two imported bindings on one chord used to both apply, because only chords already bound
    /// here were checked.
    func testPlanDropsASecondImportedBindingOnTheSameChord() {
        var result = ImportResult()
        let hotkey = Hotkey(keyCode: 123, modifierRaw: CGEventFlags.maskCommand.rawValue)
        result.arrangements[.leftHalf] = hotkey
        result.arrangements[.leftThird] = hotkey
        let plan = ShortcutImport.plan(from: result, activeChords: [])
        XCTAssertEqual(plan.toApply.count, 1)
        XCTAssertEqual(plan.droppedForCollision.count, 1)
    }

    /// Exact bindings keep Shift, as `ShortcutAudit.collisions` does: ⌃⌘← and ⌃⌘⇧← are two chords.
    func testPlanKeepsTwoImportedBindingsThatDifferOnlyByShift() {
        var result = ImportResult()
        result.arrangements[.leftHalf] = Hotkey(
            keyCode: 123, modifierRaw: CGEventFlags([.maskControl, .maskCommand]).rawValue)
        result.arrangements[.previousDisplay] = Hotkey(
            keyCode: 123,
            modifierRaw: CGEventFlags([.maskControl, .maskCommand, .maskShift]).rawValue)
        XCTAssertEqual(ShortcutImport.plan(from: result, activeChords: []).toApply.count, 2)
    }

    /// An existing exact binding is compared by the same rule two imported ones are. Rectangle's
    /// ⌃⌘⇧↑ used to be refused because ⌃⌘↑ was bound, though the tiling matcher tells them apart.
    func testPlanKeepsAnImportThatDiffersFromAnExistingExactBindingOnlyByShift() {
        var result = ImportResult()
        result.arrangements[.maximize] = Hotkey(
            keyCode: 126,
            modifierRaw: CGEventFlags([.maskControl, .maskCommand, .maskShift]).rawValue)
        let plan = ShortcutImport.plan(
            from: result, activeChords: [chord(126, [.maskControl, .maskCommand])])
        XCTAssertEqual(plan.toApply.count, 1)
        XCTAssertTrue(plan.droppedForCollision.isEmpty)
    }

    /// An existing opener still claims every Shift variant of its chord.
    func testPlanDropsAnImportOnAShiftVariantOfAnExistingOpener() {
        var result = ImportResult()
        result.arrangements[.leftHalf] = Hotkey(
            keyCode: 48, modifierRaw: CGEventFlags([.maskAlternate, .maskShift]).rawValue)
        let plan = ShortcutImport.plan(
            from: result, activeChords: [], activeOpeners: [chord(48, .maskAlternate)])
        XCTAssertEqual(plan.droppedForCollision.count, 1)
    }

    /// And an imported opener claims every Shift variant of an existing exact binding.
    func testPlanDropsAnImportedTriggerOnAShiftVariantOfAnExistingBinding() {
        var result = ImportResult()
        result.trigger = Hotkey(keyCode: 48, modifierRaw: CGEventFlags.maskAlternate.rawValue)
        let plan = ShortcutImport.plan(
            from: result, activeChords: [chord(48, [.maskAlternate, .maskShift])])
        XCTAssertEqual(plan.droppedForCollision.count, 1)
    }

    /// A target already on exactly this chord is not colliding with "something else" — it is
    /// colliding with itself, which is no collision.
    func testPlanReportsAChordTheTargetAlreadyHasAsAlreadySet() {
        var result = ImportResult()
        result.arrangements[.leftHalf] = Hotkey(
            keyCode: 123, modifierRaw: CGEventFlags.maskCommand.rawValue)
        let plan = ShortcutImport.plan(
            from: result, activeChords: [chord(123, .maskCommand)],
            current: ["tiling.leftHalf": chord(123, .maskCommand)])
        XCTAssertTrue(plan.toApply.isEmpty)
        XCTAssertTrue(plan.droppedForCollision.isEmpty)
        XCTAssertEqual(plan.alreadySet.count, 1)
    }

    /// The trigger recorder refuses a trigger that silences window actions unless the user agrees
    /// to move them; the import used to apply it with no question at all.
    func testPlanRefusesATriggerThatWouldSilenceWindowActions() {
        var result = ImportResult()
        result.trigger = Hotkey(keyCode: 48, modifierRaw: CGEventFlags.maskAlternate.rawValue)
        let plan = ShortcutImport.plan(
            from: result, activeChords: [], shadows: { _ in ["Quit", "Close Window"] })
        XCTAssertTrue(plan.toApply.isEmpty)
        XCTAssertEqual(plan.droppedForShadowing.first?.actions, ["Quit", "Close Window"])
    }

    /// No ⌘, ⌥ or ⌃: every matcher refuses it, so importing it would look set and never fire.
    func testPlanRefusesABindingWithNoPrimaryModifier() {
        var result = ImportResult()
        result.trigger = Hotkey(keyCode: 48, modifierRaw: 0)
        let plan = ShortcutImport.plan(from: result, activeChords: [])
        XCTAssertTrue(plan.toApply.isEmpty)
        XCTAssertEqual(plan.unparsed.count, 1)
    }

    func testPlanCarriesSkippedAndUnparsedThrough() {
        var result = ImportResult()
        result.skipped = ["cascade"]
        result.unparsed = ["holdShortcut (⌥⌃⌘)"]
        let plan = ShortcutImport.plan(from: result, activeChords: [])
        XCTAssertEqual(plan.skipped, ["cascade"])
        XCTAssertEqual(plan.unparsed, ["holdShortcut (⌥⌃⌘)"])
    }
}
