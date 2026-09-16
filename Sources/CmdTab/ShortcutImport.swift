import AppKit
import CoreGraphics
import Foundation

// Importing hotkeys from other window managers/switchers, rather than asking someone to re-record
// every chord they already tuned elsewhere.
//
// Two sources are supported, and each is shaped by what its own app actually persists — this is
// not one importer with two adapters bolted on, because the two storage formats have nothing in
// common:
//
// * Rectangle/Rectangle Pro (`com.knollsoft.Rectangle`/`com.knollsoft.Hookshot`) write one
//   `{keyCode, modifierFlags, type}` dictionary per action, with `modifierFlags` in
//   `NSEvent.ModifierFlags`' own raw bits — MASShortcut's persistence format, confirmed live
//   against an installed Rectangle Pro. `type` is not read; every observed value was in a plist
//   dict shaped for `MASShortcutView`, and Rectangle keeps `type` only for its own migration
//   history.
// * AltTab (`com.lwouis.alt-tab-macos`) archives its shortcuts through `ShortcutRecorder`'s
//   `NSKeyedArchiver` blob, which this app has no reason to link a third-party framework to
//   decode. AltTab also writes a human-readable string (e.g. "⌥⇥") alongside that blob for its own
//   UI, and that string is all this importer reads — reliable for the modifiers, best-effort for
//   the key glyph, and anything it cannot recognise is reported as unparsed rather than guessed at.
//
// A third candidate, Command-Tab Plus 2, is left out entirely: it is not installed anywhere this
// was measured, its preferences format could not be found on its marketing site or in any public
// source, and guessing at plist keys for an app nobody could inspect is exactly the kind of
// invented API this codebase's own conventions warn against.
//
// Parsing is pure and takes a `[String: Any]` plist dictionary — the shape `CFPreferencesCopyMultiple`
// hands back — so every case here is testable from a fabricated dictionary, with neither app
// installed.

/// What one source's hotkeys turned into, plus what did not make the trip.
struct ImportResult {
    /// Tiling chords, keyed by the Cmd-Tab action they map to.
    var arrangements: [WindowArrangement: Hotkey] = [:]
    /// The source's own "open/hold the switcher" chord, if it has one.
    var trigger: Hotkey?
    /// Source actions that exist but have no Cmd-Tab counterpart — named as the source spells them,
    /// so someone who knows their own Rectangle/AltTab setup can recognise the entry.
    var skipped: [String] = []
    /// Bindings this importer could not make sense of: an unexpected value shape, or (for AltTab) a
    /// glyph string it does not know how to read.
    var unparsed: [String] = []
}

@MainActor
enum ShortcutImport {

    // MARK: - Sources

    enum Source: String, CaseIterable {
        case rectangle = "com.knollsoft.Rectangle"
        case rectanglePro = "com.knollsoft.Hookshot"
        case altTab = "com.lwouis.alt-tab-macos"

        var title: String {
            switch self {
            case .rectangle: return "Rectangle"
            case .rectanglePro: return "Rectangle Pro"
            case .altTab: return "AltTab"
            }
        }
    }

    /// Every supported app whose preferences domain actually has something in it on this Mac.
    static func availableSources() -> [Source] {
        Source.allCases.filter { !readPreferences(domain: $0.rawValue).isEmpty }
    }

    /// The one place this reaches into another app's preferences — read-only, and only from the
    /// domains listed above. Never called with Cmd-Tab's own domain.
    static func readPreferences(domain: String) -> [String: Any] {
        (CFPreferencesCopyMultiple(nil, domain as CFString, kCFPreferencesCurrentUser, kCFPreferencesAnyHost)
            as? [String: Any]) ?? [:]
    }

    static func result(for source: Source) -> ImportResult {
        let plist = readPreferences(domain: source.rawValue)
        switch source {
        case .rectangle, .rectanglePro: return rectangleBindings(from: plist)
        case .altTab: return altTabBindings(from: plist)
        }
    }

    // MARK: - Rectangle / Rectangle Pro

