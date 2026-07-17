import AppKit
import ApplicationServices

/// Builds the switcher list and keeps it in most-recently-used order.
///
/// macOS exposes no MRU ordering, so we keep our own: seeded from the on-screen window
/// z-order at launch, then maintained from activation notifications.
///
/// Enumeration is cached. Every Accessibility call is IPC to another process, and the switcher
/// is driven from an event tap that must never stall, so `snapshot()` returns the cache
/// instantly and `refresh()` updates it off the main thread.
final class TargetProvider {
    private var mru: [pid_t] = []
    private var cache: [SwitchTarget] = []
    private let axQueue = DispatchQueue(label: "com.cmdtab.accessibility", qos: .userInteractive)

    var mode: SwitcherMode = .apps

    /// How tiles are ordered. Recently-used keeps the MRU list; alphabetical ignores it.
    var sortOrder: SortOrder = .recentlyUsed

    /// Window mode only: drop minimized windows entirely rather than showing them dimmed.
    var skipMinimized: Bool = false

    /// Window mode only: which Spaces/displays the windows may come from.
    var windowScope: WindowScope = .allSpaces

    /// App mode only: hide apps that own no on-screen window.
    var hideEmptyApps: Bool = false

    /// Bundle identifiers the user has excluded. Applied in both modes, so excluding an app also
    /// takes all of its windows out of window mode.
    var excludedBundleIDs: Set<String> = []

