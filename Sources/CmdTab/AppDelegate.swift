import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SwitcherController()
    private let settings = SettingsPresenter()
    private var statusItem: NSStatusItem?
    private var signalSources: [DispatchSourceSignal] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // First, so the measurement covers launch too — the busiest the main thread ever gets, and
        // the one stretch where a stall is expected rather than alarming. See the type.
        MainLoopMonitor.start()

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

        let tiling = WindowTilingStore.shared
        controller.tiling = tiling.tiling
        controller.mouseDrag = tiling.mouseDrag
        tiling.onChange = { [weak self] bindings in
            self?.controller.tiling = bindings
        }
        tiling.onMouseDragChange = { [weak self] settings in
            self?.controller.mouseDrag = settings
        }

        let globals = GlobalActionsStore.shared
        applyGlobalActions(globals)
        globals.onChange = { [weak self] in
            self?.applyGlobalActions(globals)
        }

        let appRules = AppRulesStore.shared
        controller.appRules = appRules.rules
        appRules.onChange = { [weak self] rules in
            self?.controller.appRules = rules
        }

        let scoped = ScopedTriggersStore.shared
        controller.scopedTriggers = scoped.scoped
        scoped.onChange = { [weak self] triggers in
            self?.controller.scopedTriggers = triggers
        }

        let shortcuts = SwitcherShortcutsStore.shared
        applySwitcherShortcuts(shortcuts)
        shortcuts.onChange = { [weak self] _ in
            self?.applySwitcherShortcuts(shortcuts)
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

        // After the stores are wired: enabling this reads the file straight into them, and the
        // observer it installs must not fire against half-built state.
        ConfigFile.shared.start()

        // Catalogued off the main thread now, so the first query that needs it does not pay for a
        // few hundred Info.plist reads mid-keystroke.
        InstalledApps.warm()

        // Sparkle's scheduled check does not exist until the updater object does, and the only
        // thing that ever built one was `AboutSettings`' stored property — a view constructed only
        // when the About tab is selected, which is not the tab Settings opens on. So a user who
        // never went looking for the version number never got a background check at all, which is
        // the whole of the feature. Constructed here, once, on the main thread at launch.
        //
        // Skipped for a `build.sh` bundle: it has no feed and no public key, so an updater there
        // could only fail on a timer. See `Updater.isConfigured`, which is static precisely so this
        // question can be asked without building the thing it gates.
        if Updater.isConfigured { _ = Updater.shared }

        // Same reason, from the main thread: the Desktop-transition observer a cross-Desktop pick
        // waits on should not be registered from inside the pick that first needs it.
        SwitchTarget.warmSpaceTracking()

        installSignalHandlers()

        Log.general.notice(
            "launched: pid=\(ProcessInfo.processInfo.processIdentifier) trusted=\(Permissions.isTrusted) path=\(Bundle.main.bundlePath, privacy: .public)")

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
        // One value rather than twenty-six assignments, so the controller can see the settings
        // together and rebuild the list at most once — see `SwitcherController.apply`. This method
        // runs on every `BehaviorStore` notification, which an unstepped slider posts once per drag
        // tick.
        controller.apply(
            SwitcherSettings(
                mode: behavior.mode,
                sortOrder: behavior.sortOrder,
                hideEmptyApps: behavior.hideEmptyApps,
                pinFavoritesFirst: behavior.pinFavoritesFirst,
                notificationBadges: behavior.notificationBadges,
                layout: behavior.layout,
                panelAppearance: behavior.panelAppearance,
                panelPosition: behavior.panelPosition,
                panelScreens: behavior.panelScreens,
                maxColumns: behavior.maxColumns,
                fade: behavior.fade,
                windowPreview: behavior.windowPreview,
                windowThumbnailTiles: behavior.windowThumbnailTiles,
                highlightColor: behavior.highlightColor,
                showNumbers: behavior.showNumbers,
                showDisplayBadges: behavior.showDisplayBadges,
                showSpaceBadges: behavior.showSpaceBadges,
                tileCorner: behavior.tileCorner,
                titleFontName: behavior.titleFontName,
                titleFontSize: behavior.titleFontSize,
                panelMaterial: behavior.panelMaterial,
                panelBlur: behavior.blurOverride ? behavior.blurRadius : nil,
                // Stored in milliseconds, used in seconds.
                showDelay: behavior.showDelay / 1000,
                launchFromSearch: behavior.launchFromSearch,
                stickyMode: behavior.stickyMode,
                hotkey: behavior.hotkey,
                sameAppHotkey: behavior.sameAppCycle ? behavior.sameAppHotkey : nil))
        // Not a controller field: the tracing is spread across types that have no view of the
        // stores, so the level lives on `Log` and is pushed here with everything else.
        Log.isVerbose = behavior.verboseLogging
        updateStatusItem(behavior)
    }

    private func applyGlobalActions(_ store: GlobalActionsStore) {
        controller.activations = store.activations
        controller.allWindows = store.allWindows
    }

    /// The in-switcher window actions. `actionsEnabled` is set before the bindings, so the shadow
    /// warning the bindings' `didSet` runs sees the switch it is conditioned on.
    private func applySwitcherShortcuts(_ store: SwitcherShortcutsStore) {
        controller.actionsEnabled = store.isEnabled
        controller.confirmsDestructiveActions = store.confirmsDestructive
        controller.shortcuts = store.shortcuts
    }

    private func startController() {
        if !controller.start() {
            presentTapFailure()
        }
        // The keyboard tap is not the only thing that needed the grant. Both mouse gestures are
        // installed from settings pushed in `init`, which on a first run happens before the user has
        // answered the system prompt — and neither is re-pushed afterwards, so without this they
        // stay dead until the app is relaunched.
        controller.retryMouseGestures()
        refreshMenu()
        watchForRevokedTrust()
    }

    /// Notices Accessibility being taken away while the app is running, and puts it back afterwards.
    ///
    /// Trust used to be asked about exactly once, at launch, on the branch that did *not* have it —
    /// `waitForTrust` returns immediately when already trusted, so a process that launched trusted
    /// never installed a poll and nothing else in the app watched `AXIsProcessTrusted()`. After a
    /// revoke the switcher went dead machine-wide and stayed dead: the tap is non-nil, so `start()`
    /// early-returns; `restoreNativeIfNeeded` runs only from `stop()`, so the native ⌘-Tab stayed
    /// suppressed too; and `refreshMenu` was never re-run, so the "Open Accessibility Settings…"
    /// item — the only in-app route back — was never built. Re-ticking the box did nothing, and
    /// only a relaunch fixed it, which nothing told the user.
    ///
    /// `stop()` first, because it is what nils the tap and hands ⌘-Tab back; `startController()`
    /// then rebuilds everything and re-arms this watch. The status item is re-evaluated in both
    /// directions because its guard keeps the icon visible while untrusted even for a user who hid
    /// it — the comment on that guard has always described this scenario, and this is what finally
    /// makes it true.
    ///
    /// Polled, because there is no notification for it. Slower than `waitForTrust`'s second: this
    /// one runs for the life of a healthy process, where that one runs only until a user answers a
    /// prompt.
    private func watchForRevokedTrust() {
        trustWatch?.invalidate()
        trustWatch = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, !Permissions.isTrusted else { return }
                Log.general.error("accessibility trust revoked; stopping until it is granted again")
                self.trustWatch?.invalidate()
                self.trustWatch = nil
                self.controller.stop()
                self.updateStatusItem(BehaviorStore.shared)
                self.refreshMenu()
                Permissions.waitForTrust { [weak self] in
                    Log.general.notice("trust restored; starting")
                    self?.startController()
                    self?.updateStatusItem(BehaviorStore.shared)
                }
            }
        }
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
    /// The repeating trust check armed by `startController`. Held so a restart can replace it
    /// rather than stack a second one.
    private var trustWatch: Timer?

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
        // Template PNGs ship loose in the bundle Resources; AppKit resolves the scale variants by
        // name. `MenuBarIcon.image` flags them as templates so they tint for light/dark menu bars.
        item.button?.image = behavior.menuBarIcon.image
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

        // No About item: the version, the permissions and the description all live in Settings →
        // About now, which is one place to look rather than a menu item and a modal panel.
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
