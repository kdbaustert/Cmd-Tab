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

    /// AltTab splits its trigger in two: `holdShortcut` is the modifier held for the session ("⌥"
    /// by default) and `nextWindowShortcut` the key pressed under it ("⇥"). A hold string with no
    /// key of its own is therefore joined to that key, where it used to be reported as unreadable —
    /// which, if AltTab's defaults are what its UI shows, meant a stock AltTab setup could never
    /// import its trigger. Like the rest of this reader, not confirmed against a live install. A
    /// hold string that does carry a key is read on its own, as it always was.
    ///
    /// - Parameter plist: a domain dump shaped like `defaults read com.lwouis.alt-tab-macos`. Each
    ///   shortcut key holds a dictionary carrying a human-readable string field (e.g. `"⌥⇥"`)
    ///   alongside an `NSKeyedArchiver` blob this importer does not decode — see the file header.
    static func altTabBindings(from plist: [String: Any]) -> ImportResult {
        var result = ImportResult()
        var usedNextWindow = false

        if let value = plist["holdShortcut"] {
            if let glyphs = readableString(from: value) {
                if let hotkey = parseGlyphChord(glyphs) {
                    result.trigger = hotkey
                } else if let hold = parseModifiers(glyphs), !hold.isEmpty,
                    let nextValue = plist["nextWindowShortcut"],
                    let nextGlyphs = readableString(from: nextValue),
                    let next = parseGlyphChord(nextGlyphs)
                {
                    result.trigger = Hotkey(
                        keyCode: next.keyCode,
                        modifierRaw: Hotkey.flags(from: hold).rawValue | next.modifierRaw)
                    usedNextWindow = true
                } else {
                    result.unparsed.append("holdShortcut (\(glyphs))")
                }
            } else {
                result.unparsed.append("holdShortcut")
            }
        }

        // Already covered by Cmd-Tab's own model — worth naming rather than importing silently
        // nowhere. The next-window key is the exception once it has become the trigger's key.
        for name in ["nextWindowShortcut", "previousWindowShortcut"]
        where plist[name] != nil && !(name == "nextWindowShortcut" && usedNextWindow) {
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
            guard let modifier = modifierGlyphs[first] else {
                let keyGlyph = String(arrowAliases[first] ?? first)
                guard rest.dropFirst().isEmpty, let code = glyphToKeyCode[keyGlyph] else { return nil }
                let cgFlags = Hotkey.flags(from: flags)
                return Hotkey(keyCode: code, modifierRaw: cgFlags.rawValue)
            }
            flags.insert(modifier)
            rest = rest.dropFirst()
        }
        return nil  // modifiers only, no key glyph at all
    }

    /// A string of modifier glyphs and nothing else, or nil if anything in it is not one.
    private static func parseModifiers(_ string: String) -> NSEvent.ModifierFlags? {
        var flags: NSEvent.ModifierFlags = []
        for glyph in string {
            guard let modifier = modifierGlyphs[glyph] else { return nil }
            flags.insert(modifier)
        }
        return flags
    }

    /// ⌘ ⌥ ⌃ ⇧, shared by both parsers above so they cannot disagree about what a modifier is.
    private static let modifierGlyphs: [Character: NSEvent.ModifierFlags] = [
        "\u{2318}": .command, "\u{2325}": .option, "\u{2303}": .control, "\u{21E7}": .shift,
    ]

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
    /// with a fabricated set standing in for "here is what Cmd-Tab already has bound". `current`
    /// and `shadows` are snapshots in the same way, and default to "nothing" for the same reason.
    struct Plan {
        var toApply: [ProposedChange] = []
        var droppedForCollision: [ProposedChange] = []
        /// A trigger that would hold a modifier window actions are built on — see `plan`.
        var droppedForShadowing: [(change: ProposedChange, actions: [String])] = []
        /// Already bound to exactly this chord. Neither applied nor a collision.
        var alreadySet: [ProposedChange] = []
        var skipped: [String] = []
        var unparsed: [String] = []
    }

    /// - Parameters:
    ///   - current: each target's present chord, keyed by `ProposedChange.id` — which spells
    ///     targets the way `ShortcutAudit.entries()` spells its ids. A chord a target already has
    ///     is claimed *by that target*, and reporting it as "bound to something else" named a
    ///     collision with itself.
    ///   - shadows: the window actions a trigger would silence — `actionsShadowed(by:)`, as the
    ///     trigger recorder asks it. Importing a trigger skipped that question, so AltTab's ⌥⇥ came
    ///     in and every ⌥ action typed into the filter instead of running, with no alert — the
    ///     exact failure the recorder's alert exists to prevent. Refused here rather than rebound:
    ///     the recorder asks before moving the actions, and this has no one to ask mid-plan.
    nonisolated static func plan(
        from result: ImportResult, activeChords: Set<ShortcutEntry.Chord>,
        current: [String: ShortcutEntry.Chord] = [:],
        shadows: (Hotkey) -> [String] = { _ in [] }
    ) -> Plan {
        var plan = Plan()
        plan.skipped = result.skipped
        plan.unparsed = result.unparsed
        // What this import has already accepted, so two imported bindings on one chord — or an
        // arrangement on the imported trigger — are caught as surely as a clash with something
        // already bound. Each entry remembers whether it ignores Shift, which is the rule
        // `ShortcutAudit.collisions` compares by: an opener claims every Shift variant, an exact
        // binding only its own.
        var accepted: [(chord: ShortcutEntry.Chord, ignoresShift: Bool)] = []

        func consider(_ change: ProposedChange) {
            // A chord with no ⌘, ⌥ or ⌃ is refused by every matcher; importing one would look set
            // and never fire.
            guard change.hotkey.isUsableGlobally else {
                plan.unparsed.append(
                    "\(change.label) (\(change.hotkey.displayString) has no ⌘, ⌥ or ⌃)")
                return
            }
            let chord = ShortcutEntry.Chord(
                keyCode: change.hotkey.keyCode, modifiers: change.hotkey.modifiers)
            let ignoresShift: Bool
            if case .trigger = change.target { ignoresShift = true } else { ignoresShift = false }
            func same(_ a: ShortcutEntry.Chord, _ b: ShortcutEntry.Chord, blind: Bool) -> Bool {
                blind ? a.ignoringShift == b.ignoringShift : a == b
            }
            if let existing = current[change.id], same(existing, chord, blind: ignoresShift) {
                plan.alreadySet.append(change)
                return
            }
            let clashesWithImport = accepted.contains { other in
                same(other.chord, chord, blind: other.ignoresShift || ignoresShift)
            }
            if activeChords.contains(chord.ignoringShift) || clashesWithImport {
                plan.droppedForCollision.append(change)
                return
            }
            if case .trigger = change.target {
                let silenced = shadows(change.hotkey)
                guard silenced.isEmpty else {
                    plan.droppedForShadowing.append((change, silenced))
                    return
                }
            }
            accepted.append((chord, ignoresShift))
            plan.toApply.append(change)
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

        let entries = ShortcutAudit.entries()
        let activeChords = Set(entries.filter(\.isActive).compactMap { $0.chord?.ignoringShift })
        let current = Dictionary(
            entries.compactMap { entry in entry.chord.map { (entry.id, $0) } },
            uniquingKeysWith: { first, _ in first })
        // Asked up front for the one trigger this import can propose — `plan` is pure and cannot
        // reach the store — and asked the way `HotkeyRecorder.apply` asks it.
        let actions = SwitcherShortcutsStore.shared
        let silenced = merged.trigger.map { trigger in
            actions.isEnabled ? actions.shortcuts.actionsShadowed(by: trigger).map(\.title) : []
        } ?? []
        let plan = plan(
            from: merged, activeChords: activeChords, current: current,
            shadows: { _ in silenced })

        guard !plan.toApply.isEmpty || !plan.droppedForCollision.isEmpty
            || !plan.droppedForShadowing.isEmpty || !plan.alreadySet.isEmpty
            || !plan.skipped.isEmpty || !plan.unparsed.isEmpty
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
        if !plan.droppedForShadowing.isEmpty {
            sections.append(
                "Not imported — would stop window actions from working (change it in Settings → "
                    + "Shortcuts, which offers to move them):\n"
                    + plan.droppedForShadowing.map {
                        "• \($0.change.label) — \($0.change.hotkey.displayString) "
                            + "(\($0.actions.joined(separator: ", ")))"
                    }.joined(separator: "\n"))
        }
        if !plan.alreadySet.isEmpty {
            sections.append(
                "Already set:\n"
                    + plan.alreadySet.map { "• \($0.label) — \($0.hotkey.displayString)" }
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
