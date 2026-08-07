import AppKit
import ScreenCaptureKit
import SwiftUI

/// What the cursor points at, as far as the hover preview is concerned.
enum PreviewTarget: Equatable {
    /// An app tile — the app's pid and the tile's screen rect.
    case tile(pid: pid_t, rect: NSRect)
    /// The floating strip itself, with where on it the cursor is. Carrying the point keeps the strip
    /// alive while the cursor is on it *and* lets it highlight the thumbnail under the pointer;
    /// without a point this case would dedupe to a single event and the highlight could never move.
    case overPreview(NSPoint)
    /// Neither. The coordinator delays the teardown a little so the cursor can cross the gap from a
    /// tile to the strip without it vanishing mid-move.
    case away
}

/// A live thumbnail of one window, as shown in the hover preview.
struct WindowThumb: Identifiable {
    /// Position in the strip, and the identity the view and hit-testing use.
    ///
    /// Deliberately *not* the `CGWindowID`: a minimized window on a host where
    /// `_AXUIElementGetWindow` fails (Electron, Catalyst) resolves to id 0, so an app with two of
    /// them would hand `ForEach` duplicate ids and collide in the frame map — which decides where a
    /// click lands. Position is unique by construction.
    let id: Int
    /// The window to raise when this thumbnail is clicked. 0 when it could not be resolved, which
    /// degrades to activating the app.
    let windowID: CGWindowID
    let image: NSImage
    let title: String
    /// The owning app, so a clicked thumbnail can be raised and activated.
    let pid: pid_t
    /// Minimized windows have no pixels to capture — `image` is the app icon for those.
    let isMinimized: Bool
    /// Which display the window is on, or nil with a single display (or when it can't be placed).
    /// An app's windows are routinely spread across monitors, and the strip gathers all of them —
    /// so without this there is no way to tell which screen a thumbnail will take you to.
    let displayIndex: Int?
}

