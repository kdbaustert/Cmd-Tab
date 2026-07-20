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
        iconSize: 88, iconSpacing: 2, titleSpacing: 2)

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

    /// `showsTitle` only matters in app mode — window mode always carries a title. When app tiles
    /// gain a title they are paid for exactly like window tiles are.
    func tile(for mode: SwitcherMode, showsTitle: Bool = false) -> CGSize {
        switch mode {
        case .apps:
            if showsTitle {
                return CGSize(
                    width: iconSize + iconSpacing + Self.titleWidth,
                    height: iconSize + iconSpacing + titleSpacing + Self.titleHeight)
            }
            return CGSize(width: iconSize + iconSpacing, height: iconSize + iconSpacing)
        case .windows:
            // The title lives inside the tile here, so it has to be paid for in both axes.
            return CGSize(
                width: windowIconSize + iconSpacing + Self.titleWidth,
                height: windowIconSize + iconSpacing + titleSpacing + Self.titleHeight)
        }
    }
}

/// Reports each tile's laid-out frame up to the panel for cursor hit-testing.
///
/// The panel used to re-derive tile positions from the grid's own parameters — padding, gap, column
/// stride, reading order. That duplicated the layout in a second place that no compiler checks, and
/// it broke every time the view gained a sibling: a long filter query made the search bar the widest
/// child, SwiftUI centred the narrower grid inside the wider panel, and the arithmetic — still
/// assuming the grid started at the panel's padding inset — silently mapped clicks onto the
/// neighbouring app. Letting the tiles report where they actually ended up removes the whole class.
private struct TileFrameKey: PreferenceKey {
    static let defaultValue: [Int: CGRect] = [:]
    static func reduce(value: inout [Int: CGRect], nextValue: () -> [Int: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

struct SwitcherView: View {
    @ObservedObject var model: SwitcherModel
    let columns: Int
    /// Where this instance reports its tile geometry.
    ///
    /// Per-instance rather than written onto the shared model, because mirroring puts one of these
    /// views on every display at once. They share a model but each has its own coordinate space, so
    /// a single shared map would have them overwriting each other's frames and hit-testing against
    /// whichever display reported last.
    let onTileFrames: ([Int: CGRect]) -> Void

    /// Name of the coordinate space tile frames are measured in — the panel's content, so a screen
    /// point maps straight onto them after flipping.
    static let space = "switcherContent"

    private var metrics: Metrics { model.metrics }
    private var tile: CGSize { metrics.tile(for: model.mode, showsTitle: model.showsTitle) }

    var body: some View {
        VStack(spacing: metrics.titleSpacing) {
            if model.targets.isEmpty {
                noMatches
            } else {
                grid
                caption
            }
            if !model.query.isEmpty { searchBar }
        }
        .padding(Metrics.panelPadding)
        .background(
            VisualEffectBackground(material: model.material.nsMaterial, blurRadius: model.blurRadius))
        .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .opacity(model.opacity)
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(TileFrameKey.self) { onTileFrames($0) }
    }

    private var grid: some View {
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
                    showsTitle: model.showsTitle,
                    isSelected: index == model.selection,
                    highlightColor: model.highlightColor,
                    corner: model.tileCorner,
                    titleFontSize: model.titleFontSize,
                    // The ⌘-number jump is disabled while filtering (digits type into the query),
                    // so the badges come off too.
                    number: model.showNumbers && model.query.isEmpty && index < 9 ? index + 1 : nil)
                    .background(
                        GeometryReader { geo in
                            Color.clear.preference(
                                key: TileFrameKey.self,
                                value: [index: geo.frame(in: .named(SwitcherView.space))])
                        })
            }
        }
    }

