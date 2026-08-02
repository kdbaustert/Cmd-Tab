import AppKit
import SwiftUI

// The settings window: a System Settings-shaped sidebar of tabs with gradient icon badges, a search
// field that jumps to any individual setting, and content built from the titled cards in
// `SettingsChrome.swift`.
//
// This replaces a toolbar-tab window sized to a single fixed pane. Five tabs of two-column rows had
// outgrown that shape — half of every pane's explanation lived in a tooltip because there was
// nowhere else to put it, and finding a setting meant remembering which tab it was on.

// MARK: - Tabs

/// The sidebar's tabs, in the order they appear.
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case shortcuts
    case windows
    case behavior
    case appearance
    case apps
    case about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .windows: return "Windows"
        case .behavior: return "Behavior"
        case .appearance: return "Appearance"
        case .apps: return "Apps"
        case .about: return "About"
        }
    }

    /// The badge's gradient. Muted System Settings-style badges, but this app's own values —
    /// restoring the *look* does not mean restoring the palette that was copied out of another
    /// app's source.
    var gradient: (Color, Color) {
        switch self {
        case .general: return (Color(hex: "#8E8E93")!, Color(hex: "#6C6C70")!)
        case .shortcuts: return (Color(hex: "#6E7BFF")!, Color(hex: "#3B45D6")!)
        case .windows: return (Color(hex: "#3FC7C7")!, Color(hex: "#0E8F97")!)
        case .behavior: return (Color(hex: "#A96BFF")!, Color(hex: "#6B2FD6")!)
        case .appearance: return (Color(hex: "#FF8A5B")!, Color(hex: "#E0532B")!)
        case .apps: return (Color(hex: "#5BC8A8")!, Color(hex: "#17916F")!)
        case .about: return (Color(hex: "#B8B8BE")!, Color(hex: "#95959B")!)
        }
    }

    var symbol: String {
        switch self {
        // One family throughout: solid, geometric, and enclosed where a shape allows it. The
        // previous set mixed a line-weight slider, a filled keyboard and a stroked arrow loop, so
        // seven badges in a column read as seven different icon sets rather than one.
        case .general: return "gearshape.2.fill"
        case .shortcuts: return "command.circle.fill"
        // The tab is about tiling, so a divided square says more than a plain window outline.
        case .windows: return "square.split.2x2.fill"
        case .behavior: return "square.stack.3d.up.fill"
        case .appearance: return "swatchpalette.fill"
        case .apps: return "square.grid.3x3.fill"
        case .about: return "info.circle.fill"
        }
    }

}

/// Section anchors, so the search index and the sections themselves agree on one spelling.
enum SettingsAnchor {
    static let startup = "general.startup"
    static let menuBar = "general.menuBar"
    static let backup = "general.backup"
    static let recovery = "general.recovery"
    static let configFile = "general.configFile"

    static let trigger = "shortcuts.trigger"
    static let windowActions = "shortcuts.windowActions"
    static let panelKeys = "shortcuts.panelKeys"
    static let scoped = "shortcuts.scoped"
    static let overview = "shortcuts.overview"

    static let tiling = "windows.tiling"
    static let mouseDrag = "windows.mouseDrag"
    static let allWindows = "windows.allWindows"
    static let layouts = "windows.layouts"

    static let session = "behavior.session"
    static let contents = "behavior.contents"
    static let placement = "behavior.placement"

    static let layout = "appearance.layout"
    static let theme = "appearance.theme"
    static let panel = "appearance.panel"
    static let tiles = "appearance.tiles"
    static let labels = "appearance.labels"
    static let markers = "appearance.markers"

    static let appRules = "apps.rules"
    static let directActivation = "apps.directActivation"
    static let overrides = "apps.overrides"

    static let permissions = "about.permissions"
    static let build = "about.build"
}

/// One searchable setting. The index is hand-written rather than derived from the views: a row is
/// findable by the words someone would actually type for it, which the label alone rarely covers.
struct SettingsIndexItem: Identifiable {
    let id: String
    let tab: SettingsTab
    let anchor: String
    let section: String
    let title: String
    let keywords: [String]

    func matches(_ query: String) -> Bool {
        let words = query.lowercased().split(separator: " ").map(String.init)
        guard !words.isEmpty else { return false }
        let hay = ([title, section, tab.title] + keywords).joined(separator: " ").lowercased()
        return words.allSatisfy(hay.contains)
    }
}

