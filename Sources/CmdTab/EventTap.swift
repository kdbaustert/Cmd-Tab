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
        let swallow = MainActor.assumeIsolated { handler(type, event) }
        return swallow ? nil : Unmanaged.passUnretained(event)
    }
}
