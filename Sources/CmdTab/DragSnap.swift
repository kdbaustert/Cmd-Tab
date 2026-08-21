import SwiftUI
import AppKit

/// Snap-on-drag: throw a window at a screen edge and it tiles there.
///
/// The keyboard chords in `WindowTiling` already do every arrangement; this is the same set reached
/// with the hand already on the mouse, which is how most window dragging starts.
///
/// Two things make this harder than it looks, and both shape the design:
///
/// 1. **Knowing a window is being dragged at all.** There is no notification for it. A global
///    monitor sees mouse events but not what they are doing, so a drag is inferred — and the proof
///    is the window itself: the press may land *anywhere* in another app's window, but nothing arms
///    until the cursor has travelled far enough to rule out a click **and the window has actually
///    moved**. Selecting text in a document, dragging a slider, or panning a map moves the cursor
///    without moving the window, so none of them ever arm.
///
///    This replaced a titlebar-strip test, which was cheap but wrong in both directions: it refused
///    the many apps whose windows drag from a toolbar or an empty stretch of background, and it
///    still armed on a press that landed in the strip and then dragged something else.
/// 2. **Not stealing the mouse.** The monitors are passive — `addGlobalMonitorForEvents` observes
///    and cannot consume — so the drag itself behaves exactly as it always did, and the snap happens
///    after the window is dropped. Nothing is ever intercepted from another app.
@MainActor
final class DragSnap {
    /// How close to an edge the cursor must be for that edge's zone to arm.
    private nonisolated static let edgeThreshold: CGFloat = 12
    /// How far into a corner counts as a corner rather than an edge.
    private nonisolated static let cornerThreshold: CGFloat = 90
    /// How far the cursor must move before a press counts as a drag rather than a click.
    private static let dragThreshold: CGFloat = 12
    /// The centre zone's side, as a fraction of the screen. Deliberately small: a window dropped
    /// anywhere near the middle of the screen is the ordinary case, and only a drop the user has
    /// clearly aimed at the centre should take over the whole display.
    private nonisolated static let centerFraction: CGFloat = 0.125

