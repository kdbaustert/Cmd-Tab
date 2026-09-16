import CoreGraphics

// Decodes the two preference domains macOS keeps its own global shortcuts in, so `ShortcutAudit`
// can warn when a Cmd-Tab binding collides with something the system already claims — see the
// spec this was measured against (a `defaults read` of `com.apple.symbolichotkeys` and of
// `NSUserKeyEquivalents`, cross-checked against real entries on the machine it was written on).
//
// Both `decode` functions are pure over a dictionary already read out of preferences, which is
// what makes them testable without touching the real plist — `ShortcutAudit` is the only caller
// that actually reaches `CFPreferencesCopyAppValue`.

enum SystemShortcuts {
    /// NX modifier bits `AppleSymbolicHotKeys` packs into `parameters[2]` — measured against live
    /// entries, not guessed. `SystemShortcutsTests` asserts these line up bit-for-bit with
    /// `CGEventFlags`' own mask rather than assuming it, because the two encodings only happen to
    /// agree on the four bits this app compares.
    private static let shiftBit = 131_072
    private static let controlBit = 262_144
    private static let optionBit = 524_288
    private static let commandBit = 1_048_576

    struct SystemHotkey {
        let id: Int
        let keyCode: Int
        let modifiers: CGEventFlags
    }

    /// Decodes `AppleSymbolicHotKeys`'s `{enabled, value: {parameters}}` shape.
    ///
    /// `enabled == 0` is not a conflict — it means macOS is not claiming that chord right now,
    /// whether or not a `value` is still sitting in the plist — so those ids are dropped here
    /// rather than surfaced disabled. An id with no `value`, a `value` missing `parameters`, or
    /// fewer than three parameters is dropped the same way: there is nothing to compare a chord
    /// against. An id absent from the dictionary entirely is *not* represented in the output —
    /// that is a real gap (its OS default may still be enabled) that this function cannot close,
    /// because the default isn't in the plist to read.
    static func decodeSymbolicHotKeys(_ raw: [String: Any]) -> [SystemHotkey] {
        var out: [SystemHotkey] = []
        for (key, value) in raw {
            guard let id = Int(key), let entry = value as? [String: Any] else { continue }
            guard isEnabled(entry["enabled"]) else { continue }
            guard let payload = entry["value"] as? [String: Any],
                let parameters = payload["parameters"] as? [Int], parameters.count >= 3
            else { continue }
            out.append(
                SystemHotkey(
                    id: id, keyCode: parameters[1], modifiers: cgEventFlags(fromNX: parameters[2])))
        }
        return out.sorted { $0.id < $1.id }
    }

    private static func isEnabled(_ raw: Any?) -> Bool {
        (raw as? Int) == 1 || (raw as? Bool) == true
    }

    /// The NX mask -> `CGEventFlags` translation the four bits above exist for.
    static func cgEventFlags(fromNX mask: Int) -> CGEventFlags {
        var flags: CGEventFlags = []
        if mask & shiftBit != 0 { flags.insert(.maskShift) }
        if mask & controlBit != 0 { flags.insert(.maskControl) }
        if mask & optionBit != 0 { flags.insert(.maskAlternate) }
        if mask & commandBit != 0 { flags.insert(.maskCommand) }
        return flags
    }

    /// Apple's own labels, for the ids measured on the machine this was written on plus the wider
    /// set documented in System Settings' Keyboard Shortcuts pane. An id outside both surfaces as
    /// "Unknown macOS shortcut (id N)" rather than being dropped — an unnamed conflict is still
    /// worth warning about.
    static func name(forID id: Int) -> String {
        knownNames[id] ?? "Unknown macOS shortcut (id \(id))"
    }

    private static let knownNames: [Int: String] = [
        27: "Show Dashboard",
        28: "Save screenshot of screen to file",
        29: "Copy screenshot of screen to clipboard",
        30: "Save screenshot of selection to file",
        31: "Copy screenshot of selection to clipboard",
        32: "Mission Control",
        33: "Mission Control",
        34: "Application windows",
        35: "Application windows",
        36: "Show Desktop",
        37: "Show Desktop",
        52: "Turn Dock Hiding On/Off",
        60: "Select next input source",
        61: "Select previous input source",
        64: "Spotlight search",
        65: "Finder search window",
        79: "Move left a space",
        80: "Move right a space",
        81: "Switch to Desktop",
        82: "Switch to Desktop",
        160: "Launchpad",
        163: "Notification Center",
        184: "Screenshot and recording options",
    ]

    // MARK: - NSUserKeyEquivalents (App Shortcuts)

    struct AppShortcut {
        let label: String
        let keyCode: Int
        let modifiers: CGEventFlags
    }

    /// Decodes `NSUserKeyEquivalents`'s `"Menu Title" = "sigils+char"` entries. Sigils, in the
    /// order Apple emits them but read here in any order: `@` = ⌘, `~` = ⌥, `^` = ⌃, `$` = ⇧. A
    /// trailing character with no entry in `ansiKeyCodes` — anything past the standard ANSI
    /// letters and digits — is dropped rather than guessed at, since this app has no keyboard-
    /// layout lookup to turn an arbitrary character into a virtual keycode.
    static func decodeUserKeyEquivalents(_ raw: [String: String]) -> [AppShortcut] {
        var out: [AppShortcut] = []
        for (label, spelling) in raw {
            guard let last = spelling.last else { continue }
            var modifiers: CGEventFlags = []
            for sigil in spelling.dropLast() {
                switch sigil {
                case "@": modifiers.insert(.maskCommand)
                case "~": modifiers.insert(.maskAlternate)
                case "^": modifiers.insert(.maskControl)
                case "$": modifiers.insert(.maskShift)
                default: break
                }
            }
            // Apple's own doc calls the alternative spelling — a bare capital with no `$` — an
            // ambiguous case, so the sigil is trusted and the character is always looked up
            // lower-cased rather than treating a capital as a second, redundant Shift signal.
            guard let keyCode = ansiKeyCodes[Character(last.lowercased())] else { continue }
            out.append(AppShortcut(label: label, keyCode: keyCode, modifiers: modifiers))
        }
        return out.sorted { $0.label < $1.label }
    }

    /// The standard US ANSI virtual keycodes (`kVK_ANSI_*` in Carbon's `HIToolbox`) — the one
    /// place this app turns a *character* into a keycode, because `NSUserKeyEquivalents` spells a
    /// shortcut as a string rather than handing over a keycode the way `CGEvent` does everywhere
    /// else in the app.
    private static let ansiKeyCodes: [Character: Int] = [
        "a": 0, "b": 11, "c": 8, "d": 2, "e": 14, "f": 3, "g": 5, "h": 4, "i": 34, "j": 38,
        "k": 40, "l": 37, "m": 46, "n": 45, "o": 31, "p": 35, "q": 12, "r": 15, "s": 1, "t": 17,
        "u": 32, "v": 9, "w": 13, "x": 7, "y": 16, "z": 6,
        "0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25,
    ]
}
