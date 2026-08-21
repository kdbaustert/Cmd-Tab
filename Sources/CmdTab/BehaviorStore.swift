import AppKit
import CoreGraphics
import Defaults
import SwiftUI

/// How the switcher orders its tiles.
enum SortOrder: String, CaseIterable {
    case recentlyUsed
    case alphabetical

    var title: String {
        switch self {
        case .recentlyUsed: return "Recently used"
        case .alphabetical: return "Alphabetical"
        }
    }
}

/// How the switcher arranges its targets.
///
/// Grid is the ⌘-Tab shape: icons in a wrapping grid with the selected one's name in a caption
/// underneath. List trades that for one target per row with the name beside the icon, which reads
/// far better when the names matter more than the artwork — a dozen windows of the same app, say.
enum SwitcherLayout: String, CaseIterable {
    case grid
    case list

    var title: String {
        switch self {
        case .grid: return "Grid"
        case .list: return "List"
        }
    }

    /// The one-line explanation under each option in Settings → Appearance.
    var detail: String {
        switch self {
        case .grid: return "Icons in a wrapping grid, with the selected name below."
        case .list: return "One target per row, name beside the icon."
        }
    }

    var symbol: String {
        switch self {
        case .grid: return "square.grid.2x2"
        case .list: return "list.bullet"
        }
    }
}

/// Which appearance the panel forces on itself, regardless of the system setting.
enum PanelAppearance: String, CaseIterable {
    case system
    case light
    case dark

    var title: String {
        switch self {
        case .system: return "Match system"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}

/// The frosted material behind the tiles — the glass/blur look. A curated subset of
/// `NSVisualEffectView.Material`, ordered roughly darkest/most-blurred to lightest.
enum PanelMaterial: String, CaseIterable {
    case hud
    case fullScreen
    case popover
    case menu
    case sidebar
    case window
    case underWindow

    var title: String {
        switch self {
        case .hud: return "HUD"
        case .fullScreen: return "Full-screen"
        case .popover: return "Popover"
        case .menu: return "Menu"
        case .sidebar: return "Sidebar"
        case .window: return "Window"
        case .underWindow: return "Under-window"
        }
    }

    var nsMaterial: NSVisualEffectView.Material {
        switch self {
        case .hud: return .hudWindow
        case .fullScreen: return .fullScreenUI
        case .popover: return .popover
        case .menu: return .menu
        case .sidebar: return .sidebar
        case .window: return .windowBackground
        case .underWindow: return .underWindowBackground
        }
    }
}

/// Where the panel places itself when it opens.
enum PanelPosition: String, CaseIterable {
    case center
    case activeScreen
    case cursor

    var title: String {
        switch self {
        case .center: return "Screen centre"
        case .activeScreen: return "Active screen"
        case .cursor: return "Near cursor"
        }
    }
}

/// Which glyph the menu-bar item shows. Every case maps to a template PNG set that ships loose in
/// the bundle Resources (`<name>.png` plus `@2x`/`@3x`), so AppKit picks the scale for the display
/// and tints the artwork for a light or dark menu bar.
///
/// The artwork ships on a 22pt canvas, and each glyph was trimmed of the padding its own artboard
/// carried and rescaled to fill 95% of that canvas on its longest side. That trimming still matters:
/// the source art padded each glyph differently, so shipping it as drawn left the ⌘ around 12pt
/// while the keycap sat near 18, and they read as inconsistent whatever size they are drawn at.
///
/// The canvas no longer sets the on-screen height, though — `image` resizes to `drawnHeight`, which
/// is what the menu bar actually shows.
///
/// The raw values are persisted, so renaming a case drops that user back to the default.
enum MenuBarIcon: String, CaseIterable {
    case command
    case switcher
    case windows
    case keycap
    case commandTab

    var title: String {
        switch self {
        case .command: return "Command"
        case .switcher: return "Switcher"
        case .windows: return "Windows"
        case .keycap: return "Keycap"
        case .commandTab: return "Command-Tab"
        }
    }

    var imageName: String {
        switch self {
        case .command: return "menuCommandTemplate"
        case .switcher: return "menuSwitcherTemplate"
        case .windows: return "menuWindowsTemplate"
        case .keycap: return "menuKeycapTemplate"
        case .commandTab: return "menuCommandTabTemplate"
        }
    }

    /// How tall the glyph is drawn in the menu bar, on its longest side.
    ///
    /// The PNGs are cut at 22pt, which `NSImage.size` picks up from the @1x pixel size, and at that
    /// height they sat noticeably larger than the system's own menu-bar items. Resized here rather
    /// than re-cut, so the @2x/@3x representations survive — AppKit still picks the right one for
    /// the display, and only the drawn size changes.
    private static let drawnHeight: CGFloat = 18

    /// The artwork, ready for either a status item or a menu of choices. Marked as a template here
    /// rather than at each call site — every one of these is a template, and an unflagged one would
    /// render as flat black on a dark menu bar.
    var image: NSImage? {
        // A copy: `NSImage(named:)` hands back a shared cached instance, and resizing that would
        // reach every other user of the same artwork.
        guard let image = NSImage(named: imageName)?.copy() as? NSImage else { return nil }
        image.isTemplate = true
        // Fitted by the longest side rather than forced square: the Command-Tab glyph is wider than
        // it is tall, and setting both dimensions would squash it.
        let size = image.size
        if size.width > 0, size.height > 0 {
            let scale = Self.drawnHeight / max(size.width, size.height)
            image.size = NSSize(width: size.width * scale, height: size.height * scale)
        }
        return image
    }
}

/// The key combination that opens the switcher. `modifierRaw` is the raw value of the
/// device-independent `CGEventFlags` that must be held (Command, Option, …).
struct Hotkey: Equatable {
    var keyCode: Int
    var modifierRaw: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRaw) }

