import AppKit
import SwiftUI

extension NSScreen {
    /// The screen under the cursor, falling back to the main screen then the first attached one.
    ///
    /// Optional because `NSScreen.screens` really can be empty — a sleeping display, a closed lid
    /// with nothing external attached, the moment a display is being reconfigured. Subscripting it
    /// for a fallback traps, and this sits on the panel's show path, so that trap would take the
    /// whole app down mid-⌘-Tab.
    static var underCursor: NSScreen? {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens.first
    }
}

/// The overlay window. It is deliberately non-activating: the panel must appear without our
/// app ever becoming frontmost, or the switch target would be us instead of whatever the user
/// picked. All keyboard input arrives through the event tap, never through this window.
@MainActor
final class SwitcherPanel: NSPanel {
    private let model: SwitcherModel
    private var host: NSHostingView<SwitcherView>?

    /// Each tile's frame in this panel's content coordinates (top-left origin), reported by its own
    /// view. Owned per panel: mirroring puts one panel on every display, each with its own layout.
    ///
    /// `layout()` clears it. An empty map means "geometry not reported yet", which hit-testing must
    /// read as "no tile" — matching frames left over from a previous list would select whichever app
    /// has since taken that slot.
    private var tileFrames: [Int: CGRect] = [:]

    /// The display this panel is pinned to, or nil to follow the position setting. Set by
    /// `PanelGroup` when it spreads panels across displays.
    var pinnedScreen: NSScreen?

    /// Fired once the tiles have reported their frames for the current layout. `layout()` clears the
    /// geometry and SwiftUI reports the new frames a turn or two later, so anything that needs a
    /// tile's position has to wait for this rather than reading straight after `layout()`.
    var onGeometryChange: (() -> Void)?

    /// Bumped on every show/hide so a pending fade-out completion can tell it has been superseded.
    private var hideToken = 0

    /// Forced appearance and placement, driven from settings.
    var appearanceMode: PanelAppearance = .system
    var positionMode: PanelPosition = .center
    /// 0 = automatic (wrap at the screen-fraction limit); otherwise a hard cap on columns.
    var maxColumns = 0
    /// Fade the panel in and out instead of appearing instantly.
    var fade = false

