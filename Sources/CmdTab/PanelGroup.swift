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
    /// Invoked when a tile's close button is clicked, with its index.
    var onClose: ((Int) -> Void)?
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
    /// Live only while the panels are up — see `startScreenTracking`.
    private var screenObserver: NSObjectProtocol?
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

    /// The value `screens` had when this session opened.
    ///
    /// The "next `show()`" promise above used to hold by construction, because `rebuildPanels()` was
    /// only ever reached from `show()`. A stay-open session that re-targets itself on a display
    /// change reaches it again mid-session, and re-reading the live setting there would apply a
    /// change the user made in Settings while the switcher was up — dropping two of three panels out
    /// from under a live selection on nothing more than the Dock sliding in. Captured once, so a
    /// re-target reproduces the session it started as.
    private var sessionScreens: PanelScreens = .automatic

    /// The displays this session's panels are *aimed* at. One entry per panel: a display id for a
    /// pinned one, nil for a panel that follows the position setting.
    ///
    /// Stamped by `rebuildPanels` from the screens it actually used, so it records what the panels
    /// are rather than what they were meant to be.
    private var sessionDisplayIDs: [CGDirectDisplayID?] = []

    /// The desk itself, as it was when the panels were last built against it.
    ///
    /// Two stamps rather than one because the aim and the desk can move independently, and a
    /// screen-parameter notification has to be judged against both — see `shouldRetarget`, which is
    /// where that rule lives and why.
    private var sessionDeskIDs: [CGDirectDisplayID?] = []

    /// Fired when the desk really did change under an open session, so the controller can rebuild the
    /// target list. The display badges are baked into each `SwitchTarget` when it is built and are
    /// numbered against `NSScreen.screens` as it was then, so nothing else refreshes them.
    var onDisplaysChanged: (() -> Void)?

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

    /// How many indices the up/down arrows move by — see `SwitcherPanel.rowStride`.
    ///
    /// The anchor's, for the reason `tileScreenRect(for:)` prefers it: mirrored panels are laid out
    /// against their own displays and can wrap at different column counts, so a row means a
    /// different number of tiles on each. The cursor is the only clue available as to which one the
    /// user is actually reading, and it is the clue the highlight and the hit-testing already
    /// follow — the arrows agreeing with them matters more than any of the three being provably
    /// right about a question the keyboard cannot answer.
    ///
    /// Costs one `NSEvent.mouseLocation` on the key path, which is the read the hover poll already
    /// takes sixty times a second on the very same run loop.
    var rowStride: Int { anchor?.rowStride ?? 1 }

    /// One clause per panel: where it is, and whether the window server has it on screen. Logged on
    /// every show rather than kept for a debug build, because "the switcher did not appear" is
    /// reported against a release copy and the show path is otherwise silent about the ways it can
    /// fail — a degenerate frame and a window that never made it on screen look identical from the
    /// outside, and identical to a panel that drew correctly.
    ///
    /// Deliberately no opacity. A fade begins at zero, so read at show time it is the animation's
    /// starting value on every healthy session and says nothing about whether the panel became
    /// visible. `SwitcherPanel.show()` reports the opacity at the point it actually means
    /// something: after the fade has had its grace period and either landed or stalled.
    var diagnostics: String {
        guard !panels.isEmpty else { return "no panels" }
        return panels.map { panel in
            "\(NSStringFromRect(panel.frame)) onscreen=\(panel.isVisible)"
        }.joined(separator: " | ")
    }

    var effectiveAppearance: NSAppearance? { anchor?.effectiveAppearance }

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
            NSScreen.screens.first { NSMouseInRect(centre, $0.frame, false) } ?? NSScreen.underCursor
        return PreviewPlacement(
            panelFrame: panel?.frame ?? frame,
            // No screen at all (every display asleep) leaves the strip nothing to bound itself
            // against; the tile's own rect is the closest thing to a sane fallback.
            visibleFrame: screen?.visibleFrame ?? rect,
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
        // Snapshot before the first build: everything a re-target does this session is measured
        // against the session as it opened, not against Settings as they stand later.
        sessionScreens = screens
        rebuildPanels()
        panels.forEach { $0.show() }
        startHoverTracking()
        startScreenTracking()
    }

    /// Builds the panels and lays them out once, without putting anything on screen.
    ///
    /// The first `show()` of a process is measurably more expensive than every one after it, and it
    /// is the one that can least afford to be: `makePanel` constructs the `NSPanel` and `layout()`
    /// constructs its `NSHostingView`, so the first ⌘-Tab pays for SwiftUI's first render — hosting
    /// view, `VisualEffectBackground`, fonts, the whole graph — inline on the main thread. Two
    /// consecutive launches measured it identically: `main loop busy 178ms` and `175ms`, both on the
    /// very first `panel shown` and neither repeated once in the sessions that followed. That is the
    /// tap starved for a sixth of a second, which is the one failure this app cannot afford (see
    /// `MainLoopMonitor`), and it is entirely a warm-up cost.
    ///
    /// So it is paid at launch, on an idle main loop, where a stall costs nothing and the monitor's
    /// own documentation already expects one. The panels built here are the ones the first session
    /// reuses — `rebuildPanels` finds them in place and `layout()` reassigns the existing hosting
    /// view's root — so this warms the objects that actually run rather than a stand-in for them.
    ///
    /// Never ordered in: `layout()` sizes and positions a window that has not been shown, which the
    /// user cannot see and the next `show()` recomputes anyway.
    func prewarm() {
        guard panels.isEmpty else { return }
        sessionScreens = screens
        MainLoopMonitor.marking("panel prewarm") {
            rebuildPanels()
            panels.forEach { $0.layout() }
        }
    }

    func hide() {
        stopScreenTracking()
        stopHoverTracking()
        panels.forEach { $0.hide() }
    }

    func layout() {
        panels.forEach { $0.layout() }
    }

    /// Creates or drops panels so there is exactly one per targeted display, and returns whichever
    /// ones were created — a caller re-targeting a live session has to put those on screen itself.
    ///
    /// The pin is stored as a display id rather than an `NSScreen`; see `SwitcherPanel`.
    @discardableResult
    private func rebuildPanels() -> [SwitcherPanel] {
        let targets: [NSScreen?]
        switch sessionScreens {
        case .automatic: targets = [nil]  // nil = let the panel follow the position setting
        // The display with the menu bar, not `NSScreen.main` — which is the screen holding the key
        // window and so follows the frontmost app around, making this option a duplicate of the
        // active-screen position rather than the fixed display it is captioned as.
        case .mainDisplay: targets = [NSScreen.primary]
        case .allDisplays: targets = NSScreen.screens.map { $0 }
        }

        while panels.count > targets.count {
            panels.removeLast().orderOut(nil)
        }
        var added: [SwitcherPanel] = []
        while panels.count < targets.count {
            let panel = makePanel()
            panels.append(panel)
            added.append(panel)
        }
        for (panel, screen) in zip(panels, targets) {
            let id = screen?.displayID
            panel.pinnedDisplayID = id
            // A pin we could not resolve to an id is not a pin — see `SwitcherPanel.isPinned`.
            // Better to fall through to the position setting than to hold a panel against a display
            // it can never match, which would leave it never laid out at all.
            panel.isPinned = screen != nil && id != nil
        }
        sessionDisplayIDs = targets.map { $0?.displayID }
        sessionDeskIDs = NSScreen.screens.map(\.displayID)
        return added
    }

    // MARK: - Display changes

    /// Watches for the desk changing under an open session.
    ///
    /// Registered only while the panels are up. A session that lasts as long as a chord is held can
    /// reasonably ignore a monitor being plugged in, which is what this used to do for every
    /// session — but a stay-open one lasts until it is dismissed, and over that span a display being
    /// unplugged leaves a pinned panel with nowhere to be while `.allDisplays` is left a panel short
    /// of the desk it is meant to cover. Off between sessions, where this would only ever fire for
    /// Dock and menu-bar changes there is nothing to do about.
    private func startScreenTracking() {
        guard screenObserver == nil else { return }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.displaysChanged() }
        }
    }

    private func stopScreenTracking() {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
    }

    /// Whether a screen-parameter notification is one the panels have to answer.
    ///
    /// `didChangeScreenParametersNotification` is not a plug/unplug notification: AppKit posts it for
    /// the Dock showing and hiding, the menu bar auto-hiding, and a resolution or arrangement change.
    /// Acting on all of them moves an unpinned panel onto whatever display the cursor is on at the
    /// time — so an open switcher jumped displays mid-session because the Dock happened to slide in,
    /// taking its selection with it. This is the filter that keeps those out.
    ///
    /// Two readings, because a notification can move either one without the other, and each of them
    /// alone misses a real change:
    ///
    /// * **The desk.** A display plugged in or unplugged while the setting is `.automatic` leaves the
    ///   aim at `[nil]`, so an aim-only check can never fire there — and `.automatic` is the default.
    ///   That left the one panel at coordinates nothing covered and, worse, skipped
    ///   `onDisplaysChanged`, which is the only thing that renumbers the display badges baked into
    ///   every target. Order counts as much as membership: the badges are numbered by position in
    ///   `NSScreen.screens`, so rearranging two monitors stales them exactly as unplugging one does.
    /// * **The aim.** Dragging the menu bar to the other monitor in Displays settings moves what
    ///   `.mainDisplay` points at while the desk keeps precisely the same displays, so a desk-only
    ///   check would leave that panel pinned to the display that is no longer primary.
    ///
    /// Pure over the readings, and `nonisolated`, so the three settings can be exercised against a
    /// desk this machine does not have — which is the whole difficulty with this predicate: the case
    /// that matters most is a second display arriving, and no test can arrange one.
    nonisolated static func shouldRetarget(
        _ screens: PanelScreens, desk: [CGDirectDisplayID?], primary: CGDirectDisplayID?,
        lastDesk: [CGDirectDisplayID?], lastAim: [CGDirectDisplayID?]
    ) -> Bool {
        let aim: [CGDirectDisplayID?]
        switch screens {
        case .automatic: aim = [nil]  // one panel, following the position setting
        case .mainDisplay: aim = [primary]
        case .allDisplays: aim = desk
        }
        return desk != lastDesk || aim != lastAim
    }

    /// Re-targets the panels onto the displays that exist now.
    ///
    /// Only the panels this creates are shown; the ones already up are relaid out instead. Showing
    /// all of them would restart the fade from zero on panels the user is looking at, so a monitor
    /// being plugged in would blink the switcher.
    private func displaysChanged() {
        guard
            Self.shouldRetarget(
                sessionScreens, desk: NSScreen.screens.map(\.displayID),
                primary: NSScreen.primary?.displayID,
                lastDesk: sessionDeskIDs, lastAim: sessionDisplayIDs)
        else { return }

        let added = rebuildPanels()
        added.forEach { $0.show() }
        panels.forEach { $0.layout() }
        // Paired with the layout, as everywhere else that relayouts: the strip is positioned from a
        // panel rect captured at hover time, and moving the panel does not re-emit it — so without
        // this it is left floating at coordinates the old desk had, detached from any tile.
        refreshPreview()
        // The badges are numbered against `NSScreen.screens` as it was when the targets were built,
        // and `TargetProvider` does not watch for screen changes.
        onDisplaysChanged?()
    }

    private func makePanel() -> SwitcherPanel {
        let panel = SwitcherPanel(model: model)
        panel.appearanceMode = appearanceMode
        panel.positionMode = positionMode
        panel.maxColumns = maxColumns
        panel.fade = fade
        panel.onPick = { [weak self] index in self?.onPick?(index) }
        panel.onClose = { [weak self] index in self?.onClose?(index) }
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
        // The cursor is not over anything once the panels are gone, and a stale index would draw a
        // close button on the first tile of the next session.
        model.hoverIndex = nil
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
        // What the cursor is actually on, which is a different fact from what is selected: the
        // close button is drawn on the tile under the pointer, and the pointer being *somewhere
        // else* is exactly when it must not be. Held while the cursor is on the strip, so crossing
        // from a tile to its own preview does not make the button flicker away underneath.
        if !overPreview, model.hoverIndex != index { model.hoverIndex = index }
        emitPreview(previewTarget(at: location, overPreview: overPreview, index: index))
    }

    /// Points the preview at whatever the *keyboard* has selected.
    ///
    /// The hover path below answers "what is the cursor on"; this answers "what is highlighted", and
    /// they are the same question only when the two happen to agree. Without it, the one feature
    /// that shows you what is inside an app before you switch to it was reachable only with the
    /// mouse — in a switcher whose entire premise is that your hands are on the keyboard.
    ///
    /// Cheap by construction: it emits a target, and `PreviewCoordinator` sits on it for its usual
    /// debounce before any capture starts. A tap of ⌘-Tab is over long before that elapses, and
    /// cycling quickly through ten tiles fires one capture — for the tile you stopped on — rather
    /// than ten.
    ///
    /// Yields to the strip. While the cursor is *on* the floating preview the user is picking a
    /// window out of it, and re-pointing the strip at the selection under their hand would replace
    /// the thing they are aiming at mid-click. `.overPreview` is therefore the one state the
    /// keyboard does not override; the selection is re-emitted as soon as the cursor leaves.
    func previewSelection() {
        if case .overPreview = lastPreviewTarget { return }
        emitPreview(tileTarget(for: model.selection))
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
        return tileTarget(for: index)
    }

    /// The preview target for one tile, or `.away` when that tile has nothing to preview.
    ///
    /// Shared by the cursor path and the keyboard path so the two cannot answer differently about
    /// the same tile — which is the sort of drift that ends with the strip showing one app's windows
    /// beside another app's icon.
    private func tileTarget(for index: Int?) -> PreviewTarget? {
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