/// Captures thumbnails of an app's windows through ScreenCaptureKit.
///
/// The only place in the app that needs Screen Recording: the switcher itself reads pids and titles
/// over Accessibility and deliberately gets by without it. That is why every entry point degrades to
/// an empty list rather than prompting — with the permission withheld the feature is simply absent,
/// and the rest of the switcher carries on.
///
/// An actor because the caches below are touched from overlapping hovers: sweeping the cursor along
/// a row of tiles starts a capture per tile, and they must not race each other rebuilding the same
/// system-wide window list.
actor WindowCapture {
    static let shared = WindowCapture()

    /// One window bound for the strip, before its pixels are fetched.
    private struct Entry {
        let id: CGWindowID
        let title: String
        /// The capture source, or nil for a minimized window — which has no surface to capture.
        let window: SCWindow?
        let isMinimized: Bool
        let displayIndex: Int?
    }

    /// Windows narrower or shorter than this are helper surfaces, not something to switch to.
    private static let minWindowSide: CGFloat = 40

    /// What Accessibility says an app's windows are.
    private struct AXWindows {
        /// Every window the app reports, by `CGWindowID`.
        let ids: Set<CGWindowID>
        /// The subset sitting in the Dock, with titles, so SC's list can be supplemented.
        let minimized: [(id: CGWindowID, title: String)]
        /// Whether this is a complete answer — a non-empty list in which every window resolved to a
        /// real id. Only then can it be used to *remove* windows SC reported; see `thumbnails`.
        let isComplete: Bool
    }

    private var content: SCShareableContent?
    private var contentFetchedAt: Date?
    private var axCache: [pid_t: (windows: AXWindows, at: Date)] = [:]

    /// How long a fetched window list may be reused. Sub-second: long enough that sweeping the
    /// cursor back across a tile doesn't re-enumerate every window on the system, short enough that
    /// the strip can't show a window that has since closed.
    private let ttl: TimeInterval = 0.75

    /// Ceiling on simultaneous captures. Each is WindowServer and GPU work for a strip the cursor
    /// may be about to sweep straight past, and it stacks with whatever the panel's own behind-window
    /// blur already costs the compositor. Four keeps the round-trips overlapping without the spike.
    private let maxConcurrentCaptures = 4

    /// Thumbnails of `pid`'s windows, front to back. Empty when Screen Recording is not granted or
    /// the app genuinely has nothing on screen.
    func thumbnails(for pid: pid_t, maxCount: Int = 12, maxHeight: CGFloat = 150) async
        -> [WindowThumb]
    {
        guard Permissions.canCaptureScreen, !Task.isCancelled else { return [] }
        guard let content = await shareableContent(), !Task.isCancelled else { return [] }

        // ScreenCaptureKit decides which windows exist. Accessibility deliberately does not.
        //
        // `AXWindows` returns *success with an empty array* for an app whose accessibility tree is
        // not live, and Chromium and Electron build theirs only on demand — so an AX-driven list
        // previewed whichever app happened to be frontmost and showed nothing at all for Chrome,
        // VS Code, Spotify or GitHub Desktop. SC enumerates every app's windows whoever is active,
        // and hands over the window id, title and frame in the same pass.
        //
        // Layer 0 is the ordinary window layer; anything above it is a panel or overlay. Window id 0
        // is the "no id" sentinel and never names a real window.
        //
        // The title is the load-bearing filter, not the size. A single app carries a surprising
        // amount of layer-0 debris — several 2056x39 strips, 1x1 and 64x64 stubs, and for Chrome a
        // couple of full-width dropdown surfaces — and every one of them is untitled, while every
        // window a user could actually switch to has a title. Size alone let the dropdowns through.
        var live = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.windowID != 0
                && $0.frame.width > Self.minWindowSide && $0.frame.height > Self.minWindowSide
                && !($0.title ?? "").isEmpty
        }

        // Which of those are actually in the Dock.
        //
        // SC does list minimized windows — the comment that used to sit here said it could not see
        // them at all, and that is wrong: they arrive in `live` with a title and a full-size frame,
        // just with nothing to capture. So they were tiled as ordinary windows, and the only reason
        // they looked right was that the capture came back blank and fell through to the icon.
        //
        // A window in the Dock is on no Space and on no screen; a window on another Desktop is off
        // screen but still has a Space. Both reads are one window-server call each for the whole
        // strip, rather than a question per tile.
        let dockedIDs = await Task.detached { Self.dockedWindowIDs() }.value

        // Accessibility supplements the list for anything SC missed entirely, and — where it gives a
        // complete answer — vetoes what SC reports but the app does not actually have. It still does
        // not *drive* the list: an app whose tree is asleep answers nothing, and that has to cost a
        // minimized thumbnail rather than the entire strip.
        let ax = await axWindows(for: pid)

        // The window server keeps a layer-0 surface, with its last title and full-size frame, for
        // windows an app has already closed. Ghostty is the standing case: a session with one window
        // open had twenty of them, so the strip filled with icon tiles captioned with the titles of
        // long-gone tabs. They look exactly like minimized windows from the window server's side —
        // on no Space and on no screen — so `dockedWindowIDs` cannot tell them apart, and only the
        // app itself can say which of its windows still exist.
        //
        // Confined to the docked set: a window that is on a Space is one SC can actually capture,
        // and dropping it on an Accessibility disagreement would cost a real thumbnail. And skipped
        // entirely unless AX gave a complete answer, so an app whose tree is asleep or whose windows
        // resolve to no id keeps every tile it has now.
        if ax.isComplete {
            live.removeAll { dockedIDs.contains($0.windowID) && !ax.ids.contains($0.windowID) }
        }

        let liveIDs = Set(live.map(\.windowID))
        let minimized = ax.minimized.filter { !liveIDs.contains($0.id) }
        guard !live.isEmpty || !minimized.isEmpty, !Task.isCancelled else { return [] }

        // `NSScreen` is main-thread-only. Empty with a single display, which is what keeps the
        // display badge off the thumbnails for everyone who has one.
        let screenFrames = await MainActor.run {
            NSScreen.screens.count > 1 ? TargetProvider.screenCGFrames() : []
        }
        let icon = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.icon }

        // SC hands back its windows front to back, which is the order the strip wants; whatever is
        // sitting in the Dock follows the windows that are actually on screen.
        var entries = live.map { window -> Entry in
            let isDocked = dockedIDs.contains(window.windowID)
            return Entry(
                // No capture source for a docked window: its surface is gone, and asking for one
                // costs a failed SC round-trip per tile to arrive at the icon fallback anyway.
                id: window.windowID, title: window.title ?? "",
                window: isDocked ? nil : window, isMinimized: isDocked,
                // A docked window's frame is where it *was*, which on a multi-display setup is not
                // where clicking it will take you. Badge nothing rather than the wrong monitor.
                displayIndex: isDocked
                    ? nil : Self.displayIndex(of: window.frame, in: screenFrames))
        }
        entries += minimized.map {
            Entry(
                id: $0.id, title: $0.title, window: nil, isMinimized: true, displayIndex: nil)
        }

        // Captured in bounded batches but reassembled by index, so the strip reads in the order
        // above rather than in whichever order the captures happened to come back.
        let wanted = Array(entries.prefix(maxCount))
        var built: [(Int, WindowThumb)] = []
        for start in stride(from: 0, to: wanted.count, by: maxConcurrentCaptures) {
            guard !Task.isCancelled else { break }
            let end = min(start + maxConcurrentCaptures, wanted.count)
            built += await withTaskGroup(of: (Int, WindowThumb?).self) { group in
                for index in start..<end {
                    let entry = wanted[index]
                    group.addTask {
                        let thumb = await Self.thumb(
                            at: index, for: entry, icon: icon, pid: pid, maxHeight: maxHeight)
                        return (index, thumb)
                    }
                }
                var out: [(Int, WindowThumb)] = []
                for await (index, thumb) in group {
                    if let thumb { out.append((index, thumb)) }
                }
                return out
            }
        }
        return built.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Which display a window is on, from the frame SC already reported — both are in global
    /// top-left coordinates, so no Accessibility round-trip is needed to place it.
    ///
    /// Centre first, then largest overlap, matching `TargetProvider.displayIndex` so a window cannot
    /// be badged one way in the switcher and another in its preview strip. A window whose centre is
    /// off every display still belongs to one.
    private static func displayIndex(of frame: CGRect, in screenFrames: [CGRect]) -> Int? {
        guard !screenFrames.isEmpty else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        if let index = screenFrames.firstIndex(where: { $0.contains(centre) }) { return index }
        return screenFrames.indices.filter { screenFrames[$0].intersection(frame).area > 0 }.max {
            screenFrames[$0].intersection(frame).area < screenFrames[$1].intersection(frame).area
        }
    }

    /// Drops the caches when a session ends.
    ///
    /// Both TTLs are sub-second, so nothing would legitimately reuse these across sessions — but
    /// `content` holds an `SCWindow` for every window on the system and `axCache` gains an entry
    /// per app hovered. Left alone they stay resident for the life of the process, which for a
    /// menu-bar agent is the life of the login.
    func clearCaches() {
        content = nil
        contentFetchedAt = nil
        axCache.removeAll()
    }

    /// One window's thumbnail: a live capture when there is one to be had, the app icon when there
    /// isn't. Returns nil for windows not worth a tile at all.
    private static func thumb(
        at index: Int, for entry: Entry, icon: NSImage?, pid: pid_t, maxHeight: CGFloat
    ) async -> WindowThumb? {
        guard !Task.isCancelled else { return nil }
        if let window = entry.window {
            if let image = try? await capture(window, maxHeight: maxHeight), !isBlank(image) {
                let size = NSSize(width: image.width, height: image.height)
                return WindowThumb(
                    id: index, windowID: entry.id, image: NSImage(cgImage: image, size: size),
                    title: entry.title, pid: pid, isMinimized: false,
                    displayIndex: entry.displayIndex)
            }
            // Captured blank: one of the invisible helper surfaces Electron and friends keep around
            // rather than a window anyone could switch to. An untitled one is dropped outright; a
            // titled one is real enough to earn the icon fallback below.
            guard !entry.title.isEmpty else { return nil }
        }
        let fallback =
            icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
        return WindowThumb(
            id: index, windowID: entry.id, image: fallback, title: entry.title, pid: pid,
            isMinimized: entry.isMinimized, displayIndex: entry.displayIndex)
    }

    /// The full window list, reused for `ttl` so a sweep across tiles doesn't re-run the whole
    /// system-wide enumeration for each one.
    private func shareableContent() async -> SCShareableContent? {
        if let content, let contentFetchedAt, Date().timeIntervalSince(contentFetchedAt) < ttl {
            return content
        }
        guard
            let fresh = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
        else { return nil }
        content = fresh
        contentFetchedAt = Date()
        return fresh
    }

    /// The windows that are sitting in the Dock: on no Space, and on no screen.
    ///
    /// Both halves are load-bearing. "On no Space" alone would also swallow a window whose Space
    /// read came back short, and "off screen" alone would swallow every window on another Desktop —
    /// which are exactly the ones the strip must keep offering as ordinary, capturable tiles.
    ///
    /// Empty when the Space read is unavailable at all, so a machine without the private symbols
    /// degrades to the old behaviour (docked windows tiled as live ones) rather than to labelling
    /// every window minimized.
    private static func dockedWindowIDs() -> Set<CGWindowID> {
        let placed = SpaceMover.windowSpaces()
        guard !placed.isEmpty else { return [] }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        var out: Set<CGWindowID> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                let id = window[kCGWindowNumber as String] as? CGWindowID, id != 0,
                placed[id] == nil,
                // Absent rather than false when the window is not being displayed.
                (window[kCGWindowIsOnscreen as String] as? Bool) != true
            else { continue }
            out.insert(id)
        }
        return out
    }

    /// What the app itself says its windows are — cached for `ttl`.
    ///
    /// Best-effort by design: this is the one thing Accessibility is still asked for, and it answers
    /// with an empty list for any app whose tree is not live. Losing a minimized thumbnail for such
    /// an app — or keeping a stale tile it could have vetoed — is a far smaller failure than letting
    /// AX decide the whole strip, which is what it used to do. `isComplete` is what keeps the veto
    /// off those apps: an empty list is no answer, and a window that resolves to no `CGWindowID`
    /// (the Electron/Catalyst case) cannot be matched against SC's list either way, so a list
    /// carrying one is treated as unusable for removal rather than as proof the rest are gone.
    ///
    /// The AX work runs off the actor, on a detached task. Those calls are synchronous and do
    /// several `AXUIElementCopyAttributeValue` round-trips per window, each of which can burn the
    /// full AX timeout against a beach-balling app. Run inline there is no suspension point, so
    /// every other hover would queue behind the one wedged app and previews would stop appearing
    /// entirely until it cleared.
    private func axWindows(for pid: pid_t) async -> AXWindows {
        let now = Date()
        if let entry = axCache[pid], now.timeIntervalSince(entry.at) < ttl { return entry.windows }
        // Shed everything else that has aged out while we are here.
        axCache = axCache.filter { now.timeIntervalSince($0.value.at) < ttl }
        let windows = await Task.detached { () -> AXWindows in
            let elements = AX.windows(of: AX.application(pid)).filter(AX.isWindow)
            var ids: Set<CGWindowID> = []
            var minimized: [(id: CGWindowID, title: String)] = []
            var resolvedEvery = !elements.isEmpty
            for element in elements {
                let id = TargetProvider.windowID(element) ?? 0
                if id == 0 { resolvedEvery = false } else { ids.insert(id) }
                guard AX.isMinimized(element) else { continue }
                minimized.append((id, AX.copyString(element, kAXTitleAttribute) ?? ""))
            }
            return AXWindows(ids: ids, minimized: minimized, isComplete: resolvedEvery)
        }.value
        axCache[pid] = (windows, now)
        return windows
    }

    private static func capture(_ window: SCWindow, maxHeight: CGFloat) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Rendered straight to thumbnail size rather than captured full-res and scaled after.
        let scale = min(1, maxHeight / max(window.frame.height, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    /// Whether a capture came back essentially empty. Downsamples to a small grid and counts pixels
    /// carrying any alpha, which separates a real (opaque) window from a hidden helper window's
    /// fully transparent surface.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        // Created, drawn and read entirely inside the closure. Passing `&data` to `CGContext` would
        // be an inout-to-pointer conversion, valid only for the duration of the initializer call —
        // but the context keeps the pointer and writes through it during `draw`, after that call
        // has returned. The compiler may hand over a temporary buffer and copy back, in which case
        // `draw` scribbles on freed memory and the verdict below is read from uninitialized bytes.
        return data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var opaque = 0
            for i in stride(from: 3, to: raw.count, by: 4) where raw[i] > 8 { opaque += 1 }
            // A real window fills nearly the whole frame; a transparent phantom leaves it near-empty.
            return opaque < (side * side) / 10
        }
    }
}

