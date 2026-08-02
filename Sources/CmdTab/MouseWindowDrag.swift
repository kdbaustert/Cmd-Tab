import AppKit
import ApplicationServices
import CoreGraphics

// Hold a modifier and drag anywhere in a window to move it; hold the other and drag to resize it.
// The gesture window managers on every other platform have had for decades, and the one people
// coming from Rectangle expect: no aiming at a 4pt border, no finding the titlebar under a full
// screen of content.
//
// Different in kind from `DragSnap`, which watches an ordinary drag passively and acts once it is
// dropped. This one *is* the drag: while a chord is held, the mouse events belong to us and never
// reach the app underneath, or a move across a document would select text all the way as it went.
// That means a real event tap rather than an `NSEvent` monitor, and it means the tap has to be very
// careful about what it swallows — see `MouseWindowDrag.handle`.

/// Which corner of a window a resize is anchored to. The one *opposite* the dragged corner stays
/// exactly where it is, which is what makes a resize feel like grabbing the window's edge.
enum ResizeCorner: CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// The two things a modifier-drag can do.
enum MouseDragAction: String, CaseIterable, Identifiable {
    case move, resize

    var id: String { rawValue }

    var title: String {
        switch self {
        case .move: return "Move"
        case .resize: return "Resize"
        }
    }

    /// ⌃⌥ moves, ⌃⌘ resizes — the combination Rectangle uses, so someone arriving from it does not
    /// have to learn a new one. Both are free on macOS with the mouse: nothing in the system drags
    /// on either.
    var defaultChord: ModifierChord {
        switch self {
        case .move: return ModifierChord([.maskControl, .maskAlternate])
        case .resize: return ModifierChord([.maskControl, .maskCommand])
        }
    }
}

/// A modifier combination, recorded rather than chosen from a list: there are fifteen usable
/// combinations of ⌃⌥⌘⇧ and no reason to decide for someone which four of them they may have.
///
/// Stored as the raw `CGEventFlags` bits, masked to the four that can be held — a stray device
/// flag (numeric pad, function, caps lock) rides along on real events and would never compare
/// equal to a recorded chord if it were kept.
struct ModifierChord: Equatable {
    var rawValue: UInt64

    static let allowed: CGEventFlags = [.maskControl, .maskAlternate, .maskCommand, .maskShift]

    init(_ flags: CGEventFlags) {
        rawValue = flags.intersection(Self.allowed).rawValue
    }

    init(rawValue: UInt64) {
        self.init(CGEventFlags(rawValue: rawValue))
    }

    var flags: CGEventFlags { CGEventFlags(rawValue: rawValue) }

    /// Whether this is safe to bind. ⇧ alone — or nothing at all — would make every ordinary drag
    /// in every app a window drag, so at least one of ⌃/⌥/⌘ is required and ⇧ is only a qualifier
    /// on top.
    var isUsable: Bool {
        !flags.intersection([.maskControl, .maskAlternate, .maskCommand]).isEmpty
    }

    /// Menu order, the same one macOS shows: ⌃⌥⇧⌘.
    var displayString: String {
        guard isUsable else { return "Not set" }
        var out = ""
        if flags.contains(.maskControl) { out += "⌃" }
        if flags.contains(.maskAlternate) { out += "⌥" }
        if flags.contains(.maskShift) { out += "⇧" }
        if flags.contains(.maskCommand) { out += "⌘" }
        return out
    }
}

/// What the feature is set to, as a value the tap can read.
struct MouseDragSettings: Equatable {
    var isEnabled: Bool = false
    var move: ModifierChord = MouseDragAction.move.defaultChord
    var resize: ModifierChord = MouseDragAction.resize.defaultChord

    func chord(for action: MouseDragAction) -> ModifierChord {
        action == .move ? move : resize
    }

    mutating func set(_ chord: ModifierChord, for action: MouseDragAction) {
        switch action {
        case .move: move = chord
        case .resize: resize = chord
        }
    }

