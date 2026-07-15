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
        item.button?.image = NSImage(
            systemSymbolName: "square.stack.3d.up", accessibilityDescription: "Overtab")
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

        for mode: SwitcherMode in [.apps, .windows] {
            let item = action(mode.title, #selector(selectMode(_:)))
            item.representedObject = mode.rawValue
            item.state = controller.mode == mode ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(.separator())
        menu.addItem(action("Settings…", #selector(openSettingsWindow)))
        menu.addItem(action("Restore System ⌘-Tab", #selector(restoreNative)))
        menu.addItem(action("Quit Overtab", #selector(quit)))
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

    @objc private func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let mode = SwitcherMode(rawValue: raw) else { return }
        controller.mode = mode
        UserDefaults.standard.set(raw, forKey: Defaults.mode)
        refreshMenu()
    }

    @objc private func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openSettingsWindow() {
        settings.show()
    }

    @objc private func restoreNative() {
        SystemSwitcher.restoreNativeIfNeeded()
        refreshMenu()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentTapFailure() {
        let alert = NSAlert()
        alert.messageText = "Overtab could not listen for ⌘-Tab"
        alert.informativeText =
            "Creating the event tap failed. This normally means Accessibility access was granted "
            + "to an older copy of Overtab. Remove Overtab from Privacy & Security → "
            + "Accessibility, then add this copy and relaunch."
        alert.addButton(withTitle: "Open Settings…")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }
}
