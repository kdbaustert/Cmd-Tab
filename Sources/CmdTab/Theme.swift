import AppKit
import SwiftUI

/// A named bundle of *visual* settings — everything that changes how the switcher looks, and
/// nothing about how it behaves (hotkeys, mode, sort). That split is deliberate: a theme is safe
/// to share because importing one can never change what your keys do.
struct Theme: Codable, Identifiable, Equatable {
    var name: String
    var highlightHex: String
    var appearance: String
    var material: String
    var blurOverride: Bool
    var blurRadius: Double
    var showNumbers: Bool
    var tileCorner: Double
    var titleFontSize: Double
    /// Font family for tile titles and the caption. Empty = the system font.
    ///
    /// Carried alongside `titleFontSize` rather than left out: a theme that restores the size but
    /// not the family renders in a visibly different panel from the one that was saved, and
    /// `sameLook` could not see the difference either — so changing the font never flipped the
    /// picker to "Custom…" and it went on claiming the old theme was still current.
    var titleFontName: String
    var fade: Bool
    var iconSize: Double
    var iconSpacing: Double
    var titleSpacing: Double
    var builtIn: Bool = false

    var id: String { name }

    /// Two themes are "the same look" when every visual field matches — the name and the built-in
    /// flag are identity, not appearance, so they are excluded. Icon size is also excluded: it is a
    /// user-level preference that `apply` deliberately preserves across theme changes, so a theme
    /// still counts as current no matter what size the icons are set to.
    ///
    /// This answers "does the panel currently look like this theme", and nothing more. It is *not*
    /// an identity test: two themes are free to look identical, so anything that needs to know
    /// *which* theme is selected must go through `ThemeStore.currentMatch()`.
    func sameLook(as other: Theme) -> Bool {
        var a = self, b = other
        a.name = ""; b.name = ""
        a.builtIn = false; b.builtIn = false
        a.iconSize = 0; b.iconSize = 0
        return a == b
    }
}

extension Theme {
    /// The ranges of the Appearance sliders for the three numbers a decoded theme is clamped to —
    /// see `init(from:)`. Copies of the literals in `SettingsAppearance`, and must move with them.
    static let blurRadiusRange: ClosedRange<Double> = 0...50
    static let tileCornerRange: ClosedRange<Double> = 0...24
    static let titleFontSizeRange: ClosedRange<Double> = 8...16

    private enum CodingKeys: String, CodingKey {
        case name, highlightHex, appearance, material, blurOverride, blurRadius, showNumbers
        case tileCorner, titleFontSize, titleFontName, fade, iconSize, iconSpacing, titleSpacing
        case builtIn
    }

    /// Decodes tolerantly: every field falls back to the built-in default when it is absent.
    ///
    /// Deliberately in an extension, which is what preserves the memberwise initialiser the presets
    /// and `captureCurrent` use.
    ///
    /// A theme file is shared between machines and survives across app versions, so its shape is not
    /// under our control at read time. With the synthesized decoder a single missing key threw, and
    /// because every call site funnelled through `try?` the failure surfaced as Import doing nothing
    /// at all — which is exactly what removing the old `opacity` field did to files written by
    /// newer builds. Defaults here mean an added or dropped field costs that one value, not the
    /// whole theme.
    ///
    /// Nor are its *values* under our control, so the three numbers nothing downstream clamps are
    /// clamped here, to the ranges of the sliders that set them. A shared file carrying
    /// `"titleFontSize": 400` drew a 403pt caption that grew the panel off the screen; the icon and
    /// spacing sizes need no such treatment, because `Metrics.init` already clamps them. Clamped at
    /// decode rather than at `apply` so the stored theme matches what it draws — otherwise
    /// `sameLook` would compare the clamped panel against the unclamped file and never match.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // `try?` on a `T?`-returning call gives `T??`: the outer nil is a decode failure (wrong
        // type), the inner one an absent key. Both mean "use the default", so flatten and coalesce.
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
        }
        func number(_ key: CodingKeys, _ fallback: Double, in range: ClosedRange<Double>)
            -> Double
        {
            let raw = value(key, fallback)
            return raw.isNaN ? fallback : min(max(raw, range.lowerBound), range.upperBound)
        }
        name = value(.name, "")
        highlightHex = value(.highlightHex, BehaviorDefault.highlightHex)
        appearance = value(.appearance, PanelAppearance.system.rawValue)
        material = value(.material, PanelMaterial.hud.rawValue)
        blurOverride = value(.blurOverride, false)
        blurRadius = number(.blurRadius, 20, in: Self.blurRadiusRange)
        showNumbers = value(.showNumbers, true)
        tileCorner = number(.tileCorner, 12, in: Self.tileCornerRange)
        titleFontSize = number(.titleFontSize, 10, in: Self.titleFontSizeRange)
        titleFontName = value(.titleFontName, "")
        fade = value(.fade, false)
        iconSize = value(.iconSize, 64)
        iconSpacing = value(.iconSpacing, 18)
        titleSpacing = value(.titleSpacing, 2)
        builtIn = value(.builtIn, false)
    }
}

