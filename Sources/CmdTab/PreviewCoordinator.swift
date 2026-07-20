import AppKit

/// Owns the hover preview: the floating strip, the debounce before a capture starts, and the grace
/// period before it goes away.
///
/// Split out of `SwitcherController`, which was carrying the session state machine, the window
/// actions, the watchdog *and* this. None of the timing here has anything to do with the key path —
/// it is driven entirely by the cursor — so keeping it next to the event-tap logic only made the
/// controller harder to read and the tap callback's "stay cheap" rule harder to see.
@MainActor
final class PreviewCoordinator {
    /// Invoked when a thumbnail is clicked, so the controller can focus that window and dismiss.
    var onPick: ((WindowThumb) -> Void)?

    private let strip = WindowPreviewPanel()
    /// The switcher the strip positions itself against and forwards scrolls to. The group rather
    /// than a panel: mirrored, the strip has to clear every panel, not just the one it grew from.
    private unowned let switcher: PanelGroup
    /// Whether a session is still open. A capture that lands after the switcher went away must not
    /// draw the strip over whatever the user just switched to.
    private let isActive: () -> Bool

    /// Pending capture, held so a cursor moving on can cancel it before any work starts.
    private var captureWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// Grace-period teardown, cancelled if the cursor reaches the strip or another tile.
    private var dismissWork: DispatchWorkItem?

    /// Long enough that sweeping across tiles doesn't fire a capture per tile, short enough that
    /// pausing on one feels immediate.
    private let captureDelay: TimeInterval = 0.3
    /// Covers the gap between a tile and the strip, so crossing it doesn't dismiss mid-move.
    private let dismissDelay: TimeInterval = 0.35

    init(switcher: PanelGroup, isActive: @escaping () -> Bool) {
        self.switcher = switcher
        self.isActive = isActive
        strip.onPick = { [weak self] thumb in self?.onPick?(thumb) }
        // Forwarded rather than swallowed, so scrolling over the strip still moves the selection.
        strip.onScroll = { [weak self] event in self?.switcher.forwardScroll(event) }
    }

    /// Whether the strip is up and covering `point` — hover tracking asks this so the strip stays
    /// alive, and clickable, while the cursor is on it.
    func isShowing(_ point: NSPoint) -> Bool { strip.isShowing(point) }

    /// Reacts to what the cursor points at. A tile (re)captures after the debounce; sitting on the
    /// strip cancels any teardown; leaving both schedules the grace-delayed dismissal.
    func hover(_ target: PreviewHoverTarget) {
        // While the keyboard is steering the strip, cursor drift must not re-target or dismiss it —
        // the pointer is usually sitting still over whichever tile the drill started from, and a
        // stray hover would swap the strip out from under the arrow keys. `wantsSteering` counts too,
        // or a hover landing mid-capture would cancel the drill before it ever engaged.
        guard !isSteering, !wantsSteering else { return }
        dismissWork?.cancel()
        dismissWork = nil
        switch target {
        case .tile(let pid, let rect):
            cancelPendingCapture()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.capture(pid: pid, tileRect: rect) }
            }
            captureWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay, execute: work)
        case .overPreview:
            // Keep what's shown; just stop any pending new capture.
            captureWork?.cancel()
            captureWork = nil
        case .away:
            cancelPendingCapture()
            let work = DispatchWorkItem { [weak self] in self?.strip.dismiss() }
            dismissWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
        }
    }

    // MARK: - Keyboard drill-down

    /// Whether the strip is currently being steered by the keyboard rather than the cursor.
    ///
    /// Only true once there are real thumbnails with a selection on them. Kept distinct from
    /// `wantsSteering` because the controller's key handling swallows everything while steering — so
    /// entering the state on intent alone would trap the keyboard in a mode with nothing in it
    /// whenever the capture came back empty (Screen Recording denied, or an app with no windows).
    private(set) var isSteering = false
    /// A drill-down asked for but not yet satisfied, because the capture is still in flight.
    private var wantsSteering = false
    /// The app whose windows the strip is currently showing, so a drill can tell whether what is on
    /// screen actually belongs to the tile being drilled into.
    private var shownPID: pid_t?

    /// The window the keyboard has selected inside the strip.
    var selectedThumb: WindowThumb? { strip.selectedThumb }

    /// Takes keyboard control of the strip for `pid`'s windows, capturing immediately if what is on
    /// screen doesn't already belong to that app.
    func beginSteering(pid: pid_t, tileRect: NSRect) {
        // A pending hover capture would land mid-drill and clear the selection underneath us.
        cancelPendingCapture()
        dismissWork?.cancel()
        dismissWork = nil

        // The pid check is the point. Arrowing between tiles only *schedules* a new capture behind
        // the hover debounce, so the strip can still be showing the previously hovered app — adopting
        // it would steer that app's windows while a different tile is highlighted, and commit one.
        if shownPID == pid, strip.beginKeyboardSelection() {
            wantsSteering = false
            isSteering = true
            return
        }
        // Nothing usable on screen: capture now, skipping the hover debounce. Steering begins only
        // if that capture actually yields windows.
        wantsSteering = true
        capture(pid: pid, tileRect: tileRect)
    }

    /// Hands control back to the cursor, leaving the strip up as a passive preview.
    func endSteering() {
        isSteering = false
        wantsSteering = false
        strip.endKeyboardSelection()
    }

    func moveSteering(_ delta: Int) { strip.moveSelection(delta) }

    /// Tears the strip down at once, skipping the grace period.
    ///
    /// The switcher's own `hide()` only *schedules* a delayed dismiss, which would leave the strip
    /// floating over the just-activated app — and, if the switcher reopens inside that window, let a
    /// stale strip be pinned into the new session.
    func teardown() {
        cancelPendingCapture()
        dismissWork?.cancel()
        dismissWork = nil
        isSteering = false
        wantsSteering = false
        shownPID = nil
        strip.endKeyboardSelection()
        strip.dismiss()
    }

    private func cancelPendingCapture() {
        captureWork?.cancel()
        captureWork = nil
        captureTask?.cancel()
        captureTask = nil
    }

    /// Captures the app's windows off the main thread, then floats them if the switcher is still up
    /// and the capture was not superseded. Empty (no permission, or nothing to show) hides the strip.
    private func capture(pid: pid_t, tileRect: NSRect) {
        let appName = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        captureTask = Task { [weak self] in
            let thumbs = await WindowCapture.shared.thumbnails(for: pid)
            guard !Task.isCancelled, let self, self.isActive() else { return }
            if thumbs.isEmpty {
                // Nothing to show, so there is nothing to steer either — drop back to the tiles
                // rather than stranding the user in a mode with no content.
                self.shownPID = nil
                self.isSteering = false
                self.wantsSteering = false
                self.strip.dismiss()
            } else {
                self.shownPID = pid
                self.strip.present(
                    thumbs: thumbs, appName: appName, over: tileRect,
                    // The anchoring panel's frame, not the union of every panel: mirrored across
                    // displays the union spans monitors, and placing the strip clear of *that*
                    // puts it outside any real screen.
                    clearOf: self.switcher.anchorFrame,
                    appearance: self.switcher.effectiveAppearance)
                // `present` clears any selection; enter it now if a drill was waiting on this capture.
                if self.wantsSteering || self.isSteering {
                    self.wantsSteering = false
                    self.isSteering = self.strip.beginKeyboardSelection()
                }
            }
        }
    }
}
