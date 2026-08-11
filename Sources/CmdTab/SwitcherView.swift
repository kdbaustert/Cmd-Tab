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
    /// The same idea between list rows, but tighter — a list reads as a list because the rows are
    /// close together, and the highlight is a full-width bar that a wide gap breaks into stripes.
    static let rowGap: CGFloat = 2
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

    /// Icon edge length in the list layout. A row puts the name *beside* the icon rather than under
    /// it, so it wants a much smaller one than a grid tile — but it still tracks the icon-size
    /// slider, which stays the single control that scales the whole panel. Clamped so neither end of
    /// that slider turns a row into a postage stamp or a billboard.
    var listIconSize: CGFloat { (iconSize * 0.42).rounded().clamped(to: 18...44) }

    /// One row of the list layout: icon, then a line of title — two in window mode, where the app
    /// name sits under it.
    ///
    /// Width is derived from the icon size rather than fixed, for the same reason the tiles are:
    /// someone who has scaled the panel up wants the names to have room to match. Every row is the
    /// same width, so this is also the width of the list.
    func listRow(for mode: SwitcherMode) -> CGSize {
        let lines: CGFloat = mode == .windows ? 2 : 1
        return CGSize(
            width: (iconSize * 4).rounded().clamped(to: 260...520),
            height: (max(listIconSize, lines * 16) + 8
                + (iconSpacing * 0.25).clamped(to: 0...12)).rounded())
    }

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

extension View {
    /// Reports this tile's laid-out frame under `index`, in the panel's content coordinate space.
    /// Both layouts use it, so the panel's hit-testing does not care which one drew the target.
    fileprivate func reportingFrame(at index: Int) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: TileFrameKey.self,
                    value: [index: geo.frame(in: .named(SwitcherView.space))])
            })
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
    private var row: CGSize { metrics.listRow(for: model.mode) }
    private var isList: Bool { model.layout == .list }

    /// Width of the laid-out targets. The caption and the search bar are clamped to it so a long
    /// title or query cannot become the widest child and stretch the panel around it.
    private var contentWidth: CGFloat {
        let count = CGFloat(max(columns, 1))
        return isList
            ? count * row.width + (count - 1) * Metrics.tileGap
            : count * tile.width
    }

    var body: some View {
        VStack(spacing: metrics.titleSpacing) {
            if model.targets.isEmpty {
                noMatches
            } else if isList {
                // No caption: every row carries its own name, so the caption would only repeat the
                // selected row back at the user.
                list
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
                    isMatch: isMatch(index),
                    highlightColor: model.highlightColor,
                    corner: model.tileCorner,
                    titleFont: model.titleFont(size: model.titleFontSize),
                    number: number(for: index),
                    showsDisplayBadges: model.showDisplayBadges,
                    showsSpaceBadges: model.showSpaceBadges,
                    thumbnail: thumbnail(for: target))
                    .reportingFrame(at: index)
            }
        }
    }

    /// The list layout: one target per row.
    ///
    /// Wraps into further columns when the rows would run off the screen, filling each column top to
    /// bottom before starting the next — so the reading order still matches the order the trigger
    /// steps through, which a row-major grid could not give a list. The panel decides how many
    /// columns fit; the split between them happens here.
    private var list: some View {
        let count = model.targets.count
        let columnCount = max(columns, 1)
        let perColumn = max(1, Int((Double(count) / Double(columnCount)).rounded(.up)))
        return HStack(alignment: .top, spacing: Metrics.tileGap) {
            // `Array` rather than the bare ranges: both bounds move with the target list, and
            // `ForEach` over a non-constant `Range` is the one shape SwiftUI warns about.
            ForEach(Array(0..<columnCount), id: \.self) { column in
                let start = column * perColumn
                let end = min(start + perColumn, count)
                VStack(spacing: Metrics.rowGap) {
                    ForEach(Array(start..<max(start, end)), id: \.self) { index in
                        TargetRow(
                            target: model.targets[index],
                            size: row,
                            iconSize: metrics.listIconSize,
                            showsAppName: model.mode == .windows,
                            isSelected: index == model.selection,
                            isMatch: isMatch(index),
                            highlightColor: model.highlightColor,
                            corner: model.tileCorner,
                            titleFont: model.titleFont(size: model.titleFontSize + 2),
                            subtitleFont: model.titleFont(size: model.titleFontSize),
                            number: number(for: index),
                            showsDisplayBadges: model.showDisplayBadges,
                            showsSpaceBadges: model.showSpaceBadges,
                            thumbnail: thumbnail(for: model.targets[index]))
                            .reportingFrame(at: index)
                    }
                }
                .frame(width: row.width)
            }
        }
    }

    /// This target's live capture, when thumbnail tiles are on and one has landed for it.
    ///
    /// Empty in the ordinary case: the feature is off by default, and a tile draws its icon until
    /// its own capture arrives — which is what keeps the panel instant rather than waiting on
    /// ScreenCaptureKit.
    private func thumbnail(for target: SwitchTarget) -> CGImage? {
        guard !model.thumbnails.isEmpty, let id = target.windowID else { return nil }
        return model.thumbnails[id]
    }

    /// Whether this target survives the current filter. Non-matches stay visible but dimmed.
    private func isMatch(_ index: Int) -> Bool {
        model.matchingIndices.isEmpty || model.matchingIndices.contains(index)
    }

    /// The digit that jumps to this target, or nil where there is none.
    ///
    /// The ⌘-number jump is disabled while filtering (digits type into the query), so the badges
    /// come off too. The tenth target is labelled 0, because 0 is the key that selects it — there is
    /// no ⌘-10 to press.
    private func number(for index: Int) -> Int? {
        model.showNumbers && model.query.isEmpty && index < 10 ? (index + 1) % 10 : nil
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
        .frame(maxWidth: contentWidth)
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
                    .font(model.titleFont(size: model.titleFontSize + 3))
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if model.mode == .windows {
                    Text(selected.appName)
                        .font(model.titleFont(size: model.titleFontSize + 1))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: contentWidth)
        }
    }
}