enum SettingsIndex {
    static let items: [SettingsIndexItem] = [
        item("menuBarIcon", .general, SettingsAnchor.startup, "Startup", "Show menu-bar icon",
             ["menu bar", "status item", "hide icon", "tray"]),
        item("startAtLogin", .general, SettingsAnchor.startup, "Startup", "Start at login",
             ["login", "launch", "boot", "autostart", "startup"]),
        item("menuBarGlyph", .general, SettingsAnchor.menuBar, "Menu bar", "Menu-bar glyph",
             ["icon", "glyph", "symbol", "artwork", "command", "keycap"]),
        item("export", .general, SettingsAnchor.backup, "Backup", "Export settings",
             ["export", "backup", "save", "json", "share"]),
        item("import", .general, SettingsAnchor.backup, "Backup", "Import settings",
             ["import", "restore", "load", "json"]),
        item("reset", .general, SettingsAnchor.backup, "Backup", "Reset to defaults",
             ["reset", "defaults", "wipe", "clear", "start over"]),

        item("configFile", .general, SettingsAnchor.configFile, "Configuration file",
             "Keep settings in a config file",
             ["config", "config file", "dotfiles", "json", "xdg", "sync", "symlink", "~/.config"]),

        item("restoreNative", .general, SettingsAnchor.recovery, "Recovery",
             "Restore macOS \u{2318}-Tab",
             ["restore", "recover", "native", "system switcher", "command tab", "cmd tab", "stuck",
              "broken", "give back"]),

        item("hotkey", .shortcuts, SettingsAnchor.trigger, "Trigger", "Switcher shortcut",
             ["hotkey", "shortcut", "cmd tab", "command tab", "trigger", "key"]),
        item("sameApp", .shortcuts, SettingsAnchor.trigger, "Trigger", "Cycle app windows",
             ["window cycle", "same app", "backtick", "cmd `", "windows"]),
        item("overview", .shortcuts, SettingsAnchor.overview, "Overview", "Shortcut overview",
             ["overview", "conflict", "conflicts", "collision", "clash", "all shortcuts",
              "bindings", "what is bound", "duplicate"]),
        item("scoped", .shortcuts, SettingsAnchor.scoped, "Scoped shortcuts",
             "Scoped shortcuts",
             ["scope", "scoped", "this app", "this display", "minimized", "all windows",
              "filtered", "subset", "extra trigger"]),
        item("windowActions", .shortcuts, SettingsAnchor.windowActions, "Window actions",
             "Window actions",
             ["quit", "force quit", "close", "hide", "hide others", "minimize", "zoom",
              "kill", "terminate", "close window", "action", "in-switcher action"]),
        item("panelKeys", .shortcuts, SettingsAnchor.panelKeys, "In-switcher keys",
             "In-switcher keys",
             ["keys", "panel", "filter", "search", "escape", "return", "digits", "navigate"]),

        item("tiling", .windows, SettingsAnchor.tiling, "Window tiling", "Window tiling",
             ["tile", "tiling", "snap", "halves", "half", "corner", "quarter", "maximize",
              "fullscreen", "center", "centre", "arrange", "window management", "restore",
              "left half", "right half", "cycle widths", "thirds", "display", "monitor",
              "screen", "gap", "gaps", "padding", "margin", "spacing", "inset", "border"]),
        item("mouseDrag", .windows, SettingsAnchor.mouseDrag, "Mouse",
             "Move and resize with the mouse",
             ["mouse", "drag", "modifier", "move window", "resize", "rectangle", "alt drag",
              "grab", "pointer", "trackpad", "point", "hold", "dot", "anchor", "highlight",
              "color", "colour", "dot color", "accent"]),
        item("layouts", .windows, SettingsAnchor.layouts, "Saved layouts", "Saved layouts",
             ["layout", "layouts", "workspace", "arrangement", "snapshot", "save windows",
              "restore windows", "session", "desk"]),
        item("allWindows", .windows, SettingsAnchor.allWindows, "All windows",
             "Hide all windows",
             ["hide all", "show all", "desktop", "clear screen", "show desktop", "unhide"]),
        item("directActivation", .apps, SettingsAnchor.directActivation, "Direct activation",
             "Jump straight to an app",
             ["direct", "activate", "jump", "hotkey", "per app", "shortcut", "focus app",
              "launch"]),

        item("overrides", .apps, SettingsAnchor.overrides, "Per-app overrides",
             "Per-app overrides",
             ["per app", "override", "rule", "expand windows", "never tile", "exception"]),
        item("launchFromSearch", .behavior, SettingsAnchor.session, "Session",
             "Launch apps from search",
             ["launch", "launcher", "open app", "search", "not running", "no matches"]),

        item("showDelay", .behavior, SettingsAnchor.session, "Session", "Show delay",
             ["delay", "wait", "flash", "quick tap", "reveal"]),
        item("sticky", .behavior, SettingsAnchor.session, "Session", "Stay open",
             ["sticky", "stay open", "release", "keep open"]),
        item("mode", .behavior, SettingsAnchor.contents, "Contents", "Switch between",
             ["mode", "applications", "apps", "windows", "window switcher", "per window"]),
        item("sortOrder", .behavior, SettingsAnchor.contents, "Contents", "Order",
             ["sort", "order", "recent", "mru", "alphabetical"]),
        item("hideEmpty", .behavior, SettingsAnchor.contents, "Contents",
             "Hide apps with no windows",
             ["empty", "windowless", "no windows", "hide"]),
        item("position", .behavior, SettingsAnchor.placement, "Placement", "Position",
             ["position", "centre", "center", "cursor", "active screen"]),
        item("screens", .behavior, SettingsAnchor.placement, "Placement", "Show on",
             ["display", "monitor", "screen", "mirror", "multi monitor"]),
        item("preview", .behavior, SettingsAnchor.placement, "Placement",
             "Preview windows on hover",
             ["preview", "thumbnail", "hover", "screen recording"]),

        item("layout", .appearance, SettingsAnchor.layout, "Layout", "Layout",
             ["layout", "grid", "list", "rows", "shape"]),
        item("maxColumns", .appearance, SettingsAnchor.layout, "Layout", "Max columns",
             ["columns", "wrap", "width", "grid"]),
        item("theme", .appearance, SettingsAnchor.theme, "Theme", "Theme",
             ["theme", "preset", "save", "import", "export"]),
        item("panelAppearance", .appearance, SettingsAnchor.panel, "Panel", "Appearance",
             ["light", "dark", "system", "appearance", "theme"]),
        item("material", .appearance, SettingsAnchor.panel, "Panel", "Material",
             ["material", "glass", "blur", "translucency", "hud"]),
        item("blur", .appearance, SettingsAnchor.panel, "Panel", "Custom blur",
             ["blur", "glass", "radius", "frost"]),
        item("highlight", .appearance, SettingsAnchor.panel, "Panel", "Highlight",
             ["highlight", "colour", "color", "selection", "tint"]),
        item("iconSize", .appearance, SettingsAnchor.tiles, "Tiles", "Icon size",
             ["icon", "size", "scale", "big", "small"]),
        item("iconSpacing", .appearance, SettingsAnchor.tiles, "Tiles", "Icon spacing",
             ["spacing", "gap", "padding", "tight"]),
        item("titleSpacing", .appearance, SettingsAnchor.tiles, "Tiles", "Title spacing",
             ["spacing", "gap", "label"]),
        item("tileCorner", .appearance, SettingsAnchor.tiles, "Tiles", "Corner radius",
             ["corner", "radius", "rounded", "highlight"]),
        item("titleSize", .appearance, SettingsAnchor.labels, "Labels", "Title size",
             ["text size", "font size", "title", "caption"]),
        item("titleFont", .appearance, SettingsAnchor.labels, "Labels", "Title font",
             ["font", "typeface", "family", "monospaced"]),
        item("numbers", .appearance, SettingsAnchor.markers, "Markers", "Number badges",
             ["number", "badge", "jump", "cmd 1", "hint"]),
        item("notificationBadges", .appearance, SettingsAnchor.markers, "Markers",
             "Notification badges",
             ["badge", "unread", "dock", "count", "notification"]),
        item("displayBadges", .appearance, SettingsAnchor.markers, "Markers",
             "Display badges",
             ["badge", "display", "monitor", "screen"]),
        item("spaceBadges", .appearance, SettingsAnchor.markers, "Markers",
             "Space badges",
             ["badge", "space", "desktop", "mission control"]),
        item("fade", .appearance, SettingsAnchor.markers, "Markers", "Fade in and out",
             ["fade", "animation", "transition"]),

        item("apps", .apps, SettingsAnchor.appRules, "App rules", "Favorites and exclusions",
             ["exclude", "hide app", "favorite", "star", "pin", "blacklist", "rules"]),

        item("accessibility", .about, SettingsAnchor.permissions, "Permissions",
             "Accessibility access",
             ["accessibility", "permission", "grant", "trusted", "not working", "broken"]),
        item("screenRecording", .about, SettingsAnchor.permissions, "Permissions",
             "Screen Recording access",
             ["screen recording", "permission", "preview", "thumbnail", "capture"]),
        item("version", .about, SettingsAnchor.build, "Build", "Version",
             ["version", "build", "about", "release"]),
        item("source", .about, SettingsAnchor.build, "Build", "Source",
             ["source", "github", "repository", "code", "issues"]),
    ]

