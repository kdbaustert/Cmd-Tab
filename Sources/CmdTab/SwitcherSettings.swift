import CoreGraphics
import Foundation
import SwiftUI

/// Every preference the switcher reads, as one value.
///
/// `SwitcherController` used to expose these as twenty-six computed properties, each four to seven
/// lines of get-set-guard-refresh forwarding to `provider`, `panels` or `model` — around a third of
/// the file, and the third with nothing in it worth reading. `AppDelegate.applyBehavior` set all
/// twenty-six in a row, one assignment per line, which is the shape that makes the cost visible:
///
/// **Seven of those setters called `provider.refresh()` and five called `panels.layout()`.** So one
/// pass through `applyBehavior` could run seven full enumerations — each with its main-thread
/// prelude walking every running app and faulting in its icon — and lay out the panel five times.
/// The individual setters guarded on an actual change, which took the common case down to nothing,
/// but any settings change that touched two provider-backed values paid for two rebuilds, and a
/// `Reset to defaults` or an imported config paid for all seven. `BehaviorStore` fires its change
/// notification once per slider tick during a drag.
///
/// Passing the whole block at once lets `apply` coalesce that to **at most one refresh and one
/// layout**, because it can see the settings together rather than one at a time.
struct SwitcherSettings: Equatable {
    // Provider-backed: these change what the target list *is*, so a change to any of them needs a
    // rebuild.
    var mode: SwitcherMode = .apps
    var sortOrder: SortOrder = .recentlyUsed
    var hideEmptyApps = false
    var pinFavoritesFirst = true
    var notificationBadges = true

    // Panel-backed: geometry and chrome. A change needs a relayout, not a rebuild.
    var layout: SwitcherLayout = .grid
    var panelAppearance: PanelAppearance = .system
    var panelPosition: PanelPosition = .center
    var panelScreens: PanelScreens = .automatic
    var maxColumns = 0
    var fade = true
    var windowPreview = false
    /// Window mode: draw a live capture as the tile artwork. See `TileThumbnails`.
    var windowThumbnailTiles = false

    // Model-backed: what a tile looks like.
    var highlightColor: Color = .accentColor
    var showNumbers = true
    var showDisplayBadges = true
    var showSpaceBadges = true
    var tileCorner: CGFloat = 12
    var titleFontName = ""
    var titleFontSize: CGFloat = 12
    var panelMaterial: PanelMaterial = .underWindow
    /// nil = the material's built-in blur; a value overrides it.
    var panelBlur: Double?

    // Session behaviour, held directly by the controller.
    var showDelay: TimeInterval = 0
    var launchFromSearch = true
    var stickyMode = false
    var hotkey: Hotkey = .commandTab
    /// nil leaves the combination alone, which matters because the default (⌘-`) is one apps use
    /// themselves.
    var sameAppHotkey: Hotkey?
}