    /// AppKit's modifier set as the window server's.
    ///
    /// One copy, here, because there were six: four identical private `cgFlags(from:)` helpers and
    /// two inline runs of the same four `contains`/`insert` pairs, every one of them inside an
    /// `NSEvent` monitor closure no test can reach. They agreed, and the risk was never that one
    /// would gain a modifier — every matcher intersects both sides down to the same four — but that
    /// one would *lose* one, or that the matchers would widen and a copy be missed, leaving a chord
    /// recorded in one settings pane carrying flags the tap's match refuses, with nothing failing
    /// at build time. `TriggerModifiers` makes the same argument for the same reason: as a free
    /// function over a value type this can be exercised without an event tap, which is the
    /// difference between the logic being tested and not.
    ///
    /// Deliberately *not* `SwitcherShortcuts.extras(from:)`, which omits ⌘ on purpose and says so.
    static func flags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    static let commandTab = Hotkey(keyCode: 48, modifierRaw: CGEventFlags.maskCommand.rawValue)

    /// Default for the same-app window cycle, matching the system's own ⌘-` for that job.
    static let commandBacktick = Hotkey(keyCode: 50, modifierRaw: CGEventFlags.maskCommand.rawValue)

    /// True when this is exactly ⌘-Tab, the one combination that also needs the system switcher
    /// suppressed. Shift is ignored here — it is the reverse-direction modifier, not part of the
    /// trigger identity.
    var isCommandTab: Bool {
        keyCode == 48 && heldModifiers == [.maskCommand]
    }

    /// The primary modifiers, with Shift masked out — Shift only ever means "go backwards".
    var heldModifiers: CGEventFlags {
        modifiers.intersection([.maskCommand, .maskAlternate, .maskControl])
    }

    /// Whether this is a combination a *global* binding may fire on.
    ///
    /// Every recorder already refuses a bare key, but a binding can also arrive from a hand-edited
    /// `config.json` or an imported settings file, and a global chord with no modifier would swallow
    /// that key everywhere on the machine — you would lose the letter "e" in every app with no
    /// indication why. The matchers check this rather than trusting the input, which is also what
    /// makes the "added but not yet bound" sentinel (`keyCode == -1`) inert.
    var isUsableGlobally: Bool {
        keyCode >= 0 && !heldModifiers.isEmpty
    }

    var displayString: String {
        var parts = ""
        if modifiers.contains(.maskControl) { parts += "⌃" }
        if modifiers.contains(.maskAlternate) { parts += "⌥" }
        if modifiers.contains(.maskShift) { parts += "⇧" }
        if modifiers.contains(.maskCommand) { parts += "⌘" }
        parts += Hotkey.keyName(for: keyCode)
        return parts
    }

