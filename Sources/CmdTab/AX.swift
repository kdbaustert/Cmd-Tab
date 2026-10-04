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
    ///
    /// Nesting is free and deliberate. The inner call finds `Thread.isMainThread` already true —
    /// the outer hop put it there — and runs inline, so wrapping a whole walk in one of these
    /// collapses what would otherwise be one `main.sync` per read into a single hop. That is what
    /// `frame`, `setFrame` and `window(ofApplication:matching:)` below are for: a modifier-drag of
    /// this app's *own* settings window writes at up to 120Hz, and paying two synchronous hops onto
    /// the main thread per frame — on the very thread the keyboard tap is serviced from — is the one
    /// place this wrapper's convenience turned into a cost worth measuring.
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
    ///
    /// The per-element timeout covers this element and nothing derived from it: `AXUIElement.h`
    /// says setting it on an element sets it "only for that object". Every window, child
    /// and menu item read *through* it is a new object, and those fell back to the process-wide
    /// default of about six seconds — so the cap held for the first call to an app and for none of
    /// the calls after it, including the four `raise(element:)` makes on a stored window. Building
    /// an app element is therefore also where the process-wide cap is installed, once; nothing
    /// reaches another app's tree without passing through here first.
    static func application(_ pid: pid_t) -> AXUIElement {
        _ = processWideTimeout
        let element = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(element, timeout)
        return element
    }

    /// `timeout`, set on the system-wide element — which is how the API spells "every element this
    /// process holds that has no timeout of its own". A `static let` so it runs exactly once, on
    /// whichever thread first asks for an app element, with the runtime's lazy-static machinery
    /// making that thread-safe. A caller that needs longer for one element — a press whose action
    /// is real work in the other app, say — sets its own on that element, which wins over this.
    private static let processWideTimeout: Void = {
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), timeout)
    }()

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

    /// An element's children, or an empty array where it has none or will not say.
    ///
    /// Unsignposted, unlike `windows(of:)`: this walks menus rather than windows, and it is called
    /// from `WindowCapture.menuWindowTitles` on a background queue where a slow app costs one
    /// preview rather than the switcher's key path.
    ///
    /// Through `onOwningThread` like every other reader here, even though its one caller only ever
    /// asks about *other* apps. A read against our own process is not IPC and has to be on the main
    /// thread, and a helper that quietly does not know that is a trap for whoever reaches for it
    /// next.
    static func children(of element: AXUIElement) -> [AXUIElement] {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard
                AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                    == .success
            else { return [] }
            return (value as? [AXUIElement]) ?? []
        }
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

    /// The same decision for a caller that already holds the window's `WindowFacts`. Only the
    /// minimize-button probe is left to pay for, and only the `AXDialog` case pays it.
    static func isSwitchableWindow(_ window: AXUIElement, _ facts: WindowFacts) -> Bool {
        WindowClassification.isSwitchable(
            role: facts.role,
            subrole: facts.subrole,
            isMinimized: facts.isMinimized,
            hasMinimizeButton: hasMinimizeButton(window))
    }

    /// Whether the window carries a minimize control — the discriminator that tells a real window
    /// misreporting its subrole from an actual dialog. See `WindowClassification.isSwitchable`.
    private static func hasMinimizeButton(_ window: AXUIElement) -> Bool {
        copyElement(window, kAXMinimizeButtonAttribute as String) != nil
    }

    /// What a window walk asks of every window it lists, read in one message.
    ///
    /// Each attribute read is a message to the owning app, and `TargetProvider.windowTargets` was
    /// sending five or six per window on every refresh — role and subrole for the switchable test,
    /// then minimized, title, position and size for the tile. `copyAttributes` carries them all in
    /// one. Measured over ten windows: six single reads cost 290-400µs per window, the one batch
    /// 80-130µs. The optional fields are nil where the window did not answer, exactly as the single
    /// readers are.
    struct WindowFacts {
        var role: String?
        var subrole: String?
        /// False when unanswered — see `isMinimized(_:)`.
        var isMinimized: Bool
        /// Only read when asked for; nil otherwise, and nil for a window that has none.
        var title: String?
        /// Only read when asked for.
        var frame: CGRect?
    }

    /// `title` and `frame` are opt-in: the title has a cache in front of it and the frame is only
    /// wanted with more than one display, so neither is asked for unless the caller says so.
    static func windowFacts(_ window: AXUIElement, title: Bool, frame: Bool) -> WindowFacts {
        var attributes = [kAXRoleAttribute, kAXSubroleAttribute, kAXMinimizedAttribute]
        if title { attributes.append(kAXTitleAttribute) }
        if frame { attributes += [kAXPositionAttribute, kAXSizeAttribute] }
        let values = copyAttributes(window, attributes)
        let origin = cgPoint(values[kAXPositionAttribute])
        let size = cgSize(values[kAXSizeAttribute])
        return WindowFacts(
            role: values[kAXRoleAttribute] as? String,
            subrole: values[kAXSubroleAttribute] as? String,
            isMinimized: values[kAXMinimizedAttribute] as? Bool ?? false,
            title: values[kAXTitleAttribute] as? String,
            frame: origin.flatMap { origin in size.map { CGRect(origin: origin, size: $0) } })
    }

    /// Several attributes of one element in one message. An attribute the element would not answer
    /// is absent from the result — the API fills its slot with an `AXValue` carrying the error — so
    /// a lookup here reads exactly like a failed single read.
    private static func copyAttributes(_ element: AXUIElement, _ attributes: [String])
        -> [String: CFTypeRef]
    {
        onOwningThread(element) {
            var values: CFArray?
            guard
                AXUIElementCopyMultipleAttributeValues(
                    element, attributes as CFArray, [], &values) == .success,
                let values = values as? [CFTypeRef], values.count == attributes.count
            else { return [:] }
            var answered: [String: CFTypeRef] = [:]
            for (attribute, value) in zip(attributes, values) {
                if let marker = axValue(value), AXValueGetType(marker) == .axError { continue }
                answered[attribute] = value
            }
            return answered
        }
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

    /// Performs the press action on `element` itself, as opposed to `press(_:button:)`, which
    /// resolves one of an element's own *button* attributes first. This is what switching a browser
    /// tab means: the `AXRadioButton` the tab list exposes is the thing to press, not a sub-attribute
    /// of it.
    static func performPress(_ element: AXUIElement) {
        onOwningThread(element) {
            AXUIElementPerformAction(element, kAXPressAction as CFString)
        }
    }

    /// An attribute read as an integer, folding in the boolean shape some hosts answer with (Safari's
    /// tab `AXValue` is a number; other attributes of the same shape could come back as a `CFBoolean`
    /// depending on the host). `copyBool` already covers the case where the caller only cares about
    /// true/false; this is for the tab search, which reads Safari's `AXValue == 1` as the active-tab
    /// marker.
    static func copyInt(_ element: AXUIElement, _ attribute: String) -> Int? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            if let number = value as? Int { return number }
            if let flag = value as? Bool { return flag ? 1 : 0 }
            return nil
        }
    }

    /// The window's on-screen origin (top-left, Quartz global coordinates).
    static func position(_ window: AXUIElement) -> CGPoint? {
        cgPoint(copyAXValue(window, kAXPositionAttribute))
    }

    static func size(_ window: AXUIElement) -> CGSize? {
        cgSize(copyAXValue(window, kAXSizeAttribute))
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

    /// Position and size as one rectangle, in one message and one hop — see `copyAttributes` and
    /// `onOwningThread`.
    static func frame(_ window: AXUIElement) -> CGRect? {
        let values = copyAttributes(window, [kAXPositionAttribute, kAXSizeAttribute])
        guard let origin = cgPoint(values[kAXPositionAttribute]),
            let size = cgSize(values[kAXSizeAttribute])
        else { return nil }
        return CGRect(origin: origin, size: size)
    }

    /// Writes a frame in a single hop.
    ///
    /// `repositionAfterSizing` is the "position, size, position" dance the tilers do: some apps
    /// clamp a move against their current size and others clamp a resize against the screen edge
    /// from their old origin, and setting the origin on both sides of the resize is what makes both
    /// land. A move needs none of it — the size is not changing — so it asks for neither.
    static func setFrame(
        _ window: AXUIElement, _ frame: CGRect, sizing: Bool, repositionAfterSizing: Bool = false
    ) {
        onOwningThread(window) {
            setPosition(window, frame.origin)
            guard sizing else { return }
            setSize(window, frame.size)
            if repositionAfterSizing { setPosition(window, frame.origin) }
        }
    }

    /// The app's frontmost *real* window — the one a window-management action should act on.
    ///
    /// Two things this cannot be a bare `kAXFocusedWindow` read. First, focus lands on palettes,
    /// inspectors and sheets as readily as on documents, and snapping a Find panel to half the
    /// screen is never what the user meant; `isSwitchableWindow` is the same filter the switcher's
    /// own window list uses. Second, `kAXFocusedWindow` comes back empty for some apps
    /// (Electron/Catalyst), which is why this walks three attributes — focused, then main, then the
    /// window list. `SwitchTarget.resolveWindow` calls this rather than keeping its own copy of the
    /// walk, which it used to, without the filter: an app-mode close aimed at TextEdit closed its
    /// Find panel.
    static func frontWindow(ofApplication pid: pid_t) -> AXUIElement? {
        let app = application(pid)
        let candidates = [
            copyElement(app, kAXFocusedWindowAttribute as String),
            copyElement(app, kAXMainWindowAttribute as String),
        ].compactMap { $0 }
        if let real = candidates.first(where: isSwitchableWindow) { return real }
        // Read once: the fallback below wants the same list, and a second read is a second
        // round trip to an app that has already been slow enough to get us this far.
        let windows = windows(of: app)
        if let window = windows.first(where: isSwitchableWindow) { return window }
        // Nothing passed the filter. Fall back to whatever focus reported rather than doing
        // nothing at all: an app whose only window reports an unexpected subrole is still a window
        // the user is looking at, and refusing to move it is the worse failure.
        return candidates.first ?? windows.first(where: isWindow)
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
        let app = application(pid)
        // The whole walk inside one hop. For another process this changes nothing — `onOwningThread`
        // runs inline there — but for this app's own windows it is the difference between one
        // `main.sync` and `2n + 1` of them, on the thread the keyboard tap is serviced from.
        return onOwningThread(app) {
            windows(of: app).first { window in
                guard let frame = AX.frame(window) else { return false }
                return abs(frame.origin.x - bounds.minX) < tolerance
                    && abs(frame.origin.y - bounds.minY) < tolerance
                    && abs(frame.width - bounds.width) < tolerance
                    && abs(frame.height - bounds.height) < tolerance
            }
        }
    }

    /// One of an app's windows read ahead for `index(of:bounds:in:)`: the element, the window
    /// number it reports (nil on hosts whose windows resolve to none), and where it is.
    struct ListedWindow {
        let element: AXUIElement
        let id: CGWindowID?
        let frame: CGRect
    }

    /// Every window of the app with its id and frame, read in one hop so a caller matching several
    /// window-server entries against one app walks its list once rather than once per entry.
    static func listedWindows(ofApplication pid: pid_t) -> [ListedWindow] {
        let app = application(pid)
        return onOwningThread(app) {
            windows(of: app).compactMap { window in
                frame(window).map {
                    ListedWindow(element: window, id: TargetProvider.windowID(window), frame: $0)
                }
            }
        }
    }

    /// Which of `listed` the window-server entry `id` at `bounds` is.
    ///
    /// By id first: a frame is not an identity, and two windows of one app at the same frame — both
    /// maximized, both tiled to the same half, both dropped on the laptop screen when a display went
    /// away — matched by frame alone both resolve to whichever is first in the list, so the second
    /// is either skipped or written twice. The frame is the fallback for windows that report no id,
    /// and only for those: a listed window whose id is known and differs is a different window that
    /// happens to sit there, however exactly its frame matches.
    static func index(
        of id: CGWindowID, bounds: CGRect, in listed: [ListedWindow], tolerance: CGFloat = 4
    ) -> Int? {
        if let exact = listed.firstIndex(where: { $0.id == id }) { return exact }
        return listed.firstIndex { window in
            window.id == nil
                && abs(window.frame.minX - bounds.minX) < tolerance
                && abs(window.frame.minY - bounds.minY) < tolerance
                && abs(window.frame.width - bounds.width) < tolerance
                && abs(window.frame.height - bounds.height) < tolerance
        }
    }

    /// `window(ofApplication:matching:)` for a caller that also knows the window's id, which is the
    /// match to prefer — see `index(of:bounds:in:)`.
    static func window(ofApplication pid: pid_t, id: CGWindowID, matching bounds: CGRect)
        -> AXUIElement?
    {
        let listed = listedWindows(ofApplication: pid)
        return index(of: id, bounds: bounds, in: listed).map { listed[$0].element }
    }

    private static func copyAXValue(_ element: AXUIElement, _ attribute: String) -> AXValue? {
        onOwningThread(element) {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success
            else { return nil }
            return axValue(value)
        }
    }

    /// `value` as an `AXValue`, or nil when it is anything else — a string, a boolean, nothing.
    private static func axValue(_ value: CFTypeRef?) -> AXValue? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        return (value as! AXValue)
    }

    private static func cgPoint(_ value: CFTypeRef?) -> CGPoint? {
        guard let value = axValue(value) else { return nil }
        var point = CGPoint.zero
        return AXValueGetValue(value, .cgPoint, &point) ? point : nil
    }

    private static func cgSize(_ value: CFTypeRef?) -> CGSize? {
        guard let value = axValue(value) else { return nil }
        var size = CGSize.zero
        return AXValueGetValue(value, .cgSize, &size) ? size : nil
    }
}
