import AppKit
import CoreGraphics

// Global chords that do something other than open the switcher: jump straight to a named app, and
// clear the screen down to the desktop.
//
// Both follow the pattern `WindowTiling` established — a value-type snapshot the tap reads, a store
// that persists it, and matching in the controller's idle branch. Neither ships a default binding:
// unlike the tiling chords, which sit on ⌃⌘ as a set, these have no natural home key, and claiming
// a combination system-wide on someone's behalf is not a guess worth making.

// MARK: - Direct activation

/// One app reachable by its own chord.
struct DirectActivation: Equatable, Identifiable {
    let bundleID: String
    var hotkey: Hotkey

    var id: String { bundleID }
}

/// The direct-activation bindings, matched against a keypress by the controller.
struct DirectActivations: Equatable {
    /// Ordered rather than a dictionary so the settings list does not reshuffle itself on every
    /// edit, and so a duplicate chord always resolves to the same app.
    var entries: [DirectActivation] = []

    func bundleID(code: Int, flags: CGEventFlags) -> String? {
        let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return entries.first {
            guard $0.hotkey.isUsableGlobally else { return false }
            let want = $0.hotkey.modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return $0.hotkey.keyCode == code && want == held
        }?.bundleID
    }

    /// Other entries sharing a chord with the one at `bundleID`. Same treatment as the tiling
    /// conflicts: shown rather than refused, because swapping a pair needs a colliding step.
    func conflicts(with bundleID: String) -> [String] {
        guard let entry = entries.first(where: { $0.bundleID == bundleID }) else { return [] }
        return entries.filter { $0.bundleID != bundleID && $0.hotkey == entry.hotkey }
            .map(\.bundleID)
    }
}

/// The two chords that hide or restore everything.
struct AllWindowsShortcuts: Equatable {
    var hideAll: Hotkey?
    var showAll: Hotkey?

    func action(code: Int, flags: CGEventFlags) -> AllWindowsAction? {
        let held = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        func matches(_ hotkey: Hotkey?) -> Bool {
            guard let hotkey, hotkey.isUsableGlobally else { return false }
            let want = hotkey.modifiers.intersection(
                [.maskCommand, .maskAlternate, .maskControl, .maskShift])
            return hotkey.keyCode == code && want == held
        }
        if matches(hideAll) { return .hide }
        if matches(showAll) { return .show }
        return nil
    }
}

enum AllWindowsAction {
    case hide
    case show
}

/// Everything the two sections above persist.
@MainActor
final class GlobalActionsStore: ObservableObject {
    static let shared = GlobalActionsStore()

    private enum Key {
        static let directActivation = "directActivationShortcuts"
        static let hideAll = "hideAllWindowsShortcut"
        static let showAll = "showAllWindowsShortcut"
    }

    static let defaultsKeys = [Key.directActivation, Key.hideAll, Key.showAll]

    @Published private(set) var activations = DirectActivations()
    @Published private(set) var allWindows = AllWindowsShortcuts()

    /// The arrangement currently armed for recording. One monitor, one owner — see
    /// `WindowTilingStore.beginRecording` for why these do not live in the views.
    @Published private(set) var recordingID: String?
    private var recordingMonitor: Any?
    /// This store's claim on `KeyRecorder`.
    private var recordingToken: Int?

    var onChange: (() -> Void)?

    private init() { load() }

    // MARK: Direct activation

    func add(bundleID: String) {
        guard !activations.entries.contains(where: { $0.bundleID == bundleID }) else { return }
        // Added unbound. Picking an app and picking its chord are two decisions, and guessing a
        // free combination on the user's behalf is how you end up shadowing something of theirs.
        activations.entries.append(
            DirectActivation(bundleID: bundleID, hotkey: Hotkey(keyCode: -1, modifierRaw: 0)))
        persist()
    }

    func remove(bundleID: String) {
        activations.entries.removeAll { $0.bundleID == bundleID }
        persist()
    }

