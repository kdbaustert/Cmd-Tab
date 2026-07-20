import AppKit
import SwiftUI

/// What the cursor (or keyboard selection) points at, for the hover window preview.
enum PreviewHoverTarget: Equatable {
    /// An app tile — the app's pid and the tile's screen rect.
    case tile(pid: pid_t, rect: NSRect)
    /// The floating preview panel itself — keep it up so a thumbnail can be reached and clicked.
    case overPreview
    /// Neither — tear the preview down (the controller adds a short grace delay so the cursor can
    /// cross the gap from a tile to the preview without it vanishing mid-move).
    case away
}

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

    // The panel never becomes key, so SwiftUI's own hover tracking stays dormant and we drive the
    // highlight from the raw cursor position instead. This is a timer poll rather than a global
    // mouse-moved monitor because a global monitor only sees events bound for *other* apps — so the
    // moment Cmd-Tab itself is frontmost (e.g. right after ⌘Q/⌘H, or after Settings was open) the
    // monitor goes silent and the highlight stops following the cursor. Polling the location is
    // immune to that.
    private var hoverTimer: Timer?
    private var lastHoverLocation: NSPoint?
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
    /// Fires when what the cursor points at (a tile, the preview, or nothing) changes. Only while
    /// app-mode previews are on.
    var onPreviewHover: ((PreviewHoverTarget) -> Void)?
    /// Whether a screen point is over the floating preview panel — the controller answers this so the
    /// preview stays up (and clickable) while the cursor is on it.
    var isOverPreview: ((NSPoint) -> Bool)?
    /// The last target emitted, so nothing re-fires while the cursor sits on the same tile/preview.
    private var lastPreviewTarget: PreviewHoverTarget = .away

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
        guard hoverTimer == nil else { return }
        lastHoverLocation = nil
        // ~60 Hz. Added in .common mode so it keeps firing during tracking run-loop modes.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHoverFromCursor() }
        }
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        // Scroll stays a global monitor — deltas can't be polled. It shares the frontmost-app
        // limitation above, but scroll-to-move is secondary to the cursor highlight.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
        }
    }

    /// Polls the cursor, moves the highlight to the tile under it, and reports what the preview
    /// should track. Skips the work when the cursor hasn't moved, so a still cursor costs nothing.
    private func updateHoverFromCursor() {
        let location = NSEvent.mouseLocation
        guard location != lastHoverLocation else { return }
        lastHoverLocation = location
        let overPreview = isOverPreview?(location) == true
        // The highlight follows the tile — but not while over the preview, so it stays put there.
        let index = overPreview ? nil : tileIndex(at: location)
        if let index, model.selection != index { model.selection = index }
        emitPreview(target(overPreview: overPreview, index: index))
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollAccumulator = 0
        lastHoverLocation = nil
        // Reset unconditionally (not via emitPreview, which is gated on the setting) so the next
        // session starts clean. The controller dismisses the preview panel itself on hide.
        lastPreviewTarget = .away
    }

    /// The preview target for the given cursor state — the preview panel, a tile, or nothing.
    private func target(overPreview: Bool, index: Int?) -> PreviewHoverTarget {
        if overPreview { return .overPreview }
        if let index, model.targets.indices.contains(index) {
            return .tile(pid: model.targets[index].pid, rect: tileScreenRect(for: index) ?? .zero)
        }
        return .away
    }

    /// Emits a target change (only in app mode with previews on), deduped so an unchanged target
    /// doesn't re-fire on every tick.
    private func emitPreview(_ target: PreviewHoverTarget) {
        guard windowPreviewEnabled, model.mode == .apps else { return }
        guard target != lastPreviewTarget else { return }
        lastPreviewTarget = target
        onPreviewHover?(target)
    }

    /// Re-evaluates the preview against whatever tile is under the cursor now. Called after the
    /// target list changes beneath a stationary cursor — a tile was quit/closed/hidden, or a
    /// background refresh folded in a new list — so the floating strip follows the app actually there
    /// (or is dismissed if the tile is gone).
    func refreshHoverPreview() {
        let location = NSEvent.mouseLocation
        emitPreview(target(overPreview: isOverPreview?(location) == true, index: tileIndex(at: location)))
    }

    /// Previews the tile the *keyboard* has selected, so arrowing/tabbing through the switcher floats
    /// the same thumbnails hovering does.
    func previewSelectedTile() {
        emitPreview(target(overPreview: false, index: model.selection))
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

    /// A scroll that landed on the floating preview instead of the switcher, forwarded here so it
    /// still moves the selection.
    func forwardScroll(_ event: NSEvent) { handleScroll(event) }

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
        return .underCursor
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
