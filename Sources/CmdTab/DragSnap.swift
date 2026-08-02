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

    // MARK: - Monitors

    private func install() {
        // Global monitors only — local ones would fire for our own windows, and the settings window
        // is the one place we must not snap.
        let down = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.mouseDown(at: NSEvent.mouseLocation, event: event) }
        }
        let dragged = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDragged]) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged(to: NSEvent.mouseLocation) }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] _ in
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
        guard let target = Self.windowUnderCursor(at: point) else { return }
        pressOrigin = point
        draggedPID = target.pid
        draggedWindowID = target.id
        initialBounds = target.bounds
    }

    private func mouseDragged(to point: CGPoint) {
        guard let origin = pressOrigin, let pid = draggedPID else { return }
        if !isDragging {
            let travelled = hypot(point.x - origin.x, point.y - origin.y)
            guard travelled >= Self.dragThreshold else { return }
            // The window has to have moved, and moved without resizing. Checked every event until
            // it has: an app may take a moment to start following the cursor, and giving up after
            // the first event would miss every window that does.
            guard let windowID = draggedWindowID, let initial = initialBounds,
                let current = Self.bounds(of: windowID), Self.isMove(from: initial, to: current)
            else { return }
            // An app the user has told us never to tile drags exactly as it always did.
            if let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                appRules[id]?.neverTile == true {
                reset()
                return
            }
            isDragging = true
        }
        let zone = Self.zone(for: point)
        guard zone != currentZone else { return }
        currentZone = zone
        if let zone, let area = Self.visibleArea(containing: point),
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
        DispatchQueue.main.async {
            WindowTiler.apply(
                zone, pid: pid, areas: WindowTiler.visibleAreas(), cycleWidths: false, gap: gap)
        }
    }

    private func reset() {
        pressOrigin = nil
        isDragging = false
        draggedPID = nil
        draggedWindowID = nil
        initialBounds = nil
        currentZone = nil
        preview.hide()
    }

    // MARK: - Geometry

    /// The arrangement a cursor position is over, or nil away from every edge.
    ///
    /// Corners are tested first and given a much wider threshold: hitting a 12pt band exactly at the
    /// meeting of two edges is finicky with a window in hand, whereas a generous corner box is easy
    /// to aim at and unambiguous once you are there.
    static func zone(for point: CGPoint) -> WindowArrangement? {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) else {
            return nil
        }
        return zone(for: point, in: screen.frame)
    }

    /// The geometry, against an explicit screen frame.
    ///
    /// Split from the lookup above so it can be tested: with the screen resolved internally, every
    /// assertion ran against whatever display the machine happened to have, which is neither
    /// reproducible nor what the test meant to describe.
    nonisolated static func zone(
        for point: CGPoint, in frame: CGRect, threshold: CGFloat? = nil
    ) -> WindowArrangement? {
        let edge = threshold ?? edgeThreshold
        guard frame.contains(point) else { return nil }
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

    /// The visible area containing a point, in Accessibility coordinates.
    private static func visibleArea(containing point: CGPoint) -> CGRect? {
        guard let index = NSScreen.screens.firstIndex(where: { $0.frame.contains(point) }) else {
            return nil
        }
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
        guard let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)
        else { return nil }
        let flipped = CGPoint(x: point.x, y: primary.frame.height - point.y)

        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                pid != ProcessInfo.processInfo.processIdentifier,
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

    /// The outline around the window a gesture is targeting: **light grey**, the colour Rectangle
    /// draws its own snap footprint's border in (`FootprintWindow.boxView.borderColor = .lightGray`).
    ///
    /// Neutral on purpose, and not the accent: a grey border sits over a window's own content
    /// without tinting it, and it stays distinct from `landing` below — one marks *which* window,
    /// the other *where it goes*, and telling those apart at a glance is the whole job of the two
    /// overlays.
    var outline: NSColor { .lightGray }

    /// The block showing where the window will land: black, shown at `blockAlpha`, with the same
    /// light-grey border as `outline`. Rectangle's footprint exactly — `fillColor = NSColor.black`,
    /// `borderColor = .lightGray`, `borderWidth = 2`, alpha 0.3 — rather than an accent tint, which
    /// paints the destination a colour the window itself will not be.
    var landing: NSColor { .black }

    /// Rectangle's `footprintAlpha` default — but applied to the **fill only**, where Rectangle
    /// puts it on the whole footprint window.
    ///
    /// The one deliberate departure from copying them. Alpha on the window fades the border with
    /// the fill, and on a dark backdrop that leaves a black block at 30% (indistinguishable from
    /// what is behind it) edged by a grey hairline at 30% (measured at #38383A — visible, but only
    /// just). The destination is the thing the user is deciding on, so its edge is drawn at full
    /// strength and only the fill is washed: same colours, same weight, same radius as Rectangle,
    /// with the one line you actually navigate by left legible.
    static let blockAlpha: CGFloat = 0.3
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

    /// The anchor dot. Always full strength: it is 14pt across, and at `blockAlpha` — the 30% the
    /// larger overlays are shown at — it would be invisible.
    private(set) var dot: NSColor = .controlAccentColor

    /// macOS's own accent, which is what the dot was before it was configurable.
    static var defaultDot: Color { Color(nsColor: .controlAccentColor) }

    func apply(dot: Color) {
        self.dot = NSColor(dot)
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
        guard let primary = (NSScreen.screens.first { $0.frame.origin == .zero } ?? NSScreen.main)
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