    /// The action a press with these modifiers starts, if any.
    ///
    /// Exact match on all four bindable modifiers, the same rule the tiling chords use: ⌃⌥ must not
    /// also fire while ⌃⌥⌘ is held, or one binding would shadow the other the moment it was a
    /// subset. Move is tested first, so pointing both at one chord resolves the same way every time
    /// rather than depending on which comparison ran.
    func action(for flags: CGEventFlags) -> MouseDragAction? {
        guard isEnabled else { return nil }
        let held = flags.intersection(ModifierChord.allowed)
        if move.isUsable, held == move.flags { return .move }
        if resize.isUsable, held == resize.flags { return .resize }
        return nil
    }
}

// MARK: - Geometry

/// The frame maths, kept apart from the event plumbing so it can be tested without a window, a
/// mouse, or a screen. Every frame here is in Accessibility coordinates — top-left origin, y
/// growing downward — matching `WindowTiler`.
enum MouseDragGeometry {
    /// Nothing may be dragged smaller than this. AX lets an app refuse a size, but plenty accept a
    /// 1×1 and become unrecoverable — there is no titlebar left to grab.
    static let minimumSize = CGSize(width: 120, height: 90)

    /// The window moved by a cursor delta. Pure translation: a move never changes the size.
    static func moved(_ frame: CGRect, by delta: CGSize) -> CGRect {
        CGRect(
            x: frame.origin.x + delta.width, y: frame.origin.y + delta.height,
            width: frame.width, height: frame.height)
    }

    /// Which corner the press landed nearest, and therefore which one the drag carries.
    ///
    /// Quadrants rather than a border band: the whole point of the gesture is not having to hit an
    /// edge, so pressing anywhere in the bottom-right quarter resizes from the bottom-right.
    static func corner(for point: CGPoint, in frame: CGRect) -> ResizeCorner {
        let right = point.x >= frame.midX
        let bottom = point.y >= frame.midY
        switch (bottom, right) {
        case (false, false): return .topLeft
        case (false, true): return .topRight
        case (true, false): return .bottomLeft
        case (true, true): return .bottomRight
        }
    }