/// What a tile announces to VoiceOver.
///
/// The panel is a `.nonactivatingPanel` that never becomes key and has no key handling of its own,
/// so driving the switcher the way an assistive technology drives an ordinary window is not
/// something this can offer — the event tap is the only input path, by design, and that is what
/// makes the switcher work at all. What it *can* do is stop the tiles being anonymous: everything
/// distinguishing one tile from the next is visual — a dimmed icon for hidden, a badge glyph for
/// the Space, a small number in the corner for the jump key — and none of it is in the text.
private func accessibilityDescription(
    for target: SwitchTarget, number: Int?, showsDisplayBadges: Bool, showsSpaceBadges: Bool
) -> String {
    var parts = [target.title]
    // In window mode the title is the window's, and the app name is the other half of the identity.
    if target.appName != target.title { parts.append(target.appName) }
    if target.isMinimized { parts.append("minimized") }
    if target.isHidden { parts.append("hidden") }
    if target.isLaunchable { parts.append("not running") }
    if let badge = target.badge { parts.append("\(badge) notifications") }
    if showsDisplayBadges, let display = target.displayIndex {
        parts.append("display \(display + 1)")
    }
    if showsSpaceBadges, let space = target.spaceIndex { parts.append("desktop \(space + 1)") }
    // The tenth tile is reached with 0, so this says the key rather than the position.
    if let number { parts.append("press \(number == 10 ? 0 : number) to switch") }
    return parts.joined(separator: ", ")
}

private struct TargetTile: View {
    let target: SwitchTarget
    let size: CGSize
    let iconSize: CGFloat
    let titleSpacing: CGFloat
    let showsTitle: Bool
    let isSelected: Bool
    /// Whether this tile matches the current search query (true when no query active).
    let isMatch: Bool
    let highlightColor: Color
    let corner: CGFloat
    /// Resolved by the model, so the family fallback happens in one place rather than per tile.
    let titleFont: Font
    /// The digit that jumps here — 1–9, then 0 for the tenth tile — or nil past the tenth, which has
    /// no key to jump to it.
    let number: Int?
    /// Whether the display and Space badges may be drawn at all.
    let showsDisplayBadges: Bool
    let showsSpaceBadges: Bool
    /// This window's live capture, when thumbnail tiles are on and one has landed.
    var thumbnail: CGImage?

