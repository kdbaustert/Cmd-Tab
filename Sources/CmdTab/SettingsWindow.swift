import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row in the settings list: an app that can be excluded from the switcher.
struct AppEntry: Identifiable {
    /// The bundle identifier, which is also what the exclusion is keyed on.
    let id: String
    let name: String
    let icon: NSImage?
    let isRunning: Bool
}

/// The list of apps offered in settings: everything currently running, plus anything already
/// excluded. Excluded apps have to appear even when they are not running, or an exclusion could
/// never be undone once the app quit.
@MainActor
final class AppListModel: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload() }
                })
        }
        reload()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    func reload() {
        let excluded = ExclusionStore.shared.excluded
        var byID: [String: AppEntry] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  !app.isTerminated else { continue }
            byID[id] = AppEntry(
                id: id, name: app.localizedName ?? id, icon: app.icon, isRunning: true)
        }

        // Fold in excluded apps that are not running right now.
        for id in excluded where byID[id] == nil {
            byID[id] = Self.installedEntry(for: id)
        }

        entries = byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolves a bundle identifier to something displayable. Falls back to the raw identifier
    /// so an app that has since been uninstalled still gets a row the user can untick.
    private static func installedEntry(for bundleID: String) -> AppEntry {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppEntry(id: bundleID, name: bundleID, icon: nil, isRunning: false)
        }
        return AppEntry(
            id: bundleID,
            name: FileManager.default.displayName(atPath: url.path),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            isRunning: false)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings(loginItem: .shared, behavior: .shared)
                .tabItem { Label("General", systemImage: "gearshape") }
            AppearanceSettings(appearance: .shared, behavior: .shared)
                .tabItem { Label("Appearance", systemImage: "slider.horizontal.3") }
            ExcludedAppsSettings(store: .shared)
                .tabItem { Label("Excluded Apps", systemImage: "eye.slash") }
        }
        .padding(12)
        .frame(width: 470, height: 620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var loginItem: LoginItemStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var favorites = FavoritesStore.shared
    @ObservedObject private var shortcutsStore = SwitcherShortcutsStore.shared

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                field("Shortcut", help: "Hold to open the switcher; release to switch.") {
                    HotkeyRecorder(hotkey: $behavior.hotkey)
                }

                field(
                    "Show delay",
                    help: "Wait before drawing the panel; a quick tap switches with no flash. "
                        + "0 = instant."
                ) {
                    HStack(spacing: 8) {
                        Slider(value: $behavior.showDelay, in: 0...400, step: 25).frame(width: 170)
                        Text("\(Int(behavior.showDelay)) ms")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(width: 52, alignment: .trailing)
                    }
                }

                field("Switch between", help: "Applications, or individual windows.") {
                    Picker("", selection: $behavior.mode) {
                        Text("Applications").tag(SwitcherMode.apps)
                        Text("Windows").tag(SwitcherMode.windows)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .frame(width: 220)
                }

                field("Order", help: "How tiles are sorted.") {
                    Picker("", selection: $behavior.sortOrder) {
                        ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                field("Window scope", help: "Which Spaces or displays window mode draws from.") {
                    Picker("", selection: $behavior.windowScope) {
                        ForEach(WindowScope.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 220)
                }

                Toggle("Skip minimized windows", isOn: $behavior.skipMinimized)
                    .toggleStyle(.checkbox)
                    .help("Window mode only: leave minimized windows out of the switcher.")
                Toggle("Hide apps with no open windows", isOn: $behavior.hideEmptyApps)
                    .toggleStyle(.checkbox)
                    .help("App mode only. Note: an app whose windows are all minimized counts as empty.")

                Divider()

                favoritesSection

                Divider()

                shortcutsSection

                Divider()

                Toggle("Show menu-bar icon", isOn: $behavior.showMenuBarIcon)
                    .toggleStyle(.checkbox)
                    .help("Off = no menu bar item. Reopen Cmd-Tab from Finder to get Settings back.")
                Toggle("Show current mode in the menu bar", isOn: $behavior.reflectMode)
                    .toggleStyle(.checkbox)
                    .disabled(!behavior.showMenuBarIcon)
                Toggle(
                    "Start at login",
                    isOn: Binding(
                        get: { loginItem.startAtLogin },
                        set: { loginItem.setStartAtLogin($0) }))
                    .toggleStyle(.checkbox)

                Divider()

                HStack {
                    Button("Export…", action: exportSettings)
                    Button("Import…", action: importSettings)
                    Spacer()
                    Button("Reset to Defaults", action: resetSettings)
                }

                Text(
                    "While the switcher is open: type to filter, 1–9 jump, ⌘⌥Q/W/H quit / close / "
                    + "hide, ⌘⌥M minimize, ⌘⌥F zoom, ⌘⌥←→ move to another display, scroll or hover "
                    + "to move, or click a tile.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .onAppear { loginItem.refresh() }
    }

    /// Pinned apps that appear in the switcher (app mode) even when not running, launching on select.
    @ViewBuilder
    private var favoritesSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Favorite apps").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Add…", action: addFavorites)
            }
            Text("Shown in app mode even when not running; picking one launches it.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
            ForEach(favorites.favorites, id: \.self) { id in
                HStack(spacing: 8) {
                    let info = FavoritesStore.appInfo(for: id)
                    Group {
                        if let icon = info?.icon {
                            Image(nsImage: icon).resizable().interpolation(.high)
                        } else {
                            Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                        }
                    }
                    .scaledToFit().frame(width: 18, height: 18)
                    Text(info?.name ?? id).font(.system(size: 12)).lineLimit(1)
                    Spacer()
                    Button {
                        favorites.remove(id)
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    /// Rebindable keys for the in-switcher window actions.
    @ViewBuilder
    private var shortcutsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Switcher shortcuts").font(.system(size: 12, weight: .medium))
                Spacer()
                Button("Reset", action: shortcutsStore.resetToDefaults)
            }
            Text(
                "Keys for the window actions while the switcher is open. ⌘ (the trigger) is held, so "
                + "each also needs ⌥ or ⌃ to stay clear of type-to-filter.")
                .font(.system(size: 10)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(SwitcherAction.allCases) { action in
                HStack {
                    Text(action.title).font(.system(size: 12))
                    Spacer()
                    ActionShortcutRecorder(action: action, store: shortcutsStore)
                }
            }
        }
    }

    private func addFavorites() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to pin as favourites"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            favorites.add(id)
        }
    }

    private func exportSettings() { SettingsIO.export() }
    private func importSettings() { SettingsIO.importSettings() }

    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset all settings to defaults?"
        alert.informativeText = "This clears every Cmd-Tab preference, including excluded apps."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        SettingsIO.reset()
    }

    /// A labelled settings row: caption on the left, control on the right, help underneath.
    @ViewBuilder
    private func field(
        _ title: String, help: String, @ViewBuilder control: () -> some View
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                control()
            }
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

/// Click, then press a combination to rebind the trigger. A modifier (⌘/⌥/⌃) is required, since the
/// switcher stays open only while that modifier is held.
struct HotkeyRecorder: View {
    @Binding var hotkey: Hotkey
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        Button(recording ? "Press keys…" : hotkey.displayString) {
            recording ? stop() : start()
        }
        .frame(width: 220)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            let flags = event.modifierFlags
            // Ignore Escape so there is a way to abort without binding it.
            if event.keyCode == 53 { stop(); return nil }
            let mods = Self.cgFlags(from: flags)
            // A hold-to-open hotkey needs a non-Shift modifier to hold.
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            hotkey = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }
}

/// Records a binding for one in-switcher action: a key plus *extra* modifiers (⌘ is the held
/// trigger, so it is neither recorded nor required). At least ⌥ or ⌃ is required so the binding
/// can't be swallowed by type-to-filter.
struct ActionShortcutRecorder: View {
    let action: SwitcherAction
    @ObservedObject var store: SwitcherShortcutsStore
    @State private var recording = false
    @State private var monitor: Any?

    private var current: ActionShortcut {
        store.shortcuts.bindings[action] ?? action.defaultShortcut
    }

    var body: some View {
        Button(recording ? "Press keys…" : current.displayString) {
            recording ? stop() : start()
        }
        .frame(width: 120)
        .onDisappear(perform: stop)
    }

    private func start() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            if event.keyCode == 53 { stop(); return nil }  // Esc aborts without binding
            let extras = Self.extras(from: event.modifierFlags)
            guard extras.contains(.maskAlternate) || extras.contains(.maskControl) else { return nil }
            store.set(
                ActionShortcut(keyCode: Int(event.keyCode), modifierRaw: extras.rawValue),
                for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        recording = false
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private static func extras(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }
}

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppearanceStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var themes = ThemeStore.shared
    @StateObject private var apps = AppListModel()

    private var metrics: Metrics { appearance.metrics }
    private static let customLabel = "Custom…"

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    themeBar
                    Divider()

                    SliderRow(
                        title: "Icon size",
                        help: "Window mode uses a smaller icon, and scales in step.",
                        value: $appearance.iconSize,
                        range: Metrics.iconSizeRange,
                        step: 8)
                    SliderRow(
                        title: "Icon spacing",
                        help: "Slack around each icon, inside its highlight.",
                        value: $appearance.iconSpacing,
                        range: Metrics.iconSpacingRange,
                        step: 2)
                    SliderRow(
                        title: "Title spacing",
                        help: "Gap between an icon and its name.",
                        value: $appearance.titleSpacing,
                        range: Metrics.titleSpacingRange,
                        step: 1)

                    Divider()

                    HStack {
                        Text("Highlight colour").font(.system(size: 12, weight: .medium))
                        Spacer()
                        ColorPicker("", selection: $behavior.highlightColor, supportsOpacity: false)
                            .labelsHidden()
                    }
                    pickerRow("Appearance", selection: $behavior.panelAppearance) {
                        ForEach(PanelAppearance.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    pickerRow("Position", selection: $behavior.panelPosition) {
                        ForEach(PanelPosition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    pickerRow("Material", selection: $behavior.panelMaterial) {
                        ForEach(PanelMaterial.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    HStack {
                        Text("Opacity").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.panelOpacity, in: 0.3...1.0).frame(width: 160)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Toggle("Custom blur", isOn: $behavior.blurOverride)
                                .toggleStyle(.checkbox)
                            Spacer()
                            Slider(value: $behavior.blurRadius, in: 0...50)
                                .frame(width: 160)
                                .disabled(!behavior.blurOverride)
                        }
                        Text("Override the material's built-in glass blur. 0 = none, 50 = heavy.")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    HStack {
                        Text("Max columns").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Stepper(
                            behavior.maxColumns == 0 ? "Auto" : "\(behavior.maxColumns)",
                            value: $behavior.maxColumns, in: 0...20)
                    }

                    HStack {
                        Text("Corner radius").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.tileCorner, in: 0...24, step: 1).frame(width: 160)
                    }
                    HStack {
                        Text("Title size").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Slider(value: $behavior.titleFontSize, in: 8...16, step: 1).frame(width: 160)
                    }
                    Toggle("Show number badges", isOn: $behavior.showNumbers)
                        .toggleStyle(.checkbox)
                    Toggle("Always show titles under icons", isOn: $behavior.alwaysShowTitles)
                        .toggleStyle(.checkbox)
                        .help("Show each tile's name in app mode too, not just the selected one.")
                    Toggle("Preview windows on hover", isOn: $behavior.windowPreview)
                        .toggleStyle(.checkbox)
                        .help(
                            "App mode: hover a tile to float live thumbnails of that app's windows. "
                                + "Needs Screen Recording permission.")
                        .onChange(of: behavior.windowPreview) {
                            if behavior.windowPreview { Permissions.ensureScreenCaptureForPreview() }
                        }
                    Toggle("Fade the panel in and out", isOn: $behavior.fade)
                        .toggleStyle(.checkbox)
                }
                .padding(12)
            }

            Divider()
            HStack {
                Text("Changes apply live, including to an open switcher.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: appearance.reset)
                    .disabled(appearance.isDefault)
            }
            .padding(12)
        }
    }

    /// A real panel: same glass, same metrics, real icons. The switcher itself cannot be seen
    /// while the settings window is frontmost, so this has to stand in for it faithfully.
    private var preview: some View {
        let tile = metrics.tile(for: .apps)
        let entries = Array(apps.entries.prefix(4))
        return ScrollView([.horizontal, .vertical], showsIndicators: false) {
            VStack(spacing: metrics.titleSpacing) {
                HStack(spacing: Metrics.tileGap) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        PreviewTile(
                            icon: entry.icon,
                            tile: tile,
                            iconSize: metrics.iconSize,
                            isSelected: i == min(1, entries.count - 1),
                            highlightColor: behavior.highlightColor)
                    }
                }
                Text(entries.count > 1 ? entries[1].name : "Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(Metrics.panelPadding)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .fixedSize()
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        // Fixed, so the window does not jump around as the sliders move.
        .frame(height: 210)
        .background(Color.primary.opacity(0.04))
    }

    /// Theme picker plus save/rename/delete/share. The picker reflects the current look: it shows
    /// the matching theme, or "Custom…" once the user has tuned away from every saved one.
    private var themeBar: some View {
        let selection = Binding<String>(
            get: { themes.currentMatch()?.name ?? Self.customLabel },
            set: { name in
                if let theme = themes.all.first(where: { $0.name == name }) { themes.apply(theme) }
            })
        let match = themes.currentMatch()
        let isCustomEditable = match != nil && !(match?.builtIn ?? true)

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Theme").font(.system(size: 12, weight: .medium))
                Spacer()
                Picker("", selection: selection) {
                    ForEach(themes.all) { Text($0.name).tag($0.name) }
                    if match == nil { Text(Self.customLabel).tag(Self.customLabel) }
                }
                .labelsHidden()
                .frame(width: 220)
            }
            HStack(spacing: 6) {
                Button("Save as…", action: saveTheme)
                Button("Rename", action: renameTheme).disabled(!isCustomEditable)
                Button("Delete", action: deleteTheme).disabled(!isCustomEditable)
                Spacer()
                Button("Import…") { themes.importTheme() }
                Button("Export…", action: exportTheme).disabled(match == nil)
            }
            .controlSize(.small)
        }
    }

    private func saveTheme() {
        guard let name = Self.promptName("Save theme as", default: "My Theme") else { return }
        themes.saveAs(name)
    }

    private func renameTheme() {
        guard let theme = themes.currentMatch(),
              let name = Self.promptName("Rename theme", default: theme.name) else { return }
        themes.rename(theme, to: name)
    }

    private func deleteTheme() {
        if let theme = themes.currentMatch() { themes.delete(theme) }
    }

    private func exportTheme() {
        if let theme = themes.currentMatch() { themes.export(theme) }
    }

    private static func promptName(_ title: String, default def: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = def
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let trimmed = field.stringValue.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// A labelled dropdown row matching the slider rows' caption style.
    @ViewBuilder
    private func pickerRow<T: Hashable>(
        _ title: String, selection: Binding<T>, @ViewBuilder content: () -> some View
    ) -> some View {
        HStack {
            Text(title).font(.system(size: 12, weight: .medium))
            Spacer()
            Picker("", selection: selection, content: content)
                .labelsHidden()
                .frame(width: 160)
        }
    }
}

private struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct PreviewTile: View {
    let icon: NSImage?
    let tile: CGSize
    let iconSize: CGFloat
    let isSelected: Bool
    let highlightColor: Color

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .frame(width: tile.width, height: tile.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(highlightColor.opacity(isSelected ? 0.30 : 0))
        }
    }
}

struct ExcludedAppsSettings: View {
    @ObservedObject var store: ExclusionStore
    @StateObject private var apps = AppListModel()
    @State private var query = ""

    private var filtered: [AppEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps.entries }
        return apps.entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A newly excluded app that is not running needs a row of its own, so the list is rebuilt
        // rather than just re-rendered.
        .onChange(of: store.excluded) { apps.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Excluded Apps").font(.system(size: 13, weight: .semibold))
            Text("Apps ticked here never appear in the switcher, in either mode.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            .padding(.top, 8)
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            VStack {
                Spacer()
                Text(query.isEmpty ? "No apps running" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        AppRow(
                            entry: entry,
                            isExcluded: Binding(
                                get: { store.isExcluded(entry.id) },
                                set: { store.setExcluded($0, for: entry.id) }))
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Add App…", action: addApps)
            Spacer()
            Text(store.excluded.isEmpty ? "None excluded" : "\(store.excluded.count) excluded")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Include All", action: store.removeAll)
                .disabled(store.excluded.isEmpty)
        }
        .padding(12)
    }

    /// Lets the user exclude an app that is not running, which by definition cannot be in the list.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to exclude from the switcher"
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            store.setExcluded(true, for: id)
        }
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @Binding var isExcluded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
            .frame(width: 22, height: 22)

            Text(entry.name).font(.system(size: 12)).lineLimit(1)
            if !entry.isRunning {
                Text("not running")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Toggle("", isOn: $isExcluded)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { isExcluded.toggle() }
    }
}

/// Hosts the settings window. Kept alive by the delegate so the window survives being closed.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Cmd-Tab Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // We run as an accessory app, so nothing activates us implicitly: without this the
        // window opens behind the frontmost app and never takes the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
