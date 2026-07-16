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

    func show() {
        layout()
        orderFrontRegardless()
        startHoverTracking()
    }

    func hide() {
        stopHoverTracking()
        orderOut(nil)
    }

    // MARK: - Hover

    private func startHoverTracking() {
        guard hoverMonitor == nil else { return }
        // Global (not local) because the switch happens while another app owns the keyboard and
        // mouse. Global monitors observe those events read-only, which is all we need. Mouse-moved
        // monitoring needs no Accessibility grant of its own.
        hoverMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) {
            [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let index = self.tileIndex(at: NSEvent.mouseLocation) else { return }
                if self.model.selection != index { self.model.selection = index }
            }
        }
    }

    private func stopHoverTracking() {
        if let hoverMonitor {
            NSEvent.removeMonitor(hoverMonitor)
            self.hoverMonitor = nil
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
        let columns = Self.columns(for: model, on: screen)
        laidOutColumns = columns
        laidOutTile = model.metrics.tile(for: model.mode)
        let view = SwitcherView(model: model, columns: columns)

        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            self.host = host
            contentView = host
        }

        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)

        let frame = screen.visibleFrame
        setFrameOrigin(
            NSPoint(
                x: frame.midX - size.width / 2,
                y: frame.midY - size.height / 2))
    }

    private func targetScreen() -> NSScreen {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }

    private static func columns(for model: SwitcherModel, on screen: NSScreen) -> Int {
        let count = model.targets.count
        guard count > 0 else { return 1 }
        let metrics = model.metrics
        let tileWidth = metrics.tile(for: model.mode).width + Metrics.tileGap
        let available = screen.visibleFrame.width * Metrics.maxScreenFraction
            - Metrics.panelPadding * 2
        let fits = max(Int(available / tileWidth), 1)
        return min(count, fits)
    }
}
