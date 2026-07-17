import AppKit
import ApplicationServices

/// Thin shared wrapper over the Accessibility API.
///
/// Every call here is IPC to another process and can block on a wedged one, so none of it may run
/// on the event tap's thread — the system kills a tap that stalls. Callers push this work onto a
/// queue of their own.
enum AX {
    /// Cap on how long any single app can make us wait.
    private static let timeout: Float = 0.25

    /// An app element with the timeout already applied. Always build them through here, so one
    /// hung app cannot hang the switcher.
    static func application(_ pid: pid_t) -> AXUIElement {
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    static func windows(of app: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &value) == .success,
            let windows = value as? [AXUIElement]
        else { return [] }
        return windows
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
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? String
    }

    static func copyBool(_ element: AXUIElement, _ attribute: String) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
        else { return nil }
        return value as? Bool
    }

    static func setBool(_ element: AXUIElement, _ attribute: String, _ value: Bool) {
        AXUIElementSetAttributeValue(element, attribute as CFString, value as CFTypeRef)
    }

    /// Reads an attribute that is itself an element — e.g. an app's `AXMainWindow`/`AXFocusedWindow`.
    static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    /// Presses a window control (close/zoom/minimize button) by resolving the button element and
    /// performing its press action — exactly what a click on the traffic-light dot does.
    static func press(_ element: AXUIElement, button attribute: String) {
        var button: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, attribute as CFString, &button) == .success,
            let button
        else { return }
        AXUIElementPerformAction(button as! AXUIElement, kAXPressAction as CFString)
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
        AXUIElementSetAttributeValue(window, kAXPositionAttribute as CFString, value)
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
            let value, CFGetTypeID(value) == AXValueGetTypeID()
        else { return nil }
        return (value as! AXValue)
    }
}