    /// Whether snapping is armed at all. Off means no monitors are installed.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? install() : uninstall()
        }
    }

    /// Per-app overrides, so an app the user has marked "never tile" is left alone here too.
    var appRules: [String: AppRule] = [:]

    /// The tiling gap, so the preview shows where the window will actually land rather than the
    /// zone it was dropped in. A preview that ignored the gap would be wrong by up to a gap on
    /// every edge — and the preview is the only thing the user sees before letting go.
    var gap: CGFloat = 0

    private var monitors: [Any] = []
    private let preview = SnapPreview.shared

    /// Where the press landed. Nil between drags.
    private var pressOrigin: CGPoint?
    private var isDragging = false
    private var draggedPID: pid_t?
    /// The window under the press, and where it was: the pair that turns "the mouse moved" into
    /// "this window is being dragged".
    private var draggedWindowID: CGWindowID?
    private var initialBounds: CGRect?
    private var currentZone: WindowArrangement?
    /// The visible area the preview for `currentZone` was drawn against.
    ///
    /// Kept rather than re-derived at drop time, because the two answers can differ: the drop used
    /// to pass no display at all and `WindowTiler.apply` re-derived one from the *window's* frame,
    /// while the preview came from the *cursor's* display. A window grabbed near its right edge and
    /// nudged right puts those on different monitors, so the user was shown one and given the
    /// other.
    private var currentArea: CGRect?
    /// How long after the press this drag may keep asking whether its window has moved yet.
    ///
    /// The check is a window-server round trip, it runs on the main thread — the one servicing the
    /// keyboard tap — and it used to run on *every* drag event until the window was seen to move.
    /// For the drags that are not window drags at all, which is most of them, that meant it never
    /// stopped: selecting a paragraph, panning a map or dragging a slider for half a minute bought a
    /// round trip per event for the whole gesture, and not one of them could ever succeed.
    ///
    /// A deadline rather than a count of attempts, deliberately. A count is a bound on the wrong
    /// axis: events arrive at the trackpad's rate, so a dozen of them is a tenth of a second on this
    /// machine and something else on the next, and an app that is merely slow to pick the drag up —
    /// a heavy Electron window under load is the standing case — would silently stop arming. Time is
    /// what "has this app started following the cursor?" is actually asking about, and a second and
    /// a half is far past any app that is going to.
    private var moveCheckDeadline: Date?
    private static let moveCheckWindow: TimeInterval = 1.5

    // MARK: - Monitors

    private func install() {
        // Global monitors only — local ones would fire for our own windows, and the settings window
        // is the one place we must not snap.
        // Our own synthetic drags are skipped throughout. `DesktopMover` moves a window between
        // Desktops by performing a real drag, and its route to Mission Control's Spaces Bar crosses
        // the top-edge snap zone — so without this, dropping a window on another Desktop also reads
        // as "maximize it", and the window arrives resized or inset by the gap. See `SyntheticEvent`.
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            guard !SyntheticEvent.isOurs(event.cgEvent) else { return }
            MainActor.assumeIsolated { self?.mouseDown(at: NSEvent.mouseLocation, event: event) }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) {
            [weak self] event in
            guard !SyntheticEvent.isOurs(event.cgEvent) else { return }
            MainActor.assumeIsolated { self?.mouseDragged(to: NSEvent.mouseLocation) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            guard !SyntheticEvent.isOurs(event.cgEvent) else { return }
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, dragged, up].compactMap { $0 }
    }

    private func uninstall() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors = []
        reset()
    }

    // MARK: - Gesture

    private func mouseDown(at point: CGPoint, event: NSEvent) {
        reset()
        // Anywhere in the window. What stops a text selection arming the preview is not where the
        // press landed but whether the window moves — see `mouseDragged`.
        guard let target = MainLoopMonitor.marking("drag-snap window lookup", {
            Self.windowUnderCursor(at: point)
        }) else { return }
        pressOrigin = point
        draggedPID = target.pid
        draggedWindowID = target.id
        initialBounds = target.bounds
        moveCheckDeadline = Date().addingTimeInterval(Self.moveCheckWindow)
    }

    private func mouseDragged(to point: CGPoint) {
        guard let origin = pressOrigin, let pid = draggedPID else { return }
        if !isDragging {
            let travelled = hypot(point.x - origin.x, point.y - origin.y)
            guard travelled >= Self.dragThreshold else { return }
            // The window has to have moved, and moved without resizing. Checked on each event for a
            // while rather than once — an app may take a moment to start following the cursor, and
            // giving up after the first would miss every window that does — but not forever; see
            // `moveCheckDeadline`.
            guard let deadline = moveCheckDeadline, Date() < deadline else { return }
            guard let windowID = draggedWindowID, let initial = initialBounds,
                let current = MainLoopMonitor.marking(
                    "drag-snap move check", { Self.bounds(of: windowID) }),
                Self.isMove(from: initial, to: current)
            else { return }
            // An app the user has told us never to tile drags exactly as it always did.
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                appRules[id]?.neverTile == true {
                reset()
                return
            }
            isDragging = true
        }
        // The screen resolved once and both answers taken from it, rather than `zone(for:)` and
        // `visibleArea(containing:)` each doing their own `NSScreen` lookup. That also removes the
        // question of whether the two could disagree — and keeps `currentArea` honest across a
        // cursor that crosses displays without changing which zone it is in, which the zone-change
        // guard below would otherwise skip right over.
        let index = NSScreen.screens.firstIndex { NSMouseInRect(point, $0.frame, false) }
        let zone = index.flatMap { Self.zone(for: point, in: NSScreen.screens[$0].frame) }
        let area = zone == nil ? nil : index.flatMap(Self.visibleArea(atScreen:))
        currentArea = area
        guard zone != currentZone else { return }
        currentZone = zone
        if let zone, let area,
            let frame = zone.frame(in: area, current: area, fraction: 0.5) {
            preview.show(zone.takesGap ? TilingGap.inset(frame, in: area, gap: gap) : frame)
        } else {
            preview.hide()
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard isDragging, let zone = currentZone, let pid = draggedPID else { return }
        // Dropped in a zone: tile the window that was dragged. Posted rather than run here for the
        // same reason the keyboard path posts — this is an Accessibility write.
        let gap = self.gap
        // The window this gesture has been following, named rather than left for the tiler to
        // re-resolve from the pid — which is `AX.frontWindow`, the app's *focused* window.
        //
        // Those two are usually the same here, because pressing in a window focuses it, and that is
        // what the pid-only call has always leaned on. Usually is not always: click-through means a
        // press can move a window of an app that was already frontmost without changing which of its
        // windows has focus, and `kAXFocusedWindow` is the app's own answer rather than the window
        // server's, so it can still be reporting the previous one when the drop lands. Either way
        // the wrong window is snapped, and the gesture has known which one all along — this is the
        // same fix the other two snap gestures already carry, arriving late.
        //
        // Its bounds *now*, not `initialBounds`: the window having moved is this gesture's arming
        // condition, so the press-time frame is stale by construction and would match nothing.
        // `bounds(of:)` is one window-server call, taken inside the hop so it stays off the monitor
        // callback. A nil — the window closed as it was dropped — degrades to the previous
        // behaviour rather than to no snap at all.
        let windowID = draggedWindowID
        // The display the preview was painted on — see `currentArea`.
        let area = currentArea
        DispatchQueue.main.async {
            let dropped = windowID.flatMap(Self.bounds(of:))
            WindowTiler.apply(
                zone, pid: pid, areas: WindowTiler.visibleAreas(), cycleWidths: false, gap: gap,
                target: dropped.map(WindowTiler.Target.bounds), destination: area)
        }
    }

    private func reset() {
        pressOrigin = nil
        isDragging = false
        draggedPID = nil
        draggedWindowID = nil
        initialBounds = nil
        currentZone = nil
        currentArea = nil
        moveCheckDeadline = nil
        preview.hide()
    }

    // MARK: - Geometry

    /// The arrangement a cursor position is over, against an explicit screen frame, or nil away
    /// from every edge.
    ///
    /// Corners are tested first and given a much wider threshold: hitting a 12pt band exactly at the
    /// meeting of two edges is finicky with a window in hand, whereas a generous corner box is easy
    /// to aim at and unambiguous once you are there.
    ///
    /// The screen is a parameter rather than resolved here, which is what makes it testable: with
    /// the lookup inside, every assertion ran against whatever display the machine happened to
    /// have, which is neither reproducible nor what the test meant to describe. The one-argument
    /// wrapper that used to sit above this is gone with its last caller — `mouseDragged` resolves
    /// the screen itself now, because it needs the index for `visibleArea(atScreen:)` anyway and
    /// two independent lookups could disagree at a boundary.
    nonisolated static func zone(
        for point: CGPoint, in frame: CGRect, threshold: CGFloat? = nil
    ) -> WindowArrangement? {
        let edge = threshold ?? edgeThreshold
        // `NSMouseInRect`, not `CGRect.contains`, and the difference is the whole top edge.
        // `contains` is `minY <= y < maxY`; these points are Cocoa bottom-up, so the topmost
        // physical row — where the cursor clamps when it is shoved at the top of the screen — is
        // exactly `maxY`, the one value `contains` rejects. That made `.maximize`, `.topLeft` and
        // `.topRight` unreachable by the gesture aimed straight at them. `NSMouseInRect` is
        // maxY-inclusive and minY-exclusive, and its rejection of `minY` is harmless because the
        // bottom physical row maps to y = 1. `SwitcherPanel.underCursor` already asks this way.
        guard NSMouseInRect(point, frame, false) else { return nil }
        let nearLeft = point.x - frame.minX <= edge
        let nearRight = frame.maxX - point.x <= edge
        // Cocoa's screen space is bottom-up, so "top" is the maximum y.
        let nearTop = frame.maxY - point.y <= edge
        let nearBottom = point.y - frame.minY <= edge

        // The centre of the screen takes the whole screen. Tested before the edge bail-out but
        // after the edges are measured, so an edge always wins — the box is nowhere near one.
        let box = CGSize(width: frame.width * centerFraction, height: frame.height * centerFraction)
        if abs(point.x - frame.midX) <= box.width / 2, abs(point.y - frame.midY) <= box.height / 2 {
            return .maximize
        }
        guard nearLeft || nearRight || nearTop || nearBottom else { return nil }

        let inLeft = point.x - frame.minX <= cornerThreshold
        let inRight = frame.maxX - point.x <= cornerThreshold
        let inTop = frame.maxY - point.y <= cornerThreshold
        let inBottom = point.y - frame.minY <= cornerThreshold

        if (nearTop || nearLeft) && inTop && inLeft { return .topLeft }
        if (nearTop || nearRight) && inTop && inRight { return .topRight }
        if (nearBottom || nearLeft) && inBottom && inLeft { return .bottomLeft }
        if (nearBottom || nearRight) && inBottom && inRight { return .bottomRight }
        if nearLeft { return .leftHalf }
        if nearRight { return .rightHalf }
        // Top is maximize rather than "top half", matching every other platform's edge-snap and the
        // gesture people already have in their fingers.
        if nearTop { return .maximize }
        if nearBottom { return .bottomHalf }
        return nil
    }

    /// The visible area of a screen, by index into `NSScreen.screens`, in Accessibility
    /// coordinates.
    ///
    /// By index rather than by point: the caller has already resolved which screen the cursor is
    /// on in order to ask `zone(for:in:)`, and resolving it twice invites the two answers to
    /// disagree at a display boundary.
    private static func visibleArea(atScreen index: Int) -> CGRect? {
        let areas = WindowTiler.visibleAreas()
        return index < areas.count ? areas[index] : nil
    }

    /// The frontmost ordinary window under `point`, with the id and bounds needed to tell later
    /// whether it has moved.
    ///
    /// Read from `CGWindowListCopyWindowInfo` rather than Accessibility: this runs on every mouse
    /// press on the machine, and the window list is a single cheap call where an AX walk would be
    /// IPC to whichever app was clicked.
    private static func windowUnderCursor(at point: CGPoint)
        -> (pid: pid_t, id: CGWindowID, bounds: CGRect)?
    {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        // Screen point is bottom-up; the window list is top-down.
        guard let primary = NSScreen.primary
        else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.height - point.y)

        for window in info {
            // Our own ordinary windows included — Settings drags to a snap zone like any other.
            // The switcher panel and the snap overlays sit above `.normal`, so `layer == 0` has
            // already dropped them.
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let id = window[kCGWindowNumber as String] as? CGWindowID,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary)
            else { continue }
            // Front-most match wins — the list is in z-order — so a window behind another cannot
            // claim a press that landed on the one on top.
            guard bounds.contains(flipped) else { continue }
            return (pid, id, bounds)
        }
        return nil
    }

    /// One window's current bounds, by id. A single-window query rather than a whole-list copy,
    /// because this runs on every drag event until the window is seen to move.
    private static func bounds(of id: CGWindowID) -> CGRect? {
        guard
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], id) as? [[String: Any]],
            let raw = info.first?[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }

    /// Whether a window has been *moved* between two observations.
    ///
    /// The origin has to have changed and the size has to be unchanged. Both halves matter: without
    /// the first, any window under the cursor would arm the moment the mouse twitched; without the
    /// second, dragging a window's resize corner — which also shifts the origin, on two of the four
    /// corners — would offer to snap the window the user is deliberately sizing by hand.
    nonisolated static func isMove(from initial: CGRect, to current: CGRect) -> Bool {
        current.origin != initial.origin && current.size == initial.size
    }
}

