import AppKit
import ScreenCaptureKit
import SwiftUI

extension NSScreen {
    /// The screen under the cursor, falling back to the main screen then the first attached one.
    static var underCursor: NSScreen {
        let mouse = NSEvent.mouseLocation
        return screens.first { NSMouseInRect(mouse, $0.frame, false) } ?? main ?? screens[0]
    }
}

/// A live thumbnail of one on-screen window, captured for the hover preview.
struct WindowThumb: Identifiable {
    let id: CGWindowID
    let image: NSImage
    let title: String
    /// The owning app's pid, so a clicked thumbnail can be raised and activated.
    let pid: pid_t
}

/// Captures thumbnails of an app's windows through ScreenCaptureKit. This is the only place in the
/// app that touches Screen Recording — the switcher itself reads pids and titles over Accessibility
/// and never needs it.
///
/// An actor so the short-lived caches below are touched from one place at a time: hovers arrive off
/// the main thread and can overlap, and the caches spare repeated system-wide window enumeration and
/// per-app Accessibility round-trips when the cursor sweeps across tiles.
actor WindowCapture {
    static let shared = WindowCapture()

    private var cachedContent: SCShareableContent?
    private var contentFetchedAt: Date?
    private var idCache: [pid_t: (ids: [CGWindowID], at: Date)] = [:]
    /// How long a fetched window list / id set may be reused before it is refetched.
    private let ttl: TimeInterval = 0.75

    /// Live thumbnails of the standard-layer windows owned by `pid`, ordered to match window mode.
    /// Returns an empty list if Screen Recording is not granted or the app has nothing capturable.
    func thumbnails(for pid: pid_t, maxCount: Int = 12, maxHeight: CGFloat = 150) async
        -> [WindowThumb]
    {
        guard !Task.isCancelled else { return [] }
        guard Permissions.canCaptureScreen else { return [] }
        guard let content = await shareableContent() else { return [] }
        // `shareableContent()` suspends on a system-wide enumeration; a hover that moved on while it
        // was in flight should not go on to spend a dozen GPU captures on a tile nobody is over.
        guard !Task.isCancelled else { return [] }

        // Standard-layer windows of this app, across every Space. `onScreenWindowsOnly: false` is
        // deliberate — a window on another Space still captures its real backing surface, so limiting
        // to the current Space would silently drop every window of an app the user isn't looking at.
        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        }

        // Prefer the switcher's own window set and order (via Accessibility), which matches window
        // mode. Fall back to a size filter when the ids can't be resolved or don't line up with the
        // captured windows. Either way, a blank capture is dropped below — that is what removes the
        // Electron/Catalyst phantom backing windows those apps expose (a hidden, transparent window).
        let order = await switchableIDs(for: pid)
        // `switchableIDs` can itself sit through the full AX timeout against a beach-balling app
        // (see its doc comment); worth re-checking before committing to a round of captures.
        guard !Task.isCancelled else { return [] }
        let rank = Dictionary(order.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        var windows = appWindows.filter { rank[$0.windowID] != nil }
        if windows.isEmpty {
            windows = appWindows.filter { $0.frame.width > 40 && $0.frame.height > 40 }
        } else {
            windows.sort { (rank[$0.windowID] ?? .max) < (rank[$1.windowID] ?? .max) }
        }
        let selected = Array(windows.prefix(maxCount))

        // Each capture is an independent GPU round-trip; run them concurrently, then restore order.
        let captured = await withTaskGroup(of: (Int, WindowThumb?).self) { group in
            for (index, window) in selected.enumerated() {
                group.addTask {
                    // Child tasks inherit cancellation from this method's `Task`; a capture still
                    // queued when the hover moves on should never start.
                    guard !Task.isCancelled else { return (index, nil) }
                    guard let image = try? await Self.capture(window, maxHeight: maxHeight),
                        !Self.isBlank(image)
                    else { return (index, nil) }
                    let size = NSSize(width: image.width, height: image.height)
                    return (
                        index,
                        WindowThumb(
                            id: window.windowID, image: NSImage(cgImage: image, size: size),
                            title: window.title ?? "", pid: pid))
                }
            }
            var out: [(Int, WindowThumb)] = []
            for await result in group where result.1 != nil {
                out.append((result.0, result.1!))
            }
            return out
        }
        return captured.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// The full window list, reused for `ttl` so a sweep across tiles doesn't re-run the whole
    /// system-wide enumeration for each one.
    private func shareableContent() async -> SCShareableContent? {
        if let cachedContent, let contentFetchedAt, Date().timeIntervalSince(contentFetchedAt) < ttl
        {
            return cachedContent
        }
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
        else { return nil }
        cachedContent = content
        contentFetchedAt = Date()
        return content
    }

    /// The app's switchable window ids (ordered), cached for `ttl` to spare the Accessibility
    /// round-trips when the same app tile is revisited.
    ///
    /// The AX work runs off the actor. `TargetProvider.switchableWindowIDs` is synchronous and does
    /// two `AXUIElementCopyAttributeValue` round-trips per window, each of which can burn the full
    /// AX timeout against a beach-balling app — several seconds for an app with a dozen windows.
    /// Run inline it would hold the actor with no suspension point, so every other hover queues
    /// behind one wedged app and the previews stop appearing entirely until it clears.
    private func switchableIDs(for pid: pid_t) async -> [CGWindowID] {
        if let entry = idCache[pid], Date().timeIntervalSince(entry.at) < ttl { return entry.ids }
        let ids = await Task.detached { TargetProvider.switchableWindowIDs(for: pid) }.value
        idCache[pid] = (ids, Date())
        return ids
    }

    /// True when a capture is essentially empty — nearly every pixel transparent. Downsamples to a
    /// small grid and counts pixels carrying any alpha, which cleanly separates a real (opaque)
    /// window from a hidden helper window's transparent surface.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        // Create, draw, and read entirely inside the closure. Passing `&data` to `CGContext` would
        // be an inout-to-pointer conversion, which is only guaranteed valid for the duration of the
        // initializer call itself — but the context keeps the pointer and writes through it during
        // `draw`, after that call has returned. The compiler is free to hand over a temporary
        // buffer and copy back, in which case `draw` scribbles on freed memory and the alpha scan
        // reads uninitialized bytes, making the blank/not-blank verdict arbitrary.
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
            // Real windows fill almost the whole frame; a transparent phantom leaves it near-empty.
            return opaque < (side * side) / 10
        }
    }

    private static func capture(_ window: SCWindow, maxHeight: CGFloat) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Render straight to thumbnail size rather than capturing full-res and scaling afterwards.
        let scale = min(1, maxHeight / max(window.frame.height, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }
}

