import AppKit
import SwiftUI

/// The overlay window. It is deliberately non-activating: the panel must appear without our
/// app ever becoming frontmost, or the switch target would be us instead of whatever the user
/// picked. All keyboard input arrives through the event tap, never through this window.
@MainActor
final class SwitcherPanel: NSPanel {
    private let model: SwitcherModel
    private var host: NSHostingView<SwitcherView>?

    // Geometry from the last layout, so the mouse can be mapped back to a tile without asking
    // SwiftUI. Kept in sync by `layout()`.
    private var laidOutColumns = 1
    private var laidOutTile = CGSize.zero

    // Fires while another app is frontmost — the panel never becomes key, so SwiftUI's own hover
    // tracking stays dormant and we drive the highlight from the raw cursor position instead.
    private var hoverMonitor: Any?
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    /// Bumped on every show/hide so a pending fade-out completion can tell it has been superseded.
    private var hideToken = 0

    /// Forced appearance and placement, driven from settings.
    var appearanceMode: PanelAppearance = .system
    var positionMode: PanelPosition = .center
    /// 0 = automatic (wrap at the screen-fraction limit); otherwise a hard cap on columns.
    var maxColumns = 0
    /// Fade the panel in and out instead of appearing instantly.
    var fade = false

    /// Invoked when a tile is clicked, with its index. Set by the controller to commit the pick.
    var onPick: ((Int) -> Void)?
    /// Invoked with a step (+1/-1) when the scroll wheel moves over the panel.
    var onScroll: ((Int) -> Void)?

    /// App-mode window previews: whether the hover thumbnails are enabled at all.
    var windowPreviewEnabled = false
    /// Fires when the hovered app tile changes: the app's pid and the tile's screen rect, or nil pid
    /// when the cursor leaves the grid. Only emitted in app mode with previews on.
    var onHoverPreview: ((_ pid: pid_t?, _ tileRect: NSRect) -> Void)?
    /// The last tile a preview was requested for, so it is not re-requested on every mouse-move.
    /// nil means the cursor is off the grid (or nothing hovered yet), matching "no preview".
    private var lastHoverPreviewIndex: Int?

