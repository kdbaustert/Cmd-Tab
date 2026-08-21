import AppKit
import CoreGraphics

/// A session-level event tap that can swallow key events before they reach the focused app.
///
/// Requires Accessibility permission; `start()` returns false without it. The callback runs on
/// the main run loop, so the handler must return fast — the system disables a tap that stalls.
final class EventTap {
    /// Return true to swallow the event so no other app sees it.
    typealias Handler = (CGEventType, CGEvent) -> Bool

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler

    /// Times the system disabled the tap for overrunning its deadline — we were too slow.
    private(set) var timeoutDisableCount = 0
    /// Times the system disabled the tap for user input (e.g. Ctrl-Alt-Cmd-Esc) — expected, not alarming.
    private(set) var userInputDisableCount = 0

    init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// A backstop, not a code path anything takes today: `SwitcherController` owns the only tap and
    /// calls `stop()` before dropping it.
    ///
    /// Worth having because of what the alternative costs. The run-loop source outlives this object
    /// — it is retained by the main run loop, not by us — and the callback reaches back through an
    /// `Unmanaged.passUnretained(self)` pointer that nothing keeps alive. So a tap released without
    /// being stopped does not leak quietly; it leaves a live source dereferencing freed memory on
    /// the next keystroke, which surfaces as a crash somewhere unrelated. One line to make that
    /// impossible by construction rather than by convention.
    deinit { stop() }

    var isRunning: Bool { tap != nil }

    @discardableResult
    func start() -> Bool {
        guard tap == nil else { return true }

        let mask: CGEventMask =
            (1 << CGEventType.keyDown.rawValue)
            | (1 << CGEventType.keyUp.rawValue)
            | (1 << CGEventType.flagsChanged.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let tap = Unmanaged<EventTap>.fromOpaque(refcon).takeUnretainedValue()
                return tap.dispatch(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            return false
        }

        self.tap = tap
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        source = nil
        tap = nil
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // The system kills the tap if we ever overrun its deadline. Switch it back on rather
        // than silently losing every future keystroke.
        if type == .tapDisabledByTimeout {
            timeoutDisableCount += 1
            Log.tap.error("Tap disabled by timeout (overran deadline), re-enabling. Count: \(self.timeoutDisableCount, privacy: .public)")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        if type == .tapDisabledByUserInput {
            userInputDisableCount += 1
            Log.tap.notice("Tap disabled by user input, re-enabling. Count: \(self.userInputDisableCount, privacy: .public)")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        // The interval the whole architecture is arranged around: overrun the system's deadline and
        // the tap is killed, taking every keystroke on the machine with it until it is re-enabled
        // above. Measured rather than asserted — see `Signpost`.
        let state = Signpost.tap.beginInterval("handle", id: Signpost.tap.makeSignpostID())
        // `nonisolated(unsafe)` on both, because neither `CGEvent` nor the handler is `Sendable` and
        // `assumeIsolated` takes a `sending` closure. Safe, and for a stronger reason than usual:
        // the run-loop source is added to `CFRunLoopGetMain`, so this callback *is* the main thread
        // — the hop is a formality that lets the handler touch main-actor state. The event itself is
        // owned by this call, arriving as a parameter and leaving as the return value, with no other
        // reference to it anywhere.
        nonisolated(unsafe) let event = event
        nonisolated(unsafe) let handler = handler
        let swallow = MainActor.assumeIsolated { handler(type, event) }
        Signpost.tap.endInterval("handle", state, "swallow=\(swallow)")
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