    static func keyName(for keyCode: Int) -> String {
        switch keyCode {
        case 48: return "⇥"
        case 49: return "Space"
        case 50: return "`"
        // The arrows were missing, which meant the move-to-desktop bindings — which default to
        // them — rendered as "Key 123" in their own recorder.
        case 123: return "←"; case 124: return "→"; case 125: return "↓"; case 126: return "↑"
        case 36: return "↩"; case 53: return "⎋"; case 51: return "⌫"
        case 29: return "0"; case 18: return "1"; case 19: return "2"; case 20: return "3"
        case 21: return "4"; case 23: return "5"; case 22: return "6"; case 26: return "7"
        case 28: return "8"; case 25: return "9"
        case 24: return "="; case 27: return "-"; case 43: return ","; case 47: return "."
        case 44: return "/"; case 42: return "\\"; case 41: return ";"; case 39: return "'"
        case 33: return "["; case 30: return "]"
        case 0: return "A"; case 1: return "S"; case 2: return "D"; case 3: return "F"
        case 4: return "H"; case 5: return "G"; case 6: return "Z"; case 7: return "X"
        case 8: return "C"; case 9: return "V"; case 11: return "B"; case 12: return "Q"
        case 13: return "W"; case 14: return "E"; case 15: return "R"; case 16: return "Y"
        case 17: return "T"; case 32: return "U"; case 34: return "I"; case 31: return "O"
        case 35: return "P"; case 37: return "L"; case 38: return "J"; case 40: return "K"
        case 45: return "N"; case 46: return "M"
        default: return "Key \(keyCode)"
        }
    }
}

// MARK: - Storage

/// Built-in default values the key table needs.
///
/// Separate from `BehaviorStore` because that type is `@MainActor` and the key table below is not:
/// a key's default is read wherever the key is, including off the main actor. Reaching into the
/// store's statics from there compiles today only as a warning, and is an error under the Swift 6
/// language mode.
enum BehaviorDefault {
    /// Tint of the selected/hovered tile. A pale neutral rather than the system accent: the
    /// highlight sits directly behind app icons of every colour, and an accent-tinted one fights
    /// whichever icon it lands on.
    static let highlightHex = "#CDD7DD"
}

// These enums persist as their raw string, which is what is already on disk. Plain `Serializable`
// conformances rather than `Codable` ones: `Defaults` picks `RawRepresentableBridge` for a
// non-`Codable` `RawRepresentable`, which writes the bare `rawValue` — the same bytes the previous
// hand-rolled `store(x.rawValue, …)` wrote.
extension SortOrder: Defaults.Serializable {}
extension SwitcherLayout: Defaults.Serializable {}
extension SwitcherMode: Defaults.Serializable {}
extension PanelAppearance: Defaults.Serializable {}
extension PanelMaterial: Defaults.Serializable {}
extension PanelPosition: Defaults.Serializable {}
extension PanelScreens: Defaults.Serializable {}
extension MenuBarIcon: Defaults.Serializable {}

/// Typed keys for everything `BehaviorStore` persists.
///
/// One declaration per setting, carrying both its `UserDefaults` name and its default value. Those
/// two facts used to be spread across a private key table, `init`, `reload()` and the owned-keys
/// list — four places that had to agree, with nothing checking that they did. A default present in
/// `init` but missing from `reload()` changed the setting's value the first time anyone imported a
/// settings file, which is exactly the kind of bug no test was ever going to catch.
///
/// The names are load-bearing. Existing installs and exported settings files key on these exact
/// strings, so renaming one silently discards that preference on the next launch.
extension Defaults.Keys {
    static let sortOrder = Key<SortOrder>("sortOrder", default: .recentlyUsed)
    /// Grid is the default because it is the shape ⌘-Tab has always had; an existing install sees
    /// no change until it picks List.
    static let switcherLayout = Key<SwitcherLayout>("switcherLayout", default: .grid)

    /// Applications or individual windows.
    ///
    /// Deliberately *not* the old `mode` key, which is in `retiredDefaultsKeys`: an install from
    /// before window mode was removed may still have `mode = windows` sitting in its defaults, and
    /// reviving that key would silently switch those users into window mode on upgrade. A fresh
    /// name means everyone starts from the documented default and opts in.
    static let switcherMode = Key<SwitcherMode>("switcherMode", default: .apps)
    static let panelAppearance = Key<PanelAppearance>("panelAppearance", default: .system)
    static let panelPosition = Key<PanelPosition>("panelPosition", default: .center)
    static let panelScreens = Key<PanelScreens>("panelScreens", default: .automatic)
    /// The glassiest of the materials: `underWindowBackground` lets the most through, where the HUD
    /// this used to default to is nearly solid. Paired with the blur override below, which is what
    /// keeps a see-through panel legible over busy content — heavy frost destroys the detail behind
    /// it, so the tiles stay the only thing with edges.
    static let panelMaterial = Key<PanelMaterial>("panelMaterial", default: .underWindow)

    /// Kept as `#RRGGBB` rather than moved to `Defaults`' own `Color` bridge: the hex form is what
    /// is already on disk, what the exported JSON carries, and what stays legible if someone edits
    /// an exported file by hand.
    static let highlightColorHex = Key<String>(
        "highlightColorHex", default: BehaviorDefault.highlightHex)

