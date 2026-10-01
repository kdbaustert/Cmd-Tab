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
        return CGEventFlags.symbols(for: flags)
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

        // Floored at the *smaller* of the configured minimum and the extent the window already
        // has. As an absolute floor this inflated a window that started under it: a 360x40 mini
        // player dragged from the top-left computed `top = min(minY + 0, bottom - 90)` and threw
        // its top edge 50pt upward on the first event, before any size change had been asked for,
        // then held it there for the rest of the gesture. The clamp is here to stop a corner
        // crossing its anchor, not to grow a window the user never asked to grow.
        let floorWidth = min(minimum.width, frame.width)
        let floorHeight = min(minimum.height, frame.height)

        switch corner {
        case .topLeft:
            left = min(frame.minX + delta.width, right - floorWidth)
            top = min(frame.minY + delta.height, bottom - floorHeight)
        case .topRight:
            right = max(frame.maxX + delta.width, left + floorWidth)
            top = min(frame.minY + delta.height, bottom - floorHeight)
        case .bottomLeft:
            left = min(frame.minX + delta.width, right - floorWidth)
            bottom = max(frame.maxY + delta.height, top + floorHeight)
        case .bottomRight:
            right = max(frame.maxX + delta.width, left + floorWidth)
            bottom = max(frame.maxY + delta.height, top + floorHeight)
        }
        return CGRect(x: left, y: top, width: right - left, height: bottom - top)
    }
}

// MARK: - Hit testing

/// What a press at a screen point would actually reach, read off the window server's list.
///
/// Every mouse gesture here used to walk that list looking for the first `layer == 0` window under
/// the point and *skip* everything above it. That answers "which ordinary window is under here",
/// which is not the question: a float-on-top video, a panel, the Dock or an open menu sits above
/// layer 0, covers what is beneath it, and a click there lands on *it*. Skipping it made the
/// surface invisible to the gesture — a modifier-drag on a floating player grabbed and snapped the
/// window underneath, and `DesktopMover`'s grab test passed a title bar a floating window was
/// covering, so its synthetic press dragged the floating window instead.
///
/// So the walk stops at the first surface that is really there and answers from that one:
/// an ordinary window is a target, anything else means the press is not ours to take.
/// Focus-follows-mouse made the same call first, as a layer check ahead of a second walk of the
/// list; this is that rule with the window attached, so a caller gets both answers from one copy.
enum WindowHitTest {
    /// One entry of the on-screen list, parsed once.
    struct Surface: Equatable {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let alpha: Double
        let bounds: CGRect
    }

    /// Surfaces at this level and above are drawn over everything and taken by nothing — dimming
    /// tools, cursor highlighters, full-screen effects. Counting them would put every point on the
    /// display under something.
    static let ceiling = Int(CGWindowLevelForKey(.screenSaverWindow))