/// How the snap overlays are painted — colours, opacity and geometry — in one place so the three of
/// them cannot drift.
///
/// Read at show time rather than baked in when a panel is built: the panels are made once and
/// reused for the life of the app, so anything read at creation would be stale after a change. Only
/// `dot` can actually change today, but reading all of it the same way is what keeps a future
/// setting from needing new plumbing to reach the screen.
@MainActor
final class SnapAppearance {
    static let shared = SnapAppearance()

    /// Rectangle Pro's highlight colour: **#BF5AF2**, which is Apple's system purple in its dark
    /// variant.
    ///
    /// Taken from Rectangle Pro's own `reticleColor` preference rather than sampled off a
    /// screenshot, and that is the stronger source: the stored value is the colour *before* it is
    /// composited, where a pixel read back off the screen has the overlay's own alpha and whatever
    /// was behind it already mixed in, and un-mixing that is guesswork. Read on macOS 26 from
    /// `com.knollsoft.Hookshot` as `{"red":0.7490196078431373, "green":0.35294117647058826,
    /// "blue":0.9490196078431372, "alpha":1}`.
    ///
    /// Copied as a literal, deliberately: reading another app's preferences at runtime would make
    /// this app's appearance depend on one it does not ship with, break silently the day that key
    /// is renamed, and leave someone without Rectangle Pro installed with no colour at all.
    static let rectangleHighlight = NSColor(
        srgbRed: 191 / 255, green: 90 / 255, blue: 242 / 255, alpha: 1)

