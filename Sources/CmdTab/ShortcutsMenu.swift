import AppKit

// The menu bar's "Shortcuts" submenu — a live answer to "what did I bind, and to what", built from
// the same flattened list the Overview audits rather than a second walk of the five stores.
//
// It only ever *shows* a chord, never claims one: `keyEquivalent` on a status-item's menu item would
// ask AppKit to intercept that combination system-wide for as long as the menu exists, which is the
// one thing this feature must not do to bindings the event tap already owns. The chord is rendered
// as text in the item's title instead — see `AppDelegate.shortcutTitle`.
//
// What a row is allowed to *do* when clicked follows the same line `URLCommand` already draws: a
// tiling arrangement, a direct activation and hide/show-all rearrange windows, which is recoverable
// and visible, so those rows perform the action. An in-switcher window action and a mouse gesture
// either can quit or close something, or have no discrete action to perform outside the panel, so
// those rows are listed — chord and all — but disabled.

/// One row the submenu can show, and whether clicking it is safe to wire up.
struct ShortcutMenuRow {
    let label: String
    let display: String
    let command: URLCommand?

    /// A row performs its action only when a `URLCommand` exists for it — which is already the set
    /// `URLCommand` itself refuses to grow past. See the file header.
    var canPerform: Bool { command != nil }
}

/// One kind's section of the submenu.
struct ShortcutMenuGroup {
    let kind: ShortcutEntry.Kind
    let rows: [ShortcutMenuRow]
}

enum ShortcutsMenuModel {
    /// Builds the submenu's sections from every binding, in `ShortcutAudit.entries()`'s own order.
    ///
    /// An unbound entry is dropped rather than shown disabled — this menu answers "what is bound",
    /// not "what could be", which is the Overview's job. A kind with nothing bound in it drops the
    /// whole section rather than leaving an empty header behind.
    nonisolated static func groups(from entries: [ShortcutEntry]) -> [ShortcutMenuGroup] {
        var rowsByKind: [ShortcutEntry.Kind: [ShortcutMenuRow]] = [:]
        for entry in entries {
            // System-owned chords are what the Overview audits *against*, not a Cmd-Tab
            // binding to remind anyone of — this menu is "what have I bound", not "what is
            // macOS holding". They still feed collisions()/the conflict row above.
            guard entry.chord != nil, entry.kind != .systemOwned else { continue }
            rowsByKind[entry.kind, default: []].append(
                ShortcutMenuRow(
                    label: entry.label, display: entry.display, command: command(for: entry)))
        }
        return ShortcutEntry.Kind.allCases.compactMap { kind in
            guard let rows = rowsByKind[kind], !rows.isEmpty else { return nil }
            return ShortcutMenuGroup(kind: kind, rows: rows)
        }
    }

    /// The `URLCommand` a bound entry performs, recovered from the id `ShortcutAudit.entries()`
    /// already builds it from — `tiling.<arrangement rawValue>`, `activate.<bundle id>`, `hideAll`
    /// and `showAll` are the same spellings `URLCommand.parse` reads out of a `cmdtab://` URL, so
    /// this is the one other place allowed to know them.
    nonisolated static func command(for entry: ShortcutEntry) -> URLCommand? {
        switch entry.kind {
        case .tiling:
            guard let raw = argument(after: "tiling.", in: entry.id),
                let arrangement = WindowArrangement(rawValue: raw)
            else { return nil }
            return .arrangement(arrangement)
        case .directActivation:
            guard let bundleID = argument(after: "activate.", in: entry.id) else { return nil }
            return .activate(bundleID: bundleID)
        case .allWindows:
            if entry.id == "hideAll" { return .allWindows(.hide) }
            if entry.id == "showAll" { return .allWindows(.show) }
            return nil
        case .systemOwned, .switcherTrigger, .appWindowCycle, .scopedTrigger, .inSwitcherAction,
            .mouseGesture:
            return nil
        }
    }

    private nonisolated static func argument(after prefix: String, in id: String) -> String? {
        guard id.hasPrefix(prefix) else { return nil }
        return String(id.dropFirst(prefix.count))
    }
}
