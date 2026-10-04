import AppKit
import CoreGraphics

// Focus follows the pointer: rest the cursor over a window and the keyboard goes to it, with no
// click. The X11 behaviour, which macOS has never offered and which people who grew up on it never
// stop missing.
//
// Off by default and gated behind a delay you choose, because the failure mode is the whole story
// here. With no delay, every sweep of the pointer across the screen on the way to somewhere else
// re-focuses each window it crosses — which steals keystrokes mid-sentence and, worse, does it
// invisibly. The delay is what turns "the cursor passed over this" into "the cursor stopped here",
// and it is the setting rather than a constant because how long that is depends on how you move a
// mouse.

/// What the watcher reads. A value type for the same reason `MouseDragSettings` is one: it is pushed
/// in from a store on the main actor and never mutated by the watcher itself.
struct FocusFollowsMouseSettings: Equatable {
    var isEnabled = false
    /// How long the pointer must be still before focus moves, in milliseconds.
    ///
    /// A quarter of a second: long enough that crossing a window on the way elsewhere never triggers
    /// it, short enough that deliberately parking the cursor feels immediate. The slider bottoms out
    /// well above zero — see `minimumDelay`.
    var delay: Double = 250

    /// The shortest delay the setting offers.
    ///
    /// Not zero, and not adjustable to zero. A no-delay focus-follows-mouse re-focuses every window
    /// the pointer crosses, which on a tiled desk means a sentence typed while the cursor drifts
    /// lands in three different windows. This is a floor on a footgun, not a limitation.
    static let minimumDelay: Double = 100
    static let maximumDelay: Double = 1000
}

/// Moves the keyboard focus to whatever window the pointer comes to rest over.
@MainActor
final class FocusFollowsMouse {
    var settings = FocusFollowsMouseSettings() {
        didSet {
            guard settings != oldValue else { return }
            settings.isEnabled ? install() : uninstall()
        }
    }

    /// Whether the switcher panel is up. Set by the controller.
    ///
    /// Focus must not wander during a session: the panel is non-activating and the frontmost app
    /// behind it is the one a commit measures itself against, so re-focusing something underneath
    /// mid-session would change what "the previous app" means while the user is looking at a list
    /// built from the old answer.
    var isSwitcherVisible = false {
        didSet { if isSwitcherVisible { disarm() } }
    }

    /// Told by the controller that a pick was just handed to `SwitchTarget`.
    ///
    /// A pick that travels to another Desktop settles over as much as a second — `SwitchTarget`'s
    /// settle and verify waits — under the same newest-pick generation this watcher claims when it
    /// focuses. So a nudge and a rest over whatever lay under the pointer in that window started a
    /// newer pick, and the switch gave up at its next check: you arrived on the Desktop with focus
    /// on the window under the cursor, or were pulled back. A rest inside `settleGrace` of a pick is
    /// ignored instead.
    func pickCommitted() {
        lastPick = DispatchTime.now().uptimeNanoseconds
    }

    /// When the switcher last committed a pick, in `DispatchTime` nanoseconds.
    private var lastPick: UInt64 = 0
    private static let settleGrace: UInt64 = 1_500_000_000

    private var monitor: Any?
    /// When the pointer last moved, in `DispatchTime` nanoseconds.
    private var lastMove: UInt64 = 0
    /// Whether a wake-up is scheduled. At most one ever is — see `pointerMoved`.
    private var isArmed = false
    /// Bumped whenever the scheduled wake-up stops being wanted, so one already on its way lands
    /// on a mismatch and does nothing. `asyncAfter` has no way to take a block back.
    private var generation: UInt64 = 0

