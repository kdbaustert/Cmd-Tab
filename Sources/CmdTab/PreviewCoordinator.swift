import AppKit

/// Owns the hover preview: the floating strip, the debounce before a capture starts, and the grace
/// period before it goes away.
///
/// Kept out of `SwitcherController`, which already carries the session state machine, the window
/// actions and the watchdog. None of the timing here has anything to do with the key path — it is
/// driven entirely by the cursor — so living next to the event-tap logic only made that file's
/// "stay cheap in the tap callback" rule harder to see.
@MainActor
final class PreviewCoordinator {
    /// Invoked when a thumbnail is clicked, so the controller can focus that window and dismiss.
    var onPick: ((WindowThumb) -> Void)?

    private let strip = WindowPreviewPanel()
    /// The switcher the strip positions itself against and forwards scrolls to. The group rather
    /// than a single panel: mirrored across displays, the strip has to clear the panel the cursor is
    /// actually on.
    private unowned let switcher: PanelGroup
    /// Whether a session is still open. A capture that lands after the switcher went away must not
    /// draw a strip over whatever the user just switched to.
    private let isActive: () -> Bool

    /// The pending capture, held so a cursor moving on can cancel it before any work starts.
    private var captureWork: DispatchWorkItem?
    private var captureTask: Task<Void, Never>?
    /// The grace-period teardown, cancelled if the cursor reaches the strip or another tile.
    private var dismissWork: DispatchWorkItem?

    /// Long enough that sweeping across a row of tiles doesn't fire a capture per tile, short enough
    /// that pausing on one feels immediate.
    private let captureDelay: TimeInterval = 0.28
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

    /// Reacts to what the cursor points at. A tile captures after the debounce; sitting on the strip
    /// keeps it up and tracks the thumbnail under the pointer; leaving both schedules the teardown.
    func hover(_ target: PreviewTarget) {
        switch target {
        case .tile(let pid, let rect):
            cancelDismiss()
            cancelCapture()
            let work = DispatchWorkItem { [weak self] in
                MainActor.assumeIsolated { self?.capture(pid: pid, tileRect: rect) }
            }
            captureWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + captureDelay, execute: work)

        case .overPreview(let point):
            cancelDismiss()
            // A capture queued for the tile the cursor just left would replace the strip the cursor
            // is now standing on, under the pointer, mid-click.
            cancelCapture()
            strip.setHover(at: point)

        case .away:
            cancelCapture()
            scheduleDismiss()
        }
    }

    /// Ends everything at once, for a session that is closing.
    func teardown() {
        cancelCapture()
        cancelDismiss()
        strip.dismiss()
        Task { await WindowCapture.shared.clearCaches() }
    }

    /// Captures `pid`'s windows and floats them by the tile, unless the session ended or the cursor
    /// moved on while the capture was in flight.
    private func capture(pid: pid_t, tileRect: NSRect) {
        captureWork = nil
        guard isActive() else { return }
        let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? ""
        captureTask = Task { [weak self] in
            let thumbs = await WindowCapture.shared.thumbnails(for: pid)
            guard !Task.isCancelled, let self, self.isActive() else { return }
            // pid and count only. Window titles carry document names, mail subjects and URLs, and
            // `.public` would persist them in the unified log for anything that can run `log show`.
            Log.general.notice(
                "preview: \(thumbs.count, privacy: .public) window(s) for pid \(pid, privacy: .public)"
            )
            guard !thumbs.isEmpty else {
                // Nothing capturable — an app with no real windows, or Screen Recording withheld.
                // Take the old strip down rather than leaving the previous app's windows floating
                // next to a tile they do not belong to.
                self.strip.dismiss()
                return
            }
            // Resolved here rather than before the await: the panels can relayout while a capture is
            // in flight, and placement must describe where the tile is now.
            self.strip.present(
                thumbs: thumbs, appName: name, over: tileRect,
                placement: self.switcher.placement(forTileAt: tileRect))
        }
    }

    private func cancelCapture() {
        captureWork?.cancel()
        captureWork = nil
        captureTask?.cancel()
        captureTask = nil
    }

    private func scheduleDismiss() {
        guard dismissWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                self?.dismissWork = nil
                self?.strip.dismiss()
            }
        }
        dismissWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + dismissDelay, execute: work)
    }

    private func cancelDismiss() {
        dismissWork?.cancel()
        dismissWork = nil
    }
}