    /// Optional deliberately: absent means "never set", which is what selects the built-in default
    /// combination. It cannot be folded into a non-optional key with a sentinel, because keyCode 0
    /// is a real key (A).
    static let hotkeyKeyCode = Key<Int?>("hotkeyKeyCode")
    static let hotkeyModifiers = Key<Int>("hotkeyModifiers", default: 0)
    static let sameAppKeyCode = Key<Int?>("sameAppHotkeyKeyCode")
    static let sameAppModifiers = Key<Int>("sameAppHotkeyModifiers", default: 0)

    static let stickyMode = Key<Bool>("stickyMode", default: false)
    static let sameAppCycle = Key<Bool>("sameAppCycle", default: false)
    static let hideEmptyApps = Key<Bool>("hideEmptyApps", default: false)
    /// On by default: with no favourites starred it changes nothing, and a user who has starred
    /// apps asked for those apps to be special — holding a fixed slot is what that finally means
    /// for one that happens to be running.
    static let pinFavoritesFirst = Key<Bool>("pinFavoritesFirst", default: true)
    static let showDelay = Key<Double>("showDelayMs", default: 0)
    static let maxColumns = Key<Int>("maxColumns", default: 0)
    /// On by default, at a heavier radius than any material carries natively. Best-effort — the
    /// override reaches a private backdrop layer, and if that is ever restructured the material's
    /// own (already large) blur simply stands, which is a graceful place to land.
    static let blurOverride = Key<Bool>("blurOverride", default: true)
    static let blurRadius = Key<Double>("blurRadius", default: 40)
    static let showNumbers = Key<Bool>("showNumbers", default: true)
    /// The display and Space markers, separately. They were one `showBadges` switch until the two
    /// turned out to answer different questions — a single-display machine with several Desktops
    /// wants the Space marker and never sees a display one, and the reverse holds for a two-monitor
    /// machine with one Desktop. `Migration.run` seeds both from the retired key.
    static let showDisplayBadges = Key<Bool>("showDisplayBadges", default: true)
    static let showSpaceBadges = Key<Bool>("showSpaceBadges", default: true)
    static let notificationBadges = Key<Bool>("notificationBadges", default: true)
    static let tileCorner = Key<Double>("tileCorner", default: 12)
    static let titleFontSize = Key<Double>("titleFontSize", default: 10)
    static let titleFontName = Key<String>("titleFontName", default: "")
    static let fade = Key<Bool>("fadeAnimation", default: false)
    static let showMenuBarIcon = Key<Bool>("showMenuBarIcon", default: true)
    /// `.command` is the plain ⌘ glyph, which is what the menu bar showed before this was
    /// selectable — so an existing install sees no change until it picks something else.
    static let menuBarIcon = Key<MenuBarIcon>("menuBarIcon", default: .command)
    /// Off by default: it is the one feature that needs Screen Recording, and switching it on is
    /// what asks for the permission. Defaulted on, an ungranted install would show nothing on hover
    /// with no hint as to why.
    static let windowPreview = Key<Bool>("windowPreviewOnHover", default: false)
    /// Window mode: draw a live capture as the tile artwork instead of the app icon.
    ///
    /// Off by default, like the hover preview and for the same reason — it needs Screen Recording,
    /// and this app's permission story is that it needs Accessibility and nothing else.
    static let windowThumbnailTiles = Key<Bool>("windowThumbnailTiles", default: false)
    /// Offer installed apps when a query matches nothing running. On by default: it only ever
    /// appears in place of "No matches", so it costs nothing when it is not wanted.
    static let launchFromSearch = Key<Bool>("launchFromSearch", default: true)

    /// Promotes the per-event tracing from `.debug` to `.default` so it survives in the system log.
    /// Off by default — see `Log.traceLevel` for what it costs and why it is worth having at all.
    static let verboseLogging = Key<Bool>("verboseLogging", default: false)
}

/// Everything the user can tune that is not one of the appearance sliders. One store, backed by the
/// typed keys above, with a single `onChange` the app uses to re-push the lot to the controller.
///
/// Still an `ObservableObject` façade rather than `@Default` property wrappers in the views. The
/// coalescing here is load-bearing — `batch()` and `reload()` exist so a theme apply or an import
/// fires the (expensive) `onChange` once instead of ~27 times, and that callback rebuilds the
/// switcher's target list. Per-view observation would hand that job back to SwiftUI, which has no
/// way to know the 27 writes were one user action.
@MainActor
final class BehaviorStore: ObservableObject {
    static let shared = BehaviorStore()

