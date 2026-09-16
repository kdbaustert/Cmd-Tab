import CoreGraphics
import XCTest

@testable import CmdTab

/// `SystemShortcuts` decodes two macOS preference domains without ever touching them — every test
/// here hands a fabricated dictionary to a pure function, the same shape `defaults read` would
/// hand back, and checks what comes out. `ShortcutAudit` is the only thing that actually reads the
/// real plist.
final class SystemShortcutsTests: XCTestCase {

    // MARK: - AppleSymbolicHotKeys

    private func hotkeyPlistEntry(
        enabled: Any, ascii: Int = 32, keyCode: Int, mods: Int, includeValue: Bool = true
    ) -> [String: Any] {
        guard includeValue else { return ["enabled": enabled] }
        return [
            "enabled": enabled,
            "value": ["parameters": [ascii, keyCode, mods], "type": "standard"],
        ]
    }

    func testEnabledEntryDecodes() {
        let raw = ["64": hotkeyPlistEntry(enabled: 1, keyCode: 49, mods: 1_048_576)]
        let decoded = SystemShortcuts.decodeSymbolicHotKeys(raw)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.id, 64)
        XCTAssertEqual(decoded.first?.keyCode, 49)
        XCTAssertEqual(decoded.first?.modifiers, .maskCommand)
    }

    /// `enabled == 0` is not a conflict, whether or not `value` is present — both are dropped.
    func testDisabledEntryIsDropped() {
        let raw = ["64": hotkeyPlistEntry(enabled: 0, keyCode: 49, mods: 1_048_576)]
        XCTAssertTrue(SystemShortcuts.decodeSymbolicHotKeys(raw).isEmpty)
    }

    func testDisabledEntryWithNoValueIsDropped() {
        let raw = ["15": hotkeyPlistEntry(enabled: 0, keyCode: 0, mods: 0, includeValue: false)]
        XCTAssertTrue(SystemShortcuts.decodeSymbolicHotKeys(raw).isEmpty)
    }

    /// `enabled` can come back as either an `Int` or a `Bool` depending on how the plist was
    /// written — both mean the same thing.
    func testEnabledAsBoolDecodes() {
        let raw = ["64": hotkeyPlistEntry(enabled: true, keyCode: 49, mods: 1_048_576)]
        XCTAssertEqual(SystemShortcuts.decodeSymbolicHotKeys(raw).count, 1)
    }

    func testMissingValueOnAnEnabledEntryIsDropped() {
        let raw = ["64": ["enabled": 1]]
        XCTAssertTrue(SystemShortcuts.decodeSymbolicHotKeys(raw).isEmpty)
    }

    func testMalformedParametersAreDropped() {
        let raw: [String: Any] = [
            "64": ["enabled": 1, "value": ["parameters": [32, 49], "type": "standard"]]
        ]
        XCTAssertTrue(SystemShortcuts.decodeSymbolicHotKeys(raw).isEmpty)
    }

    func testNonNumericKeyIsDropped() {
        let raw = ["not-an-id": hotkeyPlistEntry(enabled: 1, keyCode: 49, mods: 1_048_576)]
        XCTAssertTrue(SystemShortcuts.decodeSymbolicHotKeys(raw).isEmpty)
    }

    /// Every modifier bit, and the measured combinations from the spec — ⇧⌘ and ⇧⌃⌘ — decode to
    /// the matching `CGEventFlags`.
    func testEachModifierBitDecodesIndividually() {
        XCTAssertEqual(SystemShortcuts.cgEventFlags(fromNX: 131_072), .maskShift)
        XCTAssertEqual(SystemShortcuts.cgEventFlags(fromNX: 262_144), .maskControl)
        XCTAssertEqual(SystemShortcuts.cgEventFlags(fromNX: 524_288), .maskAlternate)
        XCTAssertEqual(SystemShortcuts.cgEventFlags(fromNX: 1_048_576), .maskCommand)
    }

    func testMeasuredModifierCombinationsDecode() {
        XCTAssertEqual(
            SystemShortcuts.cgEventFlags(fromNX: 1_179_648), [.maskShift, .maskCommand])
        XCTAssertEqual(
            SystemShortcuts.cgEventFlags(fromNX: 1_441_792),
            [.maskShift, .maskControl, .maskCommand])
        XCTAssertEqual(
            SystemShortcuts.cgEventFlags(fromNX: 786_432), [.maskControl, .maskAlternate])
    }

    /// The bit-for-bit correspondence the spec calls for asserting rather than assuming: each NX
    /// bit and its `CGEventFlags` counterpart agree on every other bit being clear.
    func testNXBitsMapOntoDistinctCGEventFlagsBits() {
        let shift = SystemShortcuts.cgEventFlags(fromNX: 131_072)
        let control = SystemShortcuts.cgEventFlags(fromNX: 262_144)
        let option = SystemShortcuts.cgEventFlags(fromNX: 524_288)
        let command = SystemShortcuts.cgEventFlags(fromNX: 1_048_576)
        XCTAssertEqual(shift, .maskShift)
        XCTAssertEqual(control, .maskControl)
        XCTAssertEqual(option, .maskAlternate)
        XCTAssertEqual(command, .maskCommand)
        XCTAssertTrue(shift.intersection(control).isEmpty)
        XCTAssertTrue(shift.intersection(option).isEmpty)
        XCTAssertTrue(shift.intersection(command).isEmpty)
    }

    // MARK: - id -> name

    func testKnownIDsResolveToAppleSName() {
        XCTAssertEqual(SystemShortcuts.name(forID: 64), "Spotlight search")
        XCTAssertEqual(SystemShortcuts.name(forID: 32), "Mission Control")
    }

    func testUnknownIDFallsBackToAGenericLabel() {
        XCTAssertEqual(SystemShortcuts.name(forID: 999_999), "Unknown macOS shortcut (id 999999)")
    }

    // MARK: - NSUserKeyEquivalents

    func testUserKeyEquivalentDecodesAllFourSigils() {
        let raw = ["Minimize": "@~^$m"]
        let decoded = SystemShortcuts.decodeUserKeyEquivalents(raw)
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded.first?.label, "Minimize")
        XCTAssertEqual(decoded.first?.keyCode, 46)
        XCTAssertEqual(
            decoded.first?.modifiers, [.maskCommand, .maskAlternate, .maskControl, .maskShift])
    }

    func testUserKeyEquivalentWithNoSigilsIsBareKey() {
        let decoded = SystemShortcuts.decodeUserKeyEquivalents(["Save": "s"])
        XCTAssertEqual(decoded.first?.modifiers, [])
        XCTAssertEqual(decoded.first?.keyCode, 1)
    }

    /// A digit, going through the same sigil-and-character path as a letter.
    func testUserKeyEquivalentWithADigit() {
        let decoded = SystemShortcuts.decodeUserKeyEquivalents(["Tab 3": "@3"])
        XCTAssertEqual(decoded.first?.keyCode, 20)
        XCTAssertEqual(decoded.first?.modifiers, .maskCommand)
    }

    /// A character outside the standard ANSI table is dropped rather than guessed at.
    func testUserKeyEquivalentWithAnUnmappableCharacterIsDropped() {
        XCTAssertTrue(SystemShortcuts.decodeUserKeyEquivalents(["Odd": "@§"]).isEmpty)
    }

    func testEmptySpellingIsDropped() {
        XCTAssertTrue(SystemShortcuts.decodeUserKeyEquivalents(["Nothing": ""]).isEmpty)
    }
}
