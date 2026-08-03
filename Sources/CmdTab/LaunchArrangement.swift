import AppKit
import ApplicationServices

/// Snaps an app's first window to a chosen arrangement as it opens — the `launchArrangement` half of
/// `AppRule`.
///
/// The whole difficulty is timing. `didLaunchApplicationNotification` fires when the *process* is
/// up, which is well before it has drawn anything: asking for its windows there returns an empty
/// list every time. There is no notification for "this app now has a window", so this polls, which
/// is the same shape `SwitchTarget.settle` uses for a Space transition and for the same reason —
/// the wait has no fixed length, and a delay long enough for the slowest app would be visible on
/// every fast one.
///
/// Deliberately fires once per launch and never again. Tiling an app's *second* window would fight
/// the user, who by then is arranging things themselves.
@MainActor
final class LaunchArrangementWatcher {
    /// Per-app rules, pushed by the controller.
    var appRules: [String: AppRule] = [:]
    /// Gap to leave around the tiled window, from the tiling settings.
    var gap: CGFloat = 0

    /// How long to keep looking for a first window, as attempts × delay. Ten seconds is chosen for
    /// the slow end of real apps — a cold-cache Xcode or a JetBrains IDE — and costs nothing on the
    /// common case, because the poll stops the moment a window appears.
    private static let attempts = 50
    private static let delay: TimeInterval = 0.2

    /// pids being watched, so a relaunch storm cannot stack several polls on one app.
    private var watching: Set<pid_t> = []

    init() {
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)
    }

    deinit { NSWorkspace.shared.notificationCenter.removeObserver(self) }

    @objc private func appLaunched(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            app.activationPolicy == .regular,
            let bundleID = app.bundleIdentifier,
            let rule = appRules[bundleID],
            let arrangement = rule.launchArrangement
        else { return }
        // `neverTile` is the stronger statement of the two, and a rule holding both is contradictory
        // rather than impossible — an imported or hand-edited config can say it. Refusing to tile is
        // the reading that cannot surprise anyone.
        guard !rule.neverTile else {
            Log.general.notice(
                "launch arrangement: \(bundleID, privacy: .public) is also set to never tile; skipping")
            return
        }
        let pid = app.processIdentifier
        guard watching.insert(pid).inserted else { return }
        Log.general.notice(
            "launch arrangement: watching \(bundleID, privacy: .public) for \(arrangement.rawValue, privacy: .public)")
        poll(pid: pid, arrangement: arrangement, remaining: Self.attempts)
    }

    /// Waits for the app to own a switchable window, then tiles it.
    ///
    /// The window is only *counted* here — `WindowTiler.apply` finds it again on its own queue. This
    /// is a readiness check, not a handle to pass along: an `AXUIElement` captured now can be
    /// replaced by the app between the poll and the tile (Electron hosts swap their first window
    /// out), and the tiler's `AX.frontWindow` re-read is what makes it the window on screen.
    private func poll(pid: pid_t, arrangement: WindowArrangement, remaining: Int) {
        guard remaining > 0 else {
            watching.remove(pid)
            Log.general.notice(
                "launch arrangement: pid \(pid, privacy: .public) drew no window in time; giving up")
            return
        }
        // The app can quit, or be force-quit, while its own poll is still running.
        guard let app = NSRunningApplication(processIdentifier: pid), !app.isTerminated else {
            watching.remove(pid)
            return
        }
        guard hasSwitchableWindow(pid: pid) else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
                self?.poll(pid: pid, arrangement: arrangement, remaining: remaining - 1)
            }
            return
        }
        watching.remove(pid)
        Log.general.notice(
            "launch arrangement: applying \(arrangement.rawValue, privacy: .public) to pid \(pid, privacy: .public)")
        // `cycleWidths: false` — the width cycle is a response to pressing the same chord twice, and
        // there is no second press here. Left on, a launch would consume the first step of the cycle
        // and the user's first real chord would land on the second.
        WindowTiler.apply(
            arrangement, pid: pid, areas: WindowTiler.visibleAreas(),
            cycleWidths: false, gap: gap)
    }

    /// Whether the app owns a window worth tiling. The role filter is what keeps a splash screen or
    /// a lone dialog from being treated as the app's real window and snapped into a corner.
    private func hasSwitchableWindow(pid: pid_t) -> Bool {
        AX.windows(of: AX.application(pid)).contains(where: AX.isSwitchableWindow)
    }
}