    /// Every key this store owns. `ownedDefaultsKeys` is derived from it, so a setting declared
    /// above cannot be quietly missed by export, import and reset.
    private static let ownedKeys: [Defaults._AnyKey] = [
        .sortOrder, .switcherLayout, .switcherMode,
        .panelAppearance, .panelPosition, .panelScreens, .panelMaterial,
        .highlightColorHex,
        .hotkeyKeyCode, .hotkeyModifiers, .sameAppKeyCode, .sameAppModifiers,
        .stickyMode, .sameAppCycle, .hideEmptyApps, .pinFavoritesFirst, .showDelay, .maxColumns,
        .blurOverride, .blurRadius,
        .showNumbers, .showDisplayBadges, .showSpaceBadges, .notificationBadges,
        .tileCorner, .titleFontSize, .titleFontName,
        .fade, .showMenuBarIcon, .menuBarIcon, .windowPreview, .windowThumbnailTiles,
        .launchFromSearch,
        .verboseLogging,
    ]

    /// Keys belonging to the *other* stores, which export/import/reset also cover. Listed by name
    /// because those stores still reach `UserDefaults` directly.
    private static let otherStoreKeys =
        [
            "iconSize", "iconSpacing", "titleSpacing",
            "excludedBundleIDs", "favoriteBundleIDs",
        ] + WindowTilingStore.defaultsKeys + ConfigFile.defaultsKeys + GlobalActionsStore.defaultsKeys + ScopedTriggersStore.defaultsKeys + AppRulesStore.defaultsKeys
        + SwitcherShortcutsStore.defaultsKeys + Updater.exportedDefaultsKeys

    /// The keys export/import/reset operate on.
    static var ownedDefaultsKeys: [String] { ownedKeys.map(\.name) + otherStoreKeys }

    /// Fired after any change so the app can reconfigure the running switcher.
    var onChange: (() -> Void)?

    // Each property loads from its key and persists back to it. Declaration, default, load and save
    // are one line apiece and cannot drift apart.