    /// The outline around the window a gesture is targeting.
    ///
    /// This was light grey — the border colour the *free* Rectangle uses
    /// (`FootprintWindow.boxView.borderColor = .lightGray`) — on the reasoning that a neutral edge
    /// sits over a window's own content without tinting it. Rectangle Pro moved on: it tints its
    /// snap UI with a single configurable colour, and matching what is actually on this machine's
    /// screen matters more than matching an older version's source — including the *configurable*
    /// part, which is why this and `landing` are settings now rather than constants.
    private(set) var outline: NSColor = SnapAppearance.rectangleHighlight

    /// The block showing where the window will land, washed down to `blockAlpha` inside a
    /// full-strength border of the same colour.
    ///
    /// Defaults to matching `outline`, and the two are separate settings rather than one because
    /// they answer different questions — one says "this is the window", the other "this is where it
    /// goes" — and someone who wants to tell them apart at a glance can now give them two colours.
    /// The wash is what keeps the block from pretending to *be* the window: you can still see what
    /// is underneath, which is the thing you are deciding to cover.
    private(set) var landing: NSColor = SnapAppearance.rectangleHighlight

    /// Applied to the **fill only**, never to the border.
    ///
    /// Alpha on the window would fade the border with the fill, and a hairline at a quarter
    /// strength over a busy backdrop is the one line you actually navigate by, lost. So the edge is
    /// drawn full and only the fill is washed.
    ///
    /// Lower than the 0.3 this used when the fill was black. Black at 30% darkens whatever is
    /// behind it and reads as shadow; a saturated purple at the same value reads as paint, and at
    /// that strength it swamps the window content underneath rather than tinting it.
    static let blockAlpha: CGFloat = 0.22
    /// Rectangle's `footprintBorderWidth` default.
    static let borderWidth: CGFloat = 2

