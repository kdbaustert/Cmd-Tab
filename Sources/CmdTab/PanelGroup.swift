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
/// try to drive the same selection. The poll, the scroll accumulator and the preview-target dedupe
/// are single-instance concerns, so they belong to whatever owns the set — here.
@MainActor
final class PanelGroup {
    private let model: SwitcherModel
    private var panels: [SwitcherPanel] = []

    /// Invoked when a tile is clicked, with its index.
    var onPick: ((Int) -> Void)?
    /// Invoked with a step (+1/-1) when the scroll wheel moves over any panel.
    var onScroll: ((Int) -> Void)?
    /// Fires when what the cursor points at changes. Only while app-mode previews are on.
    var onPreviewHover: ((PreviewHoverTarget) -> Void)?
    /// Whether a screen point is over the floating preview — answered by the controller so the strip
    /// stays up, and clickable, while the cursor is on it.
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
    private var lastPreviewTarget: PreviewHoverTarget = .away

    /// Which displays to occupy. Applied on the next `show()`; changing it mid-session would mean
    /// tearing panels out from under a live selection.
    var screens: PanelScreens = .automatic

    // Settings mirrored onto every panel as they change.
    var appearanceMode: PanelAppearance = .system { didSet { panels.forEach { $0.appearanceMode = appearanceMode } } }
    var positionMode: PanelPosition = .center { didSet { panels.forEach { $0.positionMode = positionMode } } }
    var maxColumns = 0 { didSet { panels.forEach { $0.maxColumns = maxColumns } } }
    var fade = false { didSet { panels.forEach { $0.fade = fade } } }
    /// App-mode window previews: whether the hover thumbnails are enabled at all.
    var windowPreviewEnabled = false

    init(model: SwitcherModel) {
        self.model = model
    }

    // MARK: - Geometry

    /// The panel the cursor is over, falling back to the first — what the preview strip positions
    /// itself against and what supplies the appearance for it.
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

    /// The frame of the panel the cursor is on — what the preview strip should keep clear of.
    var anchorFrame: NSRect { anchor?.frame ?? frame }

    var effectiveAppearance: NSAppearance? { anchor?.effectiveAppearance }