    @Published var sortOrder: SortOrder = Defaults[.sortOrder] {
        didSet { persist(sortOrder, oldValue, to: .sortOrder) }
    }
    /// Grid or list. Structural rather than cosmetic — it changes what a tile *is* — so it is not
    /// carried in a `Theme`, for the same reason `maxColumns` is not.
    @Published var layout: SwitcherLayout = Defaults[.switcherLayout] {
        didSet { persist(layout, oldValue, to: .switcherLayout) }
    }
    /// Whether the switcher lists applications or individual windows.
    @Published var mode: SwitcherMode = Defaults[.switcherMode] {
        didSet { persist(mode, oldValue, to: .switcherMode) }
    }
    @Published var panelAppearance: PanelAppearance = Defaults[.panelAppearance] {
        didSet { persist(panelAppearance, oldValue, to: .panelAppearance) }
    }
    @Published var panelPosition: PanelPosition = Defaults[.panelPosition] {
        didSet { persist(panelPosition, oldValue, to: .panelPosition) }
    }
    @Published var highlightColor: Color =
        Color(hex: Defaults[.highlightColorHex]) ?? BehaviorStore.defaultHighlight
    {
        didSet { persistColor(highlightColor, oldValue) }
    }
    @Published var hotkey: Hotkey = BehaviorStore.loadHotkey(
        code: .hotkeyKeyCode, mods: .hotkeyModifiers, default: .commandTab)
    {
        didSet { persistHotkey(hotkey, oldValue, code: .hotkeyKeyCode, mods: .hotkeyModifiers) }
    }
    /// Which displays the switcher appears on. Separate from `panelPosition`, which is where on a
    /// display it sits.
    @Published var panelScreens: PanelScreens = Defaults[.panelScreens] {
        didSet { persist(panelScreens, oldValue, to: .panelScreens) }
    }
    /// Keeps the switcher up after the trigger is released — but only once you have actually browsed
    /// it. A plain hold-and-release still switches; see `SwitcherController.browsed`.
    @Published var stickyMode: Bool = Defaults[.stickyMode] {
        didSet { persist(stickyMode, oldValue, to: .stickyMode) }
    }
    /// Whether the same-app window cycle is bound at all. Off by default: it takes over a
    /// combination (⌘-`) that apps themselves use, so it should be opted into rather than
    /// silently intercepted.
    @Published var sameAppCycle: Bool = Defaults[.sameAppCycle] {
        didSet { persist(sameAppCycle, oldValue, to: .sameAppCycle) }
    }
    @Published var sameAppHotkey: Hotkey = BehaviorStore.loadHotkey(
        code: .sameAppKeyCode, mods: .sameAppModifiers, default: .commandBacktick)
    {
        didSet { persistHotkey(sameAppHotkey, oldValue, code: .sameAppKeyCode, mods: .sameAppModifiers) }
    }
    @Published var hideEmptyApps: Bool = Defaults[.hideEmptyApps] {
        didSet { persist(hideEmptyApps, oldValue, to: .hideEmptyApps) }
    }
    /// Favourites hold fixed slots at the front of the app list instead of falling wherever the
    /// sort puts them.
    @Published var pinFavoritesFirst: Bool = Defaults[.pinFavoritesFirst] {
        didSet { persist(pinFavoritesFirst, oldValue, to: .pinFavoritesFirst) }
    }
    @Published var showDelay: Double = Defaults[.showDelay] {
        didSet { persist(showDelay, oldValue, to: .showDelay) }
    }
    @Published var maxColumns: Int = Defaults[.maxColumns] {
        didSet { persist(maxColumns, oldValue, to: .maxColumns) }
    }
    @Published var panelMaterial: PanelMaterial = Defaults[.panelMaterial] {
        didSet { persist(panelMaterial, oldValue, to: .panelMaterial) }
    }
    @Published var blurOverride: Bool = Defaults[.blurOverride] {
        didSet { persist(blurOverride, oldValue, to: .blurOverride) }
    }
    @Published var blurRadius: Double = Defaults[.blurRadius] {
        didSet { persist(blurRadius, oldValue, to: .blurRadius) }
    }
    @Published var showNumbers: Bool = Defaults[.showNumbers] {
        didSet { persist(showNumbers, oldValue, to: .showNumbers) }
    }
    /// The display badge on window tiles. Defaults on, and it only ever appears when there is more
    /// than one display to tell apart, so the setting is for turning it off rather than on.
    @Published var showDisplayBadges: Bool = Defaults[.showDisplayBadges] {
        didSet { persist(showDisplayBadges, oldValue, to: .showDisplayBadges) }
    }
    /// The Space (Desktop) badge, same arrangement.
    @Published var showSpaceBadges: Bool = Defaults[.showSpaceBadges] {
        didSet { persist(showSpaceBadges, oldValue, to: .showSpaceBadges) }
    }
    /// Show each app's Dock notification badge (unread counts) on its tile.
    @Published var notificationBadges: Bool = Defaults[.notificationBadges] {
        didSet { persist(notificationBadges, oldValue, to: .notificationBadges) }
    }
    @Published var tileCorner: Double = Defaults[.tileCorner] {
        didSet { persist(tileCorner, oldValue, to: .tileCorner) }
    }
    @Published var titleFontSize: Double = Defaults[.titleFontSize] {
        didSet { persist(titleFontSize, oldValue, to: .titleFontSize) }
    }
    /// Font family for tile titles and the caption. Empty = the system font.
    @Published var titleFontName: String = Defaults[.titleFontName] {
        didSet { persist(titleFontName, oldValue, to: .titleFontName) }
    }
    @Published var fade: Bool = Defaults[.fade] {
        didSet { persist(fade, oldValue, to: .fade) }
    }
    @Published var showMenuBarIcon: Bool = Defaults[.showMenuBarIcon] {
        didSet { persist(showMenuBarIcon, oldValue, to: .showMenuBarIcon) }
    }
    /// Which glyph that item shows. Kept independent of `showMenuBarIcon` so hiding the item and
    /// bringing it back does not lose the choice.
    @Published var menuBarIcon: MenuBarIcon = Defaults[.menuBarIcon] {
        didSet { persist(menuBarIcon, oldValue, to: .menuBarIcon) }
    }
    /// Hovering a tile floats live thumbnails of that app's windows; clicking one goes straight to
    /// that window. Needs Screen Recording.
    @Published var windowThumbnailTiles: Bool = Defaults[.windowThumbnailTiles] {
        didSet { persist(windowThumbnailTiles, oldValue, to: .windowThumbnailTiles) }
    }

    @Published var windowPreview: Bool = Defaults[.windowPreview] {
        didSet { persist(windowPreview, oldValue, to: .windowPreview) }
    }
    /// Offer installed apps to launch when a query matches nothing on screen.
    @Published var launchFromSearch: Bool = Defaults[.launchFromSearch] {
        didSet { persist(launchFromSearch, oldValue, to: .launchFromSearch) }
    }
    /// Writes the per-keystroke tracing to the system log instead of a live stream only. A
    /// troubleshooting switch, not a preference — but it persists like one so it survives the
    /// relaunch that reproducing a problem usually involves.
    @Published var verboseLogging: Bool = Defaults[.verboseLogging] {
        didSet { persist(verboseLogging, oldValue, to: .verboseLogging) }
    }