    init() {
        mru = Self.zOrderedPIDs()
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
            NSWorkspace.didHideApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification,
        ] {
            center.addObserver(
                self, selector: #selector(workspaceChanged(_:)), name: name, object: nil)
        }
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func workspaceChanged(_ note: Notification) {
        if note.name == NSWorkspace.didActivateApplicationNotification,
           let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication {
            touch(app.processIdentifier)
        }
        refresh()
    }

    private func touch(_ pid: pid_t) {
        mru.removeAll { $0 == pid }
        mru.insert(pid, at: 0)
    }

    /// Whatever we last computed. Never blocks.
    func snapshot() -> [SwitchTarget] { cache }

    /// Recomputes the list off-thread, then hands the result back on main.
    func refresh(then handler: (([SwitchTarget]) -> Void)? = nil) {
        let mode = self.mode
        let sortOrder = self.sortOrder
        let skipMinimized = self.skipMinimized
        let scope = self.windowScope
        let hideEmptyApps = self.hideEmptyApps
        let apps = switchableApps()
        let order = mru
        // NSScreen is main-thread-only, so resolve the active screen's CG rect here — but only when
        // the active-display scope actually needs it.
        let activeScreenCG = (mode == .windows && scope == .activeDisplay)
            ? Self.activeScreenCGFrame() : nil

        axQueue.async { [weak self] in
            var targets: [SwitchTarget]
            switch mode {
            case .apps:
                targets = Self.appTargets(apps, order: order, sortOrder: sortOrder)
                if hideEmptyApps {
                    // Windows on ANY Space, so a fullscreen app (which lives on its own Space) still
                    // counts as non-empty rather than being dropped.
                    let owning = Self.windowOwningPIDs()
                    targets.removeAll { !owning.contains($0.pid) }
                }
            case .windows:
                targets = Self.windowTargets(apps, order: order, sortOrder: sortOrder)
                if skipMinimized { targets.removeAll { $0.isMinimized } }
                if scope != .allSpaces {
                    targets = Self.scoped(
                        targets, scope: scope,
                        onScreenBounds: Self.onScreenBounds(), activeScreen: activeScreenCG)
                }
            }
            DispatchQueue.main.async {
                self?.cache = targets
                handler?(targets)
            }
        }
    }

    // MARK: - Space / display scoping

    /// Window bounds for everything on screen in the current Space, keyed by `CGWindowID` so callers
    /// can match against a target's parsed id. Layer-0 windows only; no Screen Recording needed.
    private static func onScreenBounds() -> [CGWindowID: CGRect] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        var bounds: [CGWindowID: CGRect] = [:]
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let number = window[kCGWindowNumber as String] as? CGWindowID,
                  let rect = window[kCGWindowBounds as String] as? [String: CGFloat],
                  let cg = CGRect(dictionaryRepresentation: rect as CFDictionary) else { continue }
            bounds[number] = cg
        }
        return bounds
    }

    /// PIDs owning at least one real window on ANY Space (no on-screen restriction). Used by the
    /// "hide apps with no open windows" filter so fullscreen / other-Space apps are not dropped.
    private static func windowOwningPIDs() -> Set<pid_t> {
        guard let info = CGWindowListCopyWindowInfo(
            [.excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return [] }
        var pids = Set<pid_t>()
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            pids.insert(pid)
        }
        return pids
    }

    /// Filters window targets to the current Space (present in the on-screen list) or the active
    /// display (bounds centred on it). Minimized windows are always kept — they belong to a Space
    /// we cannot see, and dropping them would strand them. Windows whose id could not be resolved
    /// are kept too: better a stray tile than a missing one.
    private static func scoped(
        _ targets: [SwitchTarget], scope: WindowScope,
        onScreenBounds: [CGWindowID: CGRect], activeScreen: CGRect?
    ) -> [SwitchTarget] {
        targets.filter { target in
            if target.isMinimized { return true }
            guard let id = windowID(fromTargetID: target.id) else { return true }
            switch scope {
            case .allSpaces:
                return true
            case .currentSpace:
                return onScreenBounds[id] != nil
            case .activeDisplay:
                guard let bounds = onScreenBounds[id], let screen = activeScreen else { return true }
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                return screen.contains(center)
            }
        }
    }

    /// The active screen (the one owning the frontmost window, else under the cursor) in CoreGraphics
    /// top-left coordinates, to match `CGWindowList` bounds.
    private static func activeScreenCGFrame() -> CGRect? {
        let screen = NSScreen.main
            ?? NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.screens.first
        guard let screen else { return nil }
        // The flip reference is the primary display — the one at AppKit origin (0,0) — not merely
        // the first in the array, which need not be primary on a multi-display setup.
        let primary = NSScreen.screens.first { $0.frame.origin == .zero } ?? screen
        let f = screen.frame
        // Flip AppKit (bottom-left) to CG (top-left) using the primary display's height.
        return CGRect(
            x: f.origin.x, y: primary.frame.height - f.origin.y - f.height,
            width: f.width, height: f.height)
    }

    /// Parses the `CGWindowID` back out of a `"win:<id>"` target id, if it carries one.
    private static func windowID(fromTargetID id: String) -> CGWindowID? {
        let parts = id.split(separator: ":")
        guard parts.count == 2, parts[0] == "win", let value = UInt32(parts[1]) else { return nil }
        return value
    }

    // MARK: - App list

    /// Metadata snapshotted on the main thread; `NSRunningApplication` is not safe to poke at
    /// from the Accessibility queue.
    private struct AppInfo {
        let pid: pid_t
        let name: String
        let icon: NSImage?
        let isHidden: Bool
    }

    private func switchableApps() -> [AppInfo] {
        let mine = ProcessInfo.processInfo.processIdentifier
        let excluded = excludedBundleIDs
        return NSWorkspace.shared.runningApplications.compactMap { app in
            guard app.activationPolicy == .regular,
                  app.processIdentifier != mine,
                  !app.isTerminated else { return nil }
            // An app with no bundle identifier can't be excluded — there is nothing stable to
            // key the exclusion on — so it always stays in the list.
            if let bundleID = app.bundleIdentifier, excluded.contains(bundleID) { return nil }
            return AppInfo(
                pid: app.processIdentifier,
                name: app.localizedName ?? "Unknown",
                icon: app.icon,
                isHidden: app.isHidden)
        }
    }

    /// Apps that currently own an on-screen window, front to back. Only used to seed the MRU
    /// list at launch — this needs no Screen Recording permission because we read pids and
    /// layers, never window titles.
    private static func zOrderedPIDs() -> [pid_t] {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let info = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return [] }

        var seen = Set<pid_t>()
        var ordered: [pid_t] = []
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if seen.insert(pid).inserted { ordered.append(pid) }
        }
        return ordered
    }

    private static func sorted(
        _ apps: [AppInfo], by order: [pid_t], sortOrder: SortOrder
    ) -> [AppInfo] {
        if sortOrder == .alphabetical {
            return apps.sorted {
                $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        // `uniquingKeysWith` rather than `uniqueKeysWithValues`: a duplicate pid should never
        // reach here, but the strict initializer would trap on it, and trapping inside the
        // switcher would take the whole app down mid-⌘-Tab.
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: min)
        return apps.enumerated().sorted { a, b in
            let ra = rank[a.element.pid] ?? Int.max
            let rb = rank[b.element.pid] ?? Int.max
            // Fall back to the workspace's own ordering so the sort stays stable.
            return ra == rb ? a.offset < b.offset : ra < rb
        }.map(\.element)
    }

    // MARK: - Target construction

    private static func appTargets(
        _ apps: [AppInfo], order: [pid_t], sortOrder: SortOrder
    ) -> [SwitchTarget] {
        sorted(apps, by: order, sortOrder: sortOrder).map { app in
            SwitchTarget(
                id: "app:\(app.pid)",
                kind: .app(app.pid),
                title: app.name,
                appName: app.name,
                icon: app.icon,
                isMinimized: false,
                isHidden: app.isHidden)
        }
    }

    private static func windowTargets(
        _ apps: [AppInfo], order: [pid_t], sortOrder: SortOrder
    ) -> [SwitchTarget] {
        sorted(apps, by: order, sortOrder: sortOrder).flatMap { app -> [SwitchTarget] in
            // `AX.application` applies the messaging timeout: a wedged app must not wedge the
            // switcher with it.
            let windows = AX.windows(of: AX.application(app.pid))

            return windows.enumerated().compactMap { index, window in
                guard AX.isSwitchableWindow(window) else { return nil }

                let title = AX.copyString(window, kAXTitleAttribute) ?? ""
                let minimized = AX.isMinimized(window)
                let id = windowID(window).map { "win:\($0)" } ?? "win:\(app.pid):\(index)"

                return SwitchTarget(
                    id: id,
                    kind: .window(app.pid, window),
                    title: title.isEmpty ? app.name : title,
                    appName: app.name,
                    icon: app.icon,
                    isMinimized: minimized,
                    isHidden: app.isHidden)
            }
        }
    }

    // MARK: - Accessibility helpers

    /// `_AXUIElementGetWindow` is private but gives us a stable identity for each window, which
    /// keeps SwiftUI from re-animating tiles on every refresh. Falls back to a positional id.
    private typealias GetWindowFn = @convention(c) (AXUIElement, UnsafeMutablePointer<CGWindowID>)
        -> AXError

    private static let getWindow: GetWindowFn? = {
        // The global handle only exposes it once ApplicationServices is actually loaded, so
        // fall back to the framework by path.
        let paths: [String?] = [
            nil,
            "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "_AXUIElementGetWindow") else { continue }
            return unsafeBitCast(symbol, to: GetWindowFn.self)
        }
        return nil
    }()

    private static func windowID(_ window: AXUIElement) -> CGWindowID? {
        guard let getWindow else { return nil }
        var id: CGWindowID = 0
        guard getWindow(window, &id) == .success, id != 0 else { return nil }
        return id
    }

    /// The `CGWindowID`s of an app's switchable windows, in Accessibility order (front-to-back) so
    /// the hover preview can match window mode's ordering. This is the set window mode shows, so it
    /// already excludes the phantom backing windows Electron/Catalyst apps expose. May come back
    /// empty — or fail to line up with the captured windows — for apps whose AX windows don't map to
    /// a resolvable `CGWindowID`; the caller falls back accordingly. Runs Accessibility IPC, so keep
    /// it off the tap.
    static func switchableWindowIDs(for pid: pid_t) -> [CGWindowID] {
        AX.windows(of: AX.application(pid)).filter(AX.isSwitchableWindow).compactMap(windowID)
    }
}
