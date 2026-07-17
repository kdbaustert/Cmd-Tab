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
        guard Permissions.canCaptureScreen else { return [] }
        guard let content = await shareableContent() else { return [] }

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
        let order = switchableIDs(for: pid)
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
                    guard let image = try? await Self.capture(window, maxHeight: maxHeight),
                        !Self.isBlank(image)
                    else { return (index, nil) }
                    let size = NSSize(width: image.width, height: image.height)
                    return (
                        index,
                        WindowThumb(
                            id: window.windowID, image: NSImage(cgImage: image, size: size),
                            title: window.title ?? ""))
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
    private func switchableIDs(for pid: pid_t) -> [CGWindowID] {
        if let entry = idCache[pid], Date().timeIntervalSince(entry.at) < ttl { return entry.ids }
        let ids = TargetProvider.switchableWindowIDs(for: pid)
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
        guard
            let ctx = CGContext(
                data: &data, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: space,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return false }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
        var opaque = 0
        for i in stride(from: 3, to: data.count, by: 4) where data[i] > 8 { opaque += 1 }
        // Real windows fill almost the whole frame; a transparent phantom leaves it near-empty.
        return opaque < (side * side) / 10
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
}

private struct WindowPreviewView: View {
    @ObservedObject var model: WindowPreviewModel

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
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { thumb in
                            thumbnail(thumb)
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
    }

    @ViewBuilder
    private func thumbnail(_ thumb: WindowThumb) -> some View {
        VStack(spacing: 4) {
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            if !thumb.title.isEmpty {
                Text(thumb.title)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
        }
    }
}

/// A small non-activating panel that floats a strip of window thumbnails next to the hovered tile.
/// Purely informational — it never takes the mouse or keyboard, so it cannot become the switch
/// target the way the tile behind it can.
@MainActor
final class WindowPreviewPanel: NSPanel {
    private let content = WindowPreviewModel()
    private var host: NSHostingView<WindowPreviewView>?
    /// Gap between the hovered tile and the preview strip.
    private let gap: CGFloat = 10

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
        ignoresMouseEvents = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows `thumbs` for `appName`, centred over `tileRect` (screen coordinates) and preferring the
    /// space above it, dropping below when there is no room. Matches the switcher's forced appearance.
    func present(
        thumbs: [WindowThumb], appName: String, over tileRect: NSRect, appearance: NSAppearance?
    ) {
        // Drive the content through the observed model; the hosting view is built once and reused,
        // its intrinsic-size sizing tracking the model rather than being rebuilt each hover.
        content.thumbs = thumbs
        content.appName = appName
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
        var x = tileRect.midX - size.width / 2
        var y = tileRect.maxY + gap  // above the tile
        if y + size.height > visible.maxY { y = tileRect.minY - gap - size.height }  // else below
        let maxX = max(visible.minX, visible.maxX - size.width)
        x = x.clamped(to: visible.minX...maxX)
        y = max(visible.minY, y)

        setFrameOrigin(NSPoint(x: x, y: y))
        orderFrontRegardless()
    }

    func dismiss() { orderOut(nil) }
}