    /// The window resized by a cursor delta, with `corner` following the cursor and the opposite
    /// corner pinned.
    ///
    /// Clamped at `minimumSize` on each axis independently, and clamped so a corner that would drag
    /// *past* its anchor stops at the minimum rather than inverting the frame — a negative width is
    /// a rect AX will happily accept and never render.
    static func resized(
        _ frame: CGRect, corner: ResizeCorner, by delta: CGSize,
        minimum: CGSize = minimumSize
    ) -> CGRect {
        var left = frame.minX
        var top = frame.minY
        var right = frame.maxX
        var bottom = frame.maxY

        switch corner {
        case .topLeft:
            left = min(frame.minX + delta.width, right - minimum.width)
            top = min(frame.minY + delta.height, bottom - minimum.height)
        case .topRight:
            right = max(frame.maxX + delta.width, left + minimum.width)
            top = min(frame.minY + delta.height, bottom - minimum.height)
        case .bottomLeft:
            left = min(frame.minX + delta.width, right - minimum.width)
            bottom = max(frame.maxY + delta.height, top + minimum.height)
        case .bottomRight:
            right = max(frame.maxX + delta.width, left + minimum.width)
            bottom = max(frame.maxY + delta.height, top + minimum.height)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

// MARK: - The gesture

/// The thread the mouse tap runs on.
///
/// Not the main run loop, unlike the keyboard tap in `EventTap`. A tap callback runs *synchronously*
/// on whichever run loop owns it, and the system kills a tap that overruns its deadline — on the
/// main thread that deadline is shared with every SwiftUI layout pass and settings redraw. Mouse
/// drags arrive at 120Hz for as long as a gesture lasts, so this one gets a thread of its own where
/// nothing else can hold it up. Rectangle's own `ActiveEventMonitor` does the same, for the same
/// reason.
private final class TapThread: Thread, @unchecked Sendable {
    private let ready = DispatchSemaphore(value: 0)
    private(set) var runLoop: CFRunLoop?

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        // A run loop with no sources returns immediately, and the source is added by the caller a
        // moment after this signals — so the loop is run in short slices rather than left to exit.
        while !isCancelled {
            CFRunLoopRunInMode(.defaultMode, 0.25, false)
        }
    }

    /// Blocks until `runLoop` is set. Called once, from `install`.
    func waitUntilReady() {
        ready.wait()
    }
}

/// Owns the mouse tap and the drag in progress.
///
/// The tap is created only while the feature is on: it sees every mouse-down on the machine, and an
/// idle install would be pure cost for someone who does not want the gesture.
///
/// Not a `@MainActor` type, because the tap callback no longer runs there: the gesture state is
/// guarded by `lock` and touched from three places — the tap thread (every event), the Accessibility
/// queue (each write completing), and the main thread (settings changing). `@unchecked Sendable` is
/// the claim that `lock` covers all of it; everything mutable below is private and taken under it.
final class MouseWindowDrag: @unchecked Sendable {
    private let lock = NSLock()

    private var storedSettings = MouseDragSettings()
    var settings: MouseDragSettings {
        get { lock.withLock { storedSettings } }
        set {
            let changed: Bool = lock.withLock {
                guard storedSettings != newValue else { return false }
                storedSettings = newValue
                return true
            }
            guard changed else { return }
            newValue.isEnabled ? install() : uninstall()
        }
    }

    /// Per-app overrides, so an app marked "never tile" is not dragged around either.
    var appRules: [String: AppRule] {
        get { lock.withLock { storedAppRules } }
        set { lock.withLock { storedAppRules = newValue } }
    }
    private var storedAppRules: [String: AppRule] = [:]

    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var thread: TapThread?
    private var screenObserver: NSObjectProtocol?

    /// The drag in flight. Resolved asynchronously on the press, so this is nil for the first few
    /// milliseconds of a gesture that is nonetheless already ours.
    ///
    /// Deliberately holds no `AXUIElement`: that lives in `draggedWindow`, on the queue that is the
    /// only thing allowed to touch it. An accessibility element is a CF type with no Sendable
    /// guarantee, and passing one between threads is exactly the trip it must not make.
    private struct Session {
        let action: MouseDragAction
        let pid: pid_t
        let startFrame: CGRect
        let startMouse: CGPoint
        let corner: ResizeCorner
    }

    /// One display, in both coordinate spaces the gesture needs: Cocoa's bottom-up `frame` for the
    /// zone test, Accessibility's top-left `area` for the frame a zone resolves to.
    ///
    /// Cached rather than read per event: `NSScreen` is main-thread-only and this is consulted on
    /// every drag event, on the tap thread, where a hop to main would be both wrong and far too
    /// slow. Refreshed when the displays change, which is the only time it can go stale.
    struct Display: Sendable {
        let frame: CGRect
        let area: CGRect
    }

    /// The window being dragged. Touched only on `queue`, which is serial — the same arrangement
    /// `WindowTiler` uses for its restore and cycle tables, and what keeps it safe without a lock.
    private nonisolated(unsafe) static var draggedWindow: AXUIElement?

    /// The tiling gap, so a snap through this gesture lands where the keyboard chords put it.
    var gap: CGFloat {
        get { lock.withLock { storedGap } }
        set { lock.withLock { storedGap = newValue } }
    }
    private var storedGap: CGFloat = 0

    private var displays: [Display] = []
    /// The height of the primary display, for turning the tap's top-left point into the bottom-up
    /// one `DragSnap.zone` works in.
    private var primaryHeight: CGFloat = 0

    private var session: Session?
    /// The zone the cursor is currently over, if any. Set on the tap thread, cleared on release —
    /// and what decides whether the drop tiles the window or leaves it where the drag put it.
    private var zone: WindowArrangement?
    /// True from the press that armed a gesture until the release, whether or not the window has
    /// been resolved yet. What decides that an event is ours to swallow.
    private var isArmed = false
    /// Set while an Accessibility write is in flight, so a 120Hz stream of drag events cannot queue
    /// up hundreds of frames the user will never see. The newest target always wins.
    private var isWriting = false
    private var pending: CGRect?

    /// Accessibility writes are IPC and can block on a wedged app; the tap callback is the one place
    /// they must never happen.
    private let queue = DispatchQueue(label: "com.cmdtab.mousedrag", qos: .userInteractive)

    // MARK: Tap

    private func install() {
        guard tap == nil else { return }
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)
            | (1 << CGEventType.leftMouseDragged.rawValue)
            | (1 << CGEventType.leftMouseUp.rawValue)

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, refcon in
                guard let refcon else { return Unmanaged.passUnretained(event) }
                let drag = Unmanaged<MouseWindowDrag>.fromOpaque(refcon).takeUnretainedValue()
                return drag.dispatch(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.general.error("mouse drag: could not create the event tap")
            return
        }
        let thread = TapThread()
        thread.qualityOfService = .userInteractive
        thread.name = "com.cmdtab.mousedrag.tap"
        thread.start()
        thread.waitUntilReady()
        guard let runLoop = thread.runLoop else {
            Log.general.error("mouse drag: tap thread has no run loop")
            CFMachPortInvalidate(tap)
            thread.cancel()
            return
        }

        // `NSScreen` is main-thread-only and `install` may be called from anywhere, so the cache is
        // filled on the main actor a moment from now. Nothing needs it until a drag is in flight,
        // and an empty cache simply means no zone matches — the gesture still moves the window.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshDisplays()
            // The only thing that can invalidate the cache. Registered here rather than in `init` so
            // a user who never turns the gesture on never carries the observer either.
            let observer = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.refreshDisplays() }
            }
            self.lock.withLock { self.screenObserver = observer }
        }

        self.tap = tap
        self.thread = thread
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .defaultMode)
        CGEvent.tapEnable(tap: tap, enable: true)
        let current = settings
        Log.general.notice(
            """
            mouse drag: tap installed on its own thread, \
            move=\(current.move.displayString, privacy: .public) \
            resize=\(current.resize.displayString, privacy: .public)
            """)
    }

    private func uninstall() {
        if let source, let runLoop = thread?.runLoop {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        thread?.cancel()
        let observer: NSObjectProtocol? = lock.withLock {
            defer { screenObserver = nil }
            return screenObserver
        }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        source = nil
        tap = nil
        thread = nil
        end()
    }

    private func dispatch(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Same contract as `EventTap`: a tap the system has switched off stays off until re-enabled,
        // and here that would strand a drag mid-gesture with the mouse already captured.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            Log.general.notice("mouse drag: tap disabled, re-enabling")
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            end()
            return Unmanaged.passUnretained(event)
        }
        return handle(type: type, event: event) ? nil : Unmanaged.passUnretained(event)
    }

    /// The whole gesture, on the tap thread. Returns true to swallow the event.
    ///
    /// Nothing here does Accessibility work: the press hands off to `queue` to resolve the window,
    /// and each drag posts a frame to the same queue. This runs only the arithmetic and one
    /// uncontended lock, which is what keeps it inside the system's deadline — overrun it and the
    /// tap is killed, taking every click on the machine with it.
    private func handle(type: CGEventType, event: CGEvent) -> Bool {
        let location = event.location
        switch type {
        case .leftMouseDown:
            let current = settings
            let held = event.flags.intersection(ModifierChord.allowed)
            guard let action = current.action(for: event.flags) else {
                // Only when something was held: an unmodified click is every click on the machine,
                // and logging those would be a line per click forever.
                if !held.isEmpty {
                    Log.general.notice(
                        "mouse drag: no action for \(ModifierChord(held).displayString, privacy: .public)")
                }
                return false
            }
            guard let target = Self.window(at: location) else {
                Log.general.notice(
                    """
                    mouse drag: \(action.rawValue, privacy: .public) at \
                    \(location.x, privacy: .public),\(location.y, privacy: .public) — no window there
                    """)
                return false
            }
            Log.general.notice(
                """
                mouse drag: \(action.rawValue, privacy: .public) armed on pid \
                \(target.pid, privacy: .public)
                """)
            lock.withLock {
                isArmed = true
                session = nil
            }
            resolve(target: target, action: action, at: location)
            // Swallowed from the press onwards. Letting the press through and taking only the drags
            // would put a click into whatever was under the cursor — a button, a link, a text
            // caret — every time the gesture started.
            return true

        case .leftMouseDragged:
            let state: (armed: Bool, session: Session?) = lock.withLock { (isArmed, session) }
            guard state.armed else { return false }
            guard let session = state.session else { return true }  // still resolving; still ours
            let delta = CGSize(
                width: location.x - session.startMouse.x,
                height: location.y - session.startMouse.y)
            let frame =
                session.action == .move
                ? MouseDragGeometry.moved(session.startFrame, by: delta)
                : MouseDragGeometry.resized(session.startFrame, corner: session.corner, by: delta)
            write(frame, isMove: session.action == .move)
            // The window follows the cursor either way; the overlay says where letting go will
            // actually put it. Both gestures snap, since a resize dragged into a corner means the
            // same thing a move dragged there does.
            updatePreview(at: location)
            return true

        case .leftMouseUp:
            let state: (armed: Bool, zone: WindowArrangement?, session: Session?) = lock.withLock {
                (isArmed, zone, session)
            }
            guard state.armed else { return false }
            if let zone = state.zone, let session = state.session {
                Log.general.notice(
                    "mouse drag: dropped in \(zone.rawValue, privacy: .public)")
                let gap = self.gap
                // Off the tap thread: this reads screens on the main actor and then does the same
                // Accessibility write the keyboard chords do.
                Task { @MainActor in
                    WindowTiler.apply(
                        zone, pid: session.pid, areas: WindowTiler.visibleAreas(),
                        cycleWidths: false, gap: gap)
                }
            }
            end()
            return true

        default:
            return false
        }
    }

    /// Resolves the window under the press and captures the frame the gesture is measured from.
    private func resolve(
        target: (pid: pid_t, bounds: CGRect), action: MouseDragAction, at point: CGPoint
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            // An app the user has told us never to tile drags exactly as it always did. Checked on
            // this queue rather than the tap thread: it reaches `NSRunningApplication` for the
            // bundle id, which is not work the callback may do.
            if let id = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier,
                self.appRules[id]?.neverTile == true {
                self.end()
                return
            }
            let element = Self.axWindow(pid: target.pid, bounds: target.bounds)
            guard let element, let origin = AX.position(element), let size = AX.size(element) else {
                Log.general.notice(
                    "mouse drag: no accessible window for pid \(target.pid, privacy: .public)")
                self.end()
                return
            }
            Self.draggedWindow = element
            Log.general.notice(
                "mouse drag: resolved window for pid \(target.pid, privacy: .public)")
            let frame = CGRect(origin: origin, size: size)
            self.lock.withLock {
                guard self.isArmed else { return }
                self.session = Session(
                    action: action, pid: target.pid, startFrame: frame, startMouse: point,
                    corner: MouseDragGeometry.corner(for: point, in: frame))
            }
        }
    }

    /// Applies a frame, coalescing anything that arrives while a write is still in flight.
    ///
    /// Without the coalescing a 120Hz trackpad queues frames faster than an app can accept them, and
    /// the window keeps travelling for a second after the mouse has stopped. Only the newest target
    /// matters: every frame in between is a position the user has already dragged past.
    private func write(_ frame: CGRect, isMove: Bool) {
        let go: Bool = lock.withLock {
            guard !isWriting else {
                pending = frame
                return false
            }
            isWriting = true
            return true
        }
        guard go else { return }
        queue.async { [weak self] in
            guard let self else { return }
            if let window = Self.draggedWindow {
                if isMove {
                    AX.setPosition(window, frame.origin)
                } else {
                    // Position first, then size: a resize from a top or left corner moves the origin
                    // as well, and an app that clamps a move against its current size needs the
                    // origin set before the size that makes room for it.
                    AX.setPosition(window, frame.origin)
                    AX.setSize(window, frame.size)
                }
            }
            let next: CGRect? = self.lock.withLock {
                self.isWriting = false
                defer { self.pending = nil }
                return self.pending
            }
            if let next { self.write(next, isMove: isMove) }
        }
    }

    private func end() {
        let hadZone: Bool = lock.withLock {
            let had = zone != nil
            isArmed = false
            session = nil
            pending = nil
            zone = nil
            return had
        }
        if hadZone { Task { @MainActor in SnapPreview.shared.hide() } }
        queue.async { Self.draggedWindow = nil }
    }

    /// Snapshots the displays in both coordinate spaces. Main-thread work, by `NSScreen`'s rules.
    @MainActor
    private func refreshDisplays() {
        let areas = WindowTiler.visibleAreas()
        let height =
            (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)?.frame.height ?? 0
        // `visibleAreas` is built by mapping `NSScreen.screens`, so the two lists are index-aligned.
        let snapshot = NSScreen.screens.enumerated().compactMap { index, screen -> Display? in
            guard index < areas.count else { return nil }
            return Display(frame: screen.frame, area: areas[index])
        }
        lock.withLock {
            displays = snapshot
            primaryHeight = height
        }
    }

    /// The snap zone under a tap-space point, and the display it belongs to.
    ///
    /// `DragSnap.zone` reasons in Cocoa's bottom-up space — it is written against `NSScreen.frame`
    /// — so the event location is flipped first. Shared with the titlebar drag deliberately: an
    /// edge that snaps one way has to snap the same way the other, or the two gestures would
    /// disagree about where the left half begins.
    private func snapZone(at point: CGPoint) -> (zone: WindowArrangement, area: CGRect)? {
        let (screens, height) = lock.withLock { (displays, primaryHeight) }
        let flipped = CGPoint(x: point.x, y: height - point.y)
        for display in screens where display.frame.contains(flipped) {
            guard let zone = DragSnap.zone(for: flipped, in: display.frame) else { return nil }
            return (zone, display.area)
        }
        return nil
    }

    /// Shows or hides the overlay for the zone the cursor is over. Called on every drag event, so it
    /// hops to main only when the zone actually changes.
    private func updatePreview(at point: CGPoint) {
        let match = snapZone(at: point)
        let changed: Bool = lock.withLock {
            guard zone != match?.zone else { return false }
            zone = match?.zone
            return true
        }
        guard changed else { return }
        let gap = self.gap
        guard let match, let frame = match.zone.frame(
            in: match.area, current: match.area, fraction: 0.5)
        else {
            Task { @MainActor in SnapPreview.shared.hide() }
            return
        }
        let target = match.zone.takesGap
            ? TilingGap.inset(frame, in: match.area, gap: gap) : frame
        Task { @MainActor in SnapPreview.shared.show(target) }
    }

    // MARK: Lookup

    /// The pid and bounds of the frontmost ordinary window under a screen point.
    ///
    /// `CGWindowListCopyWindowInfo` rather than Accessibility, for the same reason `DragSnap` uses
    /// it: this runs on every left click on the machine, and the window list is one cheap call where
    /// an AX hit test is IPC to whichever app was clicked. The event's location is already in
    /// top-left coordinates, which is the space the window list reports.
    static func window(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        let mine = ProcessInfo.processInfo.processIdentifier
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                bounds.contains(point)
            else { continue }
            // Front-most match wins — the list is in z-order — so a window behind another cannot
            // claim a press that landed on the one on top. Our own windows included: stopping here
            // rather than skipping them means the settings window is never dragged *through*.
            return pid == mine ? nil : (pid, bounds)
        }
        return nil
    }

    /// The Accessibility element for the window whose frame matches `bounds`.
    ///
    /// Matched on frame rather than taken as the app's focused window: the gesture acts on the
    /// window under the cursor, which for an app with several windows open is routinely not the one
    /// with focus. Falls back to the front window when nothing matches, which covers the hosts whose
    /// AX frames drift a point from the window list's (Electron, Catalyst).
    private static func axWindow(pid: pid_t, bounds: CGRect) -> AXUIElement? {
        let windows = AX.windows(of: AX.application(pid))
        let tolerance: CGFloat = 4
        let match = windows.first { window in
            guard let origin = AX.position(window), let size = AX.size(window) else { return false }
            return abs(origin.x - bounds.minX) < tolerance && abs(origin.y - bounds.minY) < tolerance
                && abs(size.width - bounds.width) < tolerance
                && abs(size.height - bounds.height) < tolerance
        }
        return match ?? AX.frontWindow(ofApplication: pid)
    }
}


