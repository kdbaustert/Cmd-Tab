import AppKit
import SwiftUI

@MainActor
final class SwitcherModel: ObservableObject {
    @Published var targets: [SwitchTarget] = []
    @Published var selection: Int = 0
    @Published var mode: SwitcherMode = .apps
    /// Every panel dimension; see `Metrics`.
    @Published var metrics: Metrics = .default

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
