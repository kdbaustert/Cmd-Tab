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
    case behavior
    case appearance
    case apps

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .shortcuts: return "Shortcuts"
        case .behavior: return "Behavior"
        case .appearance: return "Appearance"
        case .apps: return "Apps"
        }
    }

    var symbol: String {
        switch self {
        case .general: return "gearshape.fill"
        case .shortcuts: return "command"
        case .behavior: return "rectangle.stack.fill"
        case .appearance: return "paintbrush.fill"
        case .apps: return "square.grid.2x2.fill"
        }
    }

    /// The badge's gradient — the muted System Settings palette: grey, blue, purple, pink, green.
    var gradient: (Color, Color) {
        switch self {
        case .general: return (Color(hex: "#898A8F")!, Color(hex: "#67686E")!)
        case .shortcuts: return (Color(hex: "#40BCFF")!, Color(hex: "#0060FF")!)
        case .behavior: return (Color(hex: "#B272FF")!, Color(hex: "#6228FF")!)
        case .appearance: return (Color(hex: "#FF6991")!, Color(hex: "#D41E5A")!)
        case .apps: return (Color(hex: "#4ED98F")!, Color(hex: "#12A85B")!)
        }
    }
}

/// Section anchors, so the search index and the sections themselves agree on one spelling.
enum SettingsAnchor {
    static let startup = "general.startup"
    static let menuBar = "general.menuBar"
    static let backup = "general.backup"

    static let trigger = "shortcuts.trigger"
    static let panelKeys = "shortcuts.panelKeys"

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

        item("hotkey", .shortcuts, SettingsAnchor.trigger, "Trigger", "Switcher shortcut",
             ["hotkey", "shortcut", "cmd tab", "command tab", "trigger", "key"]),
        item("sameApp", .shortcuts, SettingsAnchor.trigger, "Trigger", "Cycle app windows",
             ["window cycle", "same app", "backtick", "cmd `", "windows"]),
        item("panelKeys", .shortcuts, SettingsAnchor.panelKeys, "In-switcher keys",
             "Window action keys",
             ["quit", "close", "hide", "minimize", "zoom", "rebind", "action", "keys"]),

        item("showDelay", .behavior, SettingsAnchor.session, "Session", "Show delay",
             ["delay", "wait", "flash", "quick tap", "reveal"]),
        item("sticky", .behavior, SettingsAnchor.session, "Session", "Stay open",
             ["sticky", "stay open", "release", "keep open"]),
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
             "Display & Space badges",
             ["badge", "display", "space", "desktop", "monitor"]),
        item("fade", .appearance, SettingsAnchor.markers, "Markers", "Fade in and out",
             ["fade", "animation", "transition"]),

        item("apps", .apps, SettingsAnchor.appRules, "App rules", "Favorites and exclusions",
             ["exclude", "hide app", "favorite", "star", "pin", "blacklist", "rules"]),
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
                .frame(width: 208)
                .background(VisualEffectBackground(material: .sidebar, blurRadius: nil))
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 800, idealWidth: 840, minHeight: 560, idealHeight: 640)
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
        case .behavior:
            BehaviorSettings(behavior: .shared)
        case .appearance:
            AppearanceSettings(appearance: .shared, behavior: .shared)
        case .apps:
            AppsSettings(store: .shared, favorites: .shared)
        }
    }
}

// MARK: - General

struct GeneralSettings: View {
    @ObservedObject var loginItem: LoginItemStore
    @ObservedObject var behavior: BehaviorStore

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
        }
        .onAppear { loginItem.refresh() }
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
    @ObservedObject private var shortcuts = SwitcherShortcutsStore.shared

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

            SettingsSection(
                title: "In-switcher keys", anchor: SettingsAnchor.panelKeys,
                footer: "While the switcher is open: type to filter, 1–9/0 jump, scroll or hover to "
                    + "move the selection, or click a tile."
            ) {
                SettingsWideRow(
                    title: "Window actions",
                    subtitle: "⌘ (the trigger) is held throughout, so each of these also needs ⌥ "
                        + "or ⌃ to stay clear of type-to-filter."
                ) {
                    LazyVGrid(
                        columns: [
                            GridItem(.flexible(), spacing: 18, alignment: .leading),
                            GridItem(.flexible(), spacing: 18, alignment: .leading),
                        ],
                        alignment: .leading, spacing: 7
                    ) {
                        ForEach(SwitcherAction.allCases) { action in
                            HStack(spacing: 8) {
                                Text(action.title).font(.system(size: 12)).lineLimit(1)
                                Spacer(minLength: 4)
                                ActionShortcutRecorder(action: action, store: shortcuts)
                            }
                        }
                    }
                }
                SettingsRow(title: "Restore default keys") {
                    Button("Reset", action: shortcuts.resetToDefaults)
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
                SettingsPicker(
                    title: "Order", subtitle: "How tiles are sorted.",
                    selection: $behavior.sortOrder, width: 160
                ) {
                    ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                SettingsToggle(
                    title: "Hide apps with no windows",
                    subtitle: "An app whose windows are all minimized counts as empty.",
                    isOn: $behavior.hideEmptyApps)
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
                    subtitle: "Hover a tile to float live thumbnails of that app's windows, and "
                        + "click one to go straight to it. Needs Screen Recording permission.",
                    isOn: $behavior.windowPreview)
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
            contentRect: NSRect(x: 0, y: 0, width: 840, height: 640),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false)
        window.title = "Cmd-Tab Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        // Deliberately off: the panes are full of sliders, lists and colour wells, and a window that
        // slides out from under a missed drag is worse than one that only moves by its titlebar —
        // which is still there, transparent, above the sidebar.
        window.isMovableByWindowBackground = false
        // The presenter owns the window across closes, so AppKit must not free it out from under us.
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: SettingsRootView())
        window.center()
        window.setFrameAutosaveName("CmdTabSettings")
        return window
    }
}