// MARK: - Hold-and-point gesture

/// Snap a window by *pointing*, with no mouse button involved.
///
/// Hold the chord and the window under the cursor is outlined; move the cursor away from where it
/// started and the destination lights up; release the chord and the window goes there. This is the
/// gesture Rectangle Pro inherited from Hookshot — "press and hold control and command, a dot
/// appears under your cursor, move away from the dot in a direction, release, and the window is
/// snapped" — and the reason it is worth having alongside the drag is that it needs no grab: the
/// window never has to be clicked, focused, or even frontmost.
///
/// The target is fixed when the chord goes down. It has to be: the cursor then travels away from
/// the window to say *where*, and re-reading what is under it mid-gesture would retarget the
/// gesture onto whatever it flew over.
enum PointDirection {
    /// The zone a cursor offset from the anchor asks for, or nil if the offset is meaningless.
    ///
    /// Eight sectors and a dead zone, in Cocoa's y-up space. Staying put means the whole screen:
    /// that is the one "direction" with nowhere to point, and taking the whole display is the
    /// natural thing for it to mean.
    static func zone(for delta: CGSize, deadZone: CGFloat = 45) -> WindowArrangement {
        let distance = hypot(delta.width, delta.height)
        guard distance >= deadZone else { return .maximize }

        // Sectors of 45°, measured from due east and running anticlockwise.
        let degrees = atan2(delta.height, delta.width) * 180 / .pi
        let normalised = degrees < 0 ? degrees + 360 : degrees
        switch normalised {
        case 0..<22.5, 337.5...360: return .rightHalf
        case 22.5..<67.5: return .topRight
        case 67.5..<112.5: return .topHalf
        case 112.5..<157.5: return .topLeft
        case 157.5..<202.5: return .leftHalf
        case 202.5..<247.5: return .bottomLeft
        case 247.5..<292.5: return .bottomHalf
        default: return .bottomRight
        }
    }
}

