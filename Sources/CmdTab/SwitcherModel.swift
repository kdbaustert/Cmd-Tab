import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var targets: [SwitchTarget] = []
    @Published var selection: Int = 0
    @Published var mode: SwitcherMode = .apps
    /// Every panel dimension; see `Metrics`.
    @Published var metrics: Metrics = .default
    /// Tint of the selected tile's highlight.
    @Published var highlightColor: Color = .accentColor
    /// Show the ⌘-number badge on the first nine tiles.
    @Published var showNumbers: Bool = true
    /// Show each tile's title, even in app mode.
    @Published var alwaysShowTitles: Bool = false
    /// The frosted material behind the tiles.
    @Published var material: PanelMaterial = .hud
    /// Panel translucency, 0.3–1.0.
    @Published var opacity: Double = 1.0
    /// Blur radius override for the glass, or nil to use the material's built-in blur.
    @Published var blurRadius: Double?
    /// Corner radius of a tile's highlight.
    @Published var tileCorner: CGFloat = 12
    /// Point size of tile titles.
    @Published var titleFontSize: CGFloat = 10

    /// Whether tiles carry a title in the current mode.
    var showsTitle: Bool { mode == .windows || alwaysShowTitles }

    var selected: SwitchTarget? {
        targets.indices.contains(selection) ? targets[selection] : nil
    }

    var isEmpty: Bool { targets.isEmpty }

    func step(_ delta: Int) {
        guard !targets.isEmpty else { return }
        selection = (selection + delta + targets.count) % targets.count
    }

    /// Keeps the highlight on the same target across a background refresh, so the tile the user
    /// is looking at does not slide out from under them.
    func update(targets new: [SwitchTarget]) {
        let anchor = selected?.id
        targets = new
        if let anchor, let index = new.firstIndex(where: { $0.id == anchor }) {
            selection = index
        } else {
            selection = min(selection, max(new.count - 1, 0))
        }
    }
}
