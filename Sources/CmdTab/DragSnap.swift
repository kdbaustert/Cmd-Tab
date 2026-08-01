import AppKit

/// Snap-on-drag: throw a window at a screen edge and it tiles there.
///
/// The keyboard chords in `WindowTiling` already do every arrangement; this is the same set reached
/// with the hand already on the mouse, which is how most window dragging starts.
///
/// Two things make this harder than it looks, and both shape the design:
///
/// 1. **Knowing a window is being dragged at all.** There is no notification for it. A global
///    monitor sees mouse events but not what they are doing, so a drag is inferred: the press must
///    land inside another app's window near its top edge (the titlebar strip), and the cursor must
///    then travel far enough to rule out a click. Dragging a selection inside a document, a slider,
///    or anything else that starts away from a titlebar never arms.
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
    /// How far below a window's top edge still counts as its titlebar.
    private static let titlebarDepth: CGFloat = 28

    /// Whether snapping is armed at all. Off means no monitors are installed.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? install() : uninstall()
        }
    }

    /// Per-app overrides, so an app the user has marked "never tile" is left alone here too.
    var appRules: [String: AppRule] = [:]

    private var monitors: [Any] = []
    private let preview = DragSnapPreview()

    /// Where the press landed, and whether it looked like a titlebar. Nil between drags.
    private var pressOrigin: CGPoint?
    private var isDragging = false
    private var draggedPID: pid_t?
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
        // Only a press that looks like it landed on a titlebar may become a snap drag. Without this
        // every drag inside every document — selecting text, moving a shape, panning a map — would
        // arm the preview the moment it neared a screen edge.
        guard let pid = Self.titlebarWindowPID(at: point) else { return }
        pressOrigin = point
        draggedPID = pid
    }

    private func mouseDragged(to point: CGPoint) {
        guard let origin = pressOrigin, let pid = draggedPID else { return }
        if !isDragging {
            let travelled = hypot(point.x - origin.x, point.y - origin.y)
            guard travelled >= Self.dragThreshold else { return }
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
            preview.show(frame)
        } else {
            preview.hide()
        }
    }

    private func mouseUp() {
        defer { reset() }
        guard isDragging, let zone = currentZone, let pid = draggedPID else { return }
        // Dropped in a zone: tile the window that was dragged. Posted rather than run here for the
        // same reason the keyboard path posts — this is an Accessibility write.
        DispatchQueue.main.async {
            WindowTiler.apply(
                zone, pid: pid, areas: WindowTiler.visibleAreas(), cycleWidths: false)
        }
    }

    private func reset() {
        pressOrigin = nil
        isDragging = false
        draggedPID = nil
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

    /// The pid of the window under `point` when the point is in its titlebar strip.
    ///
    /// Read from `CGWindowListCopyWindowInfo` rather than Accessibility: this runs on every mouse
    /// press on the machine, and the window list is a single cheap call where an AX walk would be
    /// IPC to whichever app was clicked.
    private static func titlebarWindowPID(at point: CGPoint) -> pid_t? {
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
                let bounds = window[kCGWindowBounds as String] as? [String: CGFloat],
                let x = bounds["X"], let y = bounds["Y"],
                let width = bounds["Width"], let height = bounds["Height"]
            else { continue }
            let rect = CGRect(x: x, y: y, width: width, height: height)
            guard rect.contains(flipped) else { continue }
            // Front-most match wins — the list is in z-order — so a window behind another cannot
            // claim a press that landed on the one on top.
            let titlebar = CGRect(x: x, y: y, width: width, height: min(titlebarDepth, height))
            return titlebar.contains(flipped) ? pid : nil
        }
        return nil
    }
}

/// The translucent rectangle showing where a dropped window will land.
@MainActor
private final class DragSnapPreview {
    private var panel: NSPanel?

    func show(_ areaFrame: CGRect) {
        let panel = self.panel ?? make()
        self.panel = panel
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

    private func make() -> NSPanel {
        let panel = NSPanel(
            contentRect: .zero, styleMask: [.nonactivatingPanel, .borderless], backing: .buffered,
            defer: false)
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true  // never interrupt the drag it is previewing
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]

        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.22).cgColor
        view.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.85).cgColor
        view.layer?.borderWidth = 2
        view.layer?.cornerRadius = 10
        view.layer?.cornerCurve = .continuous
        panel.contentView = view
        return panel
    }
}