// MARK: - The floating strip

/// Backing store for the strip's SwiftUI content.
@MainActor
private final class PreviewStripModel: ObservableObject {
    @Published var thumbs: [WindowThumb] = []
    /// The app whose windows are shown, as a heading over the strip.
    @Published var appName: String = ""
    /// The thumbnail under the cursor, so the click target is visible before it is clicked.
    @Published var hovered: Int?
    /// Bumped on every `present`. See `ThumbKey` — this is what keeps a click honest.
    @Published var generation = 0
    /// Each thumbnail's frame in the panel's content coordinates (top-left origin), reported by the
    /// view so the panel can hit-test a click. Not `@Published` — it only feeds the panel.
    var thumbFrames: [ThumbKey: CGRect] = [:]
}

/// Identifies a reported thumbnail frame: which strip it belongs to, and which position in it.
///
/// The generation is what makes a click safe. `onPreferenceChange` only fires when the reported
/// value actually *changes*, so the frame map cannot simply be cleared on each present — an app
/// whose strip lays out identically to the previous one would report identical frames, no callback
/// would arrive, and the map would sit empty and unclickable. Carrying the generation in the key
/// means every present reports a value that differs from the last, *and* frames left over from the
/// previous strip fail to match the current generation rather than resolving, by position, to
/// whatever window now happens to occupy that slot.
private struct ThumbKey: Hashable {
    let generation: Int
    let index: Int
}