/// Decodes one theme, turning a failure into `nil` rather than taking the rest of the file with it.
///
/// `[Theme]` decodes all-or-nothing, and `ThemeStore.persist()` writes the in-memory array straight
/// back over the file — so one unreadable entry meant every *other* saved theme was silently
/// destroyed by the next save.
private struct SalvagedTheme: Decodable {
    let theme: Theme?

    init(from decoder: Decoder) throws {
        theme = try? Theme(from: decoder)
    }
}

/// Presets plus the user's saved themes. Applying one writes into `BehaviorStore` and
/// `AppearanceStore`; capturing reads back from them. Custom themes persist as JSON in Application
/// Support so they are independent of the live settings and portable between machines.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var custom: [Theme] = []

    /// The theme the user last explicitly chose, by name.
    ///
    /// Identity, which `sameLook` cannot stand in for: two themes are free to look identical — a
    /// custom saved from a preset and then barely touched, or two that differed only in a field the
    /// app no longer has — and a look-based scan then hands Rename, Delete and Export whichever one
    /// it reaches first. Published so the picker re-renders when the selection moves.
    @Published private(set) var selected: String?

    private let fileURL: URL
    /// Where an unreadable theme file is set aside, rather than being overwritten by the next save.
    private let backupURL: URL

    var all: [Theme] { Self.presets + custom }

    /// A theme by name, preferring the user's own.
    ///
    /// Custom first throughout: nothing stops `saveAs` naming a theme after a preset, and when the
    /// two collide the user's own is both the more useful answer and the only one that can actually
    /// be renamed or deleted.
    func theme(named name: String) -> Theme? {
        custom.first { $0.name == name } ?? Self.presets.first { $0.name == name }
    }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Cmd-Tab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("themes.json")
        backupURL = dir.appendingPathComponent("themes.json.bak")
        load()
    }

    // MARK: - Apply / capture

    /// Reads the current visual settings into an unnamed theme.
    func captureCurrent(name: String = "") -> Theme {
        let b = BehaviorStore.shared
        let a = AppearanceStore.shared
        return Theme(
            name: name,
            highlightHex: b.highlightColor.hexString ?? BehaviorStore.defaultHighlightHex,
            appearance: b.panelAppearance.rawValue,
            material: b.panelMaterial.rawValue,
            blurOverride: b.blurOverride,
            blurRadius: b.blurRadius,
            showNumbers: b.showNumbers,
            tileCorner: b.tileCorner,
            titleFontSize: b.titleFontSize,
            titleFontName: b.titleFontName,
            fade: b.fade,
            iconSize: a.iconSize,
            iconSpacing: a.iconSpacing,
            titleSpacing: a.titleSpacing)
    }

    /// Pushes a theme's fields into the live stores, which in turn update the running switcher.
    func apply(_ theme: Theme) {
        let b = BehaviorStore.shared
        // Coalesce the many field writes into a single onChange so the switcher reconfigures once
        // rather than dozens of times.
        b.batch {
            b.highlightColor = Color(hex: theme.highlightHex) ?? BehaviorStore.defaultHighlight
            b.panelAppearance = PanelAppearance(rawValue: theme.appearance) ?? .system
            b.panelMaterial = PanelMaterial(rawValue: theme.material) ?? .hud
            b.blurOverride = theme.blurOverride
            b.blurRadius = theme.blurRadius
            b.showNumbers = theme.showNumbers
            b.tileCorner = theme.tileCorner
            b.titleFontSize = theme.titleFontSize
            b.titleFontName = theme.titleFontName
            b.fade = theme.fade
        }

        let a = AppearanceStore.shared
        // Icon size is a user-level preference, not a theme trait: switching themes leaves whatever
        // size is currently assigned untouched (see `sameLook`, which also ignores it).
        a.iconSpacing = theme.iconSpacing
        a.titleSpacing = theme.titleSpacing

        // Applying *is* choosing. Recorded by name so the picker keeps pointing at this theme even
        // when another one looks exactly like it.
        selected = theme.name
    }

    /// The theme whose look matches the current settings, or nil when the user has tuned away from
    /// every saved one ("Custom").
    func currentMatch() -> Theme? {
        let current = captureCurrent()
        // An explicit choice wins for as long as it still describes the panel, so a theme that
        // shares its look with another stays selected rather than flipping to its twin. Tuning any
        // setting breaks `sameLook` and drops through to the scan below — which is what puts the
        // picker back on "Custom…".
        if let selected, let theme = theme(named: selected), theme.sameLook(as: current) {
            return theme
        }
        // Nothing chosen this session, or the user has tuned away from it: fall back to recognising
        // the look, the user's own themes first.
        return custom.first { $0.sameLook(as: current) }
            ?? Self.presets.first { $0.sameLook(as: current) }
    }

    // MARK: - Custom theme management

    /// Saves the current look under `name`, or under the nearest free name when that one is taken —
    /// see `uniqueName`. It used to replace a same-named custom theme instead, and the prompt always
    /// offers "My Theme", so a second save with the default quietly destroyed the first.
    func saveAs(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        let unique = uniqueName(trimmed)
        var theme = captureCurrent(name: unique)
        theme.builtIn = false
        custom.append(theme)
        selected = unique  // saving is choosing — the new theme is the one you are now on
        persist()
    }

    func delete(_ theme: Theme) {
        guard !theme.builtIn, let index = custom.firstIndex(where: { $0.name == theme.name })
        else { return }
        // One entry, not every one carrying the name: a file saved before names were kept unique
        // can still hold two, and the button says delete *this* theme.
        custom.remove(at: index)
        // The settings are unchanged, but the theme that described them is gone, so there is no
        // longer a selection to hold; the picker falls back to recognising the look.
        if selected == theme.name { selected = nil }
        persist()
    }

    /// Refuses a name another theme already has, presets included: `id` is the name, so two themes
    /// sharing one are a single row to the picker, and `delete` would have taken both. Refused in an
    /// alert rather than ignored, for the reason `importTheme` gives about a button doing nothing.
    func rename(_ theme: Theme, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !theme.builtIn, !trimmed.isEmpty, trimmed != theme.name,
              let index = custom.firstIndex(where: { $0.name == theme.name }) else { return }
        if all.contains(where: { $0.name == trimmed }) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "A theme called “\(trimmed)” already exists"
            alert.informativeText = "Choose another name."
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }
        custom[index].name = trimmed
        if selected == theme.name { selected = trimmed }  // the selection follows the rename
        persist()
    }

    /// `base` when no theme has it, otherwise the first of `base 2`, `base 3`, … that none does.
    func uniqueName(_ base: String) -> String {
        Self.uniqueName(base, among: Set(all.map(\.name)))
    }

    nonisolated static func uniqueName(_ base: String, among taken: Set<String>) -> String {
        guard taken.contains(base) else { return base }
        var n = 2
        while taken.contains("\(base) \(n)") { n += 1 }
        return "\(base) \(n)"
    }

    // MARK: - Share

    func export(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).cmdtabtheme.json"
        panel.message = "Export theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try JSONEncoder().encode(theme).write(to: url)
        } catch {
            // The panel said OK, so a silent failure here reads as a successful export with no file
            // at the other end. Same treatment as an unreadable import below.
            Log.general.error("theme export failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "The theme could not be saved"
            alert.informativeText =
                "\(url.lastPathComponent) was not written.\n\n" + error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }

        var theme: Theme
        do {
            theme = try JSONDecoder().decode(Theme.self, from: try Data(contentsOf: url))
        } catch {
            // Reported rather than swallowed. This used to be a `try?`, so an unreadable file made
            // the Import button do nothing whatsoever — no theme, no alert, no log — which is
            // indistinguishable from the app being broken.
            Log.general.error("theme import failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "That file could not be read as a theme"
            alert.informativeText =
                "\(url.lastPathComponent) is not a Cmd-Tab theme file, or it is damaged.\n\n"
                + error.localizedDescription
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return
        }

        theme.builtIn = false
        if theme.name.trimmingCharacters(in: .whitespaces).isEmpty { theme.name = "Imported theme" }
        // Avoid clobbering a preset's name.
        if Self.presets.contains(where: { $0.name == theme.name }) { theme.name += " (imported)" }
        // And a saved theme's: a friend's "My Theme" used to replace yours.
        theme.name = uniqueName(theme.name)
        custom.append(theme)
        persist()
        apply(theme)  // also records the selection
    }

    // MARK: - Persistence

    /// Reads the saved themes, keeping whatever survives.
    ///
    /// Each entry decodes independently (see `SalvagedTheme`), so one damaged theme costs that theme
    /// rather than the file. If even the outer array is unreadable, the file is moved aside instead
    /// of being left in place for the next `persist()` to overwrite with an empty list — which is
    /// how a shape mismatch used to destroy every saved theme silently.
    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        do {
            let saved = try JSONDecoder().decode([SalvagedTheme].self, from: data)
            custom = saved.compactMap(\.theme).map { var t = $0; t.builtIn = false; return t }
            if custom.count < saved.count {
                Log.general.error(
                    "themes.json: dropped \(saved.count - self.custom.count, privacy: .public) unreadable theme(s)")
            }
        } catch {
            Log.general.error(
                "themes.json unreadable (\(error.localizedDescription, privacy: .public)); moved to \(self.backupURL.lastPathComponent, privacy: .public)")
            try? FileManager.default.removeItem(at: backupURL)
            try? FileManager.default.moveItem(at: fileURL, to: backupURL)
        }
    }

    private func persist() {
        do {
            // Atomic: written aside and renamed into place. A crash or a full disk part-way through
            // an in-place write left a truncated file, which `load()` then could not read and moved
            // aside — every saved theme gone from the picker at the next launch.
            try JSONEncoder().encode(custom).write(to: fileURL, options: .atomic)
        } catch {
            // Logged rather than swallowed: a theme that fails to save is gone at the next launch,
            // and this was the one write in the file with no record of that happening.
            Log.general.error("themes.json write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Presets

    static let presets: [Theme] = [
        // The built-in look, field for field. Named and listed so a fresh install has a theme
        // selected rather than sitting on "Custom…" — which is what it did while no preset matched
        // the defaults — and so there is something to come back to after experimenting.
        Theme(
            name: "Glass", highlightHex: BehaviorDefault.highlightHex, appearance: "system",
            material: PanelMaterial.underWindow.rawValue,
            blurOverride: true, blurRadius: 40, showNumbers: true,
            tileCorner: 12, titleFontSize: 10, titleFontName: "",
            fade: false, iconSize: 88, iconSpacing: 2, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Classic", highlightHex: "#8A8A8E", appearance: "system", material: "hud",
            blurOverride: false, blurRadius: 20, showNumbers: true,
            tileCorner: 12, titleFontSize: 10, titleFontName: "",
            fade: false, iconSize: 64, iconSpacing: 18, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Vibrant", highlightHex: "#0A84FF", appearance: "system", material: "hud",
            blurOverride: true, blurRadius: 42, showNumbers: true,
            tileCorner: 16, titleFontSize: 11, titleFontName: "",
            fade: true, iconSize: 72, iconSpacing: 20, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Minimal", highlightHex: "#8A8A8E", appearance: "system", material: "sidebar",
            blurOverride: false, blurRadius: 20, showNumbers: false,
            tileCorner: 8, titleFontSize: 10, titleFontName: "",
            fade: true, iconSize: 56, iconSpacing: 12, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Midnight", highlightHex: "#BF5AF2", appearance: "dark", material: "hud",
            blurOverride: true, blurRadius: 30, showNumbers: true,
            tileCorner: 14, titleFontSize: 10, titleFontName: "",
            fade: true, iconSize: 64, iconSpacing: 18, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Daylight", highlightHex: "#0A84FF", appearance: "light", material: "window",
            blurOverride: false, blurRadius: 20, showNumbers: true,
            tileCorner: 12, titleFontSize: 10, titleFontName: "",
            fade: false, iconSize: 64, iconSpacing: 18, titleSpacing: 3,
            builtIn: true),
    ]
}
