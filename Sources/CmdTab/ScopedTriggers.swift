import AppKit
import CoreGraphics
import SwiftUI

// Extra switcher triggers, each opening a *subset* of the window list.
//
// The same-app cycle was the first of these — one hotkey, one hard-coded scope. Rather than adding a
// setting per idea ("cycle minimized windows", "cycle this display"), a scoped trigger is a chord
// plus a scope, and the user adds as many as they want.

/// What a scoped trigger lists.
enum SwitcherScope: String, CaseIterable, Identifiable {
    case frontApp
    case allWindows
    case desktopsOverview
    case currentDisplay
    case currentDesktop
    case minimized
    case tabs

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontApp: return "This app's windows"
        case .allWindows: return "All windows"
        case .desktopsOverview: return "Desktops overview"
        case .currentDisplay: return "Windows on this display"
        case .currentDesktop: return "Windows on this desktop"
        case .minimized: return "Minimized windows"
        case .tabs: return "Browser and terminal tabs"
        }
    }

    var detail: String {
        switch self {
        case .frontApp:
            return "The frontmost app's windows — the same list the app-window cycle shows."
        case .allWindows:
            return "Every window of every app, whatever the switcher is normally set to list."
        case .desktopsOverview:
            return "Every window of every app, grouped under a header per Desktop — a searchable "
                + "map of the whole desk. Type to filter it exactly like the main switcher."
        case .currentDisplay:
            return "Only windows on the display you are working on."
        case .currentDesktop:
            return "Only windows on the Desktop (Space) in front. With more than one display, "
                + "each has its own front Desktop and both count as here."
        case .minimized:
            return "Only windows currently in the Dock."
        case .tabs:
            return "One tile per tab of the frontmost window of every running app that exposes "
                + "tabs — browsers and terminals, mostly. Gathered fresh each time this opens, "
                + "since keeping the list warm would mean walking every app's tabs on every "
                + "refresh."
        }
    }
}

/// One scoped trigger. `id` is a stable handle for the settings list and the shortcut recorder; it
/// is never shown.
struct ScopedTrigger: Equatable, Identifiable {
    let id: String
    var hotkey: Hotkey
    var scope: SwitcherScope
    var overrides = Overrides()

    /// `keyCode == -1` marks a trigger that has been added but not yet bound. 0 is a real key (A),
    /// so there is no in-band sentinel available. `Hotkey.isUsableGlobally` folds this in with the
    /// modifier requirement, which is what the matcher checks.
    var isBound: Bool { hotkey.keyCode >= 0 }

    /// How this trigger's sessions differ from the main switcher, field by field. `nil` inherits
    /// the global setting at the moment the session opens — the scoped-trigger idea ("a chord plus
    /// a scope, not a setting per idea") extended to presentation: one chord can be the icon grid
    /// while another is a dense list of this Desktop's windows.
    ///
    /// Resolved once when the session opens and put back when it ends, never read live by the
    /// panel: the stores stay the single source of the *global* settings, and a scoped session
    /// only borrows the panel from them. See `SwitcherController.beginSessionOverrides`.
    struct Overrides: Equatable {
        var layout: SwitcherLayout?
        var panelPosition: PanelPosition?
        var sortOrder: SortOrder?
        var groupWindowsByApp: Bool?
        var windowThumbnailTiles: Bool?
        /// A plain Bool where everything else inherits: a scoped chord is never sticky unless
        /// *this trigger* asks. The global Stay open belongs to the chord the user set it for —
        /// the reasoning `openScoped` has always carried — so there is no "Default" to inherit.
        var staysOpen = false

        var isDefault: Bool { self == Overrides() }

        private enum Key {
            static let layout = "layout"
            static let position = "position"
            static let sortOrder = "sortOrder"
            static let groupByApp = "groupByApp"
            static let thumbnails = "thumbnails"
            static let staysOpen = "staysOpen"
        }

        init() {}

        /// Value-tolerant the way the row parser is row-tolerant: one malformed or unknown value
        /// (a hand-edited config, an enum case from a newer build) costs that value alone and
        /// falls back to inheriting, never the trigger.
        init(stored: [String: Any]?) {
            guard let stored else { return }
            layout = (stored[Key.layout] as? String).flatMap(SwitcherLayout.init(rawValue:))
            panelPosition = (stored[Key.position] as? String).flatMap(PanelPosition.init(rawValue:))
            sortOrder = (stored[Key.sortOrder] as? String).flatMap(SortOrder.init(rawValue:))
            groupWindowsByApp = stored[Key.groupByApp] as? Bool
            windowThumbnailTiles = stored[Key.thumbnails] as? Bool
            staysOpen = stored[Key.staysOpen] as? Bool ?? false
        }

