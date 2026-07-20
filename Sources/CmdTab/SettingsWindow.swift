import AppKit
import SwiftUI
import UniformTypeIdentifiers

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
                    "Stay open",
                    help: "Keep the switcher up after the modifier is released; pick with a click "
                        + "or Return. Escape always closes it, as does clicking away."
                ) {
                    Toggle("", isOn: $behavior.stickyMode).labelsHidden()
                }

                field(
                    "Cycle app windows",
                    help: "A second shortcut that shows only the frontmost app's windows. "
                        + "Off by default — the usual ⌘` is a shortcut apps use themselves."
                ) {
                    HStack(spacing: 8) {
                        Toggle("", isOn: $behavior.sameAppCycle).labelsHidden()
                        HotkeyRecorder(hotkey: $behavior.sameAppHotkey)
                            .disabled(!behavior.sameAppCycle)
                    }
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