/// Backing store for the preview panel's SwiftUI content.
@MainActor
final class WindowPreviewModel: ObservableObject {
    @Published var thumbs: [WindowThumb] = []
    /// The app whose windows are shown, as a heading over the strip.
    @Published var appName: String = ""
    /// The keyboard-selected thumbnail, or nil while the strip is a passive hover preview.
    ///
    /// Nil and 0 are meaningfully different here: the strip appears on hover with nothing selected,
    /// and only takes a selection once the user presses ↓ to steer it with the keyboard. Highlighting
    /// the first window merely because the strip is visible would suggest Return picks it.
    @Published var selection: Int?
    /// Each thumbnail's frame in the panel's content coordinates (top-left origin), reported by the
    /// view so the panel can hit-test a click against it. Not `@Published` — it only feeds the panel.
    var thumbFrames: [CGWindowID: CGRect] = [:]
}

/// Reports each thumbnail's laid-out frame up to the panel for click hit-testing.
private struct ThumbFrameKey: PreferenceKey {
    static let defaultValue: [CGWindowID: CGRect] = [:]
    static func reduce(
        value: inout [CGWindowID: CGRect], nextValue: () -> [CGWindowID: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

private struct WindowPreviewView: View {
    @ObservedObject var model: WindowPreviewModel

    /// Name of the coordinate space the reported thumbnail frames are measured in — the panel's
    /// content, so a screen click maps straight onto them after flipping.
    static let space = "windowPreview"

    /// How many thumbnails sit in a row before wrapping, so a many-window app grows downward rather
    /// than off the side of the screen.
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
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIndex, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(Array(row.enumerated()), id: \.element.id) { column, thumb in
                            thumbnail(thumb, index: rowIndex * Self.perRow + column)
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
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1))
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ThumbFrameKey.self) { model.thumbFrames = $0 }
    }

    @ViewBuilder
    private func thumbnail(_ thumb: WindowThumb, index: Int) -> some View {
        let isSelected = model.selection == index
        VStack(spacing: 4) {
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(
                            isSelected ? Color.accentColor : Color.primary.opacity(0.15),
                            lineWidth: isSelected ? 3 : 1))
            if !thumb.title.isEmpty {
                Text(thumb.title)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
        }
        // Report the whole cell's frame (image + title) so a click anywhere on it selects the window.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ThumbFrameKey.self,
                    value: [thumb.id: geo.frame(in: .named(Self.space))])
            })
    }
}

/// A small non-activating panel that floats a strip of window thumbnails next to the hovered tile.
/// It never takes the keyboard or becomes key, but a click on a thumbnail is turned into a pick, the
/// same way the switcher panel handles a tile click.
@MainActor
final class WindowPreviewPanel: NSPanel {
    private let content = WindowPreviewModel()
    private var host: NSHostingView<WindowPreviewView>?
    /// Gap between the hovered tile and the preview strip.
    private let gap: CGFloat = 10

