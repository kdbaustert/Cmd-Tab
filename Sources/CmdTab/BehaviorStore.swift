import AppKit
import CoreGraphics
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

/// Which windows window-mode shows, relative to Spaces and displays.
enum WindowScope: String, CaseIterable {
    case allSpaces
    case currentSpace
    case activeDisplay

    var title: String {
        switch self {
        case .allSpaces: return "All Spaces"
        case .currentSpace: return "Current Space"
        case .activeDisplay: return "Active display"
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

/// Weight of the tile title text.
enum TitleWeight: String, CaseIterable {
    case regular, medium, semibold
    var title: String { rawValue.capitalized }
    var fontWeight: Font.Weight {
        switch self {
        case .regular: return .regular
        case .medium: return .medium
        case .semibold: return .semibold
        }
    }
}

/// How an over-long title is shortened.
enum TruncationStyle: String, CaseIterable {
    case tail, middle
    var title: String { rawValue.capitalized }
    var mode: Text.TruncationMode { self == .middle ? .middle : .tail }
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

/// Everything the user can tune that is not one of the appearance sliders. One store, persisted to
/// `UserDefaults`, with a single `onChange` the app uses to re-push the lot to the controller.
@MainActor
final class BehaviorStore: ObservableObject {
    static let shared = BehaviorStore()

    private enum Key {
        static let mode = "mode"
        static let sortOrder = "sortOrder"
        static let skipMinimized = "skipMinimized"
        static let panelAppearance = "panelAppearance"
        static let panelPosition = "panelPosition"
        static let highlightColor = "highlightColorHex"
        static let hotkeyKeyCode = "hotkeyKeyCode"
        static let hotkeyModifiers = "hotkeyModifiers"
        static let cycleKeyCode = "cycleHotkeyKeyCode"
        static let cycleModifiers = "cycleHotkeyModifiers"
        static let showDelay = "showDelayMs"
        static let windowScope = "windowScope"
        static let hideEmptyApps = "hideEmptyApps"
        static let maxColumns = "maxColumns"
        static let panelMaterial = "panelMaterial"
        static let panelOpacity = "panelOpacity"
        static let blurOverride = "blurOverride"
        static let blurRadius = "blurRadius"
        static let showNumbers = "showNumbers"
        static let alwaysShowTitles = "alwaysShowTitles"
        static let tileCorner = "tileCorner"
        static let titleFontSize = "titleFontSize"
        static let titleWeight = "titleWeight"
        static let truncation = "truncation"
        static let fade = "fadeAnimation"
        static let showMenuBarIcon = "showMenuBarIcon"
        static let reflectMode = "reflectModeInMenuBar"
    }

    /// The keys we own, for export/import/reset.
    static let ownedDefaultsKeys = [
        "mode", "sortOrder", "skipMinimized", "panelAppearance", "panelPosition",
        "highlightColorHex", "hotkeyKeyCode", "hotkeyModifiers", "cycleHotkeyKeyCode",
        "cycleHotkeyModifiers", "showDelayMs", "windowScope", "hideEmptyApps", "maxColumns",
        "panelMaterial", "panelOpacity", "blurOverride", "blurRadius", "showNumbers",
        "alwaysShowTitles", "tileCorner", "titleFontSize", "titleWeight", "truncation",
        "fadeAnimation", "showMenuBarIcon", "reflectModeInMenuBar", "iconSize", "iconSpacing",
        "titleSpacing", "excludedBundleIDs",
    ]

    /// Fired after any change so the app can reconfigure the running switcher.
    var onChange: (() -> Void)?

    @Published var mode: SwitcherMode {
        didSet { store(mode.rawValue, Key.mode, oldValue != mode) }
    }
    @Published var sortOrder: SortOrder {
        didSet { store(sortOrder.rawValue, Key.sortOrder, oldValue != sortOrder) }
    }
    @Published var skipMinimized: Bool {
        didSet { store(skipMinimized, Key.skipMinimized, oldValue != skipMinimized) }
    }
    @Published var panelAppearance: PanelAppearance {
        didSet { store(panelAppearance.rawValue, Key.panelAppearance, oldValue != panelAppearance) }
    }
    @Published var panelPosition: PanelPosition {
        didSet { store(panelPosition.rawValue, Key.panelPosition, oldValue != panelPosition) }
    }
    @Published var highlightColor: Color {
        didSet { storeColor(highlightColor, oldValue) }
    }
    @Published var hotkey: Hotkey {
        didSet { storeHotkey(hotkey, oldValue, Key.hotkeyKeyCode, Key.hotkeyModifiers) }
    }
    @Published var cycleHotkey: Hotkey {
        didSet { storeHotkey(cycleHotkey, oldValue, Key.cycleKeyCode, Key.cycleModifiers) }
    }
    @Published var showDelay: Double {
        didSet { store(showDelay, Key.showDelay, oldValue != showDelay) }
    }
    @Published var windowScope: WindowScope {
        didSet { store(windowScope.rawValue, Key.windowScope, oldValue != windowScope) }
    }
    @Published var hideEmptyApps: Bool {
        didSet { store(hideEmptyApps, Key.hideEmptyApps, oldValue != hideEmptyApps) }
    }
    @Published var maxColumns: Int {
        didSet { store(maxColumns, Key.maxColumns, oldValue != maxColumns) }
    }
    @Published var panelMaterial: PanelMaterial {
        didSet { store(panelMaterial.rawValue, Key.panelMaterial, oldValue != panelMaterial) }
    }
    @Published var panelOpacity: Double {
        didSet { store(panelOpacity, Key.panelOpacity, oldValue != panelOpacity) }
    }
    @Published var blurOverride: Bool {
        didSet { store(blurOverride, Key.blurOverride, oldValue != blurOverride) }
    }
    @Published var blurRadius: Double {
        didSet { store(blurRadius, Key.blurRadius, oldValue != blurRadius) }
    }
    @Published var showNumbers: Bool {
        didSet { store(showNumbers, Key.showNumbers, oldValue != showNumbers) }
    }
    @Published var alwaysShowTitles: Bool {
        didSet { store(alwaysShowTitles, Key.alwaysShowTitles, oldValue != alwaysShowTitles) }
    }
    @Published var tileCorner: Double {
        didSet { store(tileCorner, Key.tileCorner, oldValue != tileCorner) }
    }
    @Published var titleFontSize: Double {
        didSet { store(titleFontSize, Key.titleFontSize, oldValue != titleFontSize) }
    }
    @Published var titleWeight: TitleWeight {
        didSet { store(titleWeight.rawValue, Key.titleWeight, oldValue != titleWeight) }
    }
    @Published var truncation: TruncationStyle {
        didSet { store(truncation.rawValue, Key.truncation, oldValue != truncation) }
    }
    @Published var fade: Bool {
        didSet { store(fade, Key.fade, oldValue != fade) }
    }
    @Published var showMenuBarIcon: Bool {
        didSet { store(showMenuBarIcon, Key.showMenuBarIcon, oldValue != showMenuBarIcon) }
    }
    @Published var reflectMode: Bool {
        didSet { store(reflectMode, Key.reflectMode, oldValue != reflectMode) }
    }

    static let defaultHighlight = Color.accentColor
    static let defaultCycleHotkey = Hotkey(keyCode: 50, modifierRaw: CGEventFlags.maskCommand.rawValue)

    private init() {
        let d = UserDefaults.standard
        mode = d.string(forKey: Key.mode).flatMap(SwitcherMode.init) ?? .apps
        sortOrder = d.string(forKey: Key.sortOrder).flatMap(SortOrder.init) ?? .recentlyUsed
        skipMinimized = d.bool(forKey: Key.skipMinimized)
        panelAppearance =
            d.string(forKey: Key.panelAppearance).flatMap(PanelAppearance.init) ?? .system
        panelPosition = d.string(forKey: Key.panelPosition).flatMap(PanelPosition.init) ?? .center
        highlightColor =
            d.string(forKey: Key.highlightColor).flatMap(Color.init(hex:)) ?? Self.defaultHighlight
        hotkey = Self.loadHotkey(d, Key.hotkeyKeyCode, Key.hotkeyModifiers, default: .commandTab)
        cycleHotkey = Self.loadHotkey(
            d, Key.cycleKeyCode, Key.cycleModifiers, default: Self.defaultCycleHotkey)
        showDelay = d.object(forKey: Key.showDelay) != nil ? d.double(forKey: Key.showDelay) : 0
        windowScope = d.string(forKey: Key.windowScope).flatMap(WindowScope.init) ?? .allSpaces
        hideEmptyApps = d.bool(forKey: Key.hideEmptyApps)
        maxColumns = d.integer(forKey: Key.maxColumns)
        panelMaterial = d.string(forKey: Key.panelMaterial).flatMap(PanelMaterial.init) ?? .hud
        panelOpacity = d.object(forKey: Key.panelOpacity) != nil
            ? d.double(forKey: Key.panelOpacity) : 1.0
        blurOverride = d.bool(forKey: Key.blurOverride)
        blurRadius = d.object(forKey: Key.blurRadius) != nil ? d.double(forKey: Key.blurRadius) : 20
        showNumbers = d.object(forKey: Key.showNumbers) != nil
            ? d.bool(forKey: Key.showNumbers) : true
        alwaysShowTitles = d.bool(forKey: Key.alwaysShowTitles)
        tileCorner = d.object(forKey: Key.tileCorner) != nil ? d.double(forKey: Key.tileCorner) : 12
        titleFontSize = d.object(forKey: Key.titleFontSize) != nil
            ? d.double(forKey: Key.titleFontSize) : 10
        titleWeight = d.string(forKey: Key.titleWeight).flatMap(TitleWeight.init) ?? .regular
        truncation = d.string(forKey: Key.truncation).flatMap(TruncationStyle.init) ?? .tail
        fade = d.bool(forKey: Key.fade)
        showMenuBarIcon = d.object(forKey: Key.showMenuBarIcon) != nil
            ? d.bool(forKey: Key.showMenuBarIcon) : true
        reflectMode = d.bool(forKey: Key.reflectMode)
    }

    /// Re-reads every field from `UserDefaults`. Used after an import or reset so the live values
    /// (and the UI bound to them) follow the file rather than staying on what was in memory.
    func reload() {
        let d = UserDefaults.standard
        mode = d.string(forKey: Key.mode).flatMap(SwitcherMode.init) ?? .apps
        sortOrder = d.string(forKey: Key.sortOrder).flatMap(SortOrder.init) ?? .recentlyUsed
        skipMinimized = d.bool(forKey: Key.skipMinimized)
        panelAppearance =
            d.string(forKey: Key.panelAppearance).flatMap(PanelAppearance.init) ?? .system
        panelPosition = d.string(forKey: Key.panelPosition).flatMap(PanelPosition.init) ?? .center
        highlightColor =
            d.string(forKey: Key.highlightColor).flatMap(Color.init(hex:)) ?? Self.defaultHighlight
        hotkey = Self.loadHotkey(d, Key.hotkeyKeyCode, Key.hotkeyModifiers, default: .commandTab)
        cycleHotkey = Self.loadHotkey(
            d, Key.cycleKeyCode, Key.cycleModifiers, default: Self.defaultCycleHotkey)
        showDelay = d.object(forKey: Key.showDelay) != nil ? d.double(forKey: Key.showDelay) : 0
        windowScope = d.string(forKey: Key.windowScope).flatMap(WindowScope.init) ?? .allSpaces
        hideEmptyApps = d.bool(forKey: Key.hideEmptyApps)
        maxColumns = d.integer(forKey: Key.maxColumns)
        panelMaterial = d.string(forKey: Key.panelMaterial).flatMap(PanelMaterial.init) ?? .hud
        panelOpacity = d.object(forKey: Key.panelOpacity) != nil
            ? d.double(forKey: Key.panelOpacity) : 1.0
        blurOverride = d.bool(forKey: Key.blurOverride)
        blurRadius = d.object(forKey: Key.blurRadius) != nil ? d.double(forKey: Key.blurRadius) : 20
        showNumbers = d.object(forKey: Key.showNumbers) != nil ? d.bool(forKey: Key.showNumbers) : true
        alwaysShowTitles = d.bool(forKey: Key.alwaysShowTitles)
        tileCorner = d.object(forKey: Key.tileCorner) != nil ? d.double(forKey: Key.tileCorner) : 12
        titleFontSize = d.object(forKey: Key.titleFontSize) != nil
            ? d.double(forKey: Key.titleFontSize) : 10
        titleWeight = d.string(forKey: Key.titleWeight).flatMap(TitleWeight.init) ?? .regular
        truncation = d.string(forKey: Key.truncation).flatMap(TruncationStyle.init) ?? .tail
        fade = d.bool(forKey: Key.fade)
        showMenuBarIcon = d.object(forKey: Key.showMenuBarIcon) != nil
            ? d.bool(forKey: Key.showMenuBarIcon) : true
        reflectMode = d.bool(forKey: Key.reflectMode)
    }

    private static func loadHotkey(
        _ d: UserDefaults, _ codeKey: String, _ modKey: String, default fallback: Hotkey
    ) -> Hotkey {
        guard d.object(forKey: codeKey) != nil else { return fallback }
        return Hotkey(
            keyCode: d.integer(forKey: codeKey),
            modifierRaw: UInt64(bitPattern: Int64(d.integer(forKey: modKey))))
    }

    private func store(_ value: Any, _ key: String, _ changed: Bool) {
        guard changed else { return }
        UserDefaults.standard.set(value, forKey: key)
        onChange?()
    }

    private func storeColor(_ new: Color, _ old: Color) {
        guard new != old else { return }
        UserDefaults.standard.set(new.hexString, forKey: Key.highlightColor)
        onChange?()
    }

    private func storeHotkey(_ new: Hotkey, _ old: Hotkey, _ codeKey: String, _ modKey: String) {
        guard new != old else { return }
        let d = UserDefaults.standard
        d.set(new.keyCode, forKey: codeKey)
        d.set(Int(Int64(bitPattern: new.modifierRaw)), forKey: modKey)
        onChange?()
    }

    /// Wipes every owned key and reloads defaults into a fresh process on next launch. Applied by
    /// re-reading; callers should also refresh dependent stores.
    func resetAll() {
        let d = UserDefaults.standard
        for key in Self.ownedDefaultsKeys { d.removeObject(forKey: key) }
        onChange?()
    }
}

extension Color {
    /// Parses `#RRGGBB`. Alpha is not stored — the highlight applies its own opacity.
    init?(hex: String) {
        var s = hex
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6, let value = Int(s, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }

    var hexString: String {
        let ns = NSColor(self).usingColorSpace(.sRGB) ?? .systemBlue
        let r = Int((ns.redComponent * 255).rounded())
        let g = Int((ns.greenComponent * 255).rounded())
        let b = Int((ns.blueComponent * 255).rounded())
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}
