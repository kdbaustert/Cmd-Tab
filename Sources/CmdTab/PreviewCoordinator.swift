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
    /// The switcher the strip positions itself against and forwards scrolls to.
    private unowned let switcher: SwitcherPanel
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

    init(switcher: SwitcherPanel, isActive: @escaping () -> Bool) {
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

    /// Tears the strip down at once, skipping the grace period.
    ///
    /// The switcher's own `hide()` only *schedules* a delayed dismiss, which would leave the strip
    /// floating over the just-activated app — and, if the switcher reopens inside that window, let a
    /// stale strip be pinned into the new session.
    func teardown() {
        cancelPendingCapture()
        dismissWork?.cancel()
        dismissWork = nil
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
                self.strip.dismiss()
            } else {
                self.strip.present(
                    thumbs: thumbs, appName: appName, over: tileRect,
                    clearOf: self.switcher.frame, appearance: self.switcher.effectiveAppearance)
            }
        }
    }
}