    func setHotkey(_ hotkey: Hotkey?, for bundleID: String) {
        guard let index = activations.entries.firstIndex(where: { $0.bundleID == bundleID }) else {
            return
        }
        activations.entries[index].hotkey = hotkey ?? Hotkey(keyCode: -1, modifierRaw: 0)
        persist()
    }

    /// nil when the entry exists but has no chord yet. `keyCode == -1` is the unbound marker: 0 is a
    /// real key (A), so there is no in-band sentinel available.
    func hotkey(for bundleID: String) -> Hotkey? {
        guard let entry = activations.entries.first(where: { $0.bundleID == bundleID }),
            entry.hotkey.keyCode >= 0
        else { return nil }
        return entry.hotkey
    }

    // MARK: All windows

    func setHideAll(_ hotkey: Hotkey?) {
        allWindows.hideAll = hotkey
        persist()
    }

    func setShowAll(_ hotkey: Hotkey?) {
        allWindows.showAll = hotkey
        persist()
    }

    // MARK: Recording

    /// `id` is the bundle identifier for a direct activation, or one of the two all-windows keys.
    func beginRecording(
        _ id: String, validate: @escaping (Hotkey) -> Bool, assign: @escaping (Hotkey?) -> Void
    ) {
        stopRecording()
        // Across kinds too, not just this store's own rows — see `KeyRecorder`.
        recordingToken = KeyRecorder.arm { [weak self] in self?.stopRecording() }
        recordingID = id
        recordingMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case 53:  // ⎋ aborts
                self.stopRecording()
                return nil
            case 51:  // ⌫ unassigns
                self.stopRecording()
                DispatchQueue.main.async { assign(nil) }
                return nil
            default:
                break
            }
            let mods = Hotkey.flags(from: event.modifierFlags)
            guard mods.intersection([.maskCommand, .maskAlternate, .maskControl]) != [] else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            self.stopRecording()
            DispatchQueue.main.async {
                guard validate(candidate) else { return }
                assign(candidate)
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
        onChange?()
    }

    /// Direct activations persist as an ordered array of `[bundleID, keyCode, modifierRaw]`, which
    /// keeps the user's ordering without a second key to hold it.
    private func load() {
        let defaults = UserDefaults.standard
        var loaded = DirectActivations()
        if let raw = defaults.array(forKey: Key.directActivation) as? [[Any]] {
            for row in raw {
                guard row.count == 3, let bundleID = row[0] as? String,
                    let keyCode = row[1] as? Int, let mods = row[2] as? Int
                else { continue }
                loaded.entries.append(
                    DirectActivation(
                        bundleID: bundleID,
                        hotkey: Hotkey(
                            keyCode: keyCode, modifierRaw: UInt64(bitPattern: Int64(mods)))))
            }
        }
        activations = loaded
        allWindows = AllWindowsShortcuts(
            hideAll: Self.readHotkey(Key.hideAll), showAll: Self.readHotkey(Key.showAll))
    }

    private static func readHotkey(_ key: String) -> Hotkey? {
        guard let pair = UserDefaults.standard.array(forKey: key) as? [Int], pair.count == 2 else {
            return nil
        }
        return Hotkey(keyCode: pair[0], modifierRaw: UInt64(bitPattern: Int64(pair[1])))
    }

    private func persist() {
        let defaults = UserDefaults.standard
        defaults.set(
            activations.entries.map {
                [$0.bundleID, $0.hotkey.keyCode, Int(bitPattern: UInt($0.hotkey.modifierRaw))]
                    as [Any]
            }, forKey: Key.directActivation)
        Self.write(allWindows.hideAll, to: Key.hideAll)
        Self.write(allWindows.showAll, to: Key.showAll)
        onChange?()
    }

    private static func write(_ hotkey: Hotkey?, to key: String) {
        guard let hotkey else {
            UserDefaults.standard.removeObject(forKey: key)
            return
        }
        UserDefaults.standard.set(
            [hotkey.keyCode, Int(bitPattern: UInt(hotkey.modifierRaw))], forKey: key)
    }
}