    /// The live type-to-filter query, shown only while one is being typed.
    private var searchBar: some View {
        HStack(spacing: 5) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
            Text(model.query)
                .font(.system(size: 12, weight: .medium))
        }
        .foregroundStyle(.secondary)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.primary.opacity(0.08)))
        // Clamped to the grid's width for the same reason `caption` is: a long query against a
        // one- or two-match list would otherwise be the widest child and stretch the panel around
        // it. Purely cosmetic now — hit-testing reads the frames the tiles report, so an off-centre
        // grid is no longer a correctness problem, just an ugly one.
        .frame(maxWidth: CGFloat(max(columns, 1)) * tile.width)
    }

    private var noMatches: some View {
        Text("No matches")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
            .frame(minWidth: 140)
    }

    @ViewBuilder
    private var caption: some View {
        if let selected = model.selected {
            // The caption is the selected window/application title, so the "Title size" setting
            // drives it. Offset from the slider value (default 10) so the defaults still land on
            // the original 13pt title / 11pt subtitle.
            VStack(spacing: 1) {
                Text(selected.title)
                    .font(.system(size: model.titleFontSize + 3, weight: .semibold))
                    .lineLimit(1)
                if model.mode == .windows {
                    Text(selected.appName)
                        .font(.system(size: model.titleFontSize + 1))
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
    let highlightColor: Color
    let corner: CGFloat
    let titleFontSize: CGFloat
    /// 1–9, or nil past the ninth tile, which has no key to jump to it.
    let number: Int?

    var body: some View {
        VStack(spacing: titleSpacing) {
            icon
            if showsTitle {
                Text(target.title)
                    .font(.system(size: titleFontSize))
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: size.width - 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .background {
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .fill(highlightColor.opacity(isSelected ? 0.30 : 0))
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
            // Dim the icon when the window is not actually on screen right now — or, for a favourite,
            // when it isn't running yet.
            .opacity(target.isMinimized || target.isHidden ? 0.45 : (target.isLaunchable ? 0.6 : 1))

            if target.isMinimized {
                Badge(symbol: "minus")
            } else if target.isHidden {
                Badge(symbol: "eye.slash.fill")
            } else if target.isLaunchable {
                Badge(symbol: "arrow.up.forward")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if let number {
                // Lifted up the icon's trailing edge rather than left hanging off the corner.
                NumberBadge(number: number)
                    .offset(x: -1, y: -1)
            }
        }
        .overlay(alignment: .topTrailing) {
            // Stacked rather than side by side: a window can carry both, and the tile is too narrow
            // to put them in a row without crowding the icon.
            VStack(alignment: .trailing, spacing: 1) {
                if let display = target.displayIndex {
                    DisplayBadge(number: display + 1)  // 1-based for humans
                }
                if let space = target.spaceIndex {
                    SpaceBadge(number: space + 1)
                }
            }
        }
    }
}

/// Marks which Space a window is on, shown only in window mode with more than one Space.
private struct SpaceBadge: View {
    let number: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "square.on.square")
            Text("\(number)")
        }
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 3)
        .frame(height: 14)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}

/// Marks which display a window is on, shown only in window mode with more than one display.
private struct DisplayBadge: View {
    let number: Int

    var body: some View {
        HStack(spacing: 1) {
            Image(systemName: "display")
            Text("\(number)")
        }
        .font(.system(size: 7, weight: .bold))
        .foregroundStyle(.white)
        .padding(.horizontal, 3)
        .frame(height: 14)
        .background(Capsule().fill(Color.black.opacity(0.55)))
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
    var material: NSVisualEffectView.Material = .hudWindow
    /// nil keeps the material's built-in blur; a value retunes the glass's blur radius.
    var blurRadius: Double?

    func makeNSView(context: Context) -> BlurVisualEffectView {
        let view = BlurVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        view.overrideBlurRadius = blurRadius
        return view
    }

    func updateNSView(_ view: BlurVisualEffectView, context: Context) {
        view.material = material
        view.overrideBlurRadius = blurRadius
    }
}

/// `NSVisualEffectView` bakes a fixed blur into each material. It draws the glass on a private
/// backdrop sublayer whose existing Gaussian-blur filter carries an `inputRadius`; retuning that
/// value changes the blur amount. Best-effort — if the private layer is ever restructured, the
/// material's own blur simply stands, and nothing breaks.
final class BlurVisualEffectView: NSVisualEffectView {
    var overrideBlurRadius: Double? {
        didSet { applyBlurOverride() }
    }
    /// The filter's natural `inputRadius`, captured before the first override so it can be restored
    /// when the override is cleared — otherwise the last custom value would stick.
    private var naturalRadius: Double?

    override func updateLayer() {
        super.updateLayer()
        applyBlurOverride()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        applyBlurOverride()
    }

    private func applyBlurOverride() {
        for sublayer in layer?.sublayers ?? [] {
            guard let filters = sublayer.filters as? [NSObject] else { continue }
            for filter in filters where (filter.value(forKey: "name") as? String) == "gaussianBlur" {
                if let radius = overrideBlurRadius {
                    if naturalRadius == nil { naturalRadius = filter.value(forKey: "inputRadius") as? Double }
                    filter.setValue(radius, forKey: "inputRadius")
                } else if let natural = naturalRadius {
                    filter.setValue(natural, forKey: "inputRadius")
                }
            }
        }
        if overrideBlurRadius == nil { naturalRadius = nil }
    }
}
