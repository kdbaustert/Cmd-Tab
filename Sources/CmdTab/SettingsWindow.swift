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
            AppsSettings(store: .shared, favorites: .shared)
                .tabItem { Label("Apps", systemImage: "square.grid.2x2") }
        }
        .padding(12)
        // Rows are label — spacer — control, so width is what keeps the two columns apart and gives
        // the help text under each row a sensible measure. The controls grew (the same-app cycle row
        // carries a toggle *and* a 220pt recorder), which left the old 470 cramped.
        .frame(width: 620, height: 620)
    }
}

struct GeneralSettings: View {
    @ObservedObject var loginItem: LoginItemStore
    @ObservedObject var behavior: BehaviorStore
    @ObservedObject private var shortcutsStore = SwitcherShortcutsStore.shared

    var body: some View {
        ScrollView {
            // Same treatment as Appearance: one line per control with the explanation as a tooltip,
            // and everything paired into two columns. Each `field` used to carry its help text on a
            // second line, which doubled the height of the pane for prose you read once.
            VStack(alignment: .leading, spacing: 10) {
                // App-level switches first: whether Cmd-Tab is in the menu bar and whether it starts
                // with the session are about the app itself, not about how the switcher behaves, so
                // they read better before the switcher settings than buried after them.
                LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 4) {
                    Toggle("Show menu-bar icon", isOn: $behavior.showMenuBarIcon)
                        .toggleStyle(.checkbox)
                        .help(
                            "Off = no menu bar item. Reopen Cmd-Tab from Finder to get Settings "
                                + "back.")
                    Toggle(
                        "Start at login",
                        isOn: Binding(
                            get: { loginItem.startAtLogin },
                            set: { loginItem.setStartAtLogin($0) }))
                        .toggleStyle(.checkbox)
                }
                // Breathing room around the group and its rule. Checkboxes sit tight against their
                // own text box, so without this they read as crowded into the window's top edge and
                // pressed up against the divider below.
                .padding(.top, 6)
                .padding(.bottom, 12)

                Divider()
                    .padding(.bottom, 8)

                LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 8) {
                    field("Shortcut", help: "Hold to open the switcher; release to switch.") {
                        HotkeyRecorder(hotkey: $behavior.hotkey)
                    }

                    field(
                        "Show delay",
                        help: "Wait before drawing the panel; a quick tap switches with no flash. "
                            + "0 = instant."
                    ) {
                        HStack(spacing: 6) {
                            Slider(value: $behavior.showDelay, in: 0...400, step: 25)
                            Text("\(Int(behavior.showDelay))")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .frame(width: 26, alignment: .trailing)
                        }
                    }

                    field(
                        "Cycle app windows",
                        help: "A second shortcut that shows only the frontmost app's windows. "
                            + "Off by default — the usual ⌘` is a shortcut apps use themselves."
                    ) {
                        HStack(spacing: 6) {
                            Toggle("", isOn: $behavior.sameAppCycle).labelsHidden()
                            HotkeyRecorder(hotkey: $behavior.sameAppHotkey)
                                .disabled(!behavior.sameAppCycle)
                        }
                    }

                    field(
                        "Stay open",
                        help: "Releasing the trigger leaves the switcher up instead of switching. "
                            + "The arrows, ⇧-Tab, scroll and the mouse move the selection; Tab, "
                            + "Return, a click or 1–9 switches to it. Escape backs out."
                    ) {
                        Toggle("", isOn: $behavior.stickyMode).labelsHidden()
                    }

                    field("Order", help: "How tiles are sorted.") {
                        Picker("", selection: $behavior.sortOrder) {
                            ForEach(SortOrder.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        .labelsHidden()
                        .frame(width: 140)
                    }

                }

                LazyVGrid(columns: Self.twoColumns, alignment: .leading, spacing: 4) {
                    Toggle("Hide apps with no windows", isOn: $behavior.hideEmptyApps)
                        .toggleStyle(.checkbox)
                        .help("Note: an app whose windows are all minimized counts as empty.")
                }

                Divider()

                shortcutsSection

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
            // Two per row. Eleven actions stacked one-per-line dominated the pane; paired up they
            // fit the width the window gained and the section stops burying everything below it.
            // A fixed two-column grid rather than an adaptive one so the recorder buttons stay
            // aligned down the pane instead of reflowing with the longest title.
            LazyVGrid(
                columns: [
                    GridItem(.flexible(), spacing: 16, alignment: .leading),
                    GridItem(.flexible(), spacing: 16, alignment: .leading),
                ],
                alignment: .leading, spacing: 6
            ) {
                ForEach(SwitcherAction.allCases) { action in
                    HStack(spacing: 8) {
                        Text(action.title)
                            .font(.system(size: 12))
                            .lineLimit(1)
                        Spacer(minLength: 4)
                        ActionShortcutRecorder(action: action, store: shortcutsStore)
                    }
                }
            }
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

    /// Fixed rather than adaptive, so controls stay aligned down the pane instead of reflowing
    /// around whichever label happens to be longest.
    private static let twoColumns = [
        GridItem(.flexible(), spacing: 18, alignment: .leading),
        GridItem(.flexible(), spacing: 18, alignment: .leading),
    ]

    /// Label and control on one line, with the explanation as a tooltip rather than a second line.
    private func field(
        _ title: String, help: String, @ViewBuilder control: () -> some View
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 4)
            control()
        }
        .help(help)
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