/// Drives the hold-and-point gesture, and outlines the window it would act on.
///
/// Passive `NSEvent` monitors throughout: nothing is pressed, so there is nothing to consume, and a
/// tap here would take modifier keys away from every app on the machine for no gain.
///
/// Global monitors only, so the gesture never targets Cmd-Tab's own settings window.
@MainActor
final class ModifierTargetHighlight {
    var settings = MouseDragSettings() {
        didSet {
            guard settings != oldValue else { return }
            settings.isEnabled ? install() : uninstall()
        }
    }

    /// The tiling gap, so a pointed snap lands exactly where the keyboard chords put it.
    var gap: CGFloat = 0

    private var flagsMonitor: Any?
    private var moveMonitor: Any?
    private let outline = TargetOutline()
    private let dot = AnchorDot()

    /// Where the cursor was when the chord went down, in Cocoa's bottom-up space.
    private var anchor: CGPoint?
    /// The window the gesture will act on, fixed at chord-down.
    private var target: (pid: pid_t, bounds: CGRect)?
    /// The destination currently being offered.
    private var zone: WindowArrangement?

    private func install() {
        guard flagsMonitor == nil else { return }
        flagsMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
        }
    }

    private func uninstall() {
        if let flagsMonitor { NSEvent.removeMonitor(flagsMonitor) }
        flagsMonitor = nil
        cancel()
    }

    /// The chord going down starts the gesture; letting it go completes one.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        var held: CGEventFlags = []
        if flags.contains(.command) { held.insert(.maskCommand) }
        if flags.contains(.option) { held.insert(.maskAlternate) }
        if flags.contains(.control) { held.insert(.maskControl) }
        if flags.contains(.shift) { held.insert(.maskShift) }

        guard settings.action(for: held) != nil else {
            complete()
            return
        }
        guard anchor == nil else { return }  // already in a gesture; a qualifier changed, no more

        let point = NSEvent.mouseLocation
        guard let target = Self.windowUnderCursor(at: point) else { return }
        anchor = point
        self.target = target
        outline.show(target.bounds)
        // The anchor stays put while the cursor leaves it: the gesture is a direction, and a
        // direction needs both ends visible to be read.
        dot.show(at: point)
        Log.general.notice(
            "point gesture: armed on pid \(target.pid, privacy: .public)")

        if moveMonitor == nil {
            // Only while the chord is held: this fires on every pixel of cursor travel, which is
            // far too hot to carry for the whole session just in case.
            moveMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.follow() }
            }
        }
        follow()
    }

    /// Offers the zone the cursor is currently pointing at.
    private func follow() {
        guard let anchor else { return }
        let point = NSEvent.mouseLocation
        let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
        let next = PointDirection.zone(for: delta)
        guard next != zone else { return }
        zone = next
        showPreview(next, near: anchor)
    }

    /// Draws the destination on the display the gesture started on.
    private func showPreview(_ zone: WindowArrangement, near point: CGPoint) {
        guard let index = NSScreen.screens.firstIndex(where: { $0.frame.contains(point) }) else {
            return
        }
        let areas = WindowTiler.visibleAreas()
        guard index < areas.count else { return }
        let area = areas[index]
        guard let frame = zone.frame(in: area, current: area, fraction: 0.5) else { return }
        SnapPreview.shared.show(zone.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame)
    }

    /// The chord came up: snap to whatever was being offered.
    private func complete() {
        defer { cancel() }
        guard let zone, let target else { return }
        Log.general.notice(
            """
            point gesture: snapping pid \(target.pid, privacy: .public) to \
            \(zone.rawValue, privacy: .public)
            """)
        let gap = self.gap
        WindowTiler.apply(
            zone, pid: target.pid, areas: WindowTiler.visibleAreas(), cycleWidths: false, gap: gap)
    }

    private func cancel() {
        if let moveMonitor { NSEvent.removeMonitor(moveMonitor) }
        moveMonitor = nil
        anchor = nil
        target = nil
        zone = nil
        outline.hide()
        dot.hide()
        SnapPreview.shared.hide()
    }

    /// The window under a Cocoa-space point, in the top-left space the overlays and the window list
    /// both use.
    private static func windowUnderCursor(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)
        else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.height - point.y)
        return MouseWindowDrag.window(at: flipped)
    }
}

