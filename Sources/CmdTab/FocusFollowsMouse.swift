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
        didSet { if isSwitcherVisible { pending?.cancel() } }
    }

    private var monitor: Any?
    private var pending: DispatchWorkItem?

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
        pending?.cancel()
        pending = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// Restarts the rest-timer. Called for every mouse-moved event on the machine, so it does as
    /// close to nothing as it can: cancel one work item, schedule another.
    ///
    /// The check that matters is deliberately *not* here — resolving what is under the cursor is a
    /// window-server round trip, and doing it per event would put one on every pixel of every mouse
    /// movement. It happens once, when the pointer has stopped.
    private func pointerMoved() {
        pending?.cancel()
        guard !isSwitcherVisible else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.pointerRested() }
        }
        pending = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(settings.delay, FocusFollowsMouseSettings.minimumDelay) / 1000,
            execute: work)
    }

    private func pointerRested() {
        pending = nil
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

        let windows = WindowNavigator.onScreen()
        let point = Self.cursorInWindowSpace()
        guard let index = windows.firstIndex(where: { $0.frame.contains(point) }) else { return }
        // Already at the front, so there is nothing to do. This is also what makes the watcher
        // self-correcting after a click: the answer comes from live z-order rather than from a
        // record of what this object last focused, so focus changed by any other means is simply
        // the new baseline.
        guard index != windows.startIndex else { return }
        let target = windows[index]
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