    /// Rectangle action name -> Cmd-Tab arrangement, for the names that mean the same thing. See
    /// the file header: confirmed against `rxhanson/Rectangle`'s `WindowAction.swift`, plus the
    /// Pro-only `nextSpace`/`prevSpace` pair, which is a best-effort name match rather than a
    /// confirmed one — Pro's own source is closed.
    private static let rectangleActionMap: [String: WindowArrangement] = [
        "leftHalf": .leftHalf, "rightHalf": .rightHalf, "topHalf": .topHalf, "bottomHalf": .bottomHalf,
        "topLeft": .topLeft, "topRight": .topRight, "bottomLeft": .bottomLeft, "bottomRight": .bottomRight,
        "maximize": .maximize, "maximizeHeight": .maximizeHeight, "maximizeWidth": .maximizeWidth,
        "almostMaximize": .almostMaximize, "center": .center, "restore": .restore,
        "larger": .larger, "smaller": .smaller,
        "moveLeft": .nudgeLeft, "moveRight": .nudgeRight, "moveUp": .nudgeUp, "moveDown": .nudgeDown,
        "firstThird": .leftThird, "centerThird": .centerThird, "lastThird": .rightThird,
        "firstTwoThirds": .leftTwoThirds, "lastTwoThirds": .rightTwoThirds,
        "previousDisplay": .previousDisplay, "nextDisplay": .nextDisplay,
        "nextSpace": .nextDesktop, "prevSpace": .previousDesktop,
    ]

    /// Rectangle/Pro actions with no Cmd-Tab model at all — listed by name so a bound one is
    /// reported as skipped rather than silently dropped. Not exhaustive of every Pro-only key (Pro's
    /// source is closed), only of the ones the spec's live plist and the OSS `WindowAction` enum
    /// named.
    private static let rectangleUnmappedActions: Set<String> = [
        "topLeftSixth", "topCenterSixth", "topRightSixth",
        "bottomLeftSixth", "bottomCenterSixth", "bottomRightSixth",
        "topLeftNinth", "topCenterNinth", "topRightNinth",
        "middleLeftNinth", "middleCenterNinth", "middleRightNinth",
        "bottomLeftNinth", "bottomCenterNinth", "bottomRightNinth",
        "firstFourth", "secondFourth", "thirdFourth", "lastFourth",
        "firstThreeFourths", "lastThreeFourths",
        "cascade", "cascadeAll", "reverseAll", "todo", "stash", "cycleStashed", "pin",
        "appLeftHalf", "appRightHalf", "appNextDisplay", "appPreviousDisplay",
    ]

    /// - Parameter plist: a domain dump shaped like `defaults read com.knollsoft.Hookshot` —
    ///   top-level keys, each an action name, each a `{keyCode, modifierFlags, type}` dictionary
    ///   (or `{}` when unbound).
    static func rectangleBindings(from plist: [String: Any]) -> ImportResult {
        var result = ImportResult()
        let names = Set(rectangleActionMap.keys).union(rectangleUnmappedActions)
        for name in names.sorted() {
            guard let raw = plist[name] else { continue }
            guard let dict = raw as? [String: Any] else {
                result.unparsed.append(name)
                continue
            }
            if dict.isEmpty { continue }  // unbound in Rectangle's own profile — nothing to import

            if rectangleUnmappedActions.contains(name) {
                result.skipped.append(name)
                continue
            }
            guard let arrangement = rectangleActionMap[name] else { continue }
            guard let hotkey = rectangleHotkey(from: dict) else {
                result.unparsed.append(name)
                continue
            }
            result.arrangements[arrangement] = hotkey
        }
        return result
    }

    /// `modifierFlags` is `NSEvent.ModifierFlags`' raw value, so it goes through
    /// `Hotkey.flags(from:)` rather than being reinterpreted as `CGEventFlags` bits directly — see
    /// the file header.
    private static func rectangleHotkey(from dict: [String: Any]) -> Hotkey? {
        guard let keyCode = (dict["keyCode"] as? NSNumber)?.intValue,
            let modifierFlags = (dict["modifierFlags"] as? NSNumber)?.intValue
        else { return nil }
        let nsFlags = NSEvent.ModifierFlags(rawValue: UInt(bitPattern: modifierFlags))
        let cgFlags = Hotkey.flags(from: nsFlags)
        return Hotkey(keyCode: keyCode, modifierRaw: cgFlags.rawValue)
    }

    // MARK: - AltTab

    /// AltTab preference keys with no Cmd-Tab counterpart at all — listed so a bound one is
    /// reported as skipped rather than dropped with no explanation.
    private static let altTabUnmappedShortcuts: Set<String> = [
        "closeWindowShortcut", "quitAppShortcut", "hideShowAppShortcut", "minDeminWindowShortcut",
        "toggleFullscreenWindowShortcut", "searchShortcut", "cancelShortcut",
    ]