    /// The built-in highlight tint. The hex lives in `BehaviorDefault` — see there for why — and
    /// these are the names the rest of the app already uses for it.
    ///
    /// Force-unwrapped deliberately — a malformed literal there is a build-time mistake, not a
    /// runtime condition worth carrying a fallback for.
    static let defaultHighlightHex = BehaviorDefault.highlightHex
    static let defaultHighlight = Color(hex: defaultHighlightHex)!

    private init() {}

    /// Re-reads every field from its key. Used after an import or reset so the live values (and the
    /// UI bound to them) follow the file rather than staying on what was in memory.
    func reload() {
        suppressOnChange = true
        isReloading = true
        defer {
            suppressOnChange = false
            isReloading = false
            onChange?()  // one coalesced notification after the whole batch
        }
        sortOrder = Defaults[.sortOrder]
        layout = Defaults[.switcherLayout]
        mode = Defaults[.switcherMode]
        panelAppearance = Defaults[.panelAppearance]
        panelPosition = Defaults[.panelPosition]
        highlightColor = Color(hex: Defaults[.highlightColorHex]) ?? Self.defaultHighlight
        hotkey = Self.loadHotkey(code: .hotkeyKeyCode, mods: .hotkeyModifiers, default: .commandTab)
        panelScreens = Defaults[.panelScreens]
        stickyMode = Defaults[.stickyMode]
        sameAppCycle = Defaults[.sameAppCycle]
        sameAppHotkey = Self.loadHotkey(
            code: .sameAppKeyCode, mods: .sameAppModifiers, default: .commandBacktick)
        hideEmptyApps = Defaults[.hideEmptyApps]
        pinFavoritesFirst = Defaults[.pinFavoritesFirst]
        showDelay = Defaults[.showDelay]
        maxColumns = Defaults[.maxColumns]
        panelMaterial = Defaults[.panelMaterial]
        blurOverride = Defaults[.blurOverride]
        blurRadius = Defaults[.blurRadius]
        showNumbers = Defaults[.showNumbers]
        showDisplayBadges = Defaults[.showDisplayBadges]
        showSpaceBadges = Defaults[.showSpaceBadges]
        notificationBadges = Defaults[.notificationBadges]
        tileCorner = Defaults[.tileCorner]
        titleFontSize = Defaults[.titleFontSize]
        titleFontName = Defaults[.titleFontName]
        fade = Defaults[.fade]
        showMenuBarIcon = Defaults[.showMenuBarIcon]
        menuBarIcon = Defaults[.menuBarIcon]
        windowPreview = Defaults[.windowPreview]
        windowThumbnailTiles = Defaults[.windowThumbnailTiles]
        launchFromSearch = Defaults[.launchFromSearch]
        verboseLogging = Defaults[.verboseLogging]
    }

    /// A hotkey lives in two keys — the key code and the modifier mask. An absent *code* is the
    /// signal that the user has never set one, and selects `fallback`.
    private static func loadHotkey(
        code: Defaults.Key<Int?>, mods: Defaults.Key<Int>, default fallback: Hotkey
    ) -> Hotkey {
        guard let keyCode = Defaults[code] else { return fallback }
        return Hotkey(
            keyCode: keyCode, modifierRaw: UInt64(bitPattern: Int64(Defaults[mods])))
    }

    /// Suppresses per-field `onChange` during a bulk `reload()`, so an import/reset/theme-apply
    /// fires the (expensive) callback once at the end rather than ~27 times.
    private var suppressOnChange = false

    /// Suppresses the *write* half of the `didSet` handlers during `reload()`. Every value assigned
    /// there was just read back out of its key, so re-persisting it is at best a no-op — and at
    /// worst destructive: for a key that is absent, the read falls through to the current build's
    /// default and the write would store that default as though the user had picked it.
    /// `resetAll()` + `reload()` would then pin today's defaults forever, and no future default
    /// change could ever reach anyone who had reset or imported. Distinct from `suppressOnChange`,
    /// which `batch()` also sets — a theme apply *does* need its values persisted.
    private var isReloading = false

    private func notify() {
        guard !suppressOnChange else { return }
        onChange?()
    }

    /// Applies several field changes with per-field notifications suppressed, then fires one
    /// coalesced `onChange`. Used when applying a theme, which touches many fields at once.
    func batch(_ changes: () -> Void) {
        suppressOnChange = true
        changes()
        suppressOnChange = false
        onChange?()
    }

