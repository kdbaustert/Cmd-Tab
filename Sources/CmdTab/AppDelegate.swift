import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SwitcherController()
    private let settings = SettingsWindowController()
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []

    private enum Defaults {
        static let mode = "mode"
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any store is touched: the first read of one is what would bake in the defaults.
        Migration.run()

        // Seeded before the mode is set, so the very first refresh already honours exclusions.
        let store = ExclusionStore.shared
        controller.excludedBundleIDs = store.excluded
        store.onChange = { [weak self] excluded in
            self?.controller.excludedBundleIDs = excluded
        }

        let appearance = AppearanceStore.shared
        controller.metrics = appearance.metrics
        appearance.onChange = { [weak self] metrics in
            self?.controller.metrics = metrics
        }

        controller.mode =
            UserDefaults.standard.string(forKey: Defaults.mode)
            .flatMap(SwitcherMode.init(rawValue:)) ?? .apps

        installStatusItem()
        installSignalHandlers()

        Log.general.notice(
            "launched: pid=\(ProcessInfo.processInfo.processIdentifier) trusted=\(Permissions.isTrusted) path=\(Bundle.main.bundlePath)")

        if Permissions.isTrusted {
            startController()
        } else {
            Permissions.promptForTrust()
            Permissions.waitForTrust { [weak self] in
                Log.general.notice("trust acquired; starting")
                self?.startController()
                self?.refreshMenu()
            }
            refreshMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    private func startController() {
        if !controller.start() {
            presentTapFailure()
        }
        refreshMenu()
    }

    /// Leaving the system switcher disabled after we exit would strand the user with no ⌘-Tab
    /// at all, so catch the signals a `kill` or a Ctrl-C would send. Nothing can be done about
    /// SIGKILL or a crash — logging out restores it, since the window server never persists
    /// this to disk.
    private func installSignalHandlers() {
        for sig in [SIGINT, SIGTERM, SIGHUP] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { [weak self] in
                self?.controller.stop()
                NSApp.terminate(nil)
            }
            source.resume()
            signalSources.append(source)
        }
    }

    // MARK: - Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Template PNGs (cmdtabTemplate.png + @2x/@3x) ship loose in the bundle Resources; AppKit
        // resolves the scale variants by name. Marked as a template so it tints for light/dark menu bars.
        let icon = NSImage(named: "cmdtabTemplate")
        icon?.isTemplate = true
        item.button?.image = icon
        item.menu = NSMenu()
        statusItem = item
        refreshMenu()
    }

    private func refreshMenu() {
        guard let menu = statusItem?.menu else { return }
        menu.removeAllItems()

        if !Permissions.isTrusted {
            menu.addItem(disabled("Waiting for Accessibility access"))
            menu.addItem(
                action("Open Accessibility Settings…", #selector(openSettings)))
            menu.addItem(.separator())
        } else if !controller.isRunning {
            menu.addItem(disabled("Not running — event tap unavailable"))
            menu.addItem(.separator())
        } else if !SystemSwitcher.isNativeDisabled {
            menu.addItem(disabled("Running — system ⌘-Tab still active"))
            menu.addItem(.separator())
        }

        menu.addItem(action("About Cmd-Tab", #selector(showAbout)))
        menu.addItem(action("Settings…", #selector(openSettingsWindow)))
        menu.addItem(action("Quit Cmd-Tab", #selector(quit)))
    }

    private func disabled(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openSettingsWindow() {
        settings.show()
    }

    @objc private func showAbout() {
        // LSUIElement apps aren't active by default; without this the panel opens behind other windows.
        NSApp.activate(ignoringOtherApps: true)
        // An agent app has no Dock icon, so applicationIconImage defaults to a generic placeholder in
        // the About panel. Point it at our bundled AppIcon so the real icon shows.
        if let icon = NSImage(named: "AppIcon") {
            NSApp.applicationIconImage = icon
        }
        let credits = NSAttributedString(
            string: "A ⌘-Tab replacement for macOS. Switches between applications or individual "
                + "windows, toggleable from the menu bar.",
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
            ])
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Cmd-Tab",
            .credits: credits,
        ])
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentTapFailure() {
        let alert = NSAlert()
        alert.messageText = "Cmd-Tab could not listen for ⌘-Tab"
        alert.informativeText =
            "Creating the event tap failed. This normally means Accessibility access was granted "
            + "to an older copy of Cmd-Tab. Remove Cmd-Tab from Privacy & Security → "
            + "Accessibility, then add this copy and relaunch."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}
