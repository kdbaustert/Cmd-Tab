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
    /// Windows this session already tried and got nothing usable from — captured blank, or not
    /// listed by ScreenCaptureKit at all.
    ///
    /// Not retried. `begin` runs on every list mutation, and each retry paid for a fresh
    /// enumeration of every window on the system to arrive at the same answer. A thumbnail is a
    /// photograph of a moment anyway; the next session tries again.
    private var failed: Set<CGWindowID> = []

    /// Bumped by `cancel()`. A capture pass carries the value it started under and publishes
    /// nothing once that value has moved on.
    ///
    /// `task?.cancel()` is not enough on its own, which is the bug this closes. `begin` chains each
    /// pass behind the last (`await previous?.value`) and keeps only the newest in `task`, so a
    /// second pass leaves the first unstructured, unreferenced and *uncancelled* — `Task.isCancelled`
    /// inside it stays false. Ending the session then cancelled the newest pass and left the older
    /// one running, to finish some time later and write its images straight back into the map
    /// `cancel()` had just emptied. Those republish into `SwitcherModel.thumbnails`, so the next
    /// session opened showing photographs of the last one's windows — exactly what the note on
    /// `cancel()` says must not happen.
    ///
    /// The same generation counter `SwitchTarget.focusGeneration` and
    /// `TargetProvider.activationGeneration` use, for the same reason: cancellation cannot reach
    /// work that nothing holds a handle to, but a token the work checks for itself always can.
    private var generation = 0

    /// Begins capturing thumbnails for `targets`, dropping anything already captured.
    ///
    /// Called on every list mutation, including the fresh list that folds in a moment after the
    /// panel opens — hence the diffing: without it, every refresh would recapture the whole list
    /// while the user is still looking at the previous set.
    ///
    /// `maxHeight` is the tallest a thumbnail is ever drawn, in pixels — the caller knows the tile
    /// size and the display's scale, this object does not. It used to be a fixed 256, about twice
    /// what a default tile shows on a Retina display.
    func begin(for targets: [SwitchTarget], maxHeight: CGFloat) {
        guard isEnabled else { return }
        let wanted = targets.compactMap { target -> CGWindowID? in
            // App tiles and launch tiles have no window to capture. A minimized one is captured
            // like any other: the window server keeps its surface, and measured against the Dock
            // every minimized window returned real pixels — see `WindowCapture.thumbnails`. One
            // that does not is caught by the blank check and keeps its icon.
            guard case .window = target.kind else { return nil }
            guard let id = target.windowID, id != 0 else { return nil }
            return id
        }
        // Photographs of windows that have left the list go with them. A stay-open session lasts
        // until it is dismissed, and every window closed under it otherwise left its capture
        // resident — and republished into `SwitcherModel.thumbnails` — for the rest of it. One
        // assignment, so one `objectWillChange`, and only when there is something to drop.
        let wantedSet = Set(wanted)
        if images.keys.contains(where: { !wantedSet.contains($0) }) {
            images = images.filter { wantedSet.contains($0.key) }
        }
        let missing = wanted.filter {
            images[$0] == nil && !inFlight.contains($0) && !failed.contains($0)
        }
        guard !missing.isEmpty else { return }

        inFlight.formUnion(missing)
        let previous = task
        let generation = self.generation
        task = Task { [weak self] in
            // Serialised behind whatever was already running rather than cancelling it: the earlier
            // pass is capturing tiles the user is looking at right now.
            await previous?.value
            await self?.capture(missing, maxHeight: maxHeight, generation: generation)
        }
    }

    /// Drops everything and stops any capture in flight. Called when the session ends — a thumbnail
    /// is a photograph of a moment, and showing the next session what the last one looked like is
    /// worse than showing it an icon.
    func cancel() {
        // First, so a pass already past its own `Task.isCancelled` check is still stopped from
        // publishing — and so the passes this cannot cancel at all are stopped too. See `generation`.
        generation &+= 1
        task?.cancel()
        task = nil
        inFlight.removeAll()
        failed.removeAll()
        images.removeAll()
    }

    private func capture(_ ids: [CGWindowID], maxHeight: CGFloat, generation: Int) async {
        guard generation == self.generation else { return }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                // `onScreenWindowsOnly: false` so windows on other Spaces are included —
                // ScreenCaptureKit captures a window's backing surface whether or not its Space is
                // frontmost, which is exactly what a switcher needs.
                true, onScreenWindowsOnly: false)
        else {
            release(ids, generation: generation)
            return
        }
        let byID = Dictionary(
            content.windows.map { ($0.windowID, $0) }, uniquingKeysWith: { first, _ in first })

        for chunk in stride(from: 0, to: ids.count, by: Self.maxConcurrent).map({ start in
            Array(ids[start..<min(start + Self.maxConcurrent, ids.count)])
        }) {
            if Task.isCancelled || generation != self.generation { break }
            let captured = await withTaskGroup(of: (CGWindowID, CGImage?).self) { group in
                for id in chunk {
                    guard let found = byID[id] else { continue }
                    // `SCWindow` is not `Sendable`; it is a read-only descriptor naming a window to
                    // capture, which is the one thing this API exists to be used for off the main
                    // thread. Same reasoning as `WindowPreview.Entry`.
                    nonisolated(unsafe) let window = found
                    group.addTask { (id, await Self.image(of: window, maxHeight: maxHeight)) }
                }
                var out: [(CGWindowID, CGImage)] = []
                for await (id, image) in group {
                    if let image { out.append((id, image)) }
                }
                return out
            }
            if Task.isCancelled || generation != self.generation { break }
            // Published per batch rather than per image: each assignment redraws every tile bound to
            // this object, and a thirty-window list would otherwise lay the panel out thirty times.
            // One `merge` rather than a loop of subscript assignments, because `images` is
            // `@Published` and every one of those is its own `objectWillChange`.
            images.merge(captured) { _, new in new }
            let landed = Set(captured.map(\.0))
            failed.formUnion(chunk.filter { !landed.contains($0) })
        }
        release(ids, generation: generation)
    }

    /// Gives up the claim this pass had on `ids`, unless the session it belonged to has ended.
    ///
    /// The generation check is not merely tidiness. `cancel()` empties `inFlight` outright, and a
    /// later `begin` can have re-claimed some of these ids for a pass that is still running — so a
    /// stale pass subtracting them would free ids the live pass owns, and the next `begin` would
    /// queue a duplicate capture of windows already being photographed.
    private func release(_ ids: [CGWindowID], generation: Int) {
        guard generation == self.generation else { return }
        inFlight.subtract(ids)
    }

    private nonisolated static func image(
        of window: SCWindow, maxHeight: CGFloat
    ) async -> CGImage? {
        // The hover preview's capture, which renders straight to thumbnail size rather than
        // capturing full-res and scaling after. Shared so the downscale policy has one home.
        guard let image = try? await WindowCapture.capture(window, maxHeight: maxHeight)
        else { return nil }
        // The same blank check the hover preview applies, and for the same reason: Electron and
        // Catalyst apps expose phantom backing windows with no content, and a tile showing an empty
        // rectangle is worse than one showing the app's icon.
        return WindowCapture.isBlankImage(image) ? nil : image
    }
}