/// A border drawn around the window a gesture is about to act on.
///
/// Deliberately an outline where `SnapPreview` is a filled block: one says "this is the window",
/// the other says "this is where it will land", and a gesture that goes from one to the other should
/// not look like the same thing moving.
@MainActor
private final class TargetOutline {
    private var panel: NSPanel?

    /// `frame` is in the window list's top-left space; the panel wants Cocoa's bottom-up one.
    func show(_ frame: CGRect) {
        let panel = self.panel ?? make()
        self.panel = panel
        // Painted on every show and nowhere else, so a change of appearance never leaves a stale
        // outline behind and there is only ever one copy of these values.
        if let layer = panel.contentView?.layer {
            layer.borderColor = SnapAppearance.shared.outline.cgColor
            layer.borderWidth = SnapAppearance.borderWidth
            layer.cornerRadius = SnapAppearance.outlineCornerRadius
        }
        guard let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)
        else { return }
        let rect = NSRect(
            x: frame.minX, y: primary.frame.height - frame.maxY,
            width: frame.width, height: frame.height)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Outline only, no wash: the targeted window is one you are looking at and reading, and a tint
    /// over the whole of it obscures the very thing it is pointing out. The landing block is filled
    /// precisely because there is nothing underneath it worth seeing.
    private func make() -> NSPanel { OverlayPanel.make(level: .floating) }
}


