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
    case currentDisplay
    case minimized

    var id: String { rawValue }

    var title: String {
        switch self {
        case .frontApp: return "This app's windows"
        case .allWindows: return "All windows"
        case .currentDisplay: return "Windows on this display"
        case .minimized: return "Minimized windows"
        }
    }

    var detail: String {
        switch self {
        case .frontApp:
            return "The frontmost app's windows — the same list the app-window cycle shows."
        case .allWindows:
            return "Every window of every app, whatever the switcher is normally set to list."
        case .currentDisplay:
            return "Only windows on the display you are working on."
        case .minimized:
            return "Only windows currently in the Dock."
        }
    }
}

/// One scoped trigger. `id` is a stable handle for the settings list and the shortcut recorder; it
/// is never shown.
struct ScopedTrigger: Equatable, Identifiable {
    let id: String
    var hotkey: Hotkey
    var scope: SwitcherScope

    /// `keyCode == -1` marks a trigger that has been added but not yet bound. 0 is a real key (A),
    /// so there is no in-band sentinel available. `Hotkey.isUsableGlobally` folds this in with the
    /// modifier requirement, which is what the matcher checks.
    var isBound: Bool { hotkey.keyCode >= 0 }
}

/// The scoped triggers, matched against a keypress by the controller.
struct ScopedTriggers: Equatable {
    var triggers: [ScopedTrigger] = []

    /// The scope a keypress opens, if any. Unbound entries never match.
    func scope(code: Int, flags: CGEventFlags) -> (scope: SwitcherScope, held: CGEventFlags)? {
        guard
            let match = triggers.first(where: {
                $0.hotkey.isUsableGlobally && $0.hotkey.keyCode == code
                    && TriggerModifiers.opens(flags, held: $0.hotkey.heldModifiers)
            })
        else { return nil }
        return (match.scope, match.hotkey.heldModifiers)
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
            DispatchQueue.main.async {
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

    /// Stored as an ordered array of `[id, keyCode, modifierRaw, scope]`.
    private func load() {
        var loaded = ScopedTriggers()
        if let raw = UserDefaults.standard.array(forKey: Key.triggers) as? [[Any]] {
            for row in raw {
                guard row.count == 4, let id = row[0] as? String, let keyCode = row[1] as? Int,
                    let mods = row[2] as? Int, let scopeRaw = row[3] as? String,
                    let scope = SwitcherScope(rawValue: scopeRaw)
                else { continue }
                loaded.triggers.append(
                    ScopedTrigger(
                        id: id,
                        hotkey: Hotkey(
                            keyCode: keyCode, modifierRaw: UInt64(bitPattern: Int64(mods))),
                        scope: scope))
            }
        }
        scoped = loaded
    }

    private func persist() {
        UserDefaults.standard.set(
            scoped.triggers.map {
                [$0.id, $0.hotkey.keyCode, Int(bitPattern: UInt($0.hotkey.modifierRaw)),
                 $0.scope.rawValue] as [Any]
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
