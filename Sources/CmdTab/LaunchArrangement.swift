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
///
/// The poll's *state* lives on the main actor; the readiness check itself does not — see `axQueue`.
@MainActor
final class LaunchArrangementWatcher {
    /// Where the readiness check runs.
    ///
    /// `hasSwitchableWindow` is Accessibility IPC, several round-trips of it, aimed at an app that
    /// launched moments ago — the least likely thing on the machine to answer promptly, and each
    /// call can burn the full `AX` messaging timeout. Run on the main thread that is the run loop
    /// servicing the keyboard event tap, and a tap that overruns the system's deadline is disabled
    /// outright, taking every keystroke on the machine with it until it is switched back on. Same
    /// rule as every other Accessibility call in this app; this one used to be the exception.
    ///
    /// `.userInitiated` to match `WindowTiler.queue`, which is what a ready app is handed to.
    private static let axQueue = DispatchQueue(
        label: "com.cmdtab.launcharrangement", qos: .userInitiated)

    /// Per-app rules, pushed by the controller.
    var appRules: [String: AppRule] = [:]
    /// Per-window rules, unioned with `appRules`'s `neverTile`: a first window whose title a rule
    /// marks `.neverTile` is left where its app put it, even on an app with a launch arrangement.
    var titleRules: [CompiledTitleRule] = []
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
        // The rule lookup before the policy read: `activationPolicy` is a LaunchServices round trip,
        // and this runs on the main thread for every app that launches while most have no rule.
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
            let bundleID = app.bundleIdentifier,
            let rule = appRules[bundleID],
            let arrangement = rule.launchArrangement,
            app.activationPolicy == .regular
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
        poll(pid: pid, arrangement: arrangement, launchDisplay: rule.launchDisplay, remaining: Self.attempts)
    }

    /// Waits for the app to own a switchable window, then tiles it.
    ///
    /// The window is only *counted* here — `WindowTiler.apply` finds it again on its own queue. This
    /// is a readiness check, not a handle to pass along: an `AXUIElement` captured now can be
    /// replaced by the app between the poll and the tile (Electron hosts swap their first window
    /// out), and the tiler's `AX.frontWindow` re-read is what makes it the window on screen.
    private func poll(
        pid: pid_t, arrangement: WindowArrangement, launchDisplay: Int?, remaining: Int
    ) {
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
        let bundleID = app.bundleIdentifier
        let titleRules = self.titleRules
        // The check leaves the main thread; only its answer comes back, to `resume`, where the
        // state it acts on lives. See `axQueue`.
        Self.axQueue.async { [weak self] in
            let isReady = Self.hasSwitchableWindow(pid: pid)
            // Asked only once there is a window to have a title — the app-level `neverTile` was
            // settled before the poll began, but a title rule is about the window, and the window
            // did not exist until now.
            let isProtected =
                isReady && Self.titleProtects(pid: pid, bundleID: bundleID, rules: titleRules)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    // `watching` is what says this poll is still wanted: every way one ends —
                    // giving up, the app quitting, the tile being applied — takes the pid out of
                    // it, and an answer that lands after any of those has nothing left to do.
                    guard let self, self.watching.contains(pid) else { return }
                    self.resume(
                        pid: pid, arrangement: arrangement, launchDisplay: launchDisplay,
                        remaining: remaining, isReady: isReady, isProtected: isProtected)
                }
            }
        }
    }

    /// The readiness answer, back on the main thread: tile now, or wait out `delay` and ask again.
    private func resume(
        pid: pid_t, arrangement: WindowArrangement, launchDisplay: Int?, remaining: Int,
        isReady: Bool, isProtected: Bool
    ) {
        guard isReady else {
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.delay) { [weak self] in
                self?.poll(
                    pid: pid, arrangement: arrangement, launchDisplay: launchDisplay,
                    remaining: remaining - 1)
            }
            return
        }
        watching.remove(pid)
        guard !isProtected else {
            Log.general.notice(
                "launch arrangement: pid \(pid, privacy: .public) window set to never tile; skipped")
            return
        }
        let areas = WindowTiler.visibleAreas()
        // The display the rule names, handed to the tiler as the area to arrange against — so
        // "display 2, left half" is computed on display 2 and written once. By the same 1-based
        // numbering `display1…4` and the tile badges use, and not capped at four: there is no chord
        // to run out of. A display not plugged in right now is no destination at all, and the
        // arrangement applies wherever the window opened — see `AppRule.launchDisplay`.
        //
        // This used to be a separate move queued ahead of `apply`, with `apply` re-reading the
        // window's frame to find its new display. On hosts that apply Accessibility writes late the
        // move had not landed by then, and the window was tiled on the display it opened on.
        let destination = launchDisplay.flatMap { number in
            areas.indices.contains(number - 1) ? areas[number - 1] : nil
        }
        Log.general.notice(
            """
            launch arrangement: applying \(arrangement.rawValue, privacy: .public) to pid \
            \(pid, privacy: .public) on \
            \(launchDisplay.map { "display \($0)" } ?? "its own display", privacy: .public)
            """)
        // `cycleWidths: false` — the width cycle is a response to pressing the same chord twice, and
        // there is no second press here. Left on, a launch would consume the first step of the cycle
        // and the user's first real chord would land on the second.
        WindowTiler.apply(
            arrangement, pid: pid, areas: areas,
            cycleWidths: false, gap: gap, destination: destination)
    }

    /// Whether the app owns a window worth tiling. The role filter is what keeps a splash screen or
    /// a lone dialog from being treated as the app's real window and snapped into a corner.
    ///
    /// `nonisolated static` because it runs on `axQueue` and must not be reachable from the main
    /// thread by accident: it touches no instance state, and the pid is all it needs.
    private nonisolated static func hasSwitchableWindow(pid: pid_t) -> Bool {
        AX.windows(of: AX.application(pid)).contains(where: AX.isSwitchableWindow)
    }

    /// Whether a title rule protects the window the tile would land on — `AX.frontWindow`, the same
    /// one `WindowTiler.apply` resolves when it is handed no target. `axQueue` only, like the check
    /// above it, and skipped without a read when no rule could apply to this app.
    private nonisolated static func titleProtects(
        pid: pid_t, bundleID: String?, rules: [CompiledTitleRule]
    ) -> Bool {
        guard rules.mayNeverTile(bundleID), let window = AX.frontWindow(ofApplication: pid)
        else { return false }
        return CompiledTitleRule.matches(
            rules, bundleID: bundleID, title: AX.copyString(window, kAXTitleAttribute) ?? "",
            action: .neverTile)
    }
}
