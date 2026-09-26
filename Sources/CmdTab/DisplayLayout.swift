import AppKit

/// How a single display's own geometry bends the shared appearance settings.
///
/// `AppearanceStore` publishes one set of sliders for the whole app, and with **All displays** in
/// `PanelScreens` those sliders used to produce an identical panel on every screen — including its
/// size. That is wrong the moment the desk is mixed: a tile sized for a 6K monitor is a postage
/// stamp on a laptop lid, and the laptop's tile overflows a screen a third the resolution. What
/// varies here is never the user's settings, only how much of that fixed-point-size intent survives
/// contact with a screen whose backing scale and visible frame are its own. Pure functions so the
/// arithmetic is checkable without a screen, a panel, or a window server.
enum DisplayLayout {
    /// Backing scale the icon/spacing sliders were tuned against. A screen at or above it is already
    /// carrying enough pixels per point that a point-sized tile looks the way it was designed to; a
    /// screen below it — a non-Retina external, most commonly — shows more physical screen per point,
    /// so the same tile reads smaller there than the slider promised.
    private static let referenceScale: CGFloat = 2

    /// How far a display below `referenceScale` should grow its metrics to keep a tile's *physical*
    /// size roughly constant. Clamped short of the full ratio: a 1x display is not simply "half the
    /// tile", it is a bigger sheet of glass a user chose to sit further from, and over-correcting
    /// turns one big monitor's tiles into another screen's worth of padding.
    private static let scaleRange: ClosedRange<CGFloat> = 1...1.4

    /// This display's own correction factor, applied to every length `Metrics` derives from the
    /// icon-size slider.
    static func tileScale(backingScale: CGFloat) -> CGFloat {
        guard backingScale > 0, backingScale < referenceScale else { return 1 }
        return (referenceScale / backingScale).clamped(to: scaleRange)
    }

    /// The metrics this one display draws with — the user's sliders, scaled by its own backing
    /// factor. `Metrics.init` re-clamps every field to its slider range, so a correction can never
    /// push a value somewhere the slider itself could not reach.
    static func metrics(base: Metrics, backingScale: CGFloat) -> Metrics {
        let scale = tileScale(backingScale: backingScale)
        guard scale != 1 else { return base }
        return Metrics(
            iconSize: base.iconSize * scale,
            iconSpacing: base.iconSpacing * scale,
            titleSpacing: base.titleSpacing * scale)
    }

    /// How many columns fit this display's own visible frame, given the metrics already resolved for
    /// it and the user's ceiling (0 = no ceiling, only the screen-fraction limit).
    ///
    /// Mirrors `SwitcherPanel.columns(for:on:cap:)`'s two branches — list wraps on height, grid on
    /// width — so the two stay in step; that method now calls through to this one rather than holding
    /// a second copy of the arithmetic.
    static func columns(
        targetCount: Int, mode: SwitcherMode, layout: SwitcherLayout, showsTitle: Bool,
        metrics: Metrics, visibleSize: CGSize, cap: Int
    ) -> Int {
        guard targetCount > 0 else { return 1 }
        let available = Self.available(in: visibleSize)
        if layout == .list {
            let row = metrics.listRow(for: mode)
            let perColumn = max(Int(available.height / (row.height + Metrics.rowGap)), 1)
            var needed = Int((Double(targetCount) / Double(perColumn)).rounded(.up))
            if cap > 0 { needed = min(needed, cap) }
            return max(needed, 1)
        }
        let tileWidth = metrics.tile(for: mode, showsTitle: showsTitle).width + Metrics.tileGap
        var fits = max(Int(available.width / tileWidth), 1)
        if cap > 0 { fits = min(fits, cap) }
        return min(targetCount, fits)
    }

    /// `base`, shrunk until `targetCount` targets fit this display's visible frame — or until the
    /// icon-size slider's floor, past which there is nothing left to give.
    ///
    /// `columns` bounds one axis only: the grid wraps on width and lets its rows run down the
    /// screen, the list wraps on height and lets its columns run across it, and the user's column
    /// ceiling can push either past the edge by itself. The panel does not scroll, so a tile past
    /// the edge was a tile nobody could see while the selection could still land on it. Against a
    /// 13" laptop's visible frame that was a window-mode grid past roughly 80 windows at the
    /// default size, a list past 24 targets at the largest icon size, and a three-column cap past
    /// about 25 apps. Shrinking keeps the no-scroll design; the caption and search bar are paid for
    /// by the margin `Metrics.maxScreenFraction` already leaves, exactly as they are in `columns`.
    ///
    /// Stepwise rather than solved: the column count moves as tiles narrow, and the list's row
    /// width and icon are clamped independently of the icon size, so no one formula covers every
    /// case. A couple of dozen steps of arithmetic is nothing beside the layout pass that follows.
    static func fitted(
        _ base: Metrics, targetCount: Int, mode: SwitcherMode, layout: SwitcherLayout,
        showsTitle: Bool, visibleSize: CGSize, cap: Int
    ) -> Metrics {
        var metrics = base
        // Bounded as well as floored, so no input can spin here: 0.92 per step takes the largest
        // icon to the smallest in 17.
        for _ in 0..<32 {
            if fits(
                metrics, targetCount: targetCount, mode: mode, layout: layout,
                showsTitle: showsTitle, visibleSize: visibleSize, cap: cap)
            {
                return metrics
            }
            guard metrics.iconSize > Metrics.iconSizeRange.lowerBound else { break }
            // All three together, so the tile keeps its proportions as it shrinks. Whole points for
            // the icon, which is drawn from a bitmap; `Metrics.init` re-clamps to the floor.
            metrics = Metrics(
                iconSize: (metrics.iconSize * 0.92).rounded(.down),
                iconSpacing: metrics.iconSpacing * 0.92,
                titleSpacing: metrics.titleSpacing * 0.92)
        }
        return metrics
    }

    /// Whether `targetCount` targets laid out with `metrics` fit this display's visible frame, in
    /// both axes — the same rows and columns `SwitcherView` draws: a row-major grid, or a list
    /// split into `columns` runs of `ceil(count / columns)` rows.
    static func fits(
        _ metrics: Metrics, targetCount: Int, mode: SwitcherMode, layout: SwitcherLayout,
        showsTitle: Bool, visibleSize: CGSize, cap: Int
    ) -> Bool {
        guard targetCount > 0 else { return true }
        let columns = Self.columns(
            targetCount: targetCount, mode: mode, layout: layout, showsTitle: showsTitle,
            metrics: metrics, visibleSize: visibleSize, cap: cap)
        let rows = Int((Double(targetCount) / Double(columns)).rounded(.up))
        let isList = layout == .list
        let cell = isList
            ? metrics.listRow(for: mode) : metrics.tile(for: mode, showsTitle: showsTitle)
        let rowGap = isList ? Metrics.rowGap : Metrics.tileGap
        let width = CGFloat(columns) * (cell.width + Metrics.tileGap) - Metrics.tileGap
        let height = CGFloat(rows) * (cell.height + rowGap) - rowGap
        let available = Self.available(in: visibleSize)
        return width <= available.width && height <= available.height
    }

    /// The share of the visible frame the tiles may cover, inside the glass's own padding.
    private static func available(in visibleSize: CGSize) -> CGSize {
        CGSize(
            width: visibleSize.width * Metrics.maxScreenFraction - Metrics.panelPadding * 2,
            height: visibleSize.height * Metrics.maxScreenFraction - Metrics.panelPadding * 2)
    }
}