    /// The on-screen list, front to back.
    static func onScreen() -> [Surface] {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let id = window[kCGWindowNumber as String] as? CGWindowID,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { return nil }
            let alpha = (window[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1
            return Surface(id: id, pid: pid, layer: layer, alpha: alpha, bounds: bounds)
        }
    }

    /// The frontmost surface at `point` that covers what is beneath it, or nil over bare desktop.
    ///
    /// Passed over rather than counted: anything at or above `ceiling`, anything fully transparent,
    /// zero-area phantoms (the Electron and Catalyst backing windows `WindowNavigator.onScreen`
    /// drops for the same reason), and — when `ownPID` is given — this app's own surfaces above
    /// layer 0. Those are the snap overlays, which are click-through by construction (see
    /// `OverlayPanel`), so a press goes straight through them to whatever they are drawn over.
    /// Our layer-0 windows stay targets: Settings is an ordinary window.
    static func topmost(
        at point: CGPoint, in surfaces: [Surface], passingThrough ownPID: pid_t?
    ) -> Surface? {
        surfaces.first { surface in
            surface.layer < ceiling && surface.alpha > 0
                && surface.bounds.width > 1 && surface.bounds.height > 1
                && surface.bounds.contains(point)
                && !(surface.pid == ownPID && surface.layer != 0)
        }
    }

    /// The ordinary window a press at `point` reaches, or nil when the press lands on something
    /// drawn above the windows — in which case the gesture passes and the press goes where it
    /// would have gone anyway.
    static func window(
        at point: CGPoint, in surfaces: [Surface], passingThrough ownPID: pid_t?
    ) -> Surface? {
        guard let top = topmost(at: point, in: surfaces, passingThrough: ownPID), top.layer == 0
        else { return nil }
        return top
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

    /// How long a slice of the run loop lasts before `isCancelled` is re-tested.
    ///
    /// This was 0.25s, which is a timeout expiring and the thread waking four times a second for
    /// the entire life of the process — on a machine where the gesture may go all day without being
    /// used. Nothing about the interval was load-bearing: it existed only so a cancelled thread
    /// would notice, and `cancel()` now wakes the loop directly, so the slice can be long enough to
    /// be irrelevant to the power budget.
    private static let slice: CFTimeInterval = 30

    override func main() {
        runLoop = CFRunLoopGetCurrent()
        ready.signal()
        // A run loop with no sources returns immediately, and the source is added by the caller a
        // moment after this signals — so the loop is run in slices rather than left to exit.
        while !isCancelled {
            // `.finished` means the loop has no sources left and returns at once, so looping on it
            // would spin a core; only reached if the source is removed without `cancel()`.
            if CFRunLoopRunInMode(.defaultMode, Self.slice, false) == .finished { break }
        }
    }

    /// Ends the slice in progress rather than leaving the thread alive until it times out.
    ///
    /// `CFRunLoopStop` is one of the few run-loop calls documented as safe from another thread, and
    /// the caller has already removed the only source by the time this runs — so there is nothing
    /// left for the loop to service on its way out. Without it, a `slice` this long would keep the
    /// thread alive for up to half a minute after the gesture was switched off.
    override func cancel() {
        super.cancel()
        if let runLoop { CFRunLoopStop(runLoop) }
    }

    /// Blocks until `runLoop` is set, or the deadline passes. Called once, from `install`.
    ///
    /// Bounded, because the caller is the main thread — the one servicing the keyboard tap, where an
    /// unbounded wait on another thread's start-up is the stall the system answers by killing the
    /// tap. A thread that has not reached `main()` in a second is not about to, and `install` has a
    /// failure branch for exactly that.
    ///
    /// The return value is also what makes reading `runLoop` legal: the signal is the only
    /// happens-before between the two threads, so a caller that did not get it must not look.
    func waitUntilReady() -> Bool {
        ready.wait(timeout: .now() + 1) == .success
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

    /// Per-window rules, unioned with `appRules` for the same guard.
    var titleRules: [CompiledTitleRule] {
        get { lock.withLock { storedTitleRules } }
        set { lock.withLock { storedTitleRules = newValue } }
    }
    private var storedTitleRules: [CompiledTitleRule] = []

    /// Called when a press claims the chord for a drag, so the hold-and-point gesture — which is
    /// armed by the very same chord — stands down instead of firing a second snap of its own.
    ///
    /// It has to be told rather than left to notice, and that is the whole reason this exists: the
    /// press is *swallowed* by the tap below, so it never reaches the window server's delivery to
    /// any application and no `NSEvent` monitor — which is all `ModifierTargetHighlight` is built
    /// from — can ever see it. There is no event left for the other gesture to observe.
    ///
    /// Invoked from the tap thread, so the handler hops to the main actor itself. Held under `lock`
    /// like every other mutable field here, and read out of it before being called: running a
    /// closure of the caller's while holding this class's lock is how a tap thread deadlocks itself.
    var onClaimChord: (@Sendable () -> Void)? {
        get { lock.withLock { storedOnClaimChord } }
        set { lock.withLock { storedOnClaimChord = newValue } }
    }
    private var storedOnClaimChord: (@Sendable () -> Void)?

    // The installation, all four fields under `lock` like everything else here.
    //
    // They were not, and the type's own claim — "everything mutable below is private and taken
    // under it" — was false for exactly the three that matter most: `install` and `uninstall` wrote
    // `tap`, `source` and `thread` unsynchronised from the main thread while `dispatch` read `tap`
    // from the tap thread on every disabled-tap event. Narrow (the setting has to be toggled off as
    // the system disables the tap) but real, and the sort of race that reads as "the gesture
    // stopped working once" rather than as a crash.
    private var storedTap: CFMachPort?
    private var storedSource: CFRunLoopSource?
    private var storedThread: TapThread?
    private var screenObserver: NSObjectProtocol?
    /// Set for the length of an `install` so a second caller cannot start a parallel one.
    ///
    /// `install` is reachable from the settings setter and from `retryInstallIfNeeded`, which the
    /// trust handler calls — and its `guard tap == nil` was a check-then-act with the whole of the
    /// thread start-up in between, long enough for both to pass it and build two taps with only one
    /// of them ever torn down.
    private var isInstalling = false

    /// The live tap, for the callback thread. nil once `uninstall` has claimed it.
    private var tap: CFMachPort? { lock.withLock { storedTap } }
    /// Whether an installation is currently standing and so still wants a screen observer. Read by
    /// the install task, which registers one asynchronously and can land after an uninstall.
    private var wantsScreenObserver = false

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

    /// What the top and bottom edge bands answer, under the same lock as `gap`: it is read from the
    /// tap thread on every drag event and written from the main actor. Only a move reaches it — a
    /// resize takes corners alone, see `snapZones(for:)`.
    var edgeOptions: DragSnap.EdgeOptions {
        get { lock.withLock { storedEdgeOptions } }
        set { lock.withLock { storedEdgeOptions = newValue } }
    }
    private var storedEdgeOptions = DragSnap.EdgeOptions()

    private var displays: [Display] = []
    /// The height of the primary display, for turning the tap's top-left point into the bottom-up
    /// one `DragSnap.zone` works in.
    private var primaryHeight: CGFloat = 0

    private var session: Session?
    /// The zone the cursor is currently over, if any. Set on the tap thread, cleared on release —
    /// and what decides whether the drop tiles the window or leaves it where the drag put it.
    private var zone: WindowArrangement?
    /// The visible area `zone`'s preview was drawn against, under the same lock. The drop passes it
    /// on rather than letting the tiler re-derive a display from the window's frame — the cursor's
    /// display and the window's are not always the same one, and the user was shown the cursor's.
    private var zoneArea: CGRect?
    /// True from the press that armed a gesture until the release, whether or not the window has
    /// been resolved yet. What decides that an event is ours to swallow.
    private var isArmed = false
    /// Which press the gesture in flight belongs to, bumped on every press that arms one.
    ///
    /// `isArmed` alone cannot say *which* gesture is armed. A resolve is Accessibility IPC and can
    /// take a wedged app's full timeout per call, so a quick click on a slow window, released and
    /// followed by a press somewhere else, left the first resolve landing while the second gesture
    /// was armed — installing the first window and press point as the second gesture's session, so
    /// its opening frames were computed from the wrong window and written to the right one. A
    /// resolve now acts only if the press it was started for is still the current one.
    private var generation: UInt64 = 0
    /// Set while an Accessibility write is in flight, so a 120Hz stream of drag events cannot queue
    /// up hundreds of frames the user will never see. The newest target always wins.
    private var isWriting = false
    private var pending: CGRect?

    /// Accessibility writes are IPC and can block on a wedged app; the tap callback is the one place
    /// they must never happen.
    private let queue = DispatchQueue(label: "com.cmdtab.mousedrag", qos: .userInteractive)

    // MARK: Tap

    /// Re-attempts an install that Accessibility refused.
    ///
    /// `CGEvent.tapCreate` fails outright without the grant, and `settings` is edge-triggered — it
    /// installs only when the value *changes*, so re-pushing the same settings once trust lands does
    /// nothing at all and the gesture stays dead for the life of the process. Granting Accessibility
    /// to an app that is already running is the ordinary first-run path rather than an edge case:
    /// `AppDelegate` waits for exactly that and brings the keyboard tap up on it. This is the same
    /// call for the mouse one.
    ///
    /// Rebuilds a tap that already stands rather than skipping it. `SwitcherController.stop()` —
    /// what a revoke runs — tears down only the keyboard tap, so the mouse tap and its thread
    /// outlived the grant, `install`'s "a tap exists" guard made this a no-op, and a re-grant kept
    /// a tap made under the old trust that the system may have left inert. Torn down and rebuilt
    /// for the same reason `ModifierTargetHighlight.retryInstallIfNeeded` is; the cost is one
    /// rebuild on a launch that was trusted from the start.
    func retryInstallIfNeeded() {
        guard settings.isEnabled else { return }
        uninstall()
        install()
    }

    private func install() {
        // Claimed under the lock before any of the work below, so two callers racing cannot both
        // get past it. Released on every exit, whether or not a tap ends up standing.
        let claimed: Bool = lock.withLock {
            guard !isInstalling, storedTap == nil else { return false }
            isInstalling = true
            return true
        }
        guard claimed else { return }
        defer { lock.withLock { isInstalling = false } }

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
        guard thread.waitUntilReady(), let runLoop = thread.runLoop else {
            Log.general.error("mouse drag: tap thread has no run loop")
            CFMachPortInvalidate(tap)
            thread.cancel()
            return
        }

        // `NSScreen` is main-thread-only and `install` may be called from anywhere, so the cache is
        // filled on the main actor a moment from now. Nothing needs it until a drag is in flight,
        // and an empty cache simply means no zone matches — the gesture still moves the window.
        lock.withLock { wantsScreenObserver = true }
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
            // `uninstall()` can run before this body does — it looks for an observer this task has
            // not stored yet, finds none, and removes none. Storing unconditionally would leave one
            // registered for the life of the process with no installation behind it, and every
            // toggle of the setting that loses the race would strand another. Claiming the slot and
            // testing the flag under one lock is what makes the two orderings agree.
            let kept: Bool = self.lock.withLock {
                guard self.wantsScreenObserver else { return false }
                self.screenObserver = observer
                return true
            }
            if !kept { NotificationCenter.default.removeObserver(observer) }
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        // The setting can have been switched off while the thread was starting — `waitUntilReady`
        // is up to a second of it. `uninstall` running in that window finds the fields still nil,
        // tears nothing down, and returns; storing unconditionally here would then leave a live
        // session-wide mouse tap standing behind a setting the user has turned off. Testing the
        // claim under the same lock that stores is what makes the two orderings agree — the same
        // shape as `wantsScreenObserver` above, for the same race.
        let kept: Bool = lock.withLock {
            guard storedSettings.isEnabled else { return false }
            storedTap = tap
            storedThread = thread
            storedSource = source
            return true
        }
        guard kept else {
            // Never added to a run loop, so there is nothing to remove — just give the port and the
            // thread back, and withdraw the observer request this install made on its way in.
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
            thread.cancel()
            let orphan: NSObjectProtocol? = lock.withLock {
                defer {
                    screenObserver = nil
                    wantsScreenObserver = false
                }
                return screenObserver
            }
            if let orphan { NotificationCenter.default.removeObserver(orphan) }
            Log.general.notice("mouse drag: install abandoned, the gesture was switched off")
            return
        }
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
        // Claimed in one pass: after this the fields are nil, so a `dispatch` racing on the tap
        // thread sees the installation as gone and declines to re-enable a port that is about to be
        // invalidated. The CF teardown then happens *outside* the lock — the tap callback takes it
        // on every event, and holding it across a port invalidation would be the one place this
        // class could stall its own tap thread.
        let (tap, source, thread, observer): (
            CFMachPort?, CFRunLoopSource?, TapThread?, NSObjectProtocol?
        ) = lock.withLock {
            defer {
                storedTap = nil
                storedSource = nil
                storedThread = nil
                screenObserver = nil
                // Clearing this is what tells an install task still in flight that the installation
                // it was registering for is gone.
                wantsScreenObserver = false
            }
            return (storedTap, storedSource, storedThread, screenObserver)
        }
        // Source first, then cancel: the thread's run loop is only valid while the thread is alive,
        // so removing the source afterwards would be a use-after-free on the loop.
        if let source, let runLoop = thread?.runLoop {
            CFRunLoopRemoveSource(runLoop, source, .defaultMode)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
            CFMachPortInvalidate(tap)
        }
        thread?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
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
        // Never act on a drag this app posted itself — `DesktopMover`'s move between Desktops is a
        // real drag, and grabbing it here would have two of our own gestures fighting over one
        // window. See `SyntheticEvent`.
        guard !SyntheticEvent.isOurs(event) else { return false }
        let location = event.location
        switch type {
        case .leftMouseDown:
            // A press is proof the last gesture's release has happened, whether or not this tap saw
            // it. Without this, a mouse-up lost to anything ahead of us left the gesture armed with
            // its old session, and the next ordinary drag on the machine was swallowed and spent
            // moving the previous window.
            if lock.withLock({ isArmed }) { end() }
            let current = settings
            let held = event.flags.intersection(ModifierChord.allowed)
            guard let action = current.action(for: event.flags) else {
                // Only when something was held: an unmodified click is every click on the machine,
                // and logging those would be a line per click forever.
                //
                // Always `.debug`, never `Log.traceLevel`: that is persisted when verbose logging is
                // on, and this names which modifiers were held on a click. Not `.notice`, which is
                // the lowest level the persistent store keeps: ⌘-click is not a rare gesture —
                // open-in-new-tab, Finder multi-select — so a notice here wrote a line into the
                // store for a great many perfectly ordinary clicks.
                if !held.isEmpty {
                    Log.general.log(
                        level: .debug,
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
            // An app the user has told us never to tile drags exactly as it always did — which
            // means deciding *before* the press is swallowed. Checked in the resolve, as it used to
            // be, the press was already gone by the time the answer came back: the app never saw
            // its mouse-down, and a ⌃⌥-drag it had a use of its own for simply stopped working.
            //
            // Safe on the tap thread. `NSRunningApplication` is documented thread safe — see its
            // header — and the bundle identifier is one of its fixed properties, so there is no
            // run-loop policy to wait on either.
            let bundleID = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
            if let bundleID, appRules[bundleID]?.neverTile == true {
                Log.general.notice(
                    "mouse drag: \(bundleID, privacy: .public) is set to never tile; passed on")
                return false
            }
            Log.general.notice(
                """
                mouse drag: \(action.rawValue, privacy: .public) armed on pid \
                \(target.pid, privacy: .public)
                """)
            let press: UInt64 = lock.withLock {
                isArmed = true
                session = nil
                generation &+= 1
                return generation
            }
            // Before the resolve, which is asynchronous: the other gesture has to be out of the way
            // from the press onwards, not from whenever Accessibility gets back to us.
            onClaimChord?()
            resolve(
                target: target, bundleID: bundleID, action: action, at: location, press: press)
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
            // actually put it. Both gestures snap, but not to the same zones — see `snapZones`.
            updatePreview(at: location, zones: Self.snapZones(for: session.action))
            return true

        case .leftMouseUp:
            let state: (armed: Bool, zone: WindowArrangement?, session: Session?, area: CGRect?) =
                lock.withLock { (isArmed, zone, session, zoneArea) }
            guard state.armed else { return false }
            if let zone = state.zone, let session = state.session {
                Log.general.notice(
                    "mouse drag: dropped in \(zone.rawValue, privacy: .public)")
                let gap = self.gap
                // The window this gesture has been dragging, named explicitly rather than left for
                // the tiler to re-resolve. The press was swallowed, so the dragged window was never
                // focused — handed only a pid, `WindowTiler` fell back to `AX.frontWindow` and
                // snapped whichever window the app *did* have focused, which for any app with two
                // windows open is routinely not the one under the cursor.
                //
                // Read on the queue that owns `draggedWindow`, and enqueued before `end()`'s own hop
                // clears it — the queue is serial, so the ordering holds.
                let area = state.area
                queue.async {
                    let dragged = Self.draggedWindow
                    // Off the tap thread: this reads screens on the main actor and then does the
                    // same Accessibility write the keyboard chords do.
                    Task { @MainActor in
                        WindowTiler.apply(
                            zone, pid: session.pid, areas: WindowTiler.visibleAreas(),
                            cycleWidths: false, gap: gap,
                            target: dragged.map(WindowTiler.Target.element), destination: area,
                            anchor: session.startFrame)
                    }
                }
            }
            end()
            return true

        default:
            return false
        }
    }

    /// Resolves the window under the press and captures the frame the gesture is measured from.
    ///
    /// `press` is the `generation` the gesture was armed with. Everything this does to shared state
    /// is conditional on it still being current — see `generation`.
    private func resolve(
        target: (pid: pid_t, bounds: CGRect), bundleID: String?, action: MouseDragAction,
        at point: CGPoint, press: UInt64
    ) {
        queue.async { [weak self] in
            guard let self else { return }
            let element = Self.axWindow(pid: target.pid, bounds: target.bounds)
            guard let element, let frame = AX.frame(element) else {
                Log.general.notice(
                    "mouse drag: no accessible window for pid \(target.pid, privacy: .public)")
                self.end(press: press)
                return
            }
            // A title rule protects this exact window whatever app it belongs to. Unlike the app
            // rule, which the tap decides before swallowing anything, this one needs the window's
            // title — Accessibility, which the tap thread must never wait on — so the window is
            // left alone but its press has already been taken. The read is skipped outright when
            // no rule could apply to this app, which on most installs is every time.
            if self.titleRules.mayNeverTile(bundleID) {
                let title = AX.copyString(element, kAXTitleAttribute) ?? ""
                if CompiledTitleRule.matches(
                    self.titleRules, bundleID: bundleID, title: title, action: .neverTile
                ) {
                    self.end(press: press)
                    return
                }
            }
            // `draggedWindow` is unlocked on the strength of every touch being on `queue`.
            dispatchPrecondition(condition: .onQueue(self.queue))
            let current: Bool = self.lock.withLock {
                guard self.isArmed, self.generation == press else { return false }
                self.session = Session(
                    action: action, pid: target.pid, startFrame: frame, startMouse: point,
                    corner: MouseDragGeometry.corner(for: point, in: frame))
                return true
            }
            // Released already, or superseded by a newer press. Either way this window is no
            // longer the one being dragged, and the gesture that is — if any — owns the slot.
            guard current else { return }
            // Set after the session rather than before it, and still safely: any frame the tap
            // posts against that session is enqueued behind this block, which is still running.
            Self.draggedWindow = element
            Log.general.notice(
                "mouse drag: resolved window for pid \(target.pid, privacy: .public)")
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
            // Drained in a loop, holding the claim on `isWriting` for the whole of it.
            //
            // Putting it down between frames and re-entering `write` with the pending one looked
            // equivalent and was not: the lock is released in between, so a tap-thread event landing
            // in that gap finds the slot free, claims it with a *newer* frame, and the older one
            // being handed back is then stored as `pending` behind it. The stale frame is written
            // last and the window snaps to a position the cursor has already passed — mid-gesture
            // the next event corrects it, but on the final event before the release that is where
            // the window stays, a little off from where it was dropped. The very reordering the
            // coalescing exists to prevent, arriving by another route.
            var frame = frame
            while true {
                if let window = Self.draggedWindow {
                    // Position first, then size: a resize from a top or left corner moves the origin
                    // as well, and an app that clamps a move against its current size needs the
                    // origin set before the size that makes room for it. A move writes the origin
                    // alone. Both go through `setFrame` so a drag of this app's own window costs one
                    // hop onto the main thread per frame rather than two — see `AX.onOwningThread`.
                    AX.setFrame(window, frame, sizing: !isMove)
                }
                let next: CGRect? = self.lock.withLock {
                    if let pending = self.pending {
                        self.pending = nil
                        return pending
                    }
                    // Released only here — under the same lock that established there is nothing
                    // left to write, which is what makes the ordering above hold. `end()` clears
                    // `pending`, so a released gesture drops out on its next turn rather than
                    // spinning on frames the user can no longer be producing.
                    self.isWriting = false
                    return nil
                }
                guard let next else { return }
                frame = next
            }
        }
    }

    /// Ends the gesture in flight — or, given the `press` it was started for, only if that press is
    /// still the current one, so a resolve that fails late cannot end the gesture that replaced it.
    private func end(press: UInt64? = nil) {
        let outcome: (ended: Bool, hadZone: Bool) = lock.withLock {
            if let press, press != generation { return (false, false) }
            let had = zone != nil
            isArmed = false
            session = nil
            pending = nil
            zone = nil
            zoneArea = nil
            return (true, had)
        }
        guard outcome.ended else { return }
        if outcome.hadZone { Task { @MainActor in SnapPreview.shared.hide() } }
        queue.async { Self.draggedWindow = nil }
    }

    /// Snapshots the displays in both coordinate spaces. Main-thread work, by `NSScreen`'s rules.
    ///
    /// One read of the display list, not two. Pairing `visibleAreas()` with a separate walk of
    /// `NSScreen.screens` left the two lists index-aligned only by convention, with a comment as the
    /// only thing saying so; `visibleDisplays()` reports both spaces from a single pass.
    @MainActor
    private func refreshDisplays() {
        // Labelled: this runs on every screen-parameter notification, including the burst a wake
        // posts, and `NSScreen` answers from the window server that is itself just coming back.
        let (snapshot, height) = MainLoopMonitor.marking("display cache refresh") {
            (
                WindowTiler.visibleDisplays().map { Display(frame: $0.frame, area: $0.area) },
                NSScreen.primary?.frame.height ?? 0
            )
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
    private func snapZone(
        at point: CGPoint, zones: DragSnap.Zones
    ) -> (zone: WindowArrangement, area: CGRect)? {
        let (screens, height, edges) = lock.withLock {
            (displays, primaryHeight, storedEdgeOptions)
        }
        let flipped = CGPoint(x: point.x, y: height - point.y)
        for display in screens where NSMouseInRect(flipped, display.frame, false) {
            guard
                let zone = DragSnap.zone(
                    for: flipped, in: display.frame, zones: zones, edges: edges)
            else { return nil }
            return (zone, display.area)
        }
        return nil
    }

    /// Which of `DragSnap`'s zones each action may drop into.
    ///
    /// Neither takes the centre box. The titlebar drag can offer one because its cursor is on a
    /// titlebar being carried somewhere; this gesture grabs anywhere, so the cursor is wherever the
    /// press happened to land, and a window moved a little while held by its middle would maximize.
    ///
    /// A resize takes the corners and nothing else. Its cursor *is* the corner being dragged, and
    /// dragging that corner to a screen edge means "make the window reach the edge" — an edge band
    /// there snapped the window to that half and threw the resize away. A corner dragged into a
    /// screen corner still means the same thing a move dragged there does: that quarter.
    static func snapZones(for action: MouseDragAction) -> DragSnap.Zones {
        switch action {
        case .move: return [.corners, .edges]
        case .resize: return .corners
        }
    }

    /// Shows or hides the overlay for the zone the cursor is over. Called on every drag event, so it
    /// hops to main only when the zone actually changes.
    private func updatePreview(at point: CGPoint, zones: DragSnap.Zones) {
        let match = snapZone(at: point, zones: zones)
        let changed: Bool = lock.withLock {
            // Compare both the zone kind and the display area: the same zone kind (e.g. `.leftHalf`)
            // recurring on a different, adjacent display must still count as a change, or the drop
            // destination silently follows the cursor to the new display with no preview update.
            guard zone != match?.zone || zoneArea != match?.area else { return false }
            zone = match?.zone
            zoneArea = match?.area
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
    ///
    /// nil when something drawn *above* the ordinary windows is under the point — see
    /// `WindowHitTest.window(at:in:passingThrough:)` for why that passes rather than looking past.
    ///
    /// Our own windows are targets like anyone else's: Settings is an ordinary resizable window,
    /// and being unable to grab the one window this app definitely owns is the most obvious thing
    /// that can be wrong with the gesture. Our own *overlays* are passed through instead — they are
    /// click-through, and the outline the hold-and-point gesture draws is sitting over exactly the
    /// window this press is aimed at.
    static func window(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        WindowHitTest.window(
            at: point, in: WindowHitTest.onScreen(), passingThrough: getpid()
        ).map { ($0.pid, $0.bounds) }
    }

    /// The Accessibility element for the window whose frame matches `bounds`.
    ///
    /// Matched on frame rather than taken as the app's focused window: the gesture acts on the
    /// window under the cursor, which for an app with several windows open is routinely not the one
    /// with focus. Falls back to the front window when nothing matches, which covers the hosts whose
    /// AX frames drift a point from the window list's (Electron, Catalyst).
    private static func axWindow(pid: pid_t, bounds: CGRect) -> AXUIElement? {
        AX.window(ofApplication: pid, matching: bounds) ?? AX.frontWindow(ofApplication: pid)
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
    /// How far the cursor must travel from the anchor before it names a direction rather than the
    /// whole screen.
    static let deadZone: CGFloat = 45

    /// How far through the dead zone an offset is, from 0 at the anchor to 1 at its edge and beyond.
    /// 1 means releasing picks a direction — see `flick(for:)`.
    static func progress(for delta: CGSize) -> CGFloat {
        min(hypot(delta.width, delta.height) / deadZone, 1)
    }

    /// What a chord released before the gesture armed asks for: the direction it was flicked in, or
    /// nil for a tap that stayed inside the dead zone. Nil is not "maximize" here, as it is for an
    /// armed gesture: a bare tap of the chord is how every ⌃⌘ keyboard shortcut starts, and one
    /// that maximized the window under the pointer would fire on all of them.
    static func flick(for delta: CGSize) -> WindowArrangement? {
        progress(for: delta) < 1 ? nil : zone(for: delta)
    }

    /// The zone a cursor offset from the anchor asks for, or nil if the offset is meaningless.
    ///
    /// Eight sectors and a dead zone, in Cocoa's y-up space. Staying put means the whole screen:
    /// that is the one "direction" with nowhere to point, and taking the whole display is the
    /// natural thing for it to mean.
    static func zone(for delta: CGSize, deadZone: CGFloat = PointDirection.deadZone)
        -> WindowArrangement
    {
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

    /// The directions `zone(for:)` can answer with a direction for, in order anticlockwise from due
    /// east — each one's sector centred on a multiple of 45°. What the ring around the cursor is
    /// cut into, one segment per entry.
    static let headings: [WindowArrangement] = [
        .rightHalf, .topRight, .topHalf, .topLeft, .leftHalf, .bottomLeft, .bottomHalf, .bottomRight,
    ]

    /// The centre of `zone`'s sector in degrees, anticlockwise from due east in y-up space, or nil
    /// for the one answer with no direction — `.maximize`, the dead zone.
    static func heading(of zone: WindowArrangement) -> CGFloat? {
        headings.firstIndex(of: zone).map { CGFloat($0) * 45 }
    }
}

/// What a change in the held modifiers does to the hold-and-point gesture.
///
/// Pure, because the rule is the part that was wrong and nothing else here can be tested without a
/// keyboard. The gesture used to read every change that left the chord as the chord coming up, and
/// snapped — so a modifier *added* to it snapped too. ⌃⌘ then ⇧ is the first half of ⌃⇧⌘←, this
/// app's own shipped display move, and of ⌃⇧⌘4, the system's screenshot to the clipboard; ⌃⌥ then
/// ⌘ is the Desktop moves; a Hyper key posts its four modifiers one at a time. Each of them
/// maximized whatever window the pointer was resting on, a beat before the key it was for arrived.
/// The keystroke stand-down in `SwitcherController` could not catch it: the added modifier's
/// `flagsChanged` lands before the key-down does.
///
/// And arming reads the other way: only a *press* onto the chord starts a gesture. Letting go of
/// the ⇧ in ⌃⇧⌘ lands back on ⌃⌘ too, and arming there set up a snap for the ⌘ coming up next.
enum PointChord {
    enum Step: Equatable {
        /// The chord went down. Start a gesture.
        case arm
        /// Still on a bound chord mid-gesture — a qualifier moved from one chord to another.
        case hold
        /// Something came up and nothing was added: the release. Snap.
        case complete
        /// Something was added: the chord was the start of another shortcut. Stand down, no snap.
        case cancel
        /// Nothing to do.
        case ignore
    }

    /// - Parameters:
    ///   - previous: The modifiers held before this change.
    ///   - held: The modifiers held now.
    ///   - chord: The chord the gesture in progress was last held on; nil when none is armed.
    ///   - isChord: Whether `held` is itself a bound chord.
    static func step(
        previous: CGEventFlags, held: CGEventFlags, chord: CGEventFlags?, isChord: Bool
    ) -> Step {
        guard isChord else {
            guard let chord else { return .ignore }
            return held.isStrictSubset(of: chord) ? .complete : .cancel
        }
        if chord != nil { return .hold }
        return previous.isStrictSubset(of: held) ? .arm : .ignore
    }
}

/// Drives the hold-and-point gesture, and outlines the window it would act on.
///
/// Passive `NSEvent` monitors throughout: nothing is pressed, so there is nothing to consume, and a
/// tap here would take modifier keys away from every app on the machine for no gain.
///
/// Each monitor is installed twice, globally and locally. A global monitor sees only the events
/// going to *other* applications, so on its own it makes the gesture dead over Cmd-Tab's own
/// windows — the settings window is an ordinary resizable window and snaps like any other. The two
/// never both fire: an event goes either to this app or to another one.
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

    /// Per-app overrides, so an app marked "never tile" is left alone by this gesture too.
    ///
    /// The other three snap paths have honoured `neverTile` all along — the keyboard chords in
    /// `SwitcherController.applyTiling`, the titlebar drag in `DragSnap.mouseDragged`, and the
    /// modifier-drag in `MouseWindowDrag.handle` — and this one was simply never given the rules to
    /// check, so "No tiling" held everywhere except when you pointed at the window.
    var appRules: [String: AppRule] = [:]
    /// Per-window rules, unioned with `appRules` for the same guard.
    var titleRules: [CompiledTitleRule] = []

    private var flagsMonitors: [Any] = []
    private var moveMonitors: [Any] = []
    private let outline = TargetOutline()
    private let dot = AnchorDot()

    /// Where the cursor was when the chord went down, in Cocoa's bottom-up space.
    private var anchor: CGPoint?
    /// The window the gesture will act on, fixed at chord-down.
    private var target: (pid: pid_t, bounds: CGRect)?
    /// The destination currently being offered.
    private var zone: WindowArrangement?
    /// The visible area the offer was drawn against, handed to the tiler at completion so the
    /// outline and the snap cannot land on different displays.
    private var area: CGRect?
    /// The chord the gesture in progress is held on, nil when none is armed. What a later change is
    /// measured against to tell a release from an addition — see `PointChord`.
    private var chord: CGEventFlags?
    /// The modifiers the last `flagsChanged` reported, so arming can tell a press onto the chord
    /// from a release back down to it. Kept across gestures: it describes the keyboard, not them.
    private var lastHeld: CGEventFlags = []
    /// How long the chord must stay down before the gesture shows itself. Longer than the gap
    /// between the chord and the key of a keyboard shortcut, shorter than anyone waits to see
    /// whether pointing is going to do anything.
    private static let armDelay: Duration = .milliseconds(150)
    /// The pending activation, nil once it has run or been cancelled.
    private var armTask: Task<Void, Never>?

    /// Rebuilds the monitors after an install made without the Accessibility grant.
    ///
    /// A *partial* install is the failure mode here, not an absent one, and that is what makes the
    /// guard below the wrong thing to lean on: key-related events — `.flagsChanged` among them —
    /// are only delivered to a global monitor when the process is trusted, while the local monitor
    /// is handed over as normal. So an untrusted install leaves `flagsMonitors` non-empty, `install`
    /// reads that as work already done, and the outline ends up appearing over Cmd-Tab's own windows
    /// and nowhere else — the half of the gesture the local monitor covers.
    ///
    /// Torn down and rebuilt rather than topped up, so it is correct whether an untrusted global
    /// monitor comes back nil or comes back inert.
    func retryInstallIfNeeded() {
        guard settings.isEnabled else { return }
        uninstall()
        install()
    }

    private func install() {
        guard flagsMonitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] event in
            MainActor.assumeIsolated { self?.flagsChanged(event.modifierFlags) }
        }
        flagsMonitors = [
            NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged]) { handle($0) },
            // Returned unchanged: this watches the chord, it does not claim it, and swallowing
            // ⌃⌘ inside our own settings window would break every shortcut in it.
            NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged]) { event in
                handle(event)
                return event
            },
        ].compactMap { $0 }
    }

    private func uninstall() {
        flagsMonitors.forEach(NSEvent.removeMonitor)
        flagsMonitors = []
        cancel()
    }

    /// The chord going down starts the gesture; letting it go completes one; adding to it abandons
    /// one. See `PointChord` for which is which.
    private func flagsChanged(_ flags: NSEvent.ModifierFlags) {
        let held = Hotkey.flags(from: flags)
        let previous = lastHeld
        lastHeld = held

        switch PointChord.step(
            previous: previous, held: held, chord: chord,
            isChord: settings.action(for: held) != nil)
        {
        case .ignore:
            return
        case .hold:
            chord = held
            return
        case .complete:
            complete()
            return
        case .cancel:
            Log.general.notice("point gesture: stood down, a modifier was added to the chord")
            cancel()
            return
        case .arm:
            break
        }

        // Only noted here: the window lookup and the overlays wait out `armDelay`. ⌃⌘ and ⌃⌥ are
        // also the keyboard tiling chords, so every half-tile and every ⌃⌘Space came through here,
        // paid a main-thread window-list lookup and two panel orders-in, and flashed the outline
        // before the arrow key-down stood the gesture down. Nothing is lost by waiting: a key-down
        // or release inside the delay cancels this, and the cursor is where it was, so the lookup
        // at `anchor` answers as it would have at the press.
        anchor = NSEvent.mouseLocation
        chord = held
        armTask?.cancel()
        armTask = Task { [weak self] in
            try? await Task.sleep(for: Self.armDelay)
            guard !Task.isCancelled else { return }
            self?.activate()
        }
    }

    /// Finds the window under the anchor and shows the gesture, once the chord has been held long
    /// enough to be one rather than the front of a keyboard shortcut.
    private func activate() {
        armTask = nil
        guard let point = anchor, let target = armableTarget(at: point) else { return cancel() }
        self.target = target
        outline.show(target.bounds)
        // Shown at the cursor and carried with it by `follow`, so it marks where the pointer is
        // aiming. The anchor the direction is measured from is no longer drawn; the ring's fill
        // is what says how far from it the cursor has come.
        dot.show(at: point)
        Log.general.notice(
            "point gesture: armed on pid \(target.pid, privacy: .public)")

        if moveMonitors.isEmpty {
            // Only while the chord is held: this fires on every pixel of cursor travel, which is
            // far too hot to carry for the whole session just in case. Global and local for the
            // same reason the flags monitor is both — a cursor moving inside our own window has to
            // steer the gesture too.
            let follow: () -> Void = { [weak self] in
                MainActor.assumeIsolated { self?.follow() }
            }
            moveMonitors = [
                NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { _ in follow() },
                NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { event in
                    follow()
                    return event
                },
            ].compactMap { $0 }
        }
        follow()
    }

    /// The window under `point` the gesture may act on, or nil — said in the log either way it
    /// refuses. Shared by arming and by a flick, which both aim at the window that was under the
    /// pointer when the chord went down.
    private func armableTarget(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        // A window-server round trip on the main thread. Marked so a stall inside it says so.
        guard let target = MainLoopMonitor.marking("point-gesture window lookup", {
            Self.windowUnderCursor(at: point)
        }) else {
            // Said, because this is the one refusal the user sees as "the chord did nothing": the
            // desktop, the menu bar, the Dock or some other app's surface drawn above the ordinary
            // windows is under the cursor — see `MouseWindowDrag.window(at:)`. Which one is named,
            // because the window list cannot be read back afterwards: a relaunching Dock held a
            // layer-20 surface over the whole display and refused every point on it, and the line
            // said only where the cursor was.
            Log.general.notice(
                """
                point gesture: no window to act on under the cursor at \
                (\(Int(point.x), privacy: .public), \(Int(point.y), privacy: .public)); \
                \(Self.blocker(at: point), privacy: .public)
                """)
            return nil
        }
        // An app the user has told us never to tile is not offered a destination at all — no
        // outline, no dot, no landing block. Refusing at the *drop* instead would draw the whole
        // affordance and then silently do nothing, which reads as the gesture being broken rather
        // than as the setting being obeyed.
        let id = NSRunningApplication(processIdentifier: target.pid)?.bundleIdentifier
        if id.map({ appRules[$0]?.neverTile == true }) ?? false
            || Self.titleProtects(target, bundleID: id, rules: titleRules) {
            Log.general.notice(
                "point gesture: \(id ?? "window", privacy: .public) is set to never tile")
            return nil
        }
        return target
    }

    /// Offers the zone the cursor is currently pointing at.
    private func follow() {
        guard let anchor else { return }
        let point = NSEvent.mouseLocation
        let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
        // Ahead of the zone guard below: the ring tracks every move, not just the ones that change
        // the zone. One frame change on a 90pt panel, and only while the chord is held.
        dot.move(to: point)
        let next = PointDirection.zone(for: delta)
        guard next != zone else { return }
        zone = next
        dot.highlight(next)
        showPreview(next, near: anchor)
    }

    /// Draws the destination on the display the gesture started on.
    ///
    /// `NSMouseInRect` rather than `CGRect.contains` for the same reason `DragSnap.zone` uses it:
    /// the anchor is Cocoa bottom-up, so a chord pressed on the topmost row of pixels sits at
    /// exactly `maxY`, the one value `contains` rejects.
    private func showPreview(_ zone: WindowArrangement, near point: CGPoint) {
        area = nil
        guard let area = Self.area(containing: point) else { return }
        self.area = area
        guard let frame = zone.frame(in: area, current: area, fraction: 0.5) else { return }
        SnapPreview.shared.show(zone.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame)
    }

    /// The visible area of the display `point` (Cocoa bottom-up) is on.
    ///
    /// One read of the display list, not two paired by index — see `MouseWindowDrag.refreshDisplays`,
    /// which fixed the same fragility for the drag gesture after a screen reconfiguration could
    /// desync a separate `NSScreen.screens` walk from `visibleAreas()`.
    private static func area(containing point: CGPoint) -> CGRect? {
        WindowTiler.visibleDisplays().first { NSMouseInRect(point, $0.frame, false) }?.area
    }

    /// Gives the chord up to a drag that has claimed it, without snapping anything.
    ///
    /// The two gestures are deliberately on one chord — ⌃⌥ means "move this window" whether you
    /// drag it or point it — and the *press* is the only thing that separates them. Nothing
    /// separated them before, and the result was that every modifier-drag ended in a second,
    /// unasked-for snap: holding the chord armed this gesture and `follow()` set `zone` to
    /// `.maximize` (the dead-zone answer for a cursor that has not moved yet), the drag then ran on
    /// top of it without touching that value — macOS posts `leftMouseDragged`, not `mouseMoved`, so
    /// nothing here re-read it — and the modifier coming up fired `complete()` on a stale zone. The
    /// window you had just placed by hand was maximized, or thrown at whichever sector the cursor
    /// happened to be in.
    ///
    /// Worse than merely wrong about *where*: by then `target.bounds` names the window's frame from
    /// before the drag, so `WindowTiler.resolve` matched nothing, fell back to `AX.frontWindow`, and
    /// could snap a different window of the app entirely.
    ///
    /// Called rather than detected here — see `MouseWindowDrag.onClaimChord`, which explains why a
    /// swallowed press leaves no event for this gesture to notice on its own. Re-arming needs the
    /// chord *pressed* afresh — landing back on it by letting go of something else does not arm
    /// (see `PointChord`) — so the chord stays stood down for the rest of the hold.
    ///
    /// There are two claimants, not one. A drag is the original; a *keyboard* binding on the same
    /// modifiers is the other, and it failed the same way — see
    /// `SwitcherController.handle(type:event:)`, which now says so at the point it decides a
    /// keystroke is this app's.
    ///
    /// - Parameter claimant: what took the chord, named for the log. Which of the two it was is the
    ///   first thing worth knowing when reading a session back, and one shared message threw it
    ///   away.
    func standDown(claimedBy claimant: String) {
        guard anchor != nil else { return }
        Log.general.notice(
            "point gesture: stood down, \(claimant, privacy: .public) claimed the chord")
        cancel()
    }

    /// The chord came up: snap to whatever was being offered — or, if it came up before the gesture
    /// armed, to the direction it was flicked in.
    private func complete() {
        defer { cancel() }
        if armTask != nil { return flick() }
        guard let zone, let target, let area else { return }
        snap(target, to: zone, on: area, how: "snapping")
    }

    /// A chord let go of inside `armDelay`, before anything was drawn. The pointer thrown past the
    /// dead zone in that time snaps the window it started over in that direction — a gesture done
    /// faster than the ring could appear is still the gesture. One that stayed inside it is a tap,
    /// and a tap does nothing; see `PointDirection.flick`.
    ///
    /// The window is looked up here, at the anchor, rather than at arming, which never happened.
    /// Nothing has moved it since the chord went down, so the answer is the one arming would have
    /// given, never rules included.
    private func flick() {
        guard let anchor else { return }
        let point = NSEvent.mouseLocation
        let delta = CGSize(width: point.x - anchor.x, height: point.y - anchor.y)
        guard let zone = PointDirection.flick(for: delta) else {
            Log.general.notice(
                """
                point gesture: chord tapped, pointer moved \
                \(Int(hypot(delta.width, delta.height)), privacy: .public)pt; nothing snapped
                """)
            return
        }
        guard let target = armableTarget(at: anchor), let area = Self.area(containing: anchor)
        else { return }
        snap(target, to: zone, on: area, how: "flicked, snapping")
    }

    /// Hands the window to the tiler. `how` only names the path in the log.
    private func snap(
        _ target: (pid: pid_t, bounds: CGRect), to zone: WindowArrangement, on area: CGRect,
        how: String
    ) {
        Log.general.notice(
            """
            point gesture: \(how, privacy: .public) pid \(target.pid, privacy: .public) to \
            \(zone.rawValue, privacy: .public)
            """)
        // By its frame, not by its pid. This gesture never touches the window — no click, no focus,
        // nothing raised — which is exactly what the type's own doc comment promises, and handing
        // the tiler a bare pid quietly broke that promise: it re-resolved to `AX.frontWindow` and
        // snapped the app's *focused* window while the outline was drawn around a different one.
        // The bounds were fixed at chord-down and the window has not moved since, so they still
        // name it.
        WindowTiler.apply(
            zone, pid: target.pid, areas: WindowTiler.visibleAreas(), cycleWidths: false, gap: gap,
            // The display the outline was drawn on. Anchored at the chord-press point, so this only
            // diverged from the window's own display for a window straddling a boundary — but that
            // is the case where being shown one monitor and given the other is hardest to explain.
            target: .bounds(target.bounds), destination: area)
    }

    private func cancel() {
        armTask?.cancel()
        armTask = nil
        moveMonitors.forEach(NSEvent.removeMonitor)
        moveMonitors = []
        anchor = nil
        chord = nil
        target = nil
        zone = nil
        area = nil
        outline.hide()
        dot.hide()
        SnapPreview.shared.hide()
    }

    /// Whether a title rule protects the window under the chord.
    ///
    /// Still Accessibility on the main thread when it runs — the arming decision is synchronous —
    /// but it no longer runs on every press of the chord: only when some `.neverTile` rule could
    /// apply to this app at all, which on most installs is never.
    private static func titleProtects(
        _ target: (pid: pid_t, bounds: CGRect), bundleID: String?, rules: [CompiledTitleRule]
    ) -> Bool {
        guard rules.mayNeverTile(bundleID) else { return false }
        let title = AX.window(ofApplication: target.pid, matching: target.bounds)
            .flatMap { AX.copyString($0, kAXTitleAttribute) } ?? ""
        return CompiledTitleRule.matches(
            rules, bundleID: bundleID, title: title, action: .neverTile)
    }

    /// The window under a Cocoa-space point, in the top-left space the overlays and the window list
    /// both use.
    private static func windowUnderCursor(at point: CGPoint) -> (pid: pid_t, bounds: CGRect)? {
        guard let primary = NSScreen.primary
        else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.height - point.y)
        return MouseWindowDrag.window(at: flipped)
    }

    /// What is under a Cocoa-space point instead of an ordinary window, for the refusal's log line.
    /// A second read of the window list, paid only on the way out of a refusal.
    private static func blocker(at point: CGPoint) -> String {
        guard let primary = NSScreen.primary
        else { return "no primary display" }
        let flipped = CGPoint(x: point.x, y: primary.frame.height - point.y)
        guard let top = WindowHitTest.topmost(
            at: flipped, in: WindowHitTest.onScreen(), passingThrough: getpid())
        else { return "nothing but the desktop there" }
        let owner = NSRunningApplication(processIdentifier: top.pid)?.localizedName
            ?? "pid \(top.pid)"
        let b = top.bounds
        return """
            covered by \(owner), layer \(top.layer), \(Int(b.width))×\(Int(b.height)) \
            at (\(Int(b.minX)), \(Int(b.minY)))
            """
    }
}

/// A border drawn around the window a gesture is about to act on.
///
/// Both this and `SnapPreview` are borders now, so they are told apart by corner radius and by each
/// having its own colour setting: one says "this is the window", the other says "this is where it
/// will land", and a gesture that goes from one to the other should not look like the same thing
/// moving.
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
        guard let primary = NSScreen.primary
        else { return }
        let rect = NSRect(
            x: frame.minX, y: primary.frame.height - frame.maxY,
            width: frame.width, height: frame.height)
        panel.setFrame(rect, display: true)
        panel.restoreAllSpaces("drag target outline")
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


/// The ring the hold-and-point gesture draws around the cursor, from the moment the chord arms until
/// it is released.
///
/// It began as Hookshot's affordance — a dot left where the chord went down, so the direction had a
/// visible origin — and now rides with the cursor instead, drawn the way the system draws its own
/// floating indicators: a round plate of material (glass on macOS 26 and later, the HUD blur before
/// it) with a soft shadow, and on it a progress-style ring — a track in the system's adaptive grey
/// and an arc in the accent colour, the same weight, rounded at both ends. The arc is centred on
/// the direction the window will go and glides round the ring as that changes; while the cursor is
/// still inside the dead zone, where releasing takes the whole screen, the whole ring is the accent
/// colour. So the ring says where the window will go, next to the pointer, without the eye having
/// to leave it for the landing block.
@MainActor
private final class AnchorDot {
    /// The plate's size — the whole footprint. Big enough to read as an indicator around the pointer
    /// rather than a mark beside it, at the cost of being well past Rectangle Pro's 15pt reticle.
    private static let diameter: CGFloat = 90
    /// Material showing between the ring and the plate's edge, so the ring sits *on* the plate the
    /// way the system's indicators sit on theirs, rather than running round its rim.
    private static let inset: CGFloat = 5
    /// One weight for the track and the arc, as a progress ring has: the arc reads as part of the
    /// ring filled in, not as a second line laid on top of it.
    private static let lineWidth: CGFloat = 5
    /// How much of the ring the arc covers, rounded ends included. A quarter, centred on its
    /// direction: wide enough to read as a filled stretch of ring at a glance, which the 45° a
    /// sector strictly owns is not at this size.
    private static let arcDegrees: CGFloat = 90
    /// How long the arc takes to travel to a new direction. Short enough to finish well before the
    /// next sector change on any real movement, long enough to be seen as travel.
    private static let glide: CFTimeInterval = 0.15

    private var panel: NSPanel?
    /// The ring's own layer-backed view, stacked over the plate. Its own view rather than sublayers
    /// of the content view: AppKit keeps a subview's layer above hand-added sublayers, so the ring
    /// drawn straight onto the content view disappeared under the glass (measured).
    private let ring = NSView()
    private let track = CAShapeLayer()
    /// The whole ring in the accent colour, for the dead zone — releasing there takes the whole
    /// screen.
    private let full = CAShapeLayer()
    /// The arc, drawn facing due east and turned to face the direction being pointed at, so a
    /// change of direction animates as the arc travelling round the ring.
    private let arc = CAShapeLayer()
    /// `arc`'s rotation in radians, kept unwrapped so the glide can always take the short way.
    private var angle: CGFloat = 0
    private var lit: WindowArrangement?

    /// `point` is in Cocoa's bottom-up space — straight from `NSEvent.mouseLocation`, no flip.
    func show(at point: CGPoint) {
        let panel = self.panel ?? make()
        self.panel = panel
        panel.setFrame(Self.frame(centredOn: point), display: true)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // Read on every show: the accent is the user's to change in System Settings at any time,
        // and a `CGColor` resolved once would keep the old one. Resolved under the panel's own
        // appearance, which is where it is drawn.
        // The track in the system's adaptive grey, so it reads against the plate whether that is
        // light or dark glass — resolved the same way, and for the same reason, as the accent.
        ring.effectiveAppearance.performAsCurrentDrawingAppearance {
            track.strokeColor = NSColor.tertiaryLabelColor.cgColor
            full.strokeColor = NSColor.controlAccentColor.cgColor
            arc.strokeColor = NSColor.controlAccentColor.cgColor
        }
        // Straight to the dead zone's full ring, with no fade: whatever the last gesture ended on
        // has no business showing on a ring that has not been pointed anywhere yet.
        arc.opacity = 0
        full.opacity = 1
        CATransaction.commit()
        lit = .maximize
        panel.restoreAllSpaces("drag anchor dot")
        panel.orderFrontRegardless()
    }

    /// Re-centres the ring on `point`, for the per-move path. The frame only: the colours, the shape
    /// and the Space tagging were all settled by `show(at:)` and do not change mid-gesture.
    func move(to point: CGPoint) {
        panel?.setFrameOrigin(Self.frame(centredOn: point).origin)
    }

    /// Points the arc at `zone`, or fills the ring for `.maximize`. Called when the zone changes,
    /// not on every move.
    ///
    /// From one direction to another the arc glides round the ring the short way; one appearing
    /// from the dead zone starts where it is going rather than travelling from wherever it was
    /// last. Reduce Motion makes it instant.
    func highlight(_ zone: WindowArrangement) {
        guard zone != lit else { return }
        let wasPointing = lit.flatMap(PointDirection.heading(of:)) != nil
        lit = zone
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        guard let heading = PointDirection.heading(of: zone) else {
            arc.opacity = 0
            full.opacity = 1
            return
        }
        let from = angle
        var delta = (heading * .pi / 180 - angle).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi { delta -= 2 * .pi } else if delta <= -.pi { delta += 2 * .pi }
        angle += delta
        // The model value set with actions off, and the travel added explicitly: an implicit
        // `transform` animation interpolates matrices, which cuts across the ring rather than going
        // round it.
        arc.setValue(angle, forKeyPath: "transform.rotation.z")
        if wasPointing, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let travel = CABasicAnimation(keyPath: "transform.rotation.z")
            travel.fromValue = from
            travel.toValue = angle
            travel.duration = Self.glide
            travel.timingFunction = CAMediaTimingFunction(name: .easeOut)
            arc.add(travel, forKey: "travel")
        }
        arc.opacity = 1
        full.opacity = 0
    }

    func hide() {
        panel?.orderOut(nil)
    }

    private static func frame(centredOn point: CGPoint) -> NSRect {
        NSRect(
            x: point.x - diameter / 2, y: point.y - diameter / 2, width: diameter, height: diameter)
    }

    /// Above the destination block, which is a full half-screen the ring would otherwise be lost
    /// inside. The plate and the paths are built once here — the panel never changes size — and
    /// only the colours, which ring layer shows and the arc's rotation change after that.
    private func make() -> NSPanel {
        let panel = OverlayPanel.make(level: .statusBar)
        // The one overlay with a shadow: it is a small solid plate, where the others are outlines
        // that a shadow would double. The window server takes it from the plate's round shape.
        panel.hasShadow = true
        let bounds = CGRect(x: 0, y: 0, width: Self.diameter, height: Self.diameter)
        panel.contentView?.addSubview(Self.plate(bounds))
        ring.frame = bounds
        ring.wantsLayer = true
        panel.contentView?.addSubview(ring)

        let centre = CGPoint(x: bounds.midX, y: bounds.midY)
        // Inset from the plate's edge, then by half the stroke so the stroke stays inside that.
        let radius = (Self.diameter - Self.lineWidth) / 2 - Self.inset
        let circle = CGPath(
            ellipseIn: CGRect(
                x: centre.x - radius, y: centre.y - radius, width: radius * 2, height: radius * 2),
            transform: nil)
        // Facing due east, the zero of `PointDirection.heading(of:)`. The layer is y-up, so +90°
        // sits at the top on screen (measured), and a positive rotation of `arc` turns it
        // anticlockwise to match. The rounded ends reach past the path's own ends by half the
        // stroke, so the path is shortened by that much at each end to keep `arcDegrees` true.
        let half = Self.arcDegrees / 2 * .pi / 180 - (Self.lineWidth / 2) / radius
        let arcPath = CGMutablePath()
        arcPath.addArc(
            center: centre, radius: radius, startAngle: -half, endAngle: half, clockwise: false)
        track.path = circle
        full.path = circle
        arc.path = arcPath
        arc.lineCap = .round
        for layer in [track, full, arc] {
            // Turning `arc` about its own centre is turning it about the ring's.
            layer.frame = bounds
            layer.fillColor = nil
            layer.lineWidth = Self.lineWidth
            ring.layer?.addSublayer(layer)
        }
        return panel
    }

    /// The round plate under the ring: glass on macOS 26 and later, whose own corner radius makes
    /// the circle, and the dark HUD blur before it — the material the system's volume and
    /// brightness indicators were drawn on before glass.
    private static func plate(_ bounds: CGRect) -> NSView {
        if #available(macOS 26.0, *) {
            let glass = NSGlassEffectView(frame: bounds)
            glass.cornerRadius = bounds.width / 2
            return glass
        }
        let blur = NSVisualEffectView(frame: bounds)
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = bounds.width / 2
        blur.layer?.masksToBounds = true
        return blur
    }
}
