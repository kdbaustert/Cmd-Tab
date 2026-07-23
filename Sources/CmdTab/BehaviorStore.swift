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

/// The key combination that opens the switcher. `modifierRaw` is the raw value of the
/// device-independent `CGEventFlags` that must be held (Command, Option, …).
struct Hotkey: Equatable {
    var keyCode: Int
    var modifierRaw: UInt64

    var modifiers: CGEventFlags { CGEventFlags(rawValue: modifierRaw) }

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
extension PanelAppearance: Defaults.Serializable {}
extension PanelMaterial: Defaults.Serializable {}
extension PanelPosition: Defaults.Serializable {}
extension PanelScreens: Defaults.Serializable {}

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
    static let panelAppearance = Key<PanelAppearance>("panelAppearance", default: .system)
    static let panelPosition = Key<PanelPosition>("panelPosition", default: .center)
    static let panelScreens = Key<PanelScreens>("panelScreens", default: .automatic)
    static let panelMaterial = Key<PanelMaterial>("panelMaterial", default: .hud)

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
    static let showDelay = Key<Double>("showDelayMs", default: 0)
    static let maxColumns = Key<Int>("maxColumns", default: 0)
    static let blurOverride = Key<Bool>("blurOverride", default: false)
    static let blurRadius = Key<Double>("blurRadius", default: 20)
    static let showNumbers = Key<Bool>("showNumbers", default: true)
    static let showBadges = Key<Bool>("showBadges", default: true)
    static let notificationBadges = Key<Bool>("notificationBadges", default: true)
    static let tileCorner = Key<Double>("tileCorner", default: 12)
    static let titleFontSize = Key<Double>("titleFontSize", default: 10)
    static let titleFontName = Key<String>("titleFontName", default: "")
    static let fade = Key<Bool>("fadeAnimation", default: false)
    static let showMenuBarIcon = Key<Bool>("showMenuBarIcon", default: true)
    static let windowPreview = Key<Bool>("windowPreviewOnHover", default: false)
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
        .sortOrder, .panelAppearance, .panelPosition, .panelScreens, .panelMaterial,
        .highlightColorHex,
        .hotkeyKeyCode, .hotkeyModifiers, .sameAppKeyCode, .sameAppModifiers,
        .stickyMode, .sameAppCycle, .hideEmptyApps, .showDelay, .maxColumns,
        .blurOverride, .blurRadius,
        .showNumbers, .showBadges, .notificationBadges,
        .tileCorner, .titleFontSize, .titleFontName,
        .fade, .showMenuBarIcon, .windowPreview,
    ]

    /// Keys belonging to the *other* stores, which export/import/reset also cover. Listed by name
    /// because those stores still reach `UserDefaults` directly.
    private static let otherStoreKeys = [
        "iconSize", "iconSpacing", "titleSpacing",
        "excludedBundleIDs", "favoriteBundleIDs", "switcherShortcuts",
    ]

    /// The keys export/import/reset operate on.
    static var ownedDefaultsKeys: [String] { ownedKeys.map(\.name) + otherStoreKeys }

    /// Fired after any change so the app can reconfigure the running switcher.
    var onChange: (() -> Void)?

    // Each property loads from its key and persists back to it. Declaration, default, load and save
    // are one line apiece and cannot drift apart.

    @Published var sortOrder: SortOrder = Defaults[.sortOrder] {
        didSet { persist(sortOrder, oldValue, to: .sortOrder) }
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
    /// The display and Space badges on window tiles. Defaults on, and they only ever appear when
    /// there is more than one display or Space to tell apart, so the setting is for turning them
    /// off rather than on.
    @Published var showBadges: Bool = Defaults[.showBadges] {
        didSet { persist(showBadges, oldValue, to: .showBadges) }
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
    /// Hovering a tile shows live thumbnails of that app's windows. Needs Screen Recording.
    @Published var windowPreview: Bool = Defaults[.windowPreview] {
        didSet { persist(windowPreview, oldValue, to: .windowPreview) }
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
        showDelay = Defaults[.showDelay]
        maxColumns = Defaults[.maxColumns]
        panelMaterial = Defaults[.panelMaterial]
        blurOverride = Defaults[.blurOverride]
        blurRadius = Defaults[.blurRadius]
        showNumbers = Defaults[.showNumbers]
        showBadges = Defaults[.showBadges]
        notificationBadges = Defaults[.notificationBadges]
        tileCorner = Defaults[.tileCorner]
        titleFontSize = Defaults[.titleFontSize]
        titleFontName = Defaults[.titleFontName]
        fade = Defaults[.fade]
        showMenuBarIcon = Defaults[.showMenuBarIcon]
        windowPreview = Defaults[.windowPreview]
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
    static let retiredDefaultsKeys = [
        "titleWeight", "mode", "windowScope", "skipMinimized", "reflectModeInMenuBar",
        "alwaysShowTitles", "panelOpacity",
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
        for key in Self.otherStoreKeys + Self.retiredDefaultsKeys { d.removeObject(forKey: key) }
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