    /// Matching Rectangle's ladder, minus the rungs this app cannot reach: 16 on macOS 26, 10
    /// below it. Rectangle also has a 5 for pre-Big-Sur, which is dead here — `Package.swift` sets
    /// the deployment target to macOS 14, so the app cannot launch anywhere that would use it.
    ///
    /// A snap preview whose corners disagree with the system's window corners reads as a misdrawn
    /// window. That reasoning applies to the *destination* block, which is a rectangle this app
    /// draws; `TargetOutline` traces a real window it does not own and so keeps its own radius.
    static var blockCornerRadius: CGFloat {
        if #available(macOS 26.0, *) { return 16 }
        return 10
    }

    /// The outline around a targeted window. Smaller than the block's, deliberately: this one is
    /// drawn around whatever the cursor is over — a full-screen window, a borderless one, anything
    /// with square corners — and a 16pt curve there cuts across the very corners it is marking,
    /// leaving four wedges of window outside the highlight.
    static let outlineCornerRadius: CGFloat = 10

    /// The anchor dot. Always full strength: it is 14pt across, and at `blockAlpha` — the fraction
    /// the larger overlays are washed to — it would be invisible.
    ///
    /// Rectangle Pro's equivalent is its reticle, which its own `reticleSize` puts at 15pt — near
    /// enough the same object at near enough the same size, which is why the two now share a
    /// colour as well.
    private(set) var dot: NSColor = SnapAppearance.rectangleHighlight