    private func persist<Value: Defaults.Serializable & Equatable>(
        _ new: Value, _ old: Value, to key: Defaults.Key<Value>
    ) {
        guard new != old, !isReloading else { return }
        Defaults[key] = new
        notify()
    }

    private func persistColor(_ new: Color, _ old: Color) {
        guard new != old, !isReloading else { return }
        // A colour that will not convert to sRGB has no `#RRGGBB` form. Keep the previously stored
        // hex rather than writing a stand-in, so a one-off conversion failure cannot silently
        // replace the user's choice on the next launch.
        guard let hex = new.hexString else { return }
        Defaults[.highlightColorHex] = hex
        notify()
    }

    private func persistHotkey(
        _ new: Hotkey, _ old: Hotkey, code: Defaults.Key<Int?>, mods: Defaults.Key<Int>
    ) {
        guard new != old, !isReloading else { return }
        Defaults[code] = new.keyCode
        Defaults[mods] = Int(Int64(bitPattern: new.modifierRaw))
        notify()
    }

    /// Keys this app used to own and no longer reads. Cleared by `resetAll` so a retired setting
    /// cannot linger in `UserDefaults` forever, but deliberately kept out of `ownedDefaultsKeys` so
    /// export/import does not carry dead settings between machines.
    ///
    /// - `titleWeight`: the tile-title font weight picker, removed along with its `Theme` field.
    /// - `mode`, `windowScope`, `skipMinimized`, `reflectModeInMenuBar`: window mode and everything
    ///   that only applied to it. The switcher is app-only now; one app's windows are still reachable
    ///   through the same-app cycle and the ↓ drill-down, neither of which is a mode.
    /// - `panelOpacity`: the panel translucency slider. The material already decides how much shows
    ///   through, and a second control fighting it mostly produced washed-out panels; `Theme` lost
    ///   its matching field with it.
    /// - `showBadges`: one switch over both the display and the Space marker. Split into
    ///   `showDisplayBadges` and `showSpaceBadges`, which `Migration.run` seeds from it.
    /// - `windowSnapHighlightColorHex`: one colour for both the snap outline and the landing block.
    ///   Retired when both were fixed to grey-on-black; they are configurable again, but as two
    ///   separate keys rather than the one this was, so the name stays retired.
    ///   `Migration.reviveSnapHighlightColor` seeds both new keys from it once, so a colour chosen
    ///   before the withdrawal is not lost.
    static let retiredDefaultsKeys = [
        "titleWeight", "mode", "windowScope", "skipMinimized", "reflectModeInMenuBar",
        "alwaysShowTitles", "panelOpacity", "windowSnapHighlightColorHex", "showBadges",
        // Saved layouts, removed with the feature. `Migration.dropSavedLayouts` deletes it once;
        // listed here too so a reset sweeps it on any install that migration has not reached.
        "windowLayouts", "configFileLocation",
    ]

    /// Wipes every owned key. Does not fire `onChange` itself — callers follow with `reload()`,
    /// which republishes the defaults and notifies once.
    ///
    /// `Defaults.reset` removes the keys rather than writing their defaults back, which is what
    /// `isReloading` above depends on: a future change to a default has to be able to reach someone
    /// who once hit Reset.
    func resetAll() {
        Defaults.reset(Self.ownedKeys)
        let d = UserDefaults.standard
        // `Updater.transientDefaultsKeys` is swept here but is deliberately absent from
        // `ownedDefaultsKeys`: it is this install's update history rather than a preference, so a
        // reset should clear it while an export should not carry it to another Mac.
        for key in Self.otherStoreKeys + Self.retiredDefaultsKeys + Updater.transientDefaultsKeys {
            d.removeObject(forKey: key)
        }
    }
}

extension Color {
    /// Parses `#RRGGBB`. Alpha is not stored — the highlight applies its own opacity.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        // `allSatisfy(\.isHexDigit)` is not redundant with the `Int` parse: `Int(_:radix:)` also
        // accepts a leading `+`/`-`, so a six-character "-CDD7D" would parse to a negative value and
        // yield an arbitrary colour instead of the nil that callers fall back on.
        guard s.count == 6, s.allSatisfy(\.isHexDigit), let value = Int(s, radix: 16) else {
            return nil
        }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    /// Nil when the colour has no sRGB representation — pattern-backed and catalog colours, both of
    /// which the macOS colour panel can hand back through `ColorPicker`. Callers keep whatever they
    /// already had rather than persisting a substitute over the user's actual selection.
    var hexString: String? {
        guard let ns = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