        /// Only the fields that differ from "inherit everything" are written, so an untouched
        /// trigger round-trips to an empty dictionary — which `persist()` then leaves off the row
        /// entirely, keeping the stored shape one an older build still reads.
        var stored: [String: Any] {
            var dict: [String: Any] = [:]
            if let layout { dict[Key.layout] = layout.rawValue }
            if let panelPosition { dict[Key.position] = panelPosition.rawValue }
            if let sortOrder { dict[Key.sortOrder] = sortOrder.rawValue }
            if let groupWindowsByApp { dict[Key.groupByApp] = groupWindowsByApp }
            if let windowThumbnailTiles { dict[Key.thumbnails] = windowThumbnailTiles }
            if staysOpen { dict[Key.staysOpen] = true }
            return dict
        }
    }
}

/// The scoped triggers, matched against a keypress by the controller.
struct ScopedTriggers: Equatable {
    var triggers: [ScopedTrigger] = []

    init() {}

    /// Rebuilds the triggers from the stored ordered array of `[id, keyCode, modifierRaw, scope]`
    /// or `[id, keyCode, modifierRaw, scope, overrides]`, row by row: one malformed row
    /// (hand-edited config, an unknown scope from a newer build) costs that row alone, where
    /// casting the array as a unit would drop every trigger. The overrides element is optional —
    /// a trigger with none is written without it, so its row keeps the four-element shape older
    /// builds require exactly (`row.count == 4` there, so a fifth element drops the whole row).
    init(stored: [Any]?) {
        for element in stored ?? [] {
            guard let row = element as? [Any], row.count >= 4, let id = row[0] as? String,
                let keyCode = row[1] as? Int, let mods = row[2] as? Int,
                let scopeRaw = row[3] as? String, let scope = SwitcherScope(rawValue: scopeRaw)
            else { continue }
            triggers.append(
                ScopedTrigger(
                    id: id,
                    hotkey: Hotkey(keyCode: keyCode, modifierRaw: UInt64(bitPattern: Int64(mods))),
                    scope: scope,
                    overrides: ScopedTrigger.Overrides(
                        stored: row.count >= 5 ? row[4] as? [String: Any] : nil)))
        }
    }

    /// The trigger a keypress opens, if any — the whole trigger, because the session it starts
    /// needs its overrides along with its scope. Unbound entries never match.
    func trigger(code: Int, flags: CGEventFlags) -> ScopedTrigger? {
        triggers.first(where: {
            $0.hotkey.isUsableGlobally && $0.hotkey.keyCode == code
                && TriggerModifiers.opens(flags, held: $0.hotkey.heldModifiers)
        })
    }
}

@MainActor
final class ScopedTriggersStore: ObservableObject {
    static let shared = ScopedTriggersStore()

    private enum Key {
        static let triggers = "scopedTriggers"
    }

    static let defaultsKeys = [Key.triggers]

    @Published private(set) var scoped = ScopedTriggers()

    /// One monitor, one owner — see `WindowTilingStore.beginRecording`.
    @Published private(set) var recordingID: String?
    private var recordingMonitor: Any?
    /// This store's claim on `KeyRecorder`.
    private var recordingToken: Int?

    var onChange: ((ScopedTriggers) -> Void)?

    private init() { load() }

    func add(scope: SwitcherScope) {
        // Added unbound, like a direct activation: choosing the scope and choosing the chord are two
        // decisions, and picking a global combination on someone's behalf is not ours to guess.
        scoped.triggers.append(
            ScopedTrigger(
                id: UUID().uuidString, hotkey: Hotkey(keyCode: -1, modifierRaw: 0), scope: scope))
        persist()
    }

    func remove(id: String) {
        scoped.triggers.removeAll { $0.id == id }
        persist()
    }

    func setHotkey(_ hotkey: Hotkey?, for id: String) {
        guard let index = scoped.triggers.firstIndex(where: { $0.id == id }) else { return }
        scoped.triggers[index].hotkey = hotkey ?? Hotkey(keyCode: -1, modifierRaw: 0)
        persist()
    }

    func hotkey(for id: String) -> Hotkey? {
        guard let trigger = scoped.triggers.first(where: { $0.id == id }), trigger.isBound else {
            return nil
        }
        return trigger.hotkey
    }