    private func install() {
        guard monitor == nil else { return }
        // A *global* monitor, which sees only events bound for other applications — and that
        // restriction happens to be exactly right here. The windows worth following the pointer to
        // are other people's; our own Settings window is deliberately excluded below anyway, and
        // while it is frontmost this app receives the moves as local events the monitor never sees,
        // so hovering over Settings quietly does nothing rather than needing a case of its own.
        //
        // Apple's rule for global monitors is that *key* events need the Accessibility grant and
        // mouse events do not, so nothing here waits on it — but the raise this ends in goes through
        // `SwitchTarget`, which does. It never comes up in practice: the settings that switch this
        // on cannot be reached before the grant, since the settings window is opened from a menu-bar
        // item that only exists once the app is running.
        //
        // That the monitor receives `.mouseMoved` at all was measured rather than assumed — several
        // tools in this space reach for a `CGEventTap` here, which would be a second session-wide
        // tap alongside the two this app already runs.
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.pointerMoved() }
        }
        Log.general.notice("focus follows mouse: on at \(Int(self.settings.delay), privacy: .public)ms")
    }

    private func uninstall() {
        disarm()
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    private func disarm() {
        isArmed = false
        generation &+= 1
    }

    /// The rest delay in nanoseconds, floored at `minimumDelay` whatever the settings say.
    private var delayNanoseconds: UInt64 {
        UInt64(max(settings.delay, FocusFollowsMouseSettings.minimumDelay) * 1_000_000)
    }

    /// Notes the move, and schedules a wake-up only if none is already on its way. Called for every
    /// mouse-moved event on the machine, so it does as close to nothing as it can.
    ///
    /// It used to cancel a work item and schedule a fresh one per event. `cancel()` stops a block
    /// running but does not unschedule the timer behind it, so every event still cost a main-thread
    /// wake-up one delay later — as many wake-ups as events, twice over while the pointer was
    /// moving. Now there is one pending wake-up at a time, and when it lands early because the
    /// pointer kept moving it re-arms for whatever is left of the delay — see `wake`.
    ///
    /// The check that matters is deliberately *not* here — resolving what is under the cursor is a
    /// window-server round trip, and doing it per event would put one on every pixel of every mouse
    /// movement. It happens once, when the pointer has stopped.
    private func pointerMoved() {
        guard !isSwitcherVisible else { return }
        lastMove = DispatchTime.now().uptimeNanoseconds
        guard !isArmed else { return }
        isArmed = true
        schedule(after: delayNanoseconds)
    }

    private func schedule(after nanoseconds: UInt64) {
        let expected = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + .nanoseconds(Int(nanoseconds))) {
            [weak self] in
            MainActor.assumeIsolated { self?.wake(generation: expected) }
        }
    }

    private func wake(generation expected: UInt64) {
        guard isArmed, expected == generation else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        if let remaining = Self.remainingRest(
            now: now, lastMove: lastMove, delay: delayNanoseconds) {
            schedule(after: remaining)
            return
        }
        isArmed = false
        pointerRested()
    }

    /// How much longer the pointer has to stay still, or nil once it has rested for `delay`.
    ///
    /// Pure, so the re-arm rule is testable without a mouse.
    nonisolated static func remainingRest(now: UInt64, lastMove: UInt64, delay: UInt64) -> UInt64? {
        let still = now >= lastMove ? now - lastMove : 0
        return still >= delay ? nil : delay - still
    }

    private func pointerRested() {
        guard settings.isEnabled, !isSwitcherVisible else { return }
        // A button down is a drag, a text selection, or a menu being held open, and every one of
        // them is a gesture that belongs to the window it started in. Retargeting the keyboard
        // underneath it is how a drag ends in the wrong place.
        guard NSEvent.pressedMouseButtons == 0 else { return }
        // Any modifier held is a chord in progress — the switcher's own trigger, the hold-and-point
        // snap gesture, or a shortcut the user is part-way through. None of them wants focus moving
        // out from under it, and treating the whole modifier set as "busy" costs nothing: a resting
        // pointer under a held key is not a hover.
        guard NSEvent.modifierFlags.intersection([.command, .option, .control, .shift]).isEmpty
        else { return }
        // A switcher pick still landing — see `pickCommitted`.
        guard DispatchTime.now().uptimeNanoseconds &- lastPick > Self.settleGrace else { return }

        let point = Self.cursorInWindowSpace()
        // Resting on something drawn *over* the windows — an open menu, the Dock, the menu bar, a
        // floating panel — is not resting on the window beneath it. The ordinary-window list below
        // cannot see any of those, so on its own it answered with whatever lay underneath: rest on
        // a menu item that happened to overlap another app's window and that app was brought
        // forward, dismissing the menu out from under the pointer.
        //
        // One copy of the window list answers both "is anything drawn over the windows here" and
        // "which window is it" — this used to take one copy for each.
        let surfaces = WindowHitTest.onScreen()
        guard let target = WindowHitTest.window(at: point, in: surfaces, passingThrough: nil)
        else { return }
        let front = surfaces.first {
            $0.layer == 0 && $0.bounds.width > 1 && $0.bounds.height > 1
        }
        // Already at the front *and* already focused, so there is nothing to do. This is also what
        // makes the watcher self-correcting after a click: the answer comes from live state rather
        // than from a record of what this object last focused, so focus changed by any other means
        // is simply the new baseline.
        //
        // Both halves, not the z-order alone. The frontmost window is not necessarily the focused
        // one: click the desktop and Finder is active with no window of its own, while the window
        // on top still belongs to whatever was in front before — and resting on it did nothing.
        guard target.id != front?.id
            || target.pid != NSWorkspace.shared.frontmostApplication?.processIdentifier
        else { return }
        // Our own windows are left alone. Every other app here is one you were reaching for; this
        // one is an accessory that spends its life without a Dock tile, and hovering over Settings
        // on the way somewhere else should not make Cmd-Tab the frontmost application — which,
        // among other things, is what shifts the switcher's own list by one.
        guard target.pid != ProcessInfo.processInfo.processIdentifier else { return }

        SwitchTarget.focusWindow(id: target.id, pid: target.pid)
    }

    /// The cursor in the window server's top-left space, which is what `CGWindowListCopyWindowInfo`
    /// reports frames in.
    ///
    /// `NSEvent.mouseLocation` is Cocoa's bottom-up space measured against the *primary* display, so
    /// the flip is against that display's height and not the one the cursor happens to be over — the
    /// same conversion `MouseWindowDrag`'s hold-and-point gesture makes, for the same reason.
    private static func cursorInWindowSpace() -> CGPoint {
        let location = NSEvent.mouseLocation
        guard let primary = NSScreen.primary else { return location }
        return CGPoint(x: location.x, y: primary.frame.height - location.y)
    }
}