/// The dot the hold-and-point gesture starts from, marking where the cursor was when the chord went
/// down.
///
/// Hookshot's own affordance, and it earns its place: without it the gesture has one visible end —
/// you can see where the window will go but not what the direction is being measured from, which
/// matters most in the dead zone, where "near the dot" is the difference between maximize and a
/// half.
@MainActor
private final class AnchorDot {
    private static let diameter: CGFloat = 14
    private var panel: NSPanel?

    /// `point` is in Cocoa's bottom-up space — straight from `NSEvent.mouseLocation`, no flip.
    func show(at point: CGPoint) {
        let panel = self.panel ?? make()
        self.panel = panel
        // The one configurable colour here, read on every show — along with the shape, which lives
        // here rather than in the factory so the panel has exactly one styling path.
        if let layer = panel.contentView?.layer {
            layer.backgroundColor = SnapAppearance.shared.dot.cgColor
            layer.cornerRadius = Self.diameter / 2
            // Without this the corner radius shapes the border but not the fill, and a 14pt dot
            // renders as a square with rounded edges drawn on top of it.
            layer.masksToBounds = true
        }
        panel.setFrame(
            NSRect(
                x: point.x - Self.diameter / 2, y: point.y - Self.diameter / 2,
                width: Self.diameter, height: Self.diameter),
            display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Above the destination block, which is a full half-screen the dot would otherwise be lost
    /// inside. Its colour and corner radius are set on every show — see `show(at:)`.
    private func make() -> NSPanel { OverlayPanel.make(level: .statusBar) }
}
