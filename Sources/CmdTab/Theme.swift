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
    func sameLook(as other: Theme) -> Bool {
        var a = self, b = other
        a.name = ""; b.name = ""
        a.builtIn = false; b.builtIn = false
        a.iconSize = 0; b.iconSize = 0
        return a == b
    }
}

/// Presets plus the user's saved themes. Applying one writes into `BehaviorStore` and
/// `AppearanceStore`; capturing reads back from them. Custom themes persist as JSON in Application
/// Support so they are independent of the live settings and portable between machines.
@MainActor
final class ThemeStore: ObservableObject {
    static let shared = ThemeStore()

    @Published private(set) var custom: [Theme] = []

    private let fileURL: URL

    var all: [Theme] { Self.presets + custom }

    private init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        let dir = base.appendingPathComponent("Cmd-Tab", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = dir.appendingPathComponent("themes.json")
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
            b.fade = theme.fade
        }

        let a = AppearanceStore.shared
        // Icon size is a user-level preference, not a theme trait: switching themes leaves whatever
        // size is currently assigned untouched (see `sameLook`, which also ignores it).
        a.iconSpacing = theme.iconSpacing
        a.titleSpacing = theme.titleSpacing
    }

    /// The theme whose look matches the current settings, or nil when the user has tuned away from
    /// every saved one ("Custom").
    func currentMatch() -> Theme? {
        let current = captureCurrent()
        return all.first { $0.sameLook(as: current) }
    }

    // MARK: - Custom theme management

    func saveAs(_ name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        var theme = captureCurrent(name: trimmed)
        theme.builtIn = false
        custom.removeAll { $0.name == trimmed }  // overwrite a same-named custom theme
        custom.append(theme)
        persist()
    }

    func delete(_ theme: Theme) {
        guard !theme.builtIn else { return }
        custom.removeAll { $0.name == theme.name }
        persist()
    }

    func rename(_ theme: Theme, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespaces)
        guard !theme.builtIn, !trimmed.isEmpty,
              let index = custom.firstIndex(where: { $0.name == theme.name }) else { return }
        custom[index].name = trimmed
        persist()
    }

    // MARK: - Share

    func export(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).cmdtabtheme.json"
        panel.message = "Export theme"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? JSONEncoder().encode(theme) else { return }
        try? data.write(to: url)
    }

    func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Import theme"
        guard panel.runModal() == .OK, let url = panel.url,
              let data = try? Data(contentsOf: url),
              var theme = try? JSONDecoder().decode(Theme.self, from: data) else { return }
        theme.builtIn = false
        // Avoid clobbering a preset's name.
        if Self.presets.contains(where: { $0.name == theme.name }) { theme.name += " (imported)" }
        custom.removeAll { $0.name == theme.name }
        custom.append(theme)
        persist()
        apply(theme)
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL),
              let saved = try? JSONDecoder().decode([Theme].self, from: data) else { return }
        custom = saved.map { var t = $0; t.builtIn = false; return t }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(custom) else { return }
        try? data.write(to: fileURL)
    }

    // MARK: - Presets

    static let presets: [Theme] = [
        Theme(
            name: "Classic", highlightHex: "#8A8A8E", appearance: "system", material: "hud",
            blurOverride: false, blurRadius: 20, showNumbers: true,
            tileCorner: 12, titleFontSize: 10,
            fade: false, iconSize: 64, iconSpacing: 18, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Vibrant", highlightHex: "#0A84FF", appearance: "system", material: "hud",
            blurOverride: true, blurRadius: 42, showNumbers: true,
            tileCorner: 16, titleFontSize: 11,
            fade: true, iconSize: 72, iconSpacing: 20, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Minimal", highlightHex: "#8A8A8E", appearance: "system", material: "sidebar",
            blurOverride: false, blurRadius: 20, showNumbers: false,
            tileCorner: 8, titleFontSize: 10,
            fade: true, iconSize: 56, iconSpacing: 12, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Midnight", highlightHex: "#BF5AF2", appearance: "dark", material: "hud",
            blurOverride: true, blurRadius: 30, showNumbers: true,
            tileCorner: 14, titleFontSize: 10,
            fade: true, iconSize: 64, iconSpacing: 18, titleSpacing: 2,
            builtIn: true),
        Theme(
            name: "Daylight", highlightHex: "#0A84FF", appearance: "light", material: "window",
            blurOverride: false, blurRadius: 20, showNumbers: true,
            tileCorner: 12, titleFontSize: 10,
            fade: false, iconSize: 64, iconSpacing: 18, titleSpacing: 3,
            builtIn: true),
    ]
}