    /// What an unconfigured install gets for all three. One value behind them, so the snap UI ships
    /// looking like one system and only diverges if someone deliberately pulls it apart.
    static var defaultOutline: Color { Color(nsColor: rectangleHighlight) }
    static var defaultLanding: Color { Color(nsColor: rectangleHighlight) }
    static var defaultDot: Color { Color(nsColor: rectangleHighlight) }

    /// Pushed by `WindowTilingStore` whenever a colour changes, and read again by each overlay on
    /// its next `show` — every one of them restyles per-show, so a change made mid-session lands on
    /// the next gesture without anything having to be torn down or redrawn.
    ///
    /// Individually optional so a caller can set one without having to know the other two, which is
    /// how the store's three separate `didSet`s use it.
    func apply(outline: Color? = nil, landing: Color? = nil, dot: Color? = nil) {
        if let outline { self.outline = NSColor(outline) }
        if let landing { self.landing = NSColor(landing) }
        if let dot { self.dot = NSColor(dot) }
    }
}

/// The translucent rectangle showing where a dropped window will land.
///
/// Shared by both gestures that can snap — the titlebar drag above and the modifier-drag in
/// `MouseWindowDrag` — through `shared`. One panel, because only one drag can be in flight: two
/// owners meant two overlays, and whichever hid last left the other on screen.
@MainActor
final class SnapPreview {
    static let shared = SnapPreview()

    private var panel: NSPanel?

    private init() {}

    func show(_ areaFrame: CGRect) {
        let panel = self.panel ?? make()
        self.panel = panel
        restyle(panel)
        // Back from Accessibility's top-left space into Cocoa's bottom-up screen space.
        guard let primary = NSScreen.primary
        else { return }
        let rect = NSRect(
            x: areaFrame.minX, y: primary.frame.height - areaFrame.maxY,
            width: areaFrame.width, height: areaFrame.height)
        panel.setFrame(rect, display: true)
        panel.orderFrontRegardless()
    }

    func hide() {
        panel?.orderOut(nil)
    }

    /// Painted on every show and nowhere else. The panel is made blank: styling it at creation too
    /// meant two copies of the same four values, and a later change to one of them would have left
    /// the first frame of a gesture drawn the old way.
    private func restyle(_ panel: NSPanel) {
        guard let layer = panel.contentView?.layer else { return }
        // Opaque panel, translucent fill — see `SnapAppearance.blockAlpha` for why the alpha is
        // here and not on the window.
        panel.alphaValue = 1
        layer.backgroundColor = SnapAppearance.shared.landing
            .withAlphaComponent(SnapAppearance.blockAlpha).cgColor
        layer.borderColor = SnapAppearance.shared.outline.cgColor
        layer.borderWidth = SnapAppearance.borderWidth
        layer.cornerRadius = SnapAppearance.blockCornerRadius
    }

    // Never interrupts the drag it is previewing — see `OverlayPanel`.
    private func make() -> NSPanel { OverlayPanel.make(level: .floating) }
}

/// The panel every overlay is built on: non-activating, borderless, transparent, click-through, and
/// present on every Space.
///
/// One factory rather than three copies of the same eight lines. Each property is load-bearing in
/// the same way for all of them — an overlay that took a click would swallow the very gesture it is
/// drawn for, and one that did not join all Spaces would vanish the moment a window was thrown to
/// another Desktop — so a change to any of it belongs in one place.
@MainActor
enum OverlayPanel {
    static func make(level: NSWindow.Level) -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = level
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        panel.contentView = view
        return panel
    }
}