    /// Invoked when a tile is clicked, with its index. Set by `PanelGroup` to commit the pick.
    var onPick: ((Int) -> Void)?
    /// A scroll that landed on this panel, forwarded up to the group, which owns the accumulator so
    /// a flick spanning two displays still reads as one gesture.
    var onScrollEvent: ((NSEvent) -> Void)?

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
        switch event.type {
        case .leftMouseDown:
            if let index = tileIndex(at: NSEvent.mouseLocation) {
                onPick?(index)
                return
            }
        case .scrollWheel:
            // Up to the group, which owns the accumulator.
            onScrollEvent?(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    func show() {
        // Invalidate any in-flight fade-out completion so a quick re-show is not ordered back out.
        hideToken &+= 1
        let token = hideToken
        layout()
        // Whatever the last hide left running has to go before the opacity is reset, or it carries
        // on driving `alphaValue` back down underneath the fade-in below.
        settleAlphaAnimation()
        alphaValue = fade ? 0 : 1
        orderFrontRegardless()
        guard fade else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            animator().alphaValue = 1
        }
        // The fade is decoration; being on screen is not, and this is the one place the two were
        // tied together. A fade-out ends at `alphaValue == 0` and that is the window's resting
        // state between sessions, so anything that keeps the fade-in above from running to
        // completion — AppKit suspends animations for an occluded app, and a display that sleeps
        // mid-animation can strand one indefinitely — ordered the panel in fully transparent.
        // Every symptom of that is a panel that "doesn't appear": the state machine is healthy,
        // the session opens and commits, the show path logs normally, and nothing recovers it
        // short of relaunching. Settle the opacity by hand rather than trusting the animation.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeGrace) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.hideToken == token, self.alphaValue < 1 else { return }
                Log.general.error(
                    "panel fade-in stalled at alpha \(self.alphaValue, privacy: .public); forcing it visible")
                self.settleAlphaAnimation()
                self.alphaValue = 1
            }
        }
    }

    func hide() {
        // A fade-out has to keep the window up until the animation finishes, so order out in the
        // completion; the instant path just drops it. The token guards against a re-show landing
        // mid-fade — without it the stale completion would order the fresh panel back out.
        guard fade, alphaValue > 0 else {
            orderOut(nil)
            return
        }
        hideToken &+= 1
        let token = hideToken
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.10
            animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.finishHide(token) }
        }
        // The mirror of the settle in `show()`, and for the same reason: a completion handler that
        // never arrives must not be the only thing that takes the panel down.
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.fadeGrace) { [weak self] in
            MainActor.assumeIsolated { self?.finishHide(token) }
        }
    }

    /// How long to let a fade run before taking the outcome into our own hands. Comfortably past
    /// both durations, so it only ever fires for an animation that is not going to arrive.
    private static let fadeGrace: TimeInterval = 0.3

    /// Orders the panel out for the fade that `token` belongs to. Safe to call twice — the second
    /// call is the deadline catching up with a completion that already ran.
    private func finishHide(_ token: Int) {
        guard hideToken == token, isVisible else { return }
        orderOut(nil)
    }

    /// Drops any running opacity animation, leaving `alphaValue` wherever it had reached. Assigning
    /// the property directly does not do this: the animation keeps its own schedule and goes on
    /// writing over the assignment until it finishes.
    private func settleAlphaAnimation() {
        NSAnimationContext.beginGrouping()
        NSAnimationContext.current.duration = 0
        animator().alphaValue = alphaValue
        NSAnimationContext.endGrouping()
    }

    /// The highlighted tile's screen rect, for positioning a keyboard-driven preview against it.
    var selectedTileScreenRect: NSRect? { tileScreenRect(for: model.selection) }

    /// The screen rect of tile `index`, in bottom-up screen coordinates — the reported content-space
    /// frame flipped back out to the screen.
    func tileScreenRect(for index: Int) -> NSRect? {
        guard let rect = tileFrames[index] else { return nil }
        return NSRect(
            x: frame.minX + rect.minX, y: frame.maxY - rect.maxY,
            width: rect.width, height: rect.height)
    }

    /// Maps a screen point to the tile under it, or nil if the cursor is off the grid (gaps, the
    /// caption strip, or outside the panel).
    ///
    /// Reads the frames the tiles reported rather than re-deriving them. The gaps between tiles fall
    /// out for free — they belong to no reported frame — where the old arithmetic had to subtract
    /// them back out by hand.
    func tileIndex(at screenPoint: NSPoint) -> Int? {
        // Content coordinates are top-left origin; flip the bottom-up screen point into them.
        let point = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        guard let index = tileFrames.first(where: { $0.value.contains(point) })?.key,
            index < model.targets.count
        else { return nil }
        return index
    }

    /// Rebuilds the content at the size the current target list needs, then recenters.
    func layout() {
        // No screen to lay out against — every display asleep, or one being reconfigured. Keeping
        // the previous geometry is the only sane answer; the next show recomputes it.
        guard let screen = targetScreen() else {
            Log.general.error("panel layout: no screen available; keeping the current geometry")
            return
        }
        let columns = Self.columns(for: model, on: screen, cap: maxColumns)
        // Deliberately does NOT clear `tileFrames`. `onPreferenceChange` only fires when the reported
        // value actually changes, so wiping the cache here does not provoke a fresh report — it just
        // empties it until the tiles happen to move. Relayouts that keep the same geometry (stepping
        // the selection being the common one) never move them, so the cache stayed empty and every
        // reader broke: no hover highlight, no click hit-testing, and previews positioned against a
        // missing rect. Letting the callback own the cache is what keeps it in step, and because it
        // assigns the whole map rather than merging, a shorter list drops the extra entries anyway.
        let view = SwitcherView(model: model, columns: columns) { [weak self] frames in
            guard let self else { return }
            self.tileFrames = frames
            // The cache is assigned inline — readers want the new frames immediately — but the
            // notification is not. Everything downstream of it lays out views of its own (the
            // preview strip has its own hosting view) and reads panel geometry, and doing that
            // from inside the SwiftUI update that is still reporting this preference is what
            // makes SwiftUI log "Bound preference TileFrameKey tried to update multiple times
            // per frame" and then *drop* the update. A dropped report is the failure this cache
            // was written to avoid: stale frames mean no hover highlight, clicks hit-tested
            // against the previous list, and previews placed off a rect that has since moved.
            DispatchQueue.main.async { [weak self] in self?.onGeometryChange?() }
        }

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
        var size = host.fittingSize

        // A zero fitting size is not a small panel, it is an invisible one: `setContentSize` would
        // make a 0×0 window, centred on the right screen, ordered in, and showing nothing — which
        // reads to the user as the panel never opening, while every log line on the show path looks
        // normal. Measure once more from a fresh hosting view (the reused one is the thing that can
        // be wedged), and if that is empty too, keep the last size we knew was good.
        if size.width < 1 || size.height < 1 {
            Log.general.error("panel measured empty; rebuilding the hosting view")
            let rebuilt = NSHostingView(rootView: view)
            self.host = rebuilt
            contentView = rebuilt
            rebuilt.layoutSubtreeIfNeeded()
            size = rebuilt.fittingSize
        }
        guard size.width >= 1, size.height >= 1 else {
            Log.general.error("panel still measured empty; keeping the previous content size")
            setFrameOrigin(origin(for: frame.size, on: screen))
            return
        }

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

    private func targetScreen() -> NSScreen? {
        // A pinned screen wins outright — the panel exists *because* that display was chosen.
        if let pinnedScreen { return pinnedScreen }
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
        // A list wraps on *height*: rows stack downward, so what runs out first is vertical room,
        // and a second column is what a long list needs rather than a narrower row.
        if model.layout == .list {
            let row = metrics.listRow(for: model.mode)
            let available = screen.visibleFrame.height * Metrics.maxScreenFraction
                - Metrics.panelPadding * 2
            let perColumn = max(Int(available / (row.height + Metrics.rowGap)), 1)
            var needed = Int((Double(count) / Double(perColumn)).rounded(.up))
            if cap > 0 { needed = min(needed, cap) }
            return max(needed, 1)
        }
        let tileWidth = metrics.tile(for: model.mode, showsTitle: model.showsTitle).width
            + Metrics.tileGap
        let available = screen.visibleFrame.width * Metrics.maxScreenFraction
            - Metrics.panelPadding * 2
        var fits = max(Int(available / tileWidth), 1)
        if cap > 0 { fits = min(fits, cap) }
        return min(count, fits)
    }
}