    /// The highlighted tile's rect on whichever panel the cursor is over.
    var selectedTileScreenRect: NSRect? { anchor?.selectedTileScreenRect }

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
        panel.onGeometryChange = { [weak self] in self?.geometryDidChange() }
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
        pendingSelectedTile = false
        previewDrivenByKeyboard = false
        // Reset unconditionally (not via `emitPreview`, which is gated on the setting) so the next
        // session starts clean. The controller dismisses the preview strip itself on hide.
        lastPreviewTarget = .away
    }

    /// Polls the cursor, moves the highlight to the tile under it, and reports what the preview
    /// should track. Skips the work when the cursor hasn't moved, so a still cursor costs nothing.
    private func updateHoverFromCursor() {
        let location = NSEvent.mouseLocation
        guard location != lastHoverLocation else { return }
        lastHoverLocation = location
        // The cursor actually moved, so it takes the preview back from the keyboard.
        previewDrivenByKeyboard = false
        let overPreview = isOverPreview?(location) == true
        // The highlight follows the tile — but not while over the preview, so it stays put there.
        let index = overPreview ? nil : tileIndex(at: location)
        if let index, model.selection != index { model.selection = index }
        emitPreview(target(overPreview: overPreview, index: index))
    }

    /// The tile under a screen point on whichever panel contains it. Mirrored panels never overlap —
    /// they are one per display — so at most one can answer.
    private func tileIndex(at point: NSPoint) -> Int? {
        panels.lazy.compactMap { $0.tileIndex(at: point) }.first
    }

    /// The preview target for the given cursor state — the preview strip, a tile, or nothing.
    ///
    /// Returns nil when the tile's geometry hasn't been reported yet, which callers must treat as
    /// "ask again later" rather than substituting a placeholder. Standing in a zero rect here put the
    /// strip at the screen origin and then clamped it flat against the left edge.
    private func target(overPreview: Bool, index: Int?) -> PreviewHoverTarget? {
        if overPreview { return .overPreview }
        guard let index, model.targets.indices.contains(index) else { return .away }
        guard let rect = tileScreenRect(for: index) else { return nil }
        return .tile(pid: model.targets[index].pid, rect: rect)
    }

    /// The screen rect of tile `index`, preferring the panel the cursor is on.
    ///
    /// The preference matters under mirroring: taking the first panel that happens to have geometry
    /// returns display 0's copy of the tile, so a preview for a tile hovered on the second monitor
    /// gets positioned against coordinates on the first. `selectedTileScreenRect` already resolved
    /// through `anchor`, so the two disagreed about where the same tile was.
    private func tileScreenRect(for index: Int) -> NSRect? {
        if let rect = anchor?.tileScreenRect(for: index) { return rect }
        return panels.lazy.compactMap { $0.tileScreenRect(for: index) }.first
    }

    /// Emits a target change (only in app mode with previews on), deduped so an unchanged target
    /// doesn't re-fire on every tick. A nil target means the geometry isn't in yet — nothing is
    /// emitted, and `pendingSelectedTile` replays the request once it lands.
    private func emitPreview(_ target: PreviewHoverTarget?) {
        guard windowPreviewEnabled, model.mode == .apps else { return }
        guard let target, target != lastPreviewTarget else { return }
        lastPreviewTarget = target
        onPreviewHover?(target)
    }

    /// Set when a keyboard-driven preview was requested before the tiles had reported their geometry
    /// — which is the normal case, since `advance()` relayouts and asks in the same turn.
    private var pendingSelectedTile = false
    /// Whether the preview currently on screen was chosen by the keyboard rather than the cursor.
    /// A geometry replay must not hand a keyboard-driven preview back to the resting pointer.
    private var previewDrivenByKeyboard = false

    /// Re-resolves the preview now that fresh frames have landed.
    ///
    /// Both paths need this, not just the deferred keyboard one. Callers relayout and ask about the
    /// cursor in the same turn, but the frames arrive a turn or two later — so a filter keystroke
    /// that reflows the grid leaves the hover answer computed from the *previous* list's rects
    /// against the already-moved panel, pointing the strip at the wrong app until the mouse happens
    /// to move again.
    private func geometryDidChange() {
        guard windowPreviewEnabled, model.mode == .apps else { return }
        if pendingSelectedTile {
            guard let target = target(overPreview: false, index: model.selection) else { return }
            pendingSelectedTile = false
            emitPreview(target)
        } else if !previewDrivenByKeyboard {
            // Only re-resolve the cursor when the cursor is what put the current preview there.
            // Every panel installs this callback, so under mirroring one layout pass delivers it
            // several times: the first delivery satisfies the keyboard request, and the rest would
            // fall through to here and retarget the strip at whatever tile the resting pointer
            // happens to sit over — showing the wrong app's windows on every arrow press.
            refreshHoverPreview()
        }
    }

    /// Re-evaluates the preview against whatever tile is under the cursor now. Called after the
    /// target list changes beneath a stationary cursor — a tile was quit/closed/hidden, or a
    /// background refresh folded in a new list — so the strip follows the app actually there.
    func refreshHoverPreview() {
        let location = NSEvent.mouseLocation
        emitPreview(
            target(overPreview: isOverPreview?(location) == true, index: tileIndex(at: location)))
    }

    /// Previews the tile the *keyboard* has selected, so arrowing through the switcher floats the
    /// same thumbnails hovering does.
    func previewSelectedTile() {
        previewDrivenByKeyboard = true
        guard let target = target(overPreview: false, index: model.selection) else {
            // Geometry not reported yet — `geometryDidChange` picks this back up.
            pendingSelectedTile = true
            return
        }
        emitPreview(target)
    }

    /// A scroll that landed on the floating preview instead of the switcher, forwarded here so it
    /// still moves the selection.
    func forwardScroll(_ event: NSEvent) { handleScroll(event) }

    /// Turns accumulated scroll travel into discrete selection steps. The threshold keeps a single
    /// flick of an inertial trackpad from racing through the whole list. One accumulator for the
    /// whole group, so a gesture that drifts across a display boundary stays one gesture.
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
}