    init(model: SwitcherModel) {
        self.model = model
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 100, height: 100),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)

        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A non-activating panel still receives mouse clicks without bringing our app forward, so a
    /// click on a tile can be turned straight into a pick. Handled here rather than in SwiftUI:
    /// the panel is never key, so SwiftUI's own gesture recognisers stay dormant (the same reason
    /// hover is driven from a global monitor).
    override func sendEvent(_ event: NSEvent) {
        if event.type == .leftMouseDown, let index = tileIndex(at: NSEvent.mouseLocation) {
            onPick?(index)
            return
        }
        super.sendEvent(event)
    }

    func show() {
        // Invalidate any in-flight fade-out completion so a quick re-show is not ordered back out.
        hideToken &+= 1
        layout()
        if fade {
            alphaValue = 0
            orderFrontRegardless()
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.12
                animator().alphaValue = 1
            }
        } else {
            alphaValue = 1
            orderFrontRegardless()
        }
        startHoverTracking()
    }

    func hide() {
        stopHoverTracking()
        // A fade-out has to keep the window up until the animation finishes, so order out in the
        // completion; the instant path just drops it. The token guards against a re-show landing
        // mid-fade — without it the stale completion would order the fresh panel back out.
        if fade && alphaValue > 0 {
            hideToken &+= 1
            let token = hideToken
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.10
                animator().alphaValue = 0
            } completionHandler: { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.hideToken == token else { return }
                    self.orderOut(nil)
                }
            }
        } else {
            orderOut(nil)
        }
    }

    // MARK: - Hover & scroll

    private func startHoverTracking() {
        guard hoverMonitor == nil else { return }
        // Global (not local) because the switch happens while another app owns the keyboard and
        // mouse. Global monitors observe those events read-only, which is all we need. Mouse-moved
        // monitoring needs no Accessibility grant of its own.
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let index = self.tileIndex(at: NSEvent.mouseLocation)
                if let index, self.model.selection != index { self.model.selection = index }
                self.updateHoverPreview(index)
            }
        }
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
        }
    }

    private func stopHoverTracking() {
        for monitor in [hoverMonitor, scrollMonitor] {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
        hoverMonitor = nil
        scrollMonitor = nil
        scrollAccumulator = 0
        // Dismiss any live preview and reset so the next session starts clean.
        if lastHoverPreviewIndex != nil { onHoverPreview?(nil, .zero) }
        lastHoverPreviewIndex = nil
    }

    /// Requests a window preview when the hovered app tile changes, and a dismissal when the cursor
    /// leaves the grid. Debounced to tile changes so it is not re-fired on every mouse-moved event.
    private func updateHoverPreview(_ index: Int?) {
        guard windowPreviewEnabled, model.mode == .apps else { return }
        guard index != lastHoverPreviewIndex else { return }
        lastHoverPreviewIndex = index
        if let index, model.targets.indices.contains(index) {
            onHoverPreview?(model.targets[index].pid, tileScreenRect(for: index) ?? .zero)
        } else {
            onHoverPreview?(nil, .zero)
        }
    }

    /// The screen rect of tile `index` — the inverse of `tileIndex(at:)`, in bottom-up screen
    /// coordinates. Mirrors the same `LazyVGrid` layout.
    private func tileScreenRect(for index: Int) -> NSRect? {
        guard laidOutColumns > 0, laidOutTile.width > 0, laidOutTile.height > 0 else { return nil }
        let row = index / laidOutColumns
        let col = index % laidOutColumns
        let colStride = laidOutTile.width + Metrics.tileGap
        let rowStride = laidOutTile.height + Metrics.tileGap
        let left = frame.minX + Metrics.panelPadding + CGFloat(col) * colStride
        let top = frame.maxY - Metrics.panelPadding - CGFloat(row) * rowStride
        return NSRect(
            x: left, y: top - laidOutTile.height, width: laidOutTile.width, height: laidOutTile.height)
    }

    /// Turns accumulated scroll travel into discrete selection steps. The threshold keeps a single
    /// flick of an inertial trackpad from racing through the whole list.
    private func handleScroll(_ event: NSEvent) {
        let delta = event.scrollingDeltaY != 0 ? event.scrollingDeltaY : event.scrollingDeltaX
        scrollAccumulator += delta
        let threshold: CGFloat = 6
        while scrollAccumulator <= -threshold {
            scrollAccumulator += threshold
            onScroll?(1)
        }
        while scrollAccumulator >= threshold {
            scrollAccumulator -= threshold
            onScroll?(-1)
        }
    }

    /// Maps a screen point to the tile under it, or nil if the cursor is off the grid (gaps, the
    /// caption strip, or outside the panel). Mirrors the `LazyVGrid` layout in `SwitcherView`:
    /// `panelPadding` inset, `tileGap` between tiles, rows filled left-to-right.
    private func tileIndex(at screenPoint: NSPoint) -> Int? {
        let count = model.targets.count
        guard count > 0, laidOutTile.width > 0, laidOutTile.height > 0 else { return nil }

        // Panel coordinates are bottom-up; flip to top-left to match the grid's reading order.
        let x = screenPoint.x - frame.minX - Metrics.panelPadding
        let y = frame.maxY - screenPoint.y - Metrics.panelPadding
        guard x >= 0, y >= 0 else { return nil }

        let colStride = laidOutTile.width + Metrics.tileGap
        let rowStride = laidOutTile.height + Metrics.tileGap
        let col = Int(x / colStride)
        let row = Int(y / rowStride)
        guard col < laidOutColumns else { return nil }
        // Reject the gaps between tiles so the highlight doesn't jump while crossing them.
        guard x - CGFloat(col) * colStride <= laidOutTile.width,
              y - CGFloat(row) * rowStride <= laidOutTile.height else { return nil }

        let index = row * laidOutColumns + col
        return index < count ? index : nil
    }

    /// Rebuilds the content at the size the current target list needs, then recenters.
    func layout() {
        let screen = targetScreen()
        let columns = Self.columns(for: model, on: screen, cap: maxColumns)
        laidOutColumns = columns
        laidOutTile = model.metrics.tile(for: model.mode, showsTitle: model.showsTitle)
        let view = SwitcherView(model: model, columns: columns)

        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            self.host = host
            contentView = host
        }

        appearance = appearanceMode.nsAppearance

        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(origin(for: size, on: screen))
    }

    /// Where the panel's bottom-left corner goes, per the position setting. "Near cursor" keeps the
    /// whole panel on the screen it opened on rather than letting it spill off an edge.
    private func origin(for size: CGSize, on screen: NSScreen) -> NSPoint {
        let visible = screen.visibleFrame
        switch positionMode {
        case .center, .activeScreen:
            // Both centre on a screen; `targetScreen()` already chose active-vs-cursor for us.
            return NSPoint(x: visible.midX - size.width / 2, y: visible.midY - size.height / 2)
        case .cursor:
            let mouse = NSEvent.mouseLocation
            // Clamp the upper bounds up to the lower ones: a panel taller or wider than the visible
            // frame would otherwise make an inverted ClosedRange, which traps at runtime.
            let maxX = max(visible.minX, visible.maxX - size.width)
            let maxY = max(visible.minY, visible.maxY - size.height)
            let x = (mouse.x - size.width / 2).clamped(to: visible.minX...maxX)
            let y = (mouse.y - size.height / 2).clamped(to: visible.minY...maxY)
            return NSPoint(x: x, y: y)
        }
    }

    private func targetScreen() -> NSScreen {
        // "Active screen" follows the frontmost app's screen (NSScreen.main); the others follow
        // the cursor's screen.
        if positionMode == .activeScreen, let main = NSScreen.main {
            return main
        }
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func columns(for model: SwitcherModel, on screen: NSScreen, cap: Int) -> Int {
        let count = model.targets.count
        guard count > 0 else { return 1 }
        let metrics = model.metrics
        let tileWidth = metrics.tile(for: model.mode, showsTitle: model.showsTitle).width
            + Metrics.tileGap
        let available = screen.visibleFrame.width * Metrics.maxScreenFraction
            - Metrics.panelPadding * 2
        var fits = max(Int(available / tileWidth), 1)
        if cap > 0 { fits = min(fits, cap) }
        return min(count, fits)
    }
}