// MARK: - Performing

/// Everything here is posted rather than run inline.
///
/// The only caller is the event-tap callback, and `SwitcherController`'s invariant is explicit that
/// NSWorkspace and LaunchServices belong behind a `DispatchQueue.main.async`: a tap that overruns
/// the system's deadline is disabled outright, and while it is down *every* keystroke on the machine
/// is dropped. `perform(.hide)` walks every running application and sends each one a `hide()`, and
/// `activate` can reach LaunchServices for an app that is not running — neither is anywhere near
/// cheap enough for the callback. Deferring costs nothing: nothing here reports back, and the key is
/// already swallowed by the time these run.
///
/// It also does not, on its own, make them safe — the tap is serviced by the main run loop, so this
/// moves the work off the callback without moving it off the callback's *thread*. See the second
/// half of `SwitcherController`'s doc comment for what that distinction means. These stay on main
/// because the alternative is worse rather than because they are free: `NSWorkspace` and
/// `NSRunningApplication` are main-thread APIs, and both calls below are asynchronous in the sense
/// that matters — `hide()` posts a request to the app and returns rather than waiting on it, so the
/// walk is bounded by the number of running apps and not by the slowest one. Anything added here
/// that would *wait* on another process belongs on a queue of its own instead.
enum GlobalActions {
    /// Brings an app forward, launching it if it is not running.
    ///
    /// A running app goes through `SwitchTarget.focusApp`, the same path a tile pick takes, rather
    /// than being activated here. This used to call `activate(options: .activateAllWindows)`, which
    /// is the one call that drags an app's windows off the Desktops they live on and onto the one in
    /// front of you — so a shortcut meant to bring Ghostty up gathered the Ghostty window from
    /// Desktop 1 instead of taking you to it. `focusApp` fronts a single window and travels to its
    /// Desktop when that is where it is.
    ///
    /// Re-opening the bundle is still avoided for a running app: `openApplication` works on one, but
    /// it also asks LaunchServices to resolve and open the bundle, which is a disk hit on the path
    /// where the app is already right there.
    static func activate(bundleID: String) {
        DispatchQueue.main.async {
            if let running = NSWorkspace.shared.runningApplications.first(where: {
                $0.bundleIdentifier == bundleID && !$0.isTerminated
            }) {
                if running.isHidden { running.unhide() }
                SwitchTarget.focusApp(
                    pid: running.processIdentifier, bundleURL: running.bundleURL)
                return
            }
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
            else {
                Log.general.error("direct activation: no app for \(bundleID, privacy: .public)")
                return
            }
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    }

    /// Bundle ids hidden by the last "hide all", so "show all" restores exactly those.
    ///
    /// Without it, showing all would also unhide apps the user had hidden themselves, quietly
    /// undoing a decision this feature never made.
    @MainActor private static var hiddenByUs: [String] = []

    static func perform(_ action: AllWindowsAction) {
        DispatchQueue.main.async {
            switch action {
            case .hide:
                var hidden: [String] = []
                for app in NSWorkspace.shared.runningApplications {
                    guard app.activationPolicy == .regular, !app.isHidden, !app.isTerminated,
                        let id = app.bundleIdentifier, id != Bundle.main.bundleIdentifier
                    else { continue }
                    if app.hide() { hidden.append(id) }
                }
                hiddenByUs = hidden
            case .show:
                // Restore what we hid; if that list is empty — a fresh launch, say — fall back to
                // unhiding everything, which is what someone pressing "show all" plainly means.
                let targets = hiddenByUs
                for app in NSWorkspace.shared.runningApplications {
                    guard app.activationPolicy == .regular, app.isHidden,
                        let id = app.bundleIdentifier
                    else { continue }
                    if targets.isEmpty || targets.contains(id) { app.unhide() }
                }
                hiddenByUs = []
            }
        }
    }
}
