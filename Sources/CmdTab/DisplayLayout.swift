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
        if layout == .list {
            let row = metrics.listRow(for: mode)
            let available = visibleSize.height * Metrics.maxScreenFraction - Metrics.panelPadding * 2
            let perColumn = max(Int(available / (row.height + Metrics.rowGap)), 1)
            var needed = Int((Double(targetCount) / Double(perColumn)).rounded(.up))
            if cap > 0 { needed = min(needed, cap) }
            return max(needed, 1)
        }
        let tileWidth = metrics.tile(for: mode, showsTitle: showsTitle).width + Metrics.tileGap
        let available = visibleSize.width * Metrics.maxScreenFraction - Metrics.panelPadding * 2
        var fits = max(Int(available / tileWidth), 1)
        if cap > 0 { fits = min(fits, cap) }
        return min(targetCount, fits)
    }
}