    /// Invoked when a thumbnail is clicked. The controller focuses that window and dismisses.
    var onPick: ((WindowThumb) -> Void)?
    /// A scroll that landed on the preview instead of the switcher — forwarded so scroll-to-navigate
    /// keeps working (the switcher's global scroll monitor can't see events delivered to our panel).
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

    // MARK: - Keyboard selection

    /// Whether there is anything to steer with the keyboard.
    var hasThumbs: Bool { !content.thumbs.isEmpty }

    /// The keyboard-selected window, if the strip is being steered.
    var selectedThumb: WindowThumb? {
        guard let index = content.selection, content.thumbs.indices.contains(index) else {
            return nil
        }
        return content.thumbs[index]
    }

    /// Takes keyboard control of the strip, landing on the first window. No-op with nothing to show,
    /// so the caller can offer the gesture unconditionally and let it decline.
    @discardableResult
    func beginKeyboardSelection() -> Bool {
        guard hasThumbs else { return false }
        content.selection = 0
        return true
    }

    func endKeyboardSelection() { content.selection = nil }

    /// Moves the keyboard selection, wrapping like the switcher's own tile navigation does.
    func moveSelection(_ delta: Int) {
        guard hasThumbs, let current = content.selection else { return }
        let count = content.thumbs.count
        content.selection = (current + delta + count) % count
    }

    /// A non-activating panel receives clicks without bringing our app forward, so a click on a
    /// thumbnail becomes a pick — like the switcher panel, and for the same reason (never key, so
    /// SwiftUI's own gesture recognisers stay dormant).
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let thumb = thumb(at: NSEvent.mouseLocation) {
                onPick?(thumb)
                return
            }
        case .scrollWheel:
            // Forward to the switcher rather than swallowing it, so scrolling over the strip still
            // moves the selection.
            onScroll?(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// The thumbnail under a screen point, using the frames the view reported in content coordinates.
    private func thumb(at screenPoint: NSPoint) -> WindowThumb? {
        // Content coordinates are top-left origin; flip the bottom-up screen point into them.
        let point = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        guard let id = content.thumbFrames.first(where: { $0.value.contains(point) })?.key
        else { return nil }
        return content.thumbs.first { $0.id == id }
    }

    /// Whether the panel is up and the point is within it — used by hover tracking to keep the
    /// preview alive while the cursor is over it (so its thumbnails can be reached and clicked).
    func isShowing(_ screenPoint: NSPoint) -> Bool {
        isVisible && frame.contains(screenPoint)
    }

    /// Shows `thumbs` for `appName`, centred over `tileRect` (screen coordinates) and preferring the
    /// space above it, dropping below when there is no room. Matches the switcher's forced appearance.
    func present(
        thumbs: [WindowThumb], appName: String, over tileRect: NSRect, clearOf switcherFrame: NSRect,
        appearance: NSAppearance?
    ) {
        // Drive the content through the observed model; the hosting view is built once and reused,
        // its intrinsic-size sizing tracking the model rather than being rebuilt each hover.
        content.thumbs = thumbs
        content.appName = appName
        // A fresh set of windows invalidates any keyboard selection — index 2 of the last app's
        // strip means nothing here. The coordinator re-enters it if the user is still steering.
        content.selection = nil
        self.appearance = appearance

        let host: NSHostingView<WindowPreviewView>
        if let existing = self.host {
            host = existing
        } else {
            host = NSHostingView(rootView: WindowPreviewView(model: content))
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
            contentView = host
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)

        let visible = NSScreen.underCursor.visibleFrame
        // Centre horizontally on the hovered tile, but sit above/below the *whole* switcher panel so
        // the strip never floats over other tiles (which — now that it takes clicks — would make
        // those tiles unhoverable and unclickable).
        var x = tileRect.midX - size.width / 2
        let above = switcherFrame.maxY + gap
        let below = switcherFrame.minY - gap - size.height
        let roomAbove = visible.maxY - above
        let roomBelow = (switcherFrame.minY - gap) - visible.minY
        // Prefer above, then below. When the strip fits in neither gap, anchor it into the larger
        // one and let it run off the screen edge rather than clamping it back on-screen — the old
        // `max(visible.minY, y)` did exactly that and dropped the strip on top of the switcher,
        // which (since the strip takes clicks and reports `.overPreview` for any point inside it)
        // made the tiles underneath unhoverable and unclickable. That is the precise failure this
        // placement exists to prevent, so overflowing the screen edge is the better trade.
        var y: CGFloat
        if size.height <= roomAbove {
            y = above
        } else if size.height <= roomBelow {
            y = below
        } else {
            y = roomAbove >= roomBelow ? above : below
        }
        let maxX = max(visible.minX, visible.maxX - size.width)
        x = x.clamped(to: visible.minX...maxX)

        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }
}
