import AppKit
import SwiftUI

// The on-demand full-size preview: Space, with no query live, floats one large live capture of the
// highlighted tile's window — Finder's Quick Look gesture, aimed at the switcher.
//
// The hover strip answers "which of this app's windows is which" with a row of thumbnails; at that
// size a window is recognisable and not readable. This answers "is this the one I mean" — one
// window, drawn big enough to actually read — before committing to it. Space toggles it, Space
// again or Escape takes it down, and moving the highlight re-points it, so cycling with the
// preview up reads the way flicking through files in Quick Look does.
//
// It reuses the strip's capture pipeline (`WindowCapture`), so everything that machinery already
// solved — Screen Recording degradation, the phantom-window veto, minimized windows capturing
// blank — holds here without a second implementation. Like every capture feature it is off by
// default and its toggle is what prompts for Screen Recording.

/// What the preview panel draws, observed so the hosting view is built once and reused.
@MainActor
private final class QuickPreviewModel: ObservableObject {
    @Published var image: NSImage?
    @Published var title: String = ""
    /// Whether `image` is real window pixels. An icon stand-in (a minimized window, mostly) is
    /// drawn at icon size rather than blown up to the ceiling.
    @Published var hasCapture = true
    /// The largest the capture may draw, from the screen the panel is placed on.
    @Published var maxSize = CGSize(width: 800, height: 600)
}

private struct QuickPreviewContentView: View {
    @ObservedObject var model: QuickPreviewModel

    var body: some View {
        VStack(spacing: 8) {
            if let image = model.image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(
                        maxWidth: model.hasCapture ? model.maxSize.width : 128,
                        maxHeight: model.hasCapture ? model.maxSize.height : 128)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Text(model.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: model.hasCapture ? model.maxSize.width : 240)
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .fixedSize()
    }
}

/// The panel itself: borderless, non-activating, and — unlike the strip — deaf to the mouse. It is
/// a picture, not a control; the tile it previews is still the thing to click.
private final class QuickPreviewPanel: NSPanel {
    fileprivate let model = QuickPreviewModel()
    private var host: NSHostingView<QuickPreviewContentView>?

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
        ignoresMouseEvents = true
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func present(appearance: NSAppearance?, panelFrame: NSRect, visibleFrame: NSRect) {
        self.appearance = appearance
        let host: NSHostingView<QuickPreviewContentView>
        if let existing = self.host {
            host = existing
        } else {
            host = NSHostingView(rootView: QuickPreviewContentView(model: model))
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
            contentView = host
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(
            QuickPreview.origin(for: size, above: panelFrame, in: visibleFrame))
        restoreAllSpaces("quick preview")
        orderFrontRegardless()
    }
}

/// Owns the full-size preview: the toggle, the capture in flight, and following the highlight
/// while it is up. Shaped like `PreviewCoordinator`, and kept out of `SwitcherController` for the
/// same reason — none of this belongs next to the tap's "stay cheap" rule.
@MainActor
final class QuickPreview {
    /// Mirrors the Behavior setting. Off means Space types into the filter as it always did.
    var isEnabled = false

    /// Per-window rules, mirrored from the controller like the strip's — a window a rule hides
    /// must not become visible by being previewed.
    var titleRules: [CompiledTitleRule] = []

    private let panel = QuickPreviewPanel()
    private unowned let switcher: PanelGroup
    /// Whether a session is still open — a capture landing after the switcher went must not draw.
    private let isActive: () -> Bool

    private var captureTask: Task<Void, Never>?
    /// The follow-the-highlight debounce, so cycling quickly re-captures once, for the tile the
    /// highlight stops on — the same constant, and the same argument, as the hover strip's.
    private var updateWork: DispatchWorkItem?
    private let updateDelay: TimeInterval = 0.28

    /// Whether preview mode is on — what Space toggles against. It can be on with nothing drawn:
    /// while a capture is in flight, or while the highlight sits on a tile with nothing to capture.
    private(set) var isShowing = false

    /// Whether a preview is actually on screen — what lets Escape take the preview down before it
    /// takes the session. Not `isShowing`: an Escape that dismissed an invisible preview would read
    /// as the key doing nothing.
    var isOnScreen: Bool { isShowing && panel.isVisible }

    init(switcher: PanelGroup, isActive: @escaping () -> Bool) {
        self.switcher = switcher
        self.isActive = isActive
    }

    /// Space: shows the highlighted tile's preview, or takes it down if it is already up.
    func toggle(for target: SwitchTarget?) {
        if isShowing {
            dismiss()
        } else if let target, !target.isLaunchable {
            // Only a tile that can be captured turns the preview on. A launch tile has nothing to
            // draw, and a flag set with nothing on screen swallows the next Escape.
            isShowing = true
            capture(target, following: false)
        }
    }

