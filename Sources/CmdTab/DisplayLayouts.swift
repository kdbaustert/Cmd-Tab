import AppKit
import ApplicationServices
import CoreGraphics

// Putting the windows back where they were the last time the desk looked like this.
//
// Docking and undocking a laptop is the one thing that scrambles a carefully arranged screen with no
// way to undo it: macOS evacuates the windows off a display that has gone and does not remember
// where they were when it comes back. This watches the desk, keeps the layout it had under each
// arrangement of displays, and restores it when that arrangement returns.
//
// **This is not the saved-layouts feature that was removed.** That one was named layouts — "Work",
// "Writing" — restorable by chord, persisted to disk, and its two hard problems were both about a
// layout outliving the moment it was captured: which live window a saved record refers to after a
// restart, and what a stored frame means once the monitor it was measured on is gone. This has
// neither problem, by construction. It stores nothing on disk and spans nothing longer than a cable
// being pulled out, so a window is identified by its `CGWindowID` — exact, free, and stable for as
// long as the window exists — and a window that has closed in the meantime simply is not in the list
// any more. What it keeps of the older design is the half that was right: frames are held as a
// fraction of a display named by its hardware UUID, never as absolute coordinates, so the same
// monitor at a different resolution still gets its windows back in the same relative places.

/// A window's place, in terms that survive the display being unplugged and brought back.
private struct StoredFrame {
    /// The hardware UUID of the display it was on.
    let display: String
    /// Origin and size as fractions of that display's visible area. An origin of (0.5, 0) and a size
    /// of (0.5, 1) is the right half, whatever the monitor.
    let fraction: CGRect
}

/// Remembers the window layout per arrangement of displays, and restores it when one comes back.
@MainActor
final class DisplayLayouts {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    /// Per-app overrides, pushed by the controller. An app the user has excluded from tiling is not
    /// moved by this either: the rule says "do not rearrange my windows", and a rescue is a
    /// rearrangement however well meant.
    var appRules: [String: AppRule] = [:]

    /// The layout under each desk we have seen, keyed by that desk's signature.
    ///
    /// Bounded, because a signature is cheap to invent — every different set of monitors this Mac is
    /// ever plugged into is one, and a machine that visits three offices accumulates them. The cap is
    /// well past any real number of desks; this is a backstop against a leak, not a policy.
    private var layouts: [String: [CGWindowID: StoredFrame]] = [:]
    private static let deskLimit = 16
    /// Signatures in the order they were first stored, so the least recently *met* desk is the one
    /// dropped. Insertion order rather than use order: re-storing a known desk does not move it, and
    /// at a cap of sixteen against the handful of desks a real machine visits, the difference cannot
    /// be reached — this is a backstop against unbounded growth, not a cache policy.
    private var deskOrder: [String] = []

    /// The most recent capture, and the desk it was taken under. This is what is filed away when the
    /// desk changes — by then the windows have already been moved, so the live positions are no use.
    private var latest: [CGWindowID: StoredFrame] = [:]
    private var latestDesk: String?

    private var timer: Timer?
    /// The power state the running timer was armed for, so a change of it can be noticed on the
    /// tick. See `scheduleCapture`.
    private var conserving = false
    private var observer: NSObjectProtocol?
    private var settle: DispatchWorkItem?

    /// How often the live layout is re-read.
    ///
    /// A timer, which this app avoids elsewhere, and the reason it cannot be avoided here is that
    /// the interesting moment has no notification in front of it. `didChangeScreenParametersNotification`
    /// arrives *after* macOS has evacuated the windows off the display that just went, so by the
    /// time anything is told, the positions worth remembering are gone. Something has to have been
    /// watching.
    ///
    /// The cost is one `CGWindowListCopyWindowInfo` every five seconds — the same call that already
    /// runs on every left click of the machine when the drag gesture is on — and it runs only while
    /// this setting is on. Five seconds is chosen against how fast a person rearranges windows: it is
    /// short enough that a layout is captured before you reach for the cable, and long enough to be
    /// nothing at all.
    private static let captureInterval: TimeInterval = 5

    /// How long to wait after the desk changes before putting anything back.
    ///
    /// macOS moves the windows itself over the moments after a display arrives or leaves, and a
    /// restore that raced it would be overwritten by the system's own tidying. Long enough to be
    /// after that, short enough that the screen does not sit wrong while you watch it.
    private static let settleDelay: TimeInterval = 1.2