    func setOverrides(_ overrides: ScopedTrigger.Overrides, for id: String) {
        guard let index = scoped.triggers.firstIndex(where: { $0.id == id }),
            scoped.triggers[index].overrides != overrides
        else { return }
        scoped.triggers[index].overrides = overrides
        persist()
    }

    // MARK: Recording

    func beginRecording(
        _ id: String, validate: @escaping (Hotkey) -> Bool
    ) {
        stopRecording()
        // Across kinds too, not just this store's own rows — see `KeyRecorder`.
        recordingToken = KeyRecorder.arm { [weak self] in self?.stopRecording() }
        recordingID = id
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:
                self.stopRecording()
                return nil
            case 51:
                self.stopRecording()
                DispatchQueue.main.async { self.setHotkey(nil, for: id) }
                return nil
            default:
                break
            }
            let mods = Hotkey.flags(from: event.modifierFlags)
            // A scoped trigger is held open like the main one, so it needs a modifier to hold.
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            self.stopRecording()
            // A run-loop hop, not a dispatch one: `validate` may raise a modal. See `MainRunLoop`.
            MainRunLoop.perform {
                guard validate(candidate) else { return }
                self.setHotkey(candidate, for: id)
            }
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingID = nil
        if let recordingToken { KeyRecorder.disarmed(recordingToken) }
        recordingToken = nil
    }

    // MARK: Persistence

    func reload() {
        load()
        onChange?(scoped)
    }

    private func load() {
        scoped = ScopedTriggers(stored: UserDefaults.standard.array(forKey: Key.triggers))
    }

    private func persist() {
        UserDefaults.standard.set(
            scoped.triggers.map { trigger -> [Any] in
                var row: [Any] = [
                    trigger.id, trigger.hotkey.keyCode,
                    Int(bitPattern: UInt(trigger.hotkey.modifierRaw)), trigger.scope.rawValue,
                ]
                // Appended only when set — see `ScopedTriggers.init(stored:)` for why the
                // four-element shape is kept where it can be.
                let overrides = trigger.overrides.stored
                if !overrides.isEmpty { row.append(overrides) }
                return row
            }, forKey: Key.triggers)
        onChange?(scoped)
    }
}

// MARK: - Recorder

/// Records a scoped trigger's chord. Same shape as the other global recorders: the store owns the
/// single keyboard monitor, ⌫ clears, ⎋ cancels, and a chord one of the built-in triggers already
/// claims is refused rather than stored dead.
struct ScopedShortcutRecorder: View {
    let trigger: ScopedTrigger
    @ObservedObject var store: ScopedTriggersStore

    private var hotkey: Hotkey? { store.hotkey(for: trigger.id) }
    private var isRecording: Bool { store.recordingID == trigger.id }