    /// - Parameter plist: a domain dump shaped like `defaults read com.lwouis.alt-tab-macos`. Each
    ///   shortcut key holds a dictionary carrying a human-readable string field (e.g. `"⌥⇥"`)
    ///   alongside an `NSKeyedArchiver` blob this importer does not decode — see the file header.
    static func altTabBindings(from plist: [String: Any]) -> ImportResult {
        var result = ImportResult()

        if let value = plist["holdShortcut"] {
            if let glyphs = readableString(from: value) {
                if let hotkey = parseGlyphChord(glyphs) {
                    result.trigger = hotkey
                } else {
                    result.unparsed.append("holdShortcut (\(glyphs))")
                }
            } else {
                result.unparsed.append("holdShortcut")
            }
        }

        // Already covered by Cmd-Tab's own model — worth naming rather than importing silently
        // nowhere.
        for name in ["nextWindowShortcut", "previousWindowShortcut"] where plist[name] != nil {
            result.skipped.append(name)
        }
        for name in altTabUnmappedShortcuts.sorted() where plist[name] != nil {
            result.skipped.append(name)
        }
        return result
    }

    /// AltTab's `shortcutStorage` writes the readable string and the archived blob as sibling
    /// fields of one dictionary; the blob is `Data`, the readable field is the only `String` in it.
    /// The exact field name was not confirmed against a live install (AltTab is not installed on
    /// the machine this was built against — see the file header), so this reads structurally
    /// rather than by name: whichever `String` is sitting in the dictionary is the one wanted here.
    /// A bare string value is also accepted, in case a future/older AltTab writes one directly.
    private static func readableString(from value: Any) -> String? {
        if let string = value as? String { return string }
        guard let dict = value as? [String: Any] else { return nil }
        let strings = dict.values.compactMap { $0 as? String }
        return strings.count == 1 ? strings[0] : nil
    }

    /// Glyph -> key-code table, built from `Hotkey.keyName(for:)` rather than duplicated — that
    /// function is the one place this app already writes "this code means this glyph", and every
    /// entry read back out of it here is a code round-tripping through the app's own display logic
    /// rather than a second, driftable copy of it.
    private static let glyphToKeyCode: [String: Int] = Dictionary(
        (0...127).compactMap { code -> (String, Int)? in
            let name = Hotkey.keyName(for: code)
            return name.hasPrefix("Key ") ? nil : (name, code)
        },
        uniquingKeysWith: { first, _ in first })

    /// AltTab's `readableStringRepresentation` uses a couple of arrow glyphs Cmd-Tab's own table
    /// does not — normalised to the ones `Hotkey.keyName` produces before lookup.
    private static let arrowAliases: [Character: Character] = [
        "\u{2190}": "\u{2190}", "\u{2192}": "\u{2192}", "\u{2191}": "\u{2191}", "\u{2193}": "\u{2193}",
        "\u{21E0}": "\u{2190}", "\u{21E2}": "\u{2192}", "\u{21E1}": "\u{2191}", "\u{21E3}": "\u{2193}",
    ]

    /// Parses a chord like `"⌥⇥"` or `"⌘⇧A"`: every leading modifier glyph, then exactly one key
    /// glyph. Anything left over, or a string with no recognisable key glyph, is nil — the caller
    /// reports that as unparsed rather than guessing.
    private static func parseGlyphChord(_ string: String) -> Hotkey? {
        var flags: NSEvent.ModifierFlags = []
        var rest = Substring(string)
        while let first = rest.first {
            switch first {
            case "\u{2318}": flags.insert(.command)
            case "\u{2325}": flags.insert(.option)
            case "\u{2303}": flags.insert(.control)
            case "\u{21E7}": flags.insert(.shift)
            default:
                let keyGlyph = String(arrowAliases[first] ?? first)
                guard rest.dropFirst().isEmpty, let code = glyphToKeyCode[keyGlyph] else { return nil }
                let cgFlags = Hotkey.flags(from: flags)
                return Hotkey(keyCode: code, modifierRaw: cgFlags.rawValue)
            }
            rest = rest.dropFirst()
        }
        return nil  // modifiers only, no key glyph at all
    }

    // MARK: - Applying

    /// One chord this importer would write, plus enough to explain it in the review sheet.
    struct ProposedChange: Identifiable {
        enum Target { case trigger, arrangement(WindowArrangement) }
        let target: Target
        let hotkey: Hotkey
        var id: String {
            switch target {
            case .trigger: return "trigger"
            case .arrangement(let arrangement): return "tiling.\(arrangement.rawValue)"
            }
        }
        var label: String {
            switch target {
            case .trigger: return "Open the switcher"
            case .arrangement(let arrangement): return arrangement.title
            }
        }
    }

    /// What importing `result` would actually do, once it is checked against every chord already
    /// claimed in this app.
    ///
    /// Pure and MainActor-free but for the type it lives on — `activeChords` is a plain snapshot
    /// (`ShortcutAudit.entries()`'s chords, shift-blinded), not a live store, so this is testable
    /// with a fabricated set standing in for "here is what Cmd-Tab already has bound".
    struct Plan {
        var toApply: [ProposedChange] = []
        var droppedForCollision: [ProposedChange] = []
        var skipped: [String] = []
        var unparsed: [String] = []
    }