    private static func item(
        _ id: String, _ tab: SettingsTab, _ anchor: String, _ section: String, _ title: String,
        _ keywords: [String]
    ) -> SettingsIndexItem {
        SettingsIndexItem(
            id: id, tab: tab, anchor: anchor, section: section, title: title, keywords: keywords)
    }
}

// MARK: - Root

struct SettingsRootView: View {
    @State private var tab: SettingsTab = .general
    @State private var query = ""
    /// Anchor a search result asked for. Cleared once the scroll has happened, so picking the same
    /// result twice still moves.
    @State private var jump: String?
    /// Anchor currently outlined. See `SettingsChrome`'s `settingsFlash`.
    @State private var flash: String?

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: 192)
                .background(VisualEffectBackground(material: .sidebar, blurRadius: nil))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                // Deliberately no background: the window's own glass backdrop shows through here,
                // and a second opaque fill on top of it would be the one thing that undoes it.
        }
        .frame(minWidth: 700, idealWidth: 760, minHeight: 500, idealHeight: 580)
        .environment(\.settingsFlash, flash)
    }

    // MARK: Sidebar

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Room for the traffic lights, which sit over the sidebar in a full-height-content
            // window rather than in a titlebar of their own.
            SettingsSearchField(text: $query)
                .padding(.horizontal, 10)
                .padding(.top, 38)
                .padding(.bottom, 8)

            if query.trimmingCharacters(in: .whitespaces).isEmpty {
                tabList
            } else {
                results
            }
            Spacer(minLength: 0)
        }
    }

    private var tabList: some View {
        VStack(spacing: 2) {
            ForEach(SettingsTab.allCases) { candidate in
                Button {
                    tab = candidate
                } label: {
                    HStack(spacing: 9) {
                        SettingsTabIcon(
                            symbol: candidate.symbol,
                            start: candidate.gradient.0,
                            end: candidate.gradient.1)
                        Text(candidate.title).font(.system(size: 13))
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .fill(tab == candidate ? Color.primary.opacity(0.10) : .clear))
                    .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
    }

    /// Search hits, each naming the tab and section it lives in — the same job the sidebar does the
    /// rest of the time, which is why they take its place rather than covering the content.
    @ViewBuilder
    private var results: some View {
        let hits = SettingsIndex.items.filter { $0.matches(query) }
        if hits.isEmpty {
            Text("No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 6)
        } else {
            ScrollView {
                VStack(spacing: 2) {
                    ForEach(hits) { hit in
                        Button {
                            tab = hit.tab
                            query = ""
                            jump = hit.anchor
                        } label: {
                            VStack(alignment: .leading, spacing: 1) {
                                Text(hit.title).font(.system(size: 12))
                                Text("\(hit.tab.title) › \(hit.section)")
                                    .font(.system(size: 10))
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    // MARK: Detail

    private var detail: some View {
        ScrollViewReader { proxy in
            content
                .onChange(of: jump) { _, anchor in
                    guard let anchor else { return }
                    // The tab changed in the same turn, so the section being scrolled to does not
                    // exist yet; let SwiftUI build the new pane before asking for it.
                    DispatchQueue.main.async {
                        withAnimation(.easeInOut(duration: 0.25)) {
                            proxy.scrollTo(anchor, anchor: .top)
                        }
                        flash = anchor
                        jump = nil
                    }
                }
                .onChange(of: flash) { _, anchor in
                    guard anchor != nil else { return }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        if flash == anchor { flash = nil }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch tab {
        case .general:
            GeneralSettings(loginItem: .shared, behavior: .shared)
        case .shortcuts:
            ShortcutSettings(behavior: .shared)
        case .windows:
            WindowSettings(store: .shared)
        case .behavior:
            BehaviorSettings(behavior: .shared)
        case .appearance:
            AppearanceSettings(appearance: .shared, behavior: .shared)
        case .apps:
            AppsSettings(store: .shared, favorites: .shared)
        case .about:
            AboutSettings()
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var loginItem: LoginItemStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var config = ConfigFile.shared

    var body: some View {
        SettingsPage(title: "General", subtitle: "How Cmd-Tab itself starts and presents itself.") {
            SettingsSection(title: "Startup", anchor: SettingsAnchor.startup) {
                SettingsToggle(
                    title: "Show menu-bar icon",
                    subtitle: "Off leaves no menu-bar item. Reopen Cmd-Tab from Finder to get "
                        + "Settings back.",
                    isOn: $behavior.showMenuBarIcon)
                SettingsToggle(
                    title: "Start at login",
                    isOn: Binding(
                        get: { loginItem.startAtLogin },
                        set: { loginItem.setStartAtLogin($0) }))
            }

            SettingsSection(title: "Menu bar", anchor: SettingsAnchor.menuBar) {
                // Shows the artwork rather than only its name — the names are labels of
                // convenience, and which glyph you want is a thing you decide by looking at it.
                SettingsPicker(
                    title: "Menu-bar glyph",
                    subtitle: "Which icon the menu-bar item shows.",
                    selection: $behavior.menuBarIcon,
                    width: 175
                ) {
                    ForEach(MenuBarIcon.allCases, id: \.self) { icon in
                        HStack(spacing: 6) {
                            icon.image.map { Image(nsImage: $0) }
                            Text(icon.title)
                        }
                        .tag(icon)
                    }
                }
                .disabled(!behavior.showMenuBarIcon)
            }

            SettingsSection(
                title: "Backup", anchor: SettingsAnchor.backup,
                footer: "An exported file carries every preference, including favourites and "
                    + "exclusions."
            ) {
                SettingsRow(title: "Settings file", subtitle: "Move your whole setup between Macs.") {
                    HStack(spacing: 8) {
                        Button("Export…", action: SettingsIO.export)
                        Button("Import…", action: SettingsIO.importSettings)
                    }
                }
                SettingsRow(
                    title: "Reset to defaults",
                    subtitle: "Clears every Cmd-Tab preference, including excluded apps."
                ) {
                    Button("Reset…", action: resetSettings)
                }
            }

            SettingsSection(
                title: "Configuration file", anchor: SettingsAnchor.configFile,
                footer: "Written in place rather than replaced, so a symlink into a dotfiles repo "
                    + "survives every save. On launch the file wins over local settings — that is "
                    + "what makes a fresh checkout come up configured."
            ) {
                SettingsToggle(
                    title: "Keep settings in a config file",
                    subtitle: "Mirrors every preference to \(ConfigFile.displayPath). Edits to the "
                        + "file apply live; changes made here are written back.",
                    isOn: Binding(
                        get: { config.isEnabled },
                        set: { config.setEnabled($0) }))
                SettingsRow(title: "Show the file", subtitle: ConfigFile.displayPath) {
                    Button("Reveal in Finder", action: config.revealInFinder)
                        .disabled(!config.isEnabled)
                }
            }

            SettingsSection(
                title: "Recovery", anchor: SettingsAnchor.recovery,
                footer: "The takeover lives in the window server's memory, never in "
                    + "`com.apple.symbolichotkeys`, so logging out restores ⌘-Tab too."
            ) {
                SettingsRow(
                    title: "Restore macOS ⌘-Tab",
                    subtitle: nativeSwitcherSubtitle
                ) {
                    Button("Restore", action: restoreNativeSwitcher)
                        .disabled(!SystemSwitcher.isNativeDisabled)
                }
            }
        }
        .onAppear { loginItem.refresh() }
    }

    /// Reflects the live state rather than a stored preference — this is a recovery control, and
    /// what someone needs from it is whether the system switcher is off *right now*.
    private var nativeSwitcherSubtitle: String {
        SystemSwitcher.isNativeDisabled
            ? "Cmd-Tab has the system switcher disabled. Hand ⌘-Tab back to macOS without quitting."
            : "The system switcher is already enabled."
    }

    /// Hands ⌘-Tab back to macOS while Cmd-Tab keeps running.
    ///
    /// The takeover is otherwise undone only by a clean quit, which is no help at all in the case
    /// that matters: the app is misbehaving, or its trigger is bound to something you cannot reach,
    /// and ⌘-Tab does nothing. Cmd-Tab keeps its own trigger — this releases the *system's* one, so
    /// both answer until the app is restarted.
    private func restoreNativeSwitcher() {
        SystemSwitcher.restoreNativeIfNeeded()
        let alert = NSAlert()
        alert.messageText = "macOS ⌘-Tab restored"
        alert.informativeText =
            "The system switcher answers ⌘-Tab again. Cmd-Tab is still running and still bound to "
            + "its own trigger, so both will respond until you restart it.\n\n"
            + "To keep the system switcher for good, quit Cmd-Tab or turn off Start at login."
        alert.addButton(withTitle: "OK")
        alert.runModal()
    }

    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "This clears every Cmd-Tab preference, including excluded apps."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsIO.reset()
    }
}

// MARK: - Shortcuts

struct ShortcutSettings: View {
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var scoped = ScopedTriggersStore.shared
    @ObservedObject private var actions = SwitcherShortcutsStore.shared

    /// The keys the panel handles itself, listed in the order someone meets them.
    private static let panelKeys: [(title: String, keys: String)] = [
        ("Move the selection", "Tab / ⇧Tab, ← / →"),
        ("Switch to the selection", "Return"),
        ("Jump straight to a tile", "1–9, 0"),
        ("Filter the list", "type"),
        ("Delete a filter character", "⌫"),
        ("Close without switching", "⎋"),
    ]

    /// Adding a scoped trigger *is* choosing its scope, so the button is the menu — there is no
    /// sensible default scope to add first and then correct.
    private var addScopedMenu: some View {
        Menu("Add Shortcut…") {
            ForEach(SwitcherScope.allCases) { scope in
                Button(scope.title) { scoped.add(scope: scope) }
            }
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    /// Every binding in the app, and anything two of them are fighting over.
    ///
    /// Each pane already warns about clashes inside its own store; nothing could see *across*
    /// stores, which is where the confusing collisions live — a tiling chord and a direct
    /// activation on the same keys produced no warning at all.
    @ViewBuilder
    private var overviewSection: some View {
        let all = ShortcutAudit.entries()
        let collisions = ShortcutAudit.collisions(in: all)
        SettingsSection(
            title: "Overview", anchor: SettingsAnchor.overview,
            footer: "Bindings are matched in the order listed above, so the first one to claim a "
                + "combination is the one that fires. Openers come first: nothing you bind can take "
                + "the switcher's own trigger away from it."
        ) {
            if collisions.isEmpty {
                SettingsRow(
                    title: "No conflicts",
                    subtitle: "\(all.filter { $0.chord != nil }.count) shortcuts assigned across "
                        + "\(ShortcutEntry.Kind.allCases.count) groups."
                ) {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.green)
                }
            } else {
                ForEach(collisions) { collision in
                    SettingsRow(
                        title: collision.display,
                        subtitle: description(of: collision)
                    ) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(Color.orange)
                    }
                }
            }
            DisclosureGroup {
                VStack(spacing: 0) {
                    ForEach(all) { entry in
                        HStack(spacing: 10) {
                            Text(entry.label)
                                .font(.system(size: 12))
                                .foregroundStyle(entry.isActive ? .primary : .secondary)
                                .lineLimit(1)
                            Spacer(minLength: 8)
                            Text("\(entry.kind.title) · \(entry.kind.location)")
                                .font(.system(size: 10))
                                .foregroundStyle(.tertiary)
                            Text(entry.display)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(entry.chord == nil ? .tertiary : .secondary)
                                .frame(width: 78, alignment: .trailing)
                        }
                        .padding(.vertical, 3)
                    }
                }
                .padding(.top, 6)
            } label: {
                Text("All bindings").font(.system(size: 13))
            }
            .padding(.horizontal, SettingsChrome.rowInset)
            .padding(.vertical, 9)
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(SettingsChrome.divider)
                    .frame(height: SettingsChrome.hairline)
                    .padding(.leading, SettingsChrome.rowInset)
            }
        }
    }

    private func description(of collision: ShortcutCollision) -> String {
        let losers = collision.losers.map { "\($0.label) (\($0.kind.title))" }
            .joined(separator: ", ")
        guard let winner = collision.winner else { return "" }
        return "\(winner.label) (\(winner.kind.title)) wins. Never fires: \(losers)."
    }

    /// A shadowed action says so in place of its description: its binding is recorded and looks
    /// fine, and the only visible symptom is the key typing into the filter instead.
    private func actionSubtitle(for action: SwitcherAction) -> String? {
        if actions.shortcuts.actionsShadowed(by: behavior.hotkey).contains(action) {
            return "\(behavior.hotkey.displayString) already holds that modifier — this cannot fire."
        }
        return action.detail
    }

    private func scopedSubtitle(for trigger: ScopedTrigger) -> String? {
        guard let hotkey = scoped.hotkey(for: trigger.id) else {
            return "No shortcut yet — click Not set and press a combination."
        }
        if let claimer = WindowTilingBindings.triggerClaiming(hotkey, in: behavior) {
            return "\(hotkey.displayString) opens \(claimer) — this will never fire."
        }
        return trigger.scope.detail
    }

    var body: some View {
        SettingsPage(title: "Shortcuts", subtitle: "What opens the switcher, and what the keys do "
            + "while it is up.") {
            SettingsSection(title: "Trigger", anchor: SettingsAnchor.trigger) {
                SettingsRow(
                    title: "Switcher shortcut",
                    subtitle: "Hold to open the switcher; release to switch."
                ) {
                    HotkeyRecorder(hotkey: $behavior.hotkey)
                }
                SettingsRow(
                    title: "Cycle app windows",
                    subtitle: "A second shortcut that shows only the frontmost app's windows. Off "
                        + "by default — the usual ⌘` is a shortcut apps use themselves."
                ) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $behavior.sameAppCycle)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                        HotkeyRecorder(hotkey: $behavior.sameAppHotkey)
                            .disabled(!behavior.sameAppCycle)
                    }
                }
            }

            overviewSection

            SettingsSection(
                title: "Scoped shortcuts", anchor: SettingsAnchor.scoped,
                footer: "Each opens the switcher on part of the window list instead of all of it. "
                    + "Held and released like the main trigger, and never sticky — a scoped cycle "
                    + "is a quick jump, not a panel to browse."
            ) {
                if scoped.scoped.triggers.isEmpty {
                    SettingsWideRow {
                        HStack {
                            Text("None yet.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            addScopedMenu
                        }
                    }
                } else {
                    ForEach(scoped.scoped.triggers) { trigger in
                        SettingsRow(
                            title: trigger.scope.title,
                            subtitle: scopedSubtitle(for: trigger),
                            controlWidth: 210
                        ) {
                            HStack(spacing: 6) {
                                ScopedShortcutRecorder(trigger: trigger, store: scoped)
                                Button {
                                    scoped.remove(id: trigger.id)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this trigger")
                            }
                        }
                    }
                    SettingsWideRow {
                        HStack {
                            Spacer()
                            addScopedMenu
                        }
                    }
                }
            }

            SettingsSection(
                title: "Window actions", anchor: SettingsAnchor.windowActions,
                footer: "Act on the highlighted tile without leaving the switcher. Each is a key "
                    + "plus ⌥ or ⌃ held on top of the trigger — an extra modifier is required, "
                    + "since a bare letter is type-to-filter input."
            ) {
                SettingsToggle(
                    title: "Enable window actions",
                    subtitle: "Off leaves every ⌥-key to the filter. Off by default: quitting an "
                        + "app is not something to discover by mistyping a search.",
                    isOn: $actions.isEnabled)
                if actions.isEnabled {
                    SettingsToggle(
                        title: "Confirm before quitting",
                        subtitle: "Ask first for Quit and Force-quit. One key separates ⌥W (close "
                            + "a window) from ⌥Q (quit the app), and only one of them can be undone.",
                        isOn: $actions.confirmsDestructive)
                    ForEach(SwitcherAction.allCases) { action in
                        SettingsRow(
                            title: action.title,
                            subtitle: actionSubtitle(for: action),
                            controlWidth: 130
                        ) {
                            ActionShortcutRecorder(action: action, store: actions)
                        }
                    }
                    SettingsWideRow {
                        HStack {
                            Spacer()
                            Button("Reset to Defaults") { actions.resetToDefaults() }
                        }
                    }
                }
            }

            // A reference card rather than a set of recorders: what is left in the panel is
            // navigation and typing, neither of which is rebindable.
            SettingsSection(
                title: "In-switcher keys", anchor: SettingsAnchor.panelKeys,
                footer: "Pressed while the panel is up — on top of the held trigger, or on their "
                    + "own once it is released in Stay open. Scrolling or hovering over a tile "
                    + "moves the selection too, and a click switches straight to it."
            ) {
                ForEach(Self.panelKeys, id: \.title) { entry in
                    SettingsRow(title: entry.title, controlWidth: 120) {
                        Text(entry.keys)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

// MARK: - Behavior

struct BehaviorSettings: View {
    @ObservedObject var behavior: BehaviorStore

    var body: some View {
        SettingsPage(title: "Behavior", subtitle: "How the switcher opens, what it lists, and where "
            + "it appears.") {
            SettingsSection(title: "Session", anchor: SettingsAnchor.session) {
                SettingsSlider(
                    title: "Show delay",
                    subtitle: "Wait before drawing the panel, so a quick tap switches with no "
                        + "flash. 0 = instant.",
                    value: $behavior.showDelay,
                    range: 0...400,
                    step: 25,
                    format: { "\(Int($0)) ms" })
                SettingsToggle(
                    title: "Stay open",
                    subtitle: "Releasing the trigger leaves the switcher up instead of switching. "
                        + "Tab, Return, a click or 1–9/0 then picks; Escape backs out.",
                    isOn: $behavior.stickyMode)
            }

            SettingsSection(title: "Contents", anchor: SettingsAnchor.contents) {
                SettingsChoice(
                    title: "Switch between",
                    subtitle: "What each tile stands for.",
                    selection: $behavior.mode,
                    options: SwitcherMode.allCases.map {
                        .init(
                            value: $0, title: $0.shortTitle, detail: $0.detail, symbol: $0.symbol)
                    })
                SettingsPicker(
                    title: "Order", subtitle: "How tiles are sorted.",
                    selection: $behavior.sortOrder, width: 160
                ) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsToggle(
                    title: "Hide apps with no windows",
                    subtitle: behavior.mode == .windows
                        ? "Applications only — a window list has no empty apps in it."
                        : "An app whose windows are all minimized counts as empty.",
                    isOn: $behavior.hideEmptyApps)
                    .disabled(behavior.mode == .windows)
            }

            SettingsSection(title: "Placement", anchor: SettingsAnchor.placement) {
                SettingsPicker(
                    title: "Position", subtitle: "Where on a display the panel opens.",
                    selection: $behavior.panelPosition, width: 160
                ) {
                    ForEach(PanelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsPicker(
                    title: "Show on", subtitle: "Which displays get a panel.",
                    selection: $behavior.panelScreens, width: 160
                ) {
                    ForEach(PanelScreens.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsToggle(
                    title: "Preview windows on hover",
                    subtitle: behavior.mode == .windows
                        ? "Applications only — in window mode the tiles are already windows."
                        : "Hover a tile to float live thumbnails of that app's windows, and click "
                            + "one to go straight to it. Needs Screen Recording permission.",
                    isOn: $behavior.windowPreview)
                    .disabled(behavior.mode == .windows)
                    .onChange(of: behavior.windowPreview) {
                        if behavior.windowPreview { Permissions.ensureScreenCaptureForPreview() }
                    }
            }
        }
    }
}

// MARK: - Window

/// Hosts the settings window.
///
/// Kept alive by the delegate so the window survives being closed. The window is
/// full-size-content with a hidden title, which is what lets the sidebar run the full height with
/// the traffic lights sitting over it — the shape System Settings has.
@MainActor
final class SettingsPresenter {
    private var window: NSWindow?

    func show() {
        let window = self.window ?? Self.makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        // `NSApp.activate()` on macOS 14+ asks the system to hand over activation rather than
        // taking it. That is the right default for an ordinary app, but we are `.accessory`: no
        // Dock tile, and nothing else that would let the user bring the window forward if the
        // request is declined. The blunt form is what guarantees the window arrives with the
        // keyboard.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Built on first show rather than at launch. `AppsSettings` constructs an `AppListModel`, which
    /// registers workspace observers and does a LaunchServices lookup plus two disk reads per
    /// installed app — real work for a window most sessions never open.
    private static func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Cmd-Tab Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Glass, the same way the switcher panel gets it: the window paints nothing of its own, and
        // an `NSVisualEffectView` fills it instead. Both halves are `.behindWindow`, which is what
        // makes them blur the desktop rather than each other — with an opaque window background
        // underneath, the material has nothing to sample and renders as flat grey.
        window.isOpaque = false
        window.backgroundColor = .clear
        // The separator is drawn for an opaque titlebar; over glass it reads as a scar across the
        // top of the window.
        window.titlebarSeparatorStyle = .none
        // Deliberately off: the panes are full of sliders, lists and colour wells, and a window that
        // slides out from under a missed drag is worse than one that only moves by its titlebar —
        // which is still there, transparent, above the sidebar.
        window.isMovableByWindowBackground = false
        // The presenter owns the window across closes, so AppKit must not free it out from under us.
        window.isReleasedWhenClosed = false
        window.contentView = glassContent()
        window.center()
        // Suffixed deliberately. Setting an autosave name applies the frame saved under it, so an
        // install that has opened Settings before would come back at the old size and never see a
        // changed default. A new name means the size below stands once, and every resize after that
        // is remembered as usual.
        window.setFrameAutosaveName("CmdTabSettings.760")
        return window
    }

    /// The window's backdrop: one visual-effect view filling the whole frame, with the SwiftUI
    /// content hosted on top of it.
    ///
    /// The material goes on an `NSView` under the hosting view rather than into the SwiftUI tree so
    /// that it covers the titlebar region too — a `.fullSizeContentView` window whose glass stops at
    /// the content's top edge shows a bare strip behind the traffic lights.
    private static func glassContent() -> NSView {
        let backdrop = NSVisualEffectView()
        backdrop.material = .underWindowBackground
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active

        let host = NSHostingView(rootView: SettingsRootView())
        host.translatesAutoresizingMaskIntoConstraints = false
        backdrop.addSubview(host)
        NSLayoutConstraint.activate([
            host.topAnchor.constraint(equalTo: backdrop.topAnchor),
            host.leadingAnchor.constraint(equalTo: backdrop.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: backdrop.trailingAnchor),
            host.bottomAnchor.constraint(equalTo: backdrop.bottomAnchor),
        ])
        return backdrop
    }
}
