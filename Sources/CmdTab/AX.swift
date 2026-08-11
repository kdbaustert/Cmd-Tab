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

    /// Instrumented because this is where the messaging timeout earns its keep: one call, to one
    /// app, that a wedged app can stall for the full 250ms. A refresh makes this call per app, so
    /// the difference between "the machine is busy" and "one particular app is hanging us" is
    /// visible here and nowhere else — the interval carries the pid to say which.
    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var owner: pid_t = 0
        AXUIElementGetPid(app, &owner)
        let state = Signpost.targets.beginInterval(
            "windows", id: Signpost.targets.makeSignpostID(), "pid=\(owner)")
        let windows: [AXUIElement] = onOwningThread(app) {
            var value: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value)
                    == .success,
                let windows = value as? [AXUIElement]
            else { return [] }
            return windows
        }
        Signpost.targets.endInterval("windows", state, "count=\(windows.count)")
        return windows
    }

    /// A window as opposed to the other things that turn up in `AXWindows` — Finder puts the
    /// desktop in there as an `AXScrollArea`.
    static func isWindow(_ element: AXUIElement) -> Bool {
        WindowClassification.isWindow(role: copyString(element, kAXRoleAttribute))
    }

    /// A real window the user could switch to, as opposed to a palette, sheet or toolbar.
    ///
    /// The decision itself is `WindowClassification.isSwitchable`, which is pure and tested; this
    /// only gathers the facts it asks for. The reads are passed as autoclosures because the order
    /// they are needed in is the order they get cheaper to avoid — a standard window is settled by
    /// its subrole alone and never pays for the other two round trips.
    static func isSwitchableWindow(_ window: AXUIElement) -> Bool {
        WindowClassification.isSwitchable(
            role: copyString(window, kAXRoleAttribute),
            subrole: copyString(window, kAXSubroleAttribute),
            isMinimized: isMinimized(window),
            hasMinimizeButton: hasMinimizeButton(window))
    }

    /// Whether the window carries a minimize control — the discriminator that tells a real window
    /// misreporting its subrole from an actual dialog. See `WindowClassification.isSwitchable`.
    private static func hasMinimizeButton(_ window: AXUIElement) -> Bool {
        copyElement(window, kAXMinimizeButtonAttribute as String) != nil
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
        readElement(element, attribute).element
    }

    /// The same read with the failure kept.
    ///
    /// A caller that means to ask again has to tell "this app has not drawn a window yet" from
    /// "Accessibility is switched off for us", and the error code is the only thing carrying the
    /// difference — both arrive here as a nil element. An answer that is not an element at all is
    /// reported as `.noValue`, since it is the same nothing from the caller's side.
    static func readElement(
        _ element: AXUIElement, _ attribute: String
    ) -> (element: AXUIElement?, error: AXError) {
        onOwningThread(element) {
            var value: CFTypeRef?
            let error = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
            guard error == .success else { return (nil, error) }
            guard let value, CFGetTypeID(value) == AXUIElementGetTypeID() else {
                return (nil, .noValue)
            }
            return ((value as! AXUIElement), .success)
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