    nonisolated static func plan(
        from result: ImportResult, activeChords: Set<ShortcutEntry.Chord>
    ) -> Plan {
        var plan = Plan()
        plan.skipped = result.skipped
        plan.unparsed = result.unparsed

        func consider(_ change: ProposedChange) {
            let chord = ShortcutEntry.Chord(keyCode: change.hotkey.keyCode, modifiers: change.hotkey.modifiers)
            if activeChords.contains(chord.ignoringShift) {
                plan.droppedForCollision.append(change)
            } else {
                plan.toApply.append(change)
            }
        }

        if let trigger = result.trigger {
            consider(ProposedChange(target: .trigger, hotkey: trigger))
        }
        for arrangement in WindowArrangement.allCases {
            guard let hotkey = result.arrangements[arrangement] else { continue }
            consider(ProposedChange(target: .arrangement(arrangement), hotkey: hotkey))
        }
        return plan
    }

    /// Writes every change in `plan.toApply` through the stores that already own persistence,
    /// config-file mirroring and the shortcut audit — this never touches `UserDefaults` directly.
    static func apply(_ plan: Plan, behavior: BehaviorStore, tiling: WindowTilingStore) {
        for change in plan.toApply {
            switch change.target {
            case .trigger: behavior.hotkey = change.hotkey
            case .arrangement(let arrangement): tiling.set(change.hotkey, for: arrangement)
            }
        }
    }

    // MARK: - UI

    /// Reads every available source, builds one merged plan against the app's current bindings, and
    /// asks before writing anything. Cancelling — including "nothing to import" — changes nothing.
    static func presentImport() {
        let sources = availableSources()
        guard !sources.isEmpty else {
            let alert = NSAlert()
            alert.messageText = "Nothing to import"
            alert.informativeText =
                "Rectangle, Rectangle Pro and AltTab preferences were not found on this Mac."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        // Later sources win a same-target conflict between two *source* apps — there is no
        // principled tie-break between someone's Rectangle and AltTab setups, so this just needs to
        // be deterministic. `Source.allCases`' own order decides it.
        var merged = ImportResult()
        for source in sources {
            let result = result(for: source)
            merged.arrangements.merge(result.arrangements) { _, new in new }
            if let trigger = result.trigger { merged.trigger = trigger }
            merged.skipped += result.skipped.map { "\($0) (\(source.title))" }
            merged.unparsed += result.unparsed.map { "\($0) (\(source.title))" }
        }

        let activeChords = Set(
            ShortcutAudit.entries().filter(\.isActive).compactMap { $0.chord?.ignoringShift })
        let plan = plan(from: merged, activeChords: activeChords)

        guard !plan.toApply.isEmpty || !plan.droppedForCollision.isEmpty || !plan.skipped.isEmpty
            || !plan.unparsed.isEmpty
        else {
            let alert = NSAlert()
            alert.messageText = "Nothing to import"
            alert.informativeText =
                "\(sources.map(\.title).joined(separator: ", ")) had no shortcuts this app could read."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = "Import shortcuts from \(sources.map(\.title).joined(separator: ", "))?"
        alert.informativeText = summary(of: plan)
        let importButton = alert.addButton(withTitle: "Import")
        alert.addButton(withTitle: "Cancel")
        importButton.isEnabled = !plan.toApply.isEmpty
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        apply(plan, behavior: BehaviorStore.shared, tiling: WindowTilingStore.shared)
    }

    /// The plain-language body of the review alert — every section is left out when it is empty,
    /// so a clean import does not carry two headings of nothing under it.
    private static func summary(of plan: Plan) -> String {
        var sections: [String] = []
        if !plan.toApply.isEmpty {
            sections.append(
                "Will import:\n"
                    + plan.toApply.map { "• \($0.label) — \($0.hotkey.displayString)" }
                        .joined(separator: "\n"))
        }
        if !plan.droppedForCollision.isEmpty {
            sections.append(
                "Not imported — already bound in Cmd-Tab to something else:\n"
                    + plan.droppedForCollision.map { "• \($0.label) — \($0.hotkey.displayString)" }
                        .joined(separator: "\n"))
        }
        if !plan.skipped.isEmpty {
            sections.append(
                "Skipped — no matching Cmd-Tab setting:\n"
                    + plan.skipped.map { "• \($0)" }.joined(separator: "\n"))
        }
        if !plan.unparsed.isEmpty {
            sections.append(
                "Could not be read:\n" + plan.unparsed.map { "• \($0)" }.joined(separator: "\n"))
        }
        return sections.joined(separator: "\n\n")
    }
}
