import AppKit
import ApplicationServices

/// Thin shared wrapper over the Accessibility API.
///
/// Almost every call here is IPC to another process and can block on a wedged one, so none of it
/// may run on the event tap's thread — the system kills a tap that stalls. Callers push this work
/// onto a queue of their own.
///
/// The exception is a call aimed at this process — our own settings window is a tiling target like
/// any other. Those are not IPC and must run on the main thread; `onOwningThread` is where that is
/// arranged, so no caller has to know which of the two it is doing.
enum AX {
    /// Cap on how long any single app can make us wait.
    private static let timeout: Float = 0.25

    /// Runs `work` on a thread where the Accessibility API is safe to call for `element`.
    ///
    /// A call aimed at another process is IPC, and belongs off the main thread — that is what this
    /// whole wrapper exists for. A call aimed at *this* process is not IPC at all: HIServices
    /// short-circuits it straight into AppKit's accessibility entry points **on the calling
    /// thread**, and AppKit traps the moment that thread is not the main one — `Must only be used
    /// from the main thread`, as a crash inside `-[NSWindow _setFrameCommon:display:fromServer:]`.
    ///
    /// Our own windows are ordinary tiling targets, so rather than making every caller know which
    /// process it is about to touch, the hop lives here. Safe from deadlock because nothing on the
    /// main thread ever waits on the queues these calls run from; they are all `async`.
    @discardableResult
    private static func onOwningThread<T>(_ element: AXUIElement, _ work: () -> T) -> T {
        var owner: pid_t = 0
        guard AXUIElementGetPid(element, &owner) == .success,
            owner == ProcessInfo.processInfo.processIdentifier,
            !Thread.isMainThread
        else { return work() }
        return DispatchQueue.main.sync(execute: work)
    }

    /// An app element with the timeout already applied. Always build them through here, so one
    /// hung app cannot hang the switcher.
    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        onOwningThread(app) {
            var value: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                    == .success,
                let windows = value as? [AXUIElement]
            else { return [] }
            return windows
        }
    }

    /// A window as opposed to the other things that turn up in `AXWindows` — Finder puts the
    /// desktop in there as an `AXScrollArea`.
    static func isWindow(_ element: AXUIElement) -> Bool {
        copyString(element, kAXRoleAttribute) == (kAXWindowRole as String)
    }

    /// A real window the user could switch to, as opposed to a palette, sheet or toolbar.
    ///
    /// This cannot be a subrole check alone. **macOS reports a window's subrole as `AXDialog`
    /// while it is minimized**: the same window flips `AXStandardWindow` → `AXDialog` on minimize
    /// and back on restore (verified on macOS 26.5 with TextEdit). Filtering on
    /// `AXStandardWindow` therefore drops every minimized window on the floor — silently, since
    /// an empty list looks exactly like an app with no windows.
    static func isSwitchableWindow(_ window: AXUIElement) -> Bool {
        guard isWindow(window) else { return false }
        if copyString(window, kAXSubroleAttribute) == (kAXStandardWindowSubrole as String) {
            return true
        }
        // Minimized: it is sitting in the Dock and is switchable whatever it now calls itself.
        return isMinimized(window)
    }

    /// A window that does not answer is treated as not minimized: the fallback should be to leave
    /// the user's arrangement alone, never to go restoring windows on a guess.
    static func isMinimized(_ window: AXUIElement) -> Bool {
        copyBool(window, kAXMinimizedAttribute) ?? false
    }

    static func copyString(_ element: AXUIElement, _ attribute: String) -> String? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            return value as? String
        }
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            return value as? Bool
        }
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        onOwningThread(element) {
            AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
        }
    }

    /// Reads an attribute that is itself an element — e.g. an app's `AXMainWindow`/`AXFocusedWindow`.
    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXUIElementGetTypeID()
            else { return nil }
            return (value as! AXUIElement)
        }
    }

    /// Presses a window control (close/zoom/minimize button) by resolving the button element and
    /// performing its press action — exactly what a click on the traffic-light dot does.
    static func press(_ element: AXUIElement, button attribute: String) {
        onOwningThread(element) {
            var button: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, attribute as CFString, &button) == .success,
                let button, CFGetTypeID(button) == AXUIElementGetTypeID()
            else { return }
            AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
        }
    }

    /// The window's on-screen origin (top-left, Quartz global coordinates).
    static func position(_ window: AXUIElement) -> CGPoint? {
        guard let value = copyAXValue(window, kAXPositionAttribute) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    static func size(_ window: AXUIElement) -> CGSize? {
        guard let value = copyAXValue(window, kAXSizeAttribute) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }

    static func setPosition(_ window: AXUIElement, _ point: CGPoint) {
        var point = point
        guard let value = AXValueCreate(.cgPoint, &point) else { return }
        onOwningThread(window) {
            AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
        }
    }

    static func setSize(_ window: AXUIElement, _ size: CGSize) {
        var size = size
        guard let value = AXValueCreate(.cgSize, &size) else { return }
        onOwningThread(window) {
            AXUIElementSetAttributeValue(window, kAXSizeAttribute as CFString, value)
        }
    }

    /// The app's frontmost *real* window — the one a window-management action should act on.
    ///
    /// Two things this cannot be a bare `kAXFocusedWindow` read. First, focus lands on palettes,
    /// inspectors and sheets as readily as on documents, and snapping a Find panel to half the
    /// screen is never what the user meant; `isSwitchableWindow` is the same filter the switcher's
    /// own window list uses. Second, `kAXFocusedWindow` comes back empty for some apps
    /// (Electron/Catalyst), which is why `SwitchTarget.resolveWindow` walks the same three
    /// attributes — focused, then main, then the window list.
    static func frontWindow(ofApplication pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        let candidates = [
            copyElement(app, kAXFocusedWindowAttribute as String),
            copyElement(app, kAXMainWindowAttribute as String),
        ].compactMap { $0 }
        if let real = candidates.first(where: isSwitchableWindow) { return real }
        if let window = windows(of: app).first(where: isSwitchableWindow) { return window }
        // Nothing passed the filter. Fall back to whatever focus reported rather than doing
        // nothing at all: an app whose only window reports an unexpected subrole is still a window
        // the user is looking at, and refusing to move it is the worse failure.
        return candidates.first ?? windows(of: app).first(where: isWindow)
    }

    /// The app's window whose frame matches `bounds`, within a couple of points.
    ///
    /// Frame identity rather than "the app's front window": a mouse gesture acts on the window it was
    /// pointed at, which for an app with several windows open is routinely not the focused one — and
    /// neither gesture that uses this ever focuses it, so the two come apart in exactly the case that
    /// matters. nil when nothing matches, which is the honest answer for hosts whose Accessibility
    /// frames drift from the window server's (Electron, Catalyst); the caller picks the fallback.
    ///
    /// Accessibility IPC per window, so it belongs on a background queue like everything else here.
    static func window(ofApplication pid: pid_t, matching bounds: CGRect, tolerance: CGFloat = 4)
        -> AXUIElement?
    {
        windows(of: application(pid)).first { window in
            guard let origin = AX.position(window), let size = AX.size(window) else { return false }
            return abs(origin.x - bounds.minX) < tolerance
                && abs(origin.y - bounds.minY) < tolerance
                && abs(size.width - bounds.width) < tolerance
                && abs(size.height - bounds.height) < tolerance
        }
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
                let value, CFGetTypeID(value) == AXValueGetTypeID()
            else { return nil }
            return (value as! AXValue)
        }
    }
}
