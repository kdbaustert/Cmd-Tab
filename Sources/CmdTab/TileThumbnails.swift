import AppKit
import ScreenCaptureKit
import SwiftUI

/// Live window thumbnails drawn as the tile artwork in window mode.
///
/// Window mode's tiles are app icons, which is fine for the first window of an app and useless for
/// the fifth — five identical Chrome icons distinguished only by a truncated title is the case this
/// exists for. It is the feature AltTab is best known for.
///
/// **Opt-in, and off by default**, for the same reason the hover preview is: capture needs Screen
/// Recording, and this app's whole permission story is that it needs Accessibility and nothing else.
/// Leaving it off means that stays true. Turning it on flips Screen Recording from optional to
/// required for the mode you are using — which is a real cost and the user's call, not ours.
///
/// ## Why this is a separate object from `WindowPreview`
///
/// The hover preview captures *one app's* windows on a deliberate pause, with a debounce and a
/// cancel-on-move. This captures *every* tile in the list the moment the panel opens, which is a
/// different problem: the panel is already on screen, the captures must never delay it, and a tile
/// whose capture has not landed has to look like something in the meantime. So the flow is
/// inverted — the panel draws icons immediately and thumbnails replace them as they arrive, rather
/// than anything waiting.
@MainActor
final class TileThumbnails: ObservableObject {

    /// Captured images by window id. Published, so a tile redraws when its own capture lands.
    @Published private(set) var images: [CGWindowID: CGImage] = [:]

    /// Off by default. See the class comment.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue, !isEnabled else { return }
            cancel()
        }
    }

    /// Thumbnails are drawn at the tile's size, which the metrics cap. Captured a little larger than
    /// drawn so a Retina tile is not upscaled.
    private nonisolated static let maxHeight: CGFloat = 256

    /// How many captures run at once.
    ///
    /// Each is a `SCScreenshotManager` round trip, and a machine with thirty windows open would
    /// otherwise start thirty at once and contend with the window server that is, at that exact
    /// moment, compositing the panel that just appeared. The same bound the hover preview uses.
    private nonisolated static let maxConcurrent = 4

    private var task: Task<Void, Never>?
    /// Which window ids the running task is capturing, so a refresh that changes nothing does not
    /// restart it and re-capture what is already on screen.
    private var inFlight: Set<CGWindowID> = []

    /// Begins capturing thumbnails for `targets`, dropping anything already captured.
    ///
    /// Called on every list mutation, including the fresh list that folds in a moment after the
    /// panel opens — hence the diffing: without it, every refresh would recapture the whole list
    /// while the user is still looking at the previous set.
    func begin(for targets: [SwitchTarget]) {
        guard isEnabled else { return }
        let wanted = targets.compactMap { target -> CGWindowID? in
            // App tiles and launch tiles have no window to capture; a minimized window has no live
            // surface, so it captures blank and keeps its icon.
            guard case .window = target.kind, !target.isMinimized else { return nil }
            guard let id = target.windowID, id != 0 else { return nil }
            return id
        }
        let missing = wanted.filter { images[$0] == nil && !inFlight.contains($0) }
        guard !missing.isEmpty else { return }

        inFlight.formUnion(missing)
        let previous = task
        task = Task { [weak self] in
            // Serialised behind whatever was already running rather than cancelling it: the earlier
            // pass is capturing tiles the user is looking at right now.
            await previous?.value
            await self?.capture(missing)
        }
    }

    /// Drops everything and stops any capture in flight. Called when the session ends — a thumbnail
    /// is a photograph of a moment, and showing the next session what the last one looked like is
    /// worse than showing it an icon.
    func cancel() {
        task?.cancel()
        task = nil
        inFlight.removeAll()
        images.removeAll()
    }

    private func capture(_ ids: [CGWindowID]) async {
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                // `onScreenWindowsOnly: false` so windows on other Spaces are included —
                // ScreenCaptureKit captures a window's backing surface whether or not its Space is
                // frontmost, which is exactly what a switcher needs.
                true, onScreenWindowsOnly: false)
        else {
            inFlight.subtract(ids)
            return
        }
        let byID = Dictionary(
            content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        for chunk in stride(from: 0, to: ids.count, by: Self.maxConcurrent).map({ start in
            Array(ids[start..<min(start + Self.maxConcurrent, ids.count)])
        }) {
            if Task.isCancelled { break }
            let captured = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in chunk {
                    guard let found = byID[id] else { continue }
                    // `SCWindow` is not `Sendable`; it is a read-only descriptor naming a window to
                    // capture, which is the one thing this API exists to be used for off the main
                    // thread. Same reasoning as `WindowPreview.Entry`.
                    nonisolated(unsafe) let window = found
                    group.addTask { (id, await Self.image(of: window)) }
                }
                var out: [(CGWindowID, CGImage)] = []
                for await (id, image) in group {
                    if let image { out.append((id, image)) }
                }
                return out
            }
            if Task.isCancelled { break }
            // Published per batch rather than per image: each assignment redraws every tile bound to
            // this object, and a thirty-window list would otherwise lay the panel out thirty times.
            for (id, image) in captured { images[id] = image }
        }
        inFlight.subtract(ids)
    }

    private nonisolated static func image(of window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Rendered straight to thumbnail size rather than captured full-res and scaled after.
        let scale = min(1, maxHeight / max(window.frame.height, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        guard
            let image = try? await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: config)
        else { return nil }
        // The same blank check the hover preview applies, and for the same reason: Electron and
        // Catalyst apps expose phantom backing windows with no content, and a tile showing an empty
        // rectangle is worse than one showing the app's icon.
        return WindowCapture.isBlankImage(image) ? nil : image
    }
}