    private func start() {
        latestDesk = Self.signature()
        capture()
        scheduleCapture()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deskMayHaveChanged() }
        }
        Log.general.notice("display layouts: watching")
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        settle?.cancel()
        settle = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        // Dropped rather than kept. What is held is a photograph of a desk that is no longer being
        // watched, and reviving it after the setting has been off for an hour would put windows back
        // where they were before a stretch this object knows nothing about.
        layouts.removeAll()
        deskOrder.removeAll()
        latest.removeAll()
        latestDesk = nil
    }

    /// Arms the capture timer at whatever interval the current power source deserves.
    ///
    /// Rebuilt rather than left running when that changes, because the whole point is the *rate*:
    /// a timer armed at five seconds on AC keeps firing every five seconds after the cable comes
    /// out. Checked on the tick rather than subscribed to a power notification — one comparison
    /// against a cached flag, on a timer that has just woken the process anyway, against a run-loop
    /// source and its teardown for a transition that happens a few times a day.
    private func scheduleCapture() {
        timer?.invalidate()
        conserving = PowerState.isConserving
        let interval = PowerState.interval(Self.captureInterval, conserving: conserving)
        timer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.capture()
                // The cable came out, or went back in. Re-arm at the other rate.
                if PowerState.isConserving != self.conserving { self.scheduleCapture() }
            }
        }
        // Nothing here needs to land on time — it samples a layout rather than driving anything —
        // so let the run loop batch the wakeup with whatever else it has to do. That is most of the
        // saving on battery, where the alternative is waking the CPU on its own schedule.
        timer?.tolerance = interval / 4
    }

    /// Reads where every window currently is, in fractions of the display it is on.
    private func capture() {
        let displays = WindowTiler.visibleDisplays()
        guard !displays.isEmpty else { return }
        let areas = displays.map(\.area)
        var out: [CGWindowID: StoredFrame] = [:]
        for window in WindowNavigator.onScreen() {
            guard let index = WindowTiler.homeDisplay(of: window.frame, in: areas),
                let id = displays[index].id
            else { continue }
            out[window.id] = StoredFrame(
                display: id, fraction: Self.fraction(of: window.frame, in: areas[index]))
        }
        latest = out
    }

    /// A screen-parameters notification arrived. Only a change of *desk* is acted on.
    ///
    /// AppKit posts this notification for the Dock showing and hiding and for the menu bar
    /// auto-hiding as readily as for a monitor being plugged in — `PanelGroup.shouldRetarget` makes
    /// the same point about the same notification. Restoring a layout because the Dock slid in would
    /// undo every window the user had moved since, which is the single worst thing this feature
    /// could do, so the guard is on the desk's identity and nothing else.
    private func deskMayHaveChanged() {
        let now = Self.signature()
        guard now != latestDesk else { return }
        // The last capture was taken while the *old* desk was up, which is what makes it worth
        // keeping: it is the arrangement the user had before macOS rearranged it.
        if let previous = latestDesk, !latest.isEmpty { remember(latest, as: previous) }
        // Spent, and cleared rather than left to be overwritten by the next timer tick. Between a
        // desk change and that tick, `latest` belongs to a desk that is no longer up — so a *second*
        // change arriving inside the capture interval would file the first desk's layout under the
        // second desk's name, and every later visit to that desk would restore somebody else's
        // windows. Two changes in five seconds is not a stretch: unplugging a hub detaches its
        // displays one at a time.
        latest.removeAll()
        latestDesk = now
        Log.general.notice("display layouts: desk changed to \(now, privacy: .public)")

        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restore(desk: now) }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    private func remember(_ layout: [CGWindowID: StoredFrame], as desk: String) {
        if layouts[desk] == nil {
            while deskOrder.count >= Self.deskLimit, let oldest = deskOrder.first {
                deskOrder.removeFirst()
                layouts.removeValue(forKey: oldest)
            }
            deskOrder.append(desk)
        }
        layouts[desk] = layout
    }

    /// Puts back what this desk looked like the last time it was up.
    private func restore(desk: String) {
        settle = nil
        // Re-read rather than trusting the signature from a second ago: a plug-in often posts
        // several notifications in a burst, and the one that scheduled this may not be the last.
        guard Self.signature() == desk else { return }
        guard let saved = layouts[desk], !saved.isEmpty else {
            Log.general.notice("display layouts: nothing stored for this desk yet")
            // Captured anyway, so this desk is known from now on. Without it, a desk first seen
            // *as* a change would not be recorded until the next timer tick — which is harmless, but
            // this makes the first cycle behave like every later one.
            capture()
            return
        }
        let displays = WindowTiler.visibleDisplays()
        let areas = Dictionary(
            displays.compactMap { display in display.id.map { ($0, display.area) } },
            uniquingKeysWith: { first, _ in first })
        let live = WindowNavigator.onScreen()
        var moves: [(window: WindowNavigator.Window, frame: CGRect)] = []
        for window in live {
            guard let stored = saved[window.id], let area = areas[stored.display] else { continue }
            // The lookup is skipped entirely when nobody has set a rule, which is the common case:
            // `NSRunningApplication(processIdentifier:)` per window, per desk change, to ask a
            // question whose answer is always no.
            if !appRules.isEmpty,
                let id = NSRunningApplication(processIdentifier: window.pid)?.bundleIdentifier,
                appRules[id]?.neverTile == true {
                continue
            }
            let frame = WindowTiler.clamp(Self.absolute(stored.fraction, in: area), into: area)
            // A window macOS has already left where it belongs needs no write, and every write is
            // Accessibility IPC to another process. On a two-display desk this is usually most of
            // the list.
            guard !Self.matches(window.frame, frame) else { continue }
            moves.append((window, frame))
        }
        guard !moves.isEmpty else { return }
        Log.general.notice(
            "display layouts: restoring \(moves.count, privacy: .public) window(s)")
        Self.write(moves)
        // Deliberately no capture here. `write` hands the frames to a background queue and returns,
        // and each `AX.setFrame` is itself a request to another process rather than a move that has
        // happened — so a snapshot taken now records the scrambled positions macOS left behind, not
        // the restored ones. It once did exactly that, with a comment claiming the opposite, which
        // would have filed the scrambled layout as this desk's the moment a second display change
        // arrived inside the capture interval — corrupting the layout that had just been restored
        // correctly. The timer owns the refresh; until it ticks, `latest` stays empty and `remember`
        // files nothing, which is the safe way to be wrong.
    }

    /// Where a queued restore actually happens.
    ///
    /// Off the main thread, and this is the reason the whole function exists rather than being three
    /// lines in `restore`: each move is `AX.window(ofApplication:matching:)` — a walk of that app's
    /// window list, reading a frame from each — followed by a frame write, and a desk change can
    /// queue thirty of them. Run on the main thread that is also the run loop servicing the keyboard
    /// event tap, one wedged app in that list is enough to overrun the tap's deadline and have the
    /// system disable it, which costs the user every keystroke on the machine.
    private static func write(_ moves: [(window: WindowNavigator.Window, frame: CGRect)]) {
        queue.async {
            for move in moves {
                guard
                    let element = AX.window(
                        ofApplication: move.window.pid, matching: move.window.frame)
                else { continue }
                AX.setFrame(element, move.frame, sizing: true, repositionAfterSizing: true)
            }
        }
    }

    private static let queue = DispatchQueue(label: "com.cmdtab.displaylayouts", qos: .utility)

    /// What the desk is, as one comparable string.
    ///
    /// The displays' hardware UUIDs, **sorted** — so the same monitors in a different left-to-right
    /// arrangement are the same desk. That is the right call for this feature: rearranging two
    /// monitors in Displays settings does not mean you want a different window layout, it means you
    /// want the same one, on the monitors it was on. The size is deliberately not part of it either;
    /// a resolution change keeps the desk and the fractional frames absorb it.
    ///
    /// A display whose UUID cannot be read contributes a placeholder rather than being skipped, so
    /// two unreadable displays are not silently the same desk as one.
    private static func signature() -> String {
        WindowTiler.visibleDisplays().map { $0.id ?? "?" }.sorted().joined(separator: "|")
    }

    // The three below are `nonisolated`, the same annotation and the same argument `TargetProvider`
    // makes for its own statics: they are pure functions over rectangles that touch no instance
    // state, and without it the `@MainActor` on the class would drag them onto the main actor.
    //
    // Internal rather than private for the reason `WindowTiler.reachable` gives for the same choice:
    // the cases worth checking are the ones where the desk has changed under a stored frame, and no
    // test can arrange a second monitor to unplug.

    nonisolated static func fraction(of frame: CGRect, in area: CGRect) -> CGRect {
        guard area.width > 0, area.height > 0 else { return .zero }
        return CGRect(
            x: (frame.minX - area.minX) / area.width,
            y: (frame.minY - area.minY) / area.height,
            width: frame.width / area.width,
            height: frame.height / area.height)
    }

    nonisolated static func absolute(_ fraction: CGRect, in area: CGRect) -> CGRect {
        CGRect(
            x: area.minX + fraction.minX * area.width,
            y: area.minY + fraction.minY * area.height,
            width: fraction.width * area.width,
            height: fraction.height * area.height)
    }

    /// Whether a window is already close enough to where it should be to leave alone.
    ///
    /// A point of slack per edge. The fractional round trip is lossy, and the hosts whose
    /// Accessibility frames drift a point from the window server's would otherwise be rewritten on
    /// every single desk change — a write that moves a window by half a pixel, forever.
    nonisolated static func matches(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(a.minX - b.minX) < tolerance && abs(a.minY - b.minY) < tolerance
            && abs(a.width - b.width) < tolerance && abs(a.height - b.height) < tolerance
    }
}