    /// The highlight moved. Re-points an open preview after the debounce; does nothing otherwise,
    /// so a session that never pressed Space never captures.
    func selectionChanged(_ target: SwitchTarget?) {
        guard isShowing else { return }
        updateWork?.cancel()
        guard let target else { return }
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.isShowing else { return }
                self.capture(target, following: true)
            }
        }
        updateWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + updateDelay, execute: work)
    }

    /// Ends everything at once — Space again, Escape, or the session closing.
    func dismiss() {
        isShowing = false
        updateWork?.cancel()
        updateWork = nil
        captureTask?.cancel()
        captureTask = nil
        panel.orderOut(nil)
        // The last capture is a full-size bitmap, several MB; the panel is reused, so without this
        // it would stay resident for the life of the process.
        panel.model.image = nil
        panel.model.title = ""
    }

    /// The thumbnail to draw for a tile: its own window when the tile names one the capture found,
    /// else the frontmost — which is the right reading for an app tile, and the fallback for a
    /// window whose id could not be resolved (Electron and Catalyst hosts). A real id the capture
    /// did not find gets nothing rather than another window: showing a neighbour's title while
    /// this one is highlighted is worse than showing no preview. Pure, so the rule is testable
    /// without ScreenCaptureKit.
    nonisolated static func pick(_ thumbs: [WindowThumb], windowID: CGWindowID?) -> WindowThumb? {
        guard let windowID, windowID != 0 else { return thumbs.first }
        return thumbs.first { $0.windowID == windowID }
    }

    /// Where the panel sits: centred in the band between the switcher and the top of the screen
    /// when the content fits there — the strip's own neighbourhood, so the tiles stay visible —
    /// else centred on the screen outright, Quick Look's answer for content too big to share the
    /// stage. Pure for the same reason every other placement rule here is.
    nonisolated static func origin(
        for size: CGSize, above panelFrame: NSRect, in visibleFrame: NSRect
    ) -> NSPoint {
        let gap: CGFloat = 12
        // The left edge wins when the content is wider than the screen, like the bottom does below:
        // the start of a picture is the part worth seeing.
        let x = max(
            min(visibleFrame.midX - size.width / 2, visibleFrame.maxX - size.width),
            visibleFrame.minX)
        let band = visibleFrame.maxY - panelFrame.maxY - gap * 2
        if size.height <= band {
            return NSPoint(
                x: x, y: panelFrame.maxY + gap + (band - size.height) / 2)
        }
        return NSPoint(
            x: x,
            y: max(
                visibleFrame.minY,
                visibleFrame.midY - size.height / 2))
    }

    /// `following` is the highlight moving under an open preview rather than the Space that opened
    /// it, which decides what an empty capture means — see the `pick` guard below.
    private func capture(_ target: SwitchTarget, following: Bool) {
        // Nothing running, nothing to capture — a launch or fallback tile keeps whatever was up
        // rather than flashing an empty panel.
        guard !target.isLaunchable else { return }
        captureTask?.cancel()
        let pid = target.pid
        let windowID = target.windowID
        let bundleID = target.bundleID
        let titleRules = self.titleRules
        // Sized against the display the highlighted tile is on, read before the await for the same
        // reason the strip reads placement after it: the size decides the capture's resolution and
        // must exist now; where the panel lands is re-read once the capture is back.
        let ceiling = switcher.selectedTilePlacement()?.placement.visibleFrame.height ?? 900
        captureTask = Task { [weak self] in
            let thumbs = await WindowCapture.shared.thumbnails(
                for: pid, bundleID: bundleID, titleRules: titleRules,
                only: windowID.flatMap { $0 == 0 ? nil : $0 },
                maxCount: 1, maxHeight: ceiling * 0.7)
            guard !Task.isCancelled, let self, self.isActive(), self.isShowing else { return }
            guard let thumb = Self.pick(thumbs, windowID: windowID) else {
                // An app with nothing capturable — Screen Recording withheld, or every window
                // gone. Leave nothing on screen claiming otherwise. The Space that opened the
                // preview found nothing, so it ends; the highlight merely passing over such a tile
                // only hides the picture, and the next capturable tile brings it back — ending the
                // mode there would make one uncapturable window cost the user another Space.
                // Escape stays honest either way: it reads `isOnScreen`, not `isShowing`.
                if following {
                    self.panel.orderOut(nil)
                } else {
                    self.dismiss()
                }
                return
            }
            guard let placement = self.switcher.selectedTilePlacement()?.placement else { return }
            let visible = placement.visibleFrame
            self.panel.model.image = thumb.image
            self.panel.model.title = thumb.title
            self.panel.model.hasCapture = thumb.hasCapture
            self.panel.model.maxSize = CGSize(
                width: visible.width * 0.8, height: visible.height * 0.7)
            self.panel.present(
                appearance: placement.appearance,
                panelFrame: placement.panelFrame, visibleFrame: visible)
        }
    }
}