    var body: some View {
        HStack(spacing: 4) {
            Button(isRecording ? "Press keys…" : (hotkey?.displayString ?? "Not set")) {
                isRecording ? store.stopRecording() : start()
            }
            .frame(width: 128)
            .foregroundStyle(isBroken ? Color.orange : Color.primary)

            Button {
                store.setHotkey(nil, for: trigger.id)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Clear this shortcut")
            .opacity(hotkey == nil ? 0 : 1)
            .disabled(hotkey == nil)
        }
        .onDisappear { if isRecording { store.stopRecording() } }
    }

    private var isBroken: Bool {
        guard let hotkey else { return false }
        return WindowTilingBindings.triggerClaiming(hotkey, in: .shared) != nil
    }

    private func start() {
        store.beginRecording(trigger.id) { candidate in
            if let claimer = WindowTilingBindings.triggerClaiming(candidate, in: .shared) {
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(candidate.displayString) is already \(claimer)"
                alert.informativeText =
                    "Both built-in triggers are matched before scoped ones, so this combination "
                    + "would open the full switcher instead — the binding would look set and never "
                    + "fire."
                alert.addButton(withTitle: "OK")
                alert.runModal()
                return false
            }
            // The other half, which this recorder never had. A scoped trigger holds its modifiers
            // for the whole of its session exactly as the main trigger does, so binding one on ⌘⌥
            // takes ⌥ away from every in-switcher action — and nothing said so: no alert here, no
            // orange subtitle on the action rows, no log line. The keys fell through to
            // type-to-filter, which is the silent failure `HotkeyRecorder`'s own call to
            // `actionsShadowed` exists to prevent for the trigger it records.
            let actions = SwitcherShortcutsStore.shared
            guard actions.isEnabled else { return true }
            let shadowed = actions.shortcuts.actionsShadowed(by: candidate)
            guard !shadowed.isEmpty else { return true }
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText =
                "\(candidate.displayString) would stop \(shadowed.count) switcher action"
                + (shadowed.count == 1 ? "" : "s") + " working"
            alert.informativeText = """
                Holding this trigger claims the modifier \
                \(shadowed.map(\.title).joined(separator: ", ")) \
                need\(shadowed.count == 1 ? "s" : "") as an extra, so \
                \(shadowed.count == 1 ? "it would" : "they would") type into the filter instead of \
                running.

                Pick a trigger on a different modifier, or rebind the action\
                \(shadowed.count == 1 ? "" : "s") under Shortcuts.
                """
            alert.addButton(withTitle: "OK")
            alert.runModal()
            return false
        }
    }
}

// MARK: - Presets

/// The per-trigger presets popover: how this chord's sessions look and behave where they differ
/// from the main switcher. Every "Default" names the global value it would inherit, so the menu
/// answers "what happens if I leave this alone" without a trip to the other panes.
struct ScopedTriggerOptions: View {
    let trigger: ScopedTrigger
    @ObservedObject var store: ScopedTriggersStore
    @ObservedObject var behavior: BehaviorStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            optionPicker("Layout", \.layout, cases: SwitcherLayout.allCases,
                         titles: { $0.title }, inherited: behavior.layout.title)
            optionPicker("Position", \.panelPosition, cases: PanelPosition.allCases,
                         titles: { $0.title }, inherited: behavior.panelPosition.title)
            optionPicker("Sort order", \.sortOrder, cases: SortOrder.allCases,
                         titles: { $0.title }, inherited: behavior.sortOrder.title)
            togglePicker("Group by app", \.groupWindowsByApp,
                         inherited: behavior.groupWindowsByApp)
            togglePicker("Thumbnails", \.windowThumbnailTiles,
                         inherited: behavior.windowThumbnailTiles)
            Divider()
            Toggle(isOn: binding(\.staysOpen)) { SettingsChrome.text("Stay open") }
                .toggleStyle(.switch)
                .controlSize(.small)
            SettingsChrome.text(
                "Keeps the panel up after the keys are released, whatever the main "
                    + "switcher's Stay open says."
            )
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(width: 240)
    }

    private func binding<V>(
        _ keyPath: WritableKeyPath<ScopedTrigger.Overrides, V>
    ) -> Binding<V> {
        Binding(
            get: {
                // Through the store, not the captured `trigger`: the popover outlives edits made
                // from inside itself, and a stale copy would revert every earlier change on the
                // next write.
                (store.scoped.triggers.first { $0.id == trigger.id } ?? trigger)
                    .overrides[keyPath: keyPath]
            },
            set: { value in
                var overrides =
                    (store.scoped.triggers.first { $0.id == trigger.id } ?? trigger).overrides
                overrides[keyPath: keyPath] = value
                store.setOverrides(overrides, for: trigger.id)
            })
    }

    private func optionPicker<V: Hashable>(
        _ title: String, _ keyPath: WritableKeyPath<ScopedTrigger.Overrides, V?>,
        cases: [V], titles: @escaping (V) -> String, inherited: String
    ) -> some View {
        labeled(title) {
            Picker("", selection: binding(keyPath)) {
                Text("Default (\(inherited))").tag(V?.none)
                Divider()
                ForEach(cases, id: \.self) { value in
                    Text(titles(value)).tag(Optional(value))
                }
            }
            .labelsHidden()
        }
    }

    private func togglePicker(
        _ title: String, _ keyPath: WritableKeyPath<ScopedTrigger.Overrides, Bool?>,
        inherited: Bool
    ) -> some View {
        labeled(title) {
            Picker("", selection: binding(keyPath)) {
                Text("Default (\(inherited ? String(localized: "On") : String(localized: "Off")))")
                    .tag(Bool?.none)
                Divider()
                Text("On").tag(Optional(true))
                Text("Off").tag(Optional(false))
            }
            .labelsHidden()
        }
    }

    private func labeled(_ title: String, @ViewBuilder control: () -> some View) -> some View {
        HStack {
            SettingsChrome.text(title).font(.system(size: 12))
            Spacer()
            control().frame(width: 140)
        }
    }
}
