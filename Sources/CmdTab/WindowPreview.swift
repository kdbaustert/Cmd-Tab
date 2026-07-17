import AppKit
import ScreenCaptureKit
import SwiftUI

/// A live thumbnail of one on-screen window, captured for the hover preview.
struct WindowThumb: Identifiable {
    let id: CGWindowID
    let image: NSImage
    let title: String
}

/// Captures thumbnails of an app's windows through ScreenCaptureKit. This is the only place in the
/// app that touches Screen Recording — the switcher itself reads pids and titles over Accessibility
/// and never needs it.
enum WindowCapture {
    /// Live thumbnails of the standard-layer windows owned by `pid`. Returns an empty list if Screen
    /// Recording is not granted or the app has nothing capturable.
    static func thumbnails(for pid: pid_t, maxCount: Int = 12, maxHeight: CGFloat = 150) async
        -> [WindowThumb]
    {
        guard Permissions.canCaptureScreen else { return [] }
        // On-screen windows only: a window on another Space or minimized has no live surface, so it
        // would only ever capture blank.
        guard
            let content = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: true)
        else { return [] }

        let appWindows = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0
        }

        // Prefer the switcher's own window set (via Accessibility): it is exactly what window mode
        // shows, with the Electron/Catalyst phantom windows already filtered out, so no capture ever
        // comes back empty. Only when window ids can't be resolved do we fall back to a size filter
        // plus the blank-content check.
        let ids = TargetProvider.switchableWindowIDs(for: pid)
        let usingBlankFilter = ids.isEmpty
        let windows =
            (ids.isEmpty
            ? appWindows.filter { $0.frame.width > 40 && $0.frame.height > 40 }
            : appWindows.filter { ids.contains($0.windowID) })
            .prefix(maxCount)

        var thumbs: [WindowThumb] = []
        for window in windows {
            guard let image = try? await capture(window, maxHeight: maxHeight) else { continue }
            if usingBlankFilter && isBlank(image) { continue }
            let size = NSSize(width: image.width, height: image.height)
            thumbs.append(
                WindowThumb(id: window.windowID, image: NSImage(cgImage: image, size: size),
                    title: window.title ?? ""))
        }
        return thumbs
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
        content.thumbs = thumbs
        content.appName = appName
        self.appearance = appearance

        let view = WindowPreviewView(model: content)
        if let host {
            host.rootView = view
        } else {
            let host = NSHostingView(rootView: view)
            self.host = host
            contentView = host
        }
        guard let host else { return }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)

        let screen =
            NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }
            ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame

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