/// Reports each thumbnail's laid-out frame up to the panel for click hit-testing.
private struct ThumbFrameKey: PreferenceKey {
    static let defaultValue: [ThumbKey: CGRect] = [:]
    static func reduce(value: inout [ThumbKey: CGRect], nextValue: () -> [ThumbKey: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

private struct PreviewStripView: View {
    @ObservedObject var model: PreviewStripModel

    /// The coordinate space the reported frames are measured in — the panel's own content, so a
    /// screen click maps onto them after nothing more than a flip.
    static let space = "windowPreview"

    /// How many thumbnails sit in a row before wrapping, so an app with many windows grows downward
    /// rather than off the side of the screen.
    private static let perRow = 4

    private var rows: [[WindowThumb]] {
        stride(from: 0, to: model.thumbs.count, by: Self.perRow).map {
            Array(model.thumbs[$0..<min($0 + Self.perRow, model.thumbs.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.appName.isEmpty {
                Text(model.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { thumb in
                            cell(thumb)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ThumbFrameKey.self) { model.thumbFrames = $0 }
    }

    @ViewBuilder
    private func cell(_ thumb: WindowThumb) -> some View {
        let isHovered = model.hovered == thumb.id
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                image(thumb)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isHovered ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: isHovered ? 3 : 1)
                    )
                if thumb.isMinimized {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .orange)
                        .padding(4)
                }
            }
            .overlay(alignment: .topTrailing) {
                if let display = thumb.displayIndex {
                    DisplayBadge(number: display + 1)  // 1-based for humans
                        .padding(4)
                }
            }
            if !thumb.title.isEmpty {
                Text(thumb.title)
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
        }
        // The whole cell — image and title — is the click target, so report its frame rather than
        // the image's.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ThumbFrameKey.self,
                    value: [
                        ThumbKey(generation: model.generation, index: thumb.id):
                            geo.frame(in: .named(Self.space))
                    ])
            })
    }

    @ViewBuilder
    private func image(_ thumb: WindowThumb) -> some View {
        if thumb.isMinimized {
            // The app icon, padded into a tile the size a real capture would be, so a minimized
            // window doesn't collapse the row it is in.
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(20)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The small non-activating panel that floats the thumbnails next to the hovered tile.
///
/// It never takes the keyboard and never becomes key, but a click on a thumbnail becomes a pick —
/// the same arrangement, for the same reason, as the switcher panel's own tile clicks.
@MainActor
final class WindowPreviewPanel: NSPanel {
    private let content = PreviewStripModel()
    private var host: NSHostingView<PreviewStripView>?

    /// Gap between the switcher and the strip.
    private let gap: CGFloat = 10

    /// Invoked when a thumbnail is clicked, so the controller can focus that window and dismiss.
    var onPick: ((WindowThumb) -> Void)?
    /// A scroll that landed on the strip instead of the switcher, forwarded so scroll-to-navigate
    /// keeps working (the switcher's global monitor cannot see events delivered to our own panel).
    var onScroll: ((NSEvent) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
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

    /// A non-activating panel receives clicks without bringing our app forward, so a click on a
    /// thumbnail can be turned straight into a pick. Handled here rather than in SwiftUI because the
    /// panel is never key, which leaves SwiftUI's own gesture recognisers dormant.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let thumb = thumb(at: NSEvent.mouseLocation) {
                onPick?(thumb)
                return
            }
        case .scrollWheel:
            onScroll?(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Whether the strip is up and covering `point`. Hover tracking asks this so the strip stays
    /// alive — and stays clickable — while the cursor is on it.
    func isShowing(_ screenPoint: NSPoint) -> Bool {
        isVisible && frame.contains(screenPoint)
    }

    /// Moves the hover highlight to whatever the cursor is over. Driven from the switcher's cursor
    /// poll: mouse-moved events only go to the key window, and this panel is never key.
    func setHover(at screenPoint: NSPoint) {
        let id = thumb(at: screenPoint)?.id
        guard content.hovered != id else { return }
        content.hovered = id
    }

    /// The thumbnail under a screen point, from the frames the view reported for the strip that is
    /// on screen now. A frame from an earlier strip is ignored rather than trusted — see `ThumbKey`.
    private func thumb(at screenPoint: NSPoint) -> WindowThumb? {
        // Content coordinates are top-left origin; flip the bottom-up screen point into them.
        let point = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        let generation = content.generation
        guard
            let key = content.thumbFrames.first(where: {
                $0.key.generation == generation && $0.value.contains(point)
            })?.key
        else { return nil }
        return content.thumbs.first { $0.id == key.index }
    }

    /// Shows `thumbs` for `appName`, centred on the hovered tile and clear of the switcher panel
    /// that tile belongs to — which under mirroring is not necessarily the one under the cursor.
    func present(
        thumbs: [WindowThumb], appName: String, over tileRect: NSRect,
        placement: PanelGroup.PreviewPlacement
    ) {
        // Driven through the observed model: the hosting view is built once and reused, sizing
        // itself to the content rather than being torn down and rebuilt on every hover.
        content.generation &+= 1
        content.thumbs = thumbs
        content.appName = appName
        content.hovered = nil
        self.appearance = placement.appearance

        let host: NSHostingView<PreviewStripView>
        if let existing = self.host {
            host = existing
        } else {
            host = NSHostingView(rootView: PreviewStripView(model: content))
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
            contentView = host
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(origin(for: size, over: tileRect, placement: placement))
        orderFrontRegardless()
        // Geometry only — where a floating panel landed is the first thing worth knowing when it
        // lands somewhere wrong, and a rect names no windows, apps or documents.
        Log.general.notice("preview strip at \(NSStringFromRect(self.frame), privacy: .public)")
    }

    /// Centres the strip on the hovered tile but places it above or below the *whole* switcher panel,
    /// so it never floats over the other tiles — which, since it takes clicks, would make them
    /// unhoverable and unclickable.
    private func origin(
        for size: CGSize, over tileRect: NSRect, placement: PanelGroup.PreviewPlacement
    ) -> NSPoint {
        let visible = placement.visibleFrame
        let switcher = placement.panelFrame
        let above = switcher.maxY + gap
        let below = switcher.minY - gap - size.height
        let roomAbove = visible.maxY - above
        let roomBelow = (switcher.minY - gap) - visible.minY

        // Prefer above, then below. When it fits in neither, anchor it into the larger gap and let
        // it run off the screen edge rather than clamping it back on — clamping drops the strip on
        // top of the switcher, which is precisely the overlap this placement exists to avoid.
        let y: CGFloat
        if size.height <= roomAbove {
            y = above
        } else if size.height <= roomBelow {
            y = below
        } else {
            y = roomAbove >= roomBelow ? above : below
        }

        let maxX = max(visible.minX, visible.maxX - size.width)
        let x = (tileRect.midX - size.width / 2).clamped(to: visible.minX...maxX)
        return NSPoint(x: x, y: y)
    }

    func dismiss() {
        orderOut(nil)
        content.hovered = nil
    }
}
