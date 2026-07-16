import AppKit
import SwiftUI

extension CGFloat {
    /// `Swift.` qualified: inside an extension on CGFloat, bare `min`/`max` resolve to the type's
    /// own static members rather than the global functions.
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}

/// Every dimension of the panel, derived from the four values the user controls in
/// Settings → Appearance so the whole thing scales and tightens as one piece.
struct Metrics: Equatable {
    /// Gap between neighbouring highlight rects. Fixed, and deliberately not zero: adjacent
    /// selections touching each other reads as one smeared blob rather than two tiles.
    static let tileGap: CGFloat = 6
    /// Kept modest — a large radius against a thin `panelPadding` bites into the corner tiles.
    static let corner: CGFloat = 16
    /// The switcher never grows past this share of the screen before it wraps to a new row.
    static let maxScreenFraction: CGFloat = 0.86
    /// The frosted border around the tiles, on every side — this is padding *inside* the glass.
    static let panelPadding: CGFloat = 10

    /// Room for two wrapped lines of 10pt title in window mode.
    private static let titleHeight: CGFloat = 26
    /// Extra width a window tile needs so titles are not shredded into three-character lines.
    private static let titleWidth: CGFloat = 38

    static let iconSizeRange: ClosedRange<CGFloat> = 32...128
    static let iconSpacingRange: ClosedRange<CGFloat> = 0...48
    static let titleSpacingRange: ClosedRange<CGFloat> = 0...28

    static let `default` = Metrics(
        iconSize: 64, iconSpacing: 18, titleSpacing: 2)

    /// Icon edge length in app mode.
    let iconSize: CGFloat
    /// Slack around each icon, inside its highlight. Sets how far apart neighbouring icons sit,
    /// and at the edges it stacks with `panelPadding` to set the distance to the glass.
    let iconSpacing: CGFloat
    /// Gap between an icon and its label: the caption in app mode, the in-tile title in window
    /// mode.
    let titleSpacing: CGFloat

    init(iconSize: CGFloat, iconSpacing: CGFloat, titleSpacing: CGFloat) {
        // Values can arrive from a hand-edited defaults plist, so clamp rather than trust.
        self.iconSize = iconSize.clamped(to: Self.iconSizeRange)
        self.iconSpacing = iconSpacing.clamped(to: Self.iconSpacingRange)
        self.titleSpacing = titleSpacing.clamped(to: Self.titleSpacingRange)
    }

    /// Window mode puts a title under the icon, so it gets a smaller icon to pay for it.
    var windowIconSize: CGFloat { (iconSize * 0.75).rounded() }

    func icon(for mode: SwitcherMode) -> CGFloat {
        mode == .windows ? windowIconSize : iconSize
    }

    func tile(for mode: SwitcherMode) -> CGSize {
        switch mode {
        case .apps:
            return CGSize(width: iconSize + iconSpacing, height: iconSize + iconSpacing)
        case .windows:
            // The title lives inside the tile here, so it has to be paid for in both axes.
            return CGSize(
                width: windowIconSize + iconSpacing + Self.titleWidth,
                height: windowIconSize + iconSpacing + titleSpacing + Self.titleHeight)
        }
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let columns: Int

    private var metrics: Metrics { model.metrics }
    private var tile: CGSize { metrics.tile(for: model.mode) }

    var body: some View {
        VStack(spacing: metrics.titleSpacing) {
            LazyVGrid(
                columns: Array(
                    repeating: GridItem(.fixed(tile.width), spacing: Metrics.tileGap),
                    count: max(columns, 1)),
                spacing: Metrics.tileGap
            ) {
                ForEach(Array(model.targets.enumerated()), id: \.element.id) { index, target in
                    TargetTile(
                        target: target,
                        size: tile,
                        iconSize: metrics.icon(for: model.mode),
                        titleSpacing: metrics.titleSpacing,
                        showsTitle: model.mode == .windows,
                        isSelected: index == model.selection,
                        number: index < 9 ? index + 1 : nil)
                }
            }
            caption
        }
        .padding(Metrics.panelPadding)
        .background(VisualEffectBackground())
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
    }

    @ViewBuilder
    private var caption: some View {
        if let selected = model.selected {
            VStack(spacing: 1) {
                Text(selected.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
                if model.mode == .windows {
                    Text(selected.appName)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: CGFloat(max(columns, 1)) * tile.width)
        }
    }
}

private struct TargetTile: View {
    let target: SwitchTarget
    let size: CGSize
    let iconSize: CGFloat
    let titleSpacing: CGFloat
    let showsTitle: Bool
    let isSelected: Bool
    /// 1–9, or nil past the ninth tile, which has no key to jump to it.
    let number: Int?

    var body: some View {
        VStack(spacing: titleSpacing) {
            icon
            if showsTitle {
                Text(target.title)
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: size.width - 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.16 : 0))
        }
    }

    /// Both badges hang off the icon rather than the tile. The tile grows and shrinks with the
    /// icon spacing slider, so a badge pinned to *its* corner would drift away from the artwork
    /// as that changes; pinned to the icon, it stays on the corner at every setting.
    ///
    /// The status badge takes bottom-leading because the number owns bottom-trailing.
    @ViewBuilder
    private var icon: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let image = target.icon {
                    Image(nsImage: image).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
            .frame(width: iconSize, height: iconSize)
            // Dim the icon when the window is not actually on screen right now.
            .opacity(target.isMinimized || target.isHidden ? 0.45 : 1)

            if target.isMinimized {
                Badge(symbol: "minus")
            } else if target.isHidden {
                Badge(symbol: "eye.slash.fill")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let number {
                // Lifted up the icon's trailing edge rather than left hanging off the corner.
                NumberBadge(number: number)
                    .offset(x: 4, y: 4)
            }
        }
    }
}

private struct Badge: View {
    let symbol: String

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 7, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(Color.accentColor))
            .overlay(Circle().strokeBorder(Color.black.opacity(0.25), lineWidth: 0.5))
    }
}

/// The ⌘-number shortcut for a tile. Deliberately quiet — it is a hint, not a decoration, and
/// there is one on every tile at once.
private struct NumberBadge: View {
    /// #b7b7b7 on #000000. Fixed rather than semantic: the badge sits on top of app artwork of
    /// every possible colour, not on the panel, so it cannot follow the light/dark appearance.
    private static let foreground = Color(red: 183 / 255, green: 183 / 255, blue: 183 / 255)
    private static let background = Color(red: 0, green: 0, blue: 0)

    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(Self.foreground)
            .frame(width: 25, height: 25)
            .background(Circle().fill(Self.background))
    }
}

/// Not private: the settings preview renders against the same glass, so what the user tunes is
/// what they get.
struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .hudWindow
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
