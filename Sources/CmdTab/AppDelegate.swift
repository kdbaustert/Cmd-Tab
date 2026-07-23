import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SwitcherController()
    private let settings = SettingsPresenter()
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Before any store is touched: the first read of one is what would bake in the defaults.
        Migration.run()

        // Seeded before the mode is set, so the very first refresh already honours exclusions.
        let store = ExclusionStore.shared
        controller.excludedBundleIDs = store.excluded
        store.onChange = { [weak self] excluded in
            self?.controller.excludedBundleIDs = excluded
        }

        // Settings written before favourites and exclusions shared a pane can set both on one app.
        // Nothing reconciles them here: the provider already drops an excluded app from the launch
        // tiles, so exclusion wins without either key having to be rewritten.
        let favorites = FavoritesStore.shared
        controller.favoriteBundleIDs = favorites.favorites
        favorites.onChange = { [weak self] ids in
            self?.controller.favoriteBundleIDs = ids
        }

        let shortcuts = SwitcherShortcutsStore.shared
        controller.shortcuts = shortcuts.shortcuts
        shortcuts.onChange = { [weak self] bindings in
            self?.controller.shortcuts = bindings
        }

        let appearance = AppearanceStore.shared
        controller.metrics = appearance.metrics
        appearance.onChange = { [weak self] metrics in
            self?.controller.metrics = metrics
        }

        let behavior = BehaviorStore.shared
        applyBehavior(behavior)
        behavior.onChange = { [weak self] in
            self?.applyBehavior(behavior)
        }

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
                // Now trusted: re-evaluate the icon so a user who chose to hide it gets their wish.
                self?.updateStatusItem(BehaviorStore.shared)
                self?.refreshMenu()
            }
            refreshMenu()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stop()
    }

    /// Relaunching from Finder (or `open`) while already running opens Settings. This is the way
    /// back when the menu-bar icon has been hidden — otherwise there would be no visible affordance.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        settings.show()
        return true
    }

    /// Pushes every tunable in `BehaviorStore` onto the running switcher. Cheap enough to run
    /// wholesale on any change rather than tracking which field moved.
    private func applyBehavior(_ behavior: BehaviorStore) {
        controller.sortOrder = behavior.sortOrder
        controller.hideEmptyApps = behavior.hideEmptyApps
        controller.panelAppearance = behavior.panelAppearance
        controller.panelPosition = behavior.panelPosition
        controller.highlightColor = behavior.highlightColor
        controller.showNumbers = behavior.showNumbers
        controller.showBadges = behavior.showBadges
        controller.notificationBadges = behavior.notificationBadges
        controller.tileCorner = behavior.tileCorner
        controller.titleFontSize = behavior.titleFontSize
        controller.titleFontName = behavior.titleFontName
        controller.fade = behavior.fade
        controller.panelMaterial = behavior.panelMaterial
        controller.panelBlur = behavior.blurOverride ? behavior.blurRadius : nil
        controller.maxColumns = behavior.maxColumns
        controller.showDelay = behavior.showDelay / 1000
        controller.windowPreview = behavior.windowPreview
        controller.hotkey = behavior.hotkey
        controller.sameAppHotkey = behavior.sameAppCycle ? behavior.sameAppHotkey : nil
        controller.stickyMode = behavior.stickyMode
        controller.panelScreens = behavior.panelScreens
        updateStatusItem(behavior)
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

    /// Creates, removes, or restyles the menu-bar item to match settings. Hidden entirely when the
    /// user turns it off; the app is then reachable only through the shortcut (reopening it from
    /// Finder brings the settings window back — see `applicationShouldHandleReopen`).
    private func updateStatusItem(_ behavior: BehaviorStore) {
        // Keep the item when Accessibility is not trusted even if the user hid it: the menu is the
        // only in-app path to the "Open Accessibility Settings…" recovery item, and without it a
        // permission reset would leave the switcher dead with no way back.
        guard behavior.showMenuBarIcon || !Permissions.isTrusted else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem
            ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Template PNGs (cmdtabTemplate.png + @2x/@3x) ship loose in the bundle Resources; AppKit
        // resolves the scale variants by name. Marked as a template so it tints for light/dark menu bars.
        let icon = NSImage(named: "cmdtabTemplate")
        icon?.isTemplate = true
        item.button?.image = icon
        // Optionally spell out the current mode next to the icon.
        item.button?.title = ""
        item.button?.imagePosition = .imageOnly
        if item.menu == nil { item.menu = NSMenu() }
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

        // Opens a session that stays up without a held chord — the only way in for anyone who can't
        // comfortably hold one, and useful for browsing the list with the mouse.
        if controller.isRunning {
            menu.addItem(action("Open Switcher", #selector(openSwitcher)))
            menu.addItem(.separator())
        }

        menu.addItem(action("About Cmd-Tab", #selector(showAbout)))
        menu.addItem(action("Settings…", #selector(openSettingsWindow)))
        menu.addItem(action("Quit Cmd-Tab", #selector(quit)))
    }

    @objc private func openSwitcher() {
        controller.openSticky()
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
