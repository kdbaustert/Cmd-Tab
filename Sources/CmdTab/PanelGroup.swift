import AppKit
import SwiftUI

/// Which displays the switcher appears on. Orthogonal to `PanelPosition`, which decides where on a
/// display it sits.
enum PanelScreens: String, CaseIterable {
    /// One panel, on whichever display the position setting selects.
    case automatic
    /// One panel, always on the main display, wherever the cursor happens to be.
    case mainDisplay
    /// A panel on every display, all showing the same list.
    case allDisplays

    var title: String {
        switch self {
        case .automatic: return "Follow position"
        case .mainDisplay: return "Main display"
        case .allDisplays: return "All displays"
        }
    }
}

/// The switcher's on-screen presence: one panel, or one per display when mirroring.
///
/// Exists because cursor tracking cannot live on the panels themselves once there is more than one.
/// Each panel used to run its own ~60 Hz poll; mirrored, they would all poll the same cursor and all
/// try to drive the same selection. The poll and the scroll accumulator are single-instance concerns,
/// so they belong to whatever owns the set — here.
@MainActor
final class PanelGroup {
    private let model: SwitcherModel
    private var panels: [SwitcherPanel] = []

    /// Invoked when a tile is clicked, with its index.
    var onPick: ((Int) -> Void)?
    /// Invoked with a step (+1/-1) when the scroll wheel moves over any panel.
    var onScroll: ((Int) -> Void)?
    /// Fires when what the cursor points at changes. Only while window previews are on.
    var onPreviewHover: ((PreviewTarget) -> Void)?
    /// Whether a screen point is over the floating preview — answered by the controller, so the
    /// strip stays up (and clickable) while the cursor is on it.
    var isOverPreview: ((NSPoint) -> Bool)?

    // The panel never becomes key, so SwiftUI's own hover tracking stays dormant and the highlight is
    // driven from the raw cursor position. A timer poll rather than a global mouse-moved monitor
    // because a global monitor only sees events bound for *other* apps — the moment Cmd-Tab itself is
    // frontmost (right after ⌘Q/⌘H, or once Settings has been open) the monitor goes silent and the
    // highlight stops following the cursor. Polling is immune to that.
    private var hoverTimer: Timer?
    private var lastHoverLocation: NSPoint?
    private var scrollMonitor: Any?
    private var scrollAccumulator: CGFloat = 0
    /// The last target emitted, so nothing re-fires while the cursor sits on the same tile.
    private var lastPreviewTarget: PreviewTarget = .away
    /// Whether the cursor has moved at all this session.
    ///
    /// The same rule the seeded `lastHoverLocation` applies to the highlight, for the same reason:
    /// a pointer left parked wherever the last click happened is not hovering anything. Without it,
    /// every ⌘-Tab taken with the mouse resting over the middle of the screen floats a strip nobody
    /// asked for — and pays for a screen capture to do it.
    private var cursorMoved = false

    /// Which displays to occupy. Applied on the next `show()`; changing it mid-session would mean
    /// tearing panels out from under a live selection.
    var screens: PanelScreens = .automatic

    // Settings mirrored onto every panel as they change.
    var appearanceMode: PanelAppearance = .system { didSet { panels.forEach { $0.appearanceMode = appearanceMode } } }
    var positionMode: PanelPosition = .center { didSet { panels.forEach { $0.positionMode = positionMode } } }
    var maxColumns = 0 { didSet { panels.forEach { $0.maxColumns = maxColumns } } }
    var fade = false { didSet { panels.forEach { $0.fade = fade } } }
    /// Whether hovering a tile floats that app's window thumbnails.
    var windowPreviewEnabled = false

    init(model: SwitcherModel) {
        self.model = model
    }

    // MARK: - Geometry

    /// The panel the cursor is over, falling back to the first.
    var anchor: SwitcherPanel? {
        let mouse = NSEvent.mouseLocation
        return panels.first { $0.frame.contains(mouse) } ?? panels.first
    }

    /// Union of every panel's frame. Only meaningful for logging — anything positioning itself
    /// against the switcher wants `anchorFrame`, since the union spans displays and describes a
    /// region no single screen contains.
    var frame: NSRect {
        panels.dropFirst().reduce(panels.first?.frame ?? .zero) { $0.union($1.frame) }
    }

    /// The frame of the panel the cursor is on.
    var anchorFrame: NSRect { anchor?.frame ?? frame }

    var effectiveAppearance: NSAppearance? { anchor?.effectiveAppearance }

    /// The highlighted tile's rect on whichever panel the cursor is over.
    var selectedTileScreenRect: NSRect? { anchor?.selectedTileScreenRect }