    var body: some View {
        VStack(spacing: titleSpacing) {
            TargetIcon(
                target: target, iconSize: iconSize, number: number,
                showsDisplayBadges: showsDisplayBadges, showsSpaceBadges: showsSpaceBadges,
                thumbnail: thumbnail)
            if showsTitle {
                Text(target.title)
                    .font(titleFont)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: size.width - 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .opacity(isMatch ? 1 : 0.3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityDescription(
                for: target, number: number, showsDisplayBadges: showsDisplayBadges,
                showsSpaceBadges: showsSpaceBadges))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .background {
            // The tint alone cannot carry the selection: `highlightColor` is a fixed sRGB value —
            // the user's, or the default — while the panel behind it is light or dark depending on
            // `panelAppearance` and the system setting. A pale tint at 30% over a light panel is
            // nearly invisible, a dark one over a dark panel likewise. The border is drawn in
            // `.primary`, which inverts with the panel's appearance, so there is always a legible
            // marker whatever tint it is paired with.
            let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
            shape
                .fill(highlightColor.opacity(isSelected ? 0.30 : 0))
                .overlay {
                    shape.strokeBorder(.primary.opacity(isSelected ? 0.28 : 0), lineWidth: 1)
                }
        }
    }
}

/// One row of the list layout: icon, name, and — where a tile would put them on the artwork — the
/// display/Space markers and the ⌘-number hint along the trailing edge.
private struct TargetRow: View {
    let target: SwitchTarget
    let size: CGSize
    let iconSize: CGFloat
    /// Window mode puts the owning app's name under the window title.
    let showsAppName: Bool
    let isSelected: Bool
    let isMatch: Bool
    let highlightColor: Color
    let corner: CGFloat
    let titleFont: Font
    let subtitleFont: Font
    let number: Int?
    let showsDisplayBadges: Bool
    let showsSpaceBadges: Bool
    var thumbnail: CGImage?

    var body: some View {
        HStack(spacing: 8) {
            TargetIcon(
                target: target, iconSize: iconSize, number: nil,
                showsDisplayBadges: false, showsSpaceBadges: false, thumbnail: thumbnail)

            VStack(alignment: .leading, spacing: 0) {
                Text(target.title)
                    .font(titleFont)
                    .fontWeight(isSelected ? .semibold : .regular)
                    .foregroundStyle(isSelected ? .primary : .secondary)
                    .lineLimit(1)
                if showsAppName {
                    Text(target.appName)
                        .font(subtitleFont)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }
            // The name column takes whatever the badges leave, and truncates rather than pushing
            // them off the row: every row is the same width, so there is no growing out of it.
            .frame(maxWidth: .infinity, alignment: .leading)

            if showsDisplayBadges, let display = target.displayIndex {
                DisplayBadge(number: display + 1)  // 1-based for humans
            }
            if showsSpaceBadges, let space = target.spaceIndex {
                SpaceBadge(number: space + 1)
            }
            if let number {
                RowNumber(number: number)
            }
        }
        .padding(.horizontal, 8)
        .frame(width: size.width, height: size.height)
        .opacity(isMatch ? 1 : 0.3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            accessibilityDescription(
                for: target, number: number, showsDisplayBadges: showsDisplayBadges,
                showsSpaceBadges: showsSpaceBadges))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .background {
            // Same treatment as `TargetTile` — see the reasoning there.
            let shape = RoundedRectangle(cornerRadius: min(corner, size.height / 2), style: .continuous)
            shape
                .fill(highlightColor.opacity(isSelected ? 0.30 : 0))
                .overlay {
                    shape.strokeBorder(.primary.opacity(isSelected ? 0.28 : 0), lineWidth: 1)
                }
        }
    }
}

/// The ⌘-number hint on a list row. Set in the panel's own text colours rather than the tile
/// badge's fixed black-on-grey: on a row it sits against the glass, not against app artwork, so it
/// can follow the appearance the way the rest of the row does.
private struct RowNumber: View {
    let number: Int

    var body: some View {
        Text("\(number)")
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(.secondary)
            .frame(width: 18, height: 18)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(0.08)))
    }
}

/// A target's artwork with everything that hangs off it.
///
/// Every badge hangs off the icon rather than the tile. The tile grows and shrinks with the icon
/// spacing slider, so a badge pinned to *its* corner would drift away from the artwork as that
/// changes; pinned to the icon, it stays on the corner at every setting.
///
/// The status badge takes bottom-leading because the number owns bottom-trailing. Shared with the
/// list layout, which draws the same icon but hands the number and the display/Space badges to the
/// row — a row has width to spare and corners of its own, so crowding them onto a 20pt icon there
/// would be a waste of both.
private struct TargetIcon: View {
    let target: SwitchTarget
    let iconSize: CGFloat
    let number: Int?
    let showsDisplayBadges: Bool
    let showsSpaceBadges: Bool
    /// A live capture of this window, when thumbnail tiles are on and one has landed. nil is the
    /// ordinary case — the feature is off by default, and even with it on a tile draws its icon
    /// until its capture arrives.
    var thumbnail: CGImage?

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            Group {
                if let thumbnail {
                    // Aspect-fit inside the tile with the app's icon inset in the corner, which is
                    // what makes a strip of thumbnails still readable as "these are Chrome windows".
                    // A thumbnail alone loses the app identity that the icon carried for free.
                    Image(decorative: thumbnail, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                        .overlay(alignment: .bottomTrailing) {
                            if let icon = target.icon {
                                Image(nsImage: icon)
                                    .resizable()
                                    .interpolation(.high)
                                    .frame(width: iconSize * 0.34, height: iconSize * 0.34)
                                    .offset(x: 2, y: 2)
                            }
                        }
                } else if let image = target.icon {
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
        .overlay(alignment: .topLeading) {
            // Top-leading keeps it clear of the ⌘-number badge (bottom-trailing) and the
            // display/Space badges (top-trailing), so a tile can carry all three without collision.
            if let badge = target.badge {
                NotificationBadge(text: badge)
                    .offset(x: 1, y: 1)
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
                if showsDisplayBadges, let display = target.displayIndex {
                    DisplayBadge(number: display + 1)  // 1-based for humans
                }
                if showsSpaceBadges, let space = target.spaceIndex {
                    SpaceBadge(number: space + 1)
                }
            }
        }
    }
}

/// An app's Dock notification badge — an unread count, or a bare dot for apps that badge without a
/// number. Red-on-white to match the Dock's own treatment, so it reads as the same signal.
private struct NotificationBadge: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 4)
            .frame(minWidth: 16, minHeight: 16)
            .background(Capsule().fill(Color.red))
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.85), lineWidth: 1))
            // Long labels ("999+") must not stretch the tile the hit-test measured.
            .lineLimit(1)
            .fixedSize()
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
/// Not private: the hover preview badges its thumbnails with the same marker, so "which display"
/// looks the same on a tile and on a window thumbnail.
struct DisplayBadge: View {
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
        // Both guarded on a real change. `SwitcherPanel.layout()` reassigns the hosting view's root
        // on every keystroke of the key path, so this runs constantly — and assigning an unchanged
        // material re-tears the glass down while `overrideBlurRadius` walks the layer tree.
        if view.material != material { view.material = material }
        view.overrideBlurRadius = blurRadius
    }
}

/// `NSVisualEffectView` bakes a fixed blur into each material. It draws the glass on a private
/// backdrop sublayer whose existing Gaussian-blur filter carries an `inputRadius`; retuning that
/// value changes the blur amount. Best-effort — if the private layer is ever restructured, the
/// material's own blur simply stands, and nothing breaks.
final class BlurVisualEffectView: NSVisualEffectView {
    var overrideBlurRadius: Double? {
        didSet {
            guard overrideBlurRadius != oldValue else { return }
            applyBlurOverride()
        }
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
        // Nothing to apply and nothing to restore. `updateLayer()` calls in on every redraw, and the
        // default — no override, so the material's own blur stands — is the common case; without
        // this it walked the sublayer tree and ran KVC over every filter each time, for no effect.
        guard overrideBlurRadius != nil || naturalRadius != nil else { return }
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