    /// Everything the preview strip needs to place itself against a tile, resolved from the tile's
    /// own rect rather than from the cursor.
    ///
    /// Cursor-derived placement breaks in exactly the case mirroring makes common: a capture takes a
    /// few hundred milliseconds, and if the pointer has crossed to another display by the time it
    /// lands, `anchor` names a panel on a display the tile is not on — so the strip is positioned
    /// against one screen's coordinates while centred on another's tile.
    struct PreviewPlacement {
        /// The frame of the panel the tile belongs to. The strip clears this, not the union of every
        /// panel — that union spans displays and describes a region no single screen contains.
        let panelFrame: NSRect
        /// The visible frame of the display the tile is on, which bounds the strip.
        let visibleFrame: NSRect
        /// That panel's appearance, so the strip matches the switcher it grew out of.
        let appearance: NSAppearance?
    }

    func placement(forTileAt rect: NSRect) -> PreviewPlacement {
        let centre = NSPoint(x: rect.midX, y: rect.midY)
        // The panel that actually contains the tile. Mirrored panels are one per display and never
        // overlap, so at most one can answer; the fallbacks cover a tile rect that has gone stale
        // against a panel that has since moved.
        let panel = panels.first { $0.frame.contains(centre) } ?? anchor ?? panels.first
        let screen =
            NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) } ?? .underCursor
        return PreviewPlacement(
            panelFrame: panel?.frame ?? frame,
            visibleFrame: screen.visibleFrame,
            appearance: panel?.effectiveAppearance)
    }

    /// The screen rect of tile `index`, preferring the panel the cursor is on.
    ///
    /// The preference matters under mirroring: taking the first panel that happens to have reported
    /// geometry returns display 0's copy of the tile, so a preview for a tile hovered on the second
    /// monitor would be positioned against coordinates on the first.
    private func tileScreenRect(for index: Int) -> NSRect? {
        if let rect = anchor?.tileScreenRect(for: index) { return rect }
        return panels.lazy.compactMap { $0.tileScreenRect(for: index) }.first
    }

    // MARK: - Lifecycle

    func show() {
        rebuildPanels()
        panels.forEach { $0.show() }
        startHoverTracking()
    }

    func hide() {
        stopHoverTracking()
        panels.forEach { $0.hide() }
    }

    func layout() {
        panels.forEach { $0.layout() }
    }

    /// Creates or drops panels so there is exactly one per targeted display.
    ///
    /// Rebuilt per session rather than kept in sync with display changes: a monitor plugged in while
    /// the switcher is open is vanishingly rare next to the cost of watching for it, and the next
    /// session picks the new layout up anyway.
    private func rebuildPanels() {
        let targets: [NSScreen?]
        switch screens {
        case .automatic: targets = [nil]  // nil = let the panel follow the position setting
        case .mainDisplay: targets = [NSScreen.main ?? NSScreen.screens.first]
        case .allDisplays: targets = NSScreen.screens.map { $0 }
        }

        while panels.count > targets.count {
            panels.removeLast().orderOut(nil)
        }
        while panels.count < targets.count {
            panels.append(makePanel())
        }
        for (panel, screen) in zip(panels, targets) {
            panel.pinnedScreen = screen
        }
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(model: model)
        panel.appearanceMode = appearanceMode
        panel.positionMode = positionMode
        panel.maxColumns = maxColumns
        panel.fade = fade
        panel.onPick = { [weak self] index in self?.onPick?(index) }
        panel.onScrollEvent = { [weak self] event in self?.handleScroll(event) }
        panel.onGeometryChange = { [weak self] in self?.refreshPreview() }
        return panel
    }

    // MARK: - Hover & scroll

    private func startHoverTracking() {
        guard hoverTimer == nil else { return }
        // Seed with where the cursor already is, not nil. This poll cannot tell "moved here" from
        // "was already here", so a nil seed made the first tick treat a resting cursor as a fresh
        // hover and hand the selection to whatever tile happened to be under it — turning a plain
        // ⌘-Tab into a switch to the wrong app.
        lastHoverLocation = NSEvent.mouseLocation
        // ~60 Hz. Added in .common mode so it keeps firing during tracking run-loop modes.
        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.updateHoverFromCursor() }
        }
        // Nothing here depends on the tick landing on time — it samples a position rather than
        // driving an animation. The tolerance lets the run loop batch these wakeups instead of
        // forcing 60 of its own per second onto the loop that also services the event tap, where an
        // overrun costs the user every keystroke on the machine.
        timer.tolerance = 1.0 / 240.0
        RunLoop.main.add(timer, forMode: .common)
        hoverTimer = timer
        // Scroll stays a global monitor — deltas can't be polled. It shares the frontmost-app
        // limitation above, but scroll-to-move is secondary to the cursor highlight.
        scrollMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handleScroll(event) }
        }
    }

    private func stopHoverTracking() {
        hoverTimer?.invalidate()
        hoverTimer = nil
        if let scrollMonitor { NSEvent.removeMonitor(scrollMonitor) }
        scrollMonitor = nil
        scrollAccumulator = 0
        lastHoverLocation = nil
        // Reset unconditionally rather than through `emitPreview`, which is gated on the setting, so
        // the next session starts clean. The controller takes the strip down itself on hide.
        lastPreviewTarget = .away
        cursorMoved = false
    }

    /// Polls the cursor, moves the highlight to the tile under it, and reports what the preview
    /// should track. Skips the work when the cursor hasn't moved, so a still cursor costs nothing.
    private func updateHoverFromCursor() {
        let location = NSEvent.mouseLocation
        guard location != lastHoverLocation else { return }
        lastHoverLocation = location
        cursorMoved = true
        let overPreview = isOverPreview?(location) == true
        // The highlight follows the tile under the cursor — but not while the cursor is over the
        // strip, so the tile the strip belongs to stays highlighted while its windows are picked.
        let index = overPreview ? nil : tileIndex(at: location)
        if let index, model.selection != index { model.selection = index }
        emitPreview(previewTarget(at: location, overPreview: overPreview, index: index))
    }

    /// Re-resolves the preview against whatever is under the cursor now.
    ///
    /// Called when fresh tile frames land. Callers relayout and would like to ask about the cursor
    /// in the same turn, but SwiftUI reports the new frames a turn or two later — so a filter
    /// keystroke that reflows the grid would otherwise leave the answer computed from the *previous*
    /// list's rects, pointing the strip at the wrong app until the mouse happened to move again.
    func refreshPreview() {
        // A relayout is not a hover. Until the pointer has moved there is nothing to re-resolve.
        guard cursorMoved else { return }
        let location = NSEvent.mouseLocation
        let overPreview = isOverPreview?(location) == true
        let index = overPreview ? nil : tileIndex(at: location)
        emitPreview(previewTarget(at: location, overPreview: overPreview, index: index))
    }

    /// What the preview should be tracking, given where the cursor is.
    ///
    /// Returns nil when the tile's geometry has not been reported yet, which callers must treat as
    /// "ask again later" rather than substituting a placeholder — standing in a zero rect puts the
    /// strip at the screen origin and then clamps it flat against the left edge.
    private func previewTarget(at location: NSPoint, overPreview: Bool, index: Int?)
        -> PreviewTarget?
    {
        if overPreview { return .overPreview(location) }
        guard let index, model.targets.indices.contains(index) else { return .away }
        // A favourite that isn't running has no process, let alone windows.
        guard !model.targets[index].isLaunchable else { return .away }
        guard let rect = tileScreenRect(for: index) else { return nil }
        return .tile(pid: model.targets[index].pid, rect: rect)
    }

    /// Emits a target change, deduped so an unchanged target doesn't re-fire on every tick. A nil
    /// target means the geometry isn't in yet — nothing is emitted, and the next `refreshPreview`
    /// picks it up.
    private func emitPreview(_ target: PreviewTarget?) {
        // Window mode is already a list of windows; previewing them would show the same thing twice.
        guard windowPreviewEnabled, model.mode == .apps else { return }
        guard let target, target != lastPreviewTarget else { return }
        lastPreviewTarget = target
        onPreviewHover?(target)
    }

    /// The tile under a screen point on whichever panel contains it. Mirrored panels never overlap —
    /// they are one per display — so at most one can answer.
    private func tileIndex(at point: NSPoint) -> Int? {
        panels.lazy.compactMap { $0.tileIndex(at: point) }.first
    }

    private func handleScroll(_ event: NSEvent) {
        // A scroll on a real wheel (or a fast swipe) carries useful deltas; the trackpad posts many
        // tiny ones. Accumulate until a full "step" has landed.
        scrollAccumulator += event.scrollingDeltaY
        let step = Int(scrollAccumulator / 20)
        guard step != 0 else { return }
        scrollAccumulator -= CGFloat(step) * 20
        onScroll?(-step)
    }

    /// A scroll that landed on the floating preview instead of the switcher, forwarded here so it
    /// still drives the selection (the global monitor can't see events delivered to our panel).
    func forwardScroll(_ event: NSEvent) {
        handleScroll(event)
    }
}
