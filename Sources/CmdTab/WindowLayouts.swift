import AppKit
import ApplicationServices

/// Named snapshots of where every window sits, restorable by chord — "Work", "Writing", "Review".
///
/// Two problems have to be solved, and both are about a layout outliving the moment it was captured.
///
/// **Which window is which.** `AXUIElement` is the identity the tiler uses for its restore points,
/// and it is right there because those live only as long as the session does. A saved layout has to
/// survive quitting the app, restarting the machine and reinstalling Cmd-Tab, and no live handle
/// survives any of that: not the element, not the `CGWindowID`, not the pid. So a saved window is
/// described the way a person would recognise it — its app, its title, where it sat in the app's
/// window list, and where it was on screen — and `assign` weighs all four at once.
///
/// **Where "there" is.** Frames are stored as a fraction of the display they were captured on, keyed
/// by that display's hardware UUID, never as absolute screen coordinates. Absolute coordinates are
/// only meaningful while the desk stays exactly as it was: undock the laptop and half the frames
/// name coordinates no display covers; swap a 2560-wide monitor for a 1920-wide one and every frame
/// is silently wrong while still looking plausible. A fraction of a named display survives all of
/// it, and degrades honestly when that display is gone — the window lands in the same relative place
/// on whatever screen is left, rather than being dropped or thrown into the void.
struct LayoutWindow: Equatable {
    let bundleID: String
    /// The window title at capture. The strongest single signal, and also the most fragile — a
    /// document window's title is its filename, and an editor's often carries a dirty marker.
    let title: String
    /// Where it sat in the app's Accessibility window list.
    let index: Int
    /// The hardware UUID of the display it was on, or nil if that could not be read at capture.
    let displayID: String?
    /// Origin and size as fractions of that display's visible area. An origin of (0.5, 0) and a size
    /// of (0.5, 1) is the right half, whatever the monitor.
    let relativeFrame: CGRect
}

/// One live window, reduced to what matching needs. Read once per app, so the scorer never touches
/// Accessibility itself.
struct LiveWindow: Equatable {
    let title: String
    /// Absolute, in Accessibility's top-left space.
    let frame: CGRect
}

/// One named layout.
struct WindowLayout: Identifiable, Equatable {
    let id: String
    var name: String
    var windows: [LayoutWindow]
    /// The chord that restores it. Nil until the user records one — a layout is saved and named
    /// first, and choosing a free combination on their behalf is how you shadow something of theirs.
    var hotkey: Hotkey?
}

// MARK: - Geometry

enum LayoutGeometry {
    /// Converts an absolute frame into a fraction of whichever display it mostly sits on.
    ///
    /// "Mostly", not "touches": a window straddling two monitors belongs to the one it is actually
    /// being used on, the same rule `WindowTiler.apply` uses to pick a screen.
    static func relative(_ frame: CGRect, displays: [WindowTiler.DisplayArea])
        -> (displayID: String?, relativeFrame: CGRect)?
    {
        // The one shared rule — see `WindowTiler.homeDisplay`. It answers nil for a window that
        // overlaps no display, where `max(by:)` used to keep the first element on the all-zero
        // comparison and record the window as a fraction of display 0's area.
        guard
            let index = WindowTiler.homeDisplay(of: frame, in: displays.map(\.area))
        else { return nil }
        let home = displays[index]
        guard home.area.width > 0, home.area.height > 0 else { return nil }
        let area = home.area
        return (
            home.id,
            CGRect(
                x: (frame.minX - area.minX) / area.width,
                y: (frame.minY - area.minY) / area.height,
                width: frame.width / area.width,
                height: frame.height / area.height)
        )
    }

    /// Turns a saved fraction back into an absolute frame on the display it names.
    ///
    /// Falls back to the primary display when that one is not connected — the honest degradation.
    /// A window from an absent monitor lands in the same relative place on a screen the user can
    /// actually see, which beats both dropping it and putting it at coordinates nothing covers.
    /// The same fallback catches a window whose display had no readable UUID when it was captured,
    /// which is saved as no display at all and cannot be told apart from one that has since gone.
    ///
    /// "Primary" is the display carrying the menu bar, asked of the display list rather than taken
    /// as its first element: the list is in `NSScreen.screens` order so that callers who pair it
    /// with a screen index stay aligned, and nothing promises the primary sits at the front of it.
    static func absolute(_ window: LayoutWindow, displays: [WindowTiler.DisplayArea]) -> CGRect? {
        guard !displays.isEmpty else { return nil }
        let home =
            window.displayID.flatMap { id in displays.first { $0.id == id } }
            ?? displays.first(where: \.isPrimary)
            ?? displays[0]
        let area = home.area
        let frame = CGRect(
            x: area.minX + window.relativeFrame.minX * area.width,
            y: area.minY + window.relativeFrame.minY * area.height,
            width: window.relativeFrame.width * area.width,
            height: window.relativeFrame.height * area.height)
        return clamp(frame, into: area)
    }

    /// Keeps a frame on its display. A fraction wider than 1 — a window that was hanging off the
    /// edge when it was captured — would otherwise come back proportionally further off a smaller
    /// screen, which is how "restore my layout" loses a window on a laptop.
    static func clamp(_ frame: CGRect, into area: CGRect) -> CGRect {
        let size = CGSize(
            width: min(frame.width, area.width), height: min(frame.height, area.height))
        return CGRect(
            x: min(max(frame.minX, area.minX), area.maxX - size.width),
            y: min(max(frame.minY, area.minY), area.maxY - size.height),
            width: size.width, height: size.height)
    }
}

// MARK: - Matching

enum LayoutMatcher {
    /// A title match is worth more than any amount of overlap: two windows of one app can sit almost
    /// on top of each other, but they rarely share a title.
    static let titleScore = 1000
    /// Perfect overlap. Below a title match, above a bare position match — a window that has not
    /// moved since capture is very likely the same window, but a *new* window opened where an old
    /// one used to be looks identical by this measure alone.
    static let overlapScore = 200
    /// Same slot in the app's window list. Enough on its own, which is what keeps a layout working
    /// for an app that reopened with every title changed.
    static let indexScore = 25

    /// Pairs saved windows to live ones, best match first.
    ///
    /// Deliberately a global assignment rather than a walk down the saved list taking the first
    /// acceptable window for each. First-fit lets an early entry with a weak claim take a window
    /// that a later entry matches exactly, and the result depends on the order the layout happened
    /// to be captured in. Scoring every pair and taking the strongest first is stable, order-free,
    /// and lets position break the ties that titles cannot.
    ///
    /// Returns saved index → live index. Anything unmatched is absent, and its window is left where
    /// it is: moving the wrong window is worse than moving none, because the user cannot tell it
    /// happened until they look.
    static func assign(
        saved: [LayoutWindow], live: [LiveWindow], expected: [Int: CGRect]
    ) -> [Int: Int] {
        var pairs: [(saved: Int, live: Int, score: Int)] = []
        for (savedIndex, entry) in saved.enumerated() {
            for (liveIndex, candidate) in live.enumerated() {
                let score = score(entry, candidate, expected: expected[savedIndex], at: liveIndex)
                if score > 0 { pairs.append((savedIndex, liveIndex, score)) }
            }
        }
        // Ties break on the saved index and then the live one, so an ambiguous layout resolves the
        // same way every time it is restored rather than following the sort's internal order.
        pairs.sort {
            ($0.score, $1.saved, $1.live) > ($1.score, $0.saved, $0.live)
        }

        var result: [Int: Int] = [:]
        var takenLive = Set<Int>()
        for pair in pairs {
            guard result[pair.saved] == nil, !takenLive.contains(pair.live) else { continue }
            result[pair.saved] = pair.live
            takenLive.insert(pair.live)
        }
        return result
    }

    /// How strongly a saved window and a live one look like the same window. Zero means "no signal
    /// at all", which is never matched — the alternative is pairing two windows that have nothing
    /// in common just because both are unclaimed.
    static func score(
        _ saved: LayoutWindow, _ live: LiveWindow, expected: CGRect?, at liveIndex: Int
    ) -> Int {
        var total = 0
        // An empty saved title means the window had no title when captured, not that it should
        // match the first untitled window found.
        if !saved.title.isEmpty, saved.title == live.title { total += titleScore }
        if let expected { total += Int(overlap(expected, live.frame) * Double(overlapScore)) }
        if saved.index == liveIndex { total += indexScore }
        return total
    }

    /// Intersection over union, so a small window sitting inside a large one does not read as a
    /// near-perfect match the way plain intersection-over-self would.
    static func overlap(_ a: CGRect, _ b: CGRect) -> Double {
        let intersection = a.intersection(b).area
        guard intersection > 0 else { return 0 }
        let union = a.area + b.area - intersection
        guard union > 0 else { return 0 }
        return Double(intersection / union)
    }
}

// MARK: - Capture and restore

enum WindowLayoutEngine {
    /// Accessibility calls against every running app — never on the tap callback or the main thread.
    private static let queue = DispatchQueue(label: "com.cmdtab.layouts", qos: .userInitiated)

    /// What a restore did, for the pane to report. A layout that quietly places three of eight
    /// windows should say so.
    struct Result {
        var placed = 0
        /// Matched a live window, but its app was not running.
        var missingApps = 0
        /// The app was running, but no window looked enough like the saved one.
        var unmatched = 0
    }

    /// Snapshots every switchable window on the system.
    ///
    /// Runs on `queue` and comes back on the main thread, because reading a wedged app's window list
    /// blocks for the Accessibility messaging timeout and there may be dozens of apps.
    ///
    /// `@MainActor` for the prelude, not the walk: `NSScreen` and `NSWorkspace` are both read before
    /// anything is handed off, and the isolation is what makes that a compiler-checked fact rather
    /// than a comment every future caller has to notice.
    @MainActor
    static func capture(completion: @escaping ([LayoutWindow]) -> Void) {
        // `runningApplications` and `NSScreen` are both main-thread work, so they are read here and
        // only the Accessibility walk goes to the queue.
        let apps: [(pid: pid_t, bundleID: String)] = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .compactMap { app in
                guard let id = app.bundleIdentifier else { return nil }
                return (app.processIdentifier, id)
            }
        let displays = WindowTiler.visibleDisplays()
        let mine = ProcessInfo.processInfo.processIdentifier
        queue.async {
            var out: [LayoutWindow] = []
            for app in apps where app.pid != mine {
                for (index, window) in switchableWindows(pid: app.pid).enumerated() {
                    guard let origin = AX.position(window.element),
                        let size = AX.size(window.element),
                        let placed = LayoutGeometry.relative(
                            CGRect(origin: origin, size: size), displays: displays)
                    else { continue }
                    out.append(
                        LayoutWindow(
                            bundleID: app.bundleID,
                            title: window.title,
                            index: index,
                            displayID: placed.displayID,
                            relativeFrame: placed.relativeFrame))
                }
            }
            DispatchQueue.main.async { completion(out) }
        }
    }

    /// Puts every window back where the layout says, as far as it can.
    ///
    /// `@MainActor` for the same reason `capture` is: the running-application list and the display
    /// geometry are both read here, before the Accessibility work goes to `queue`.
    @MainActor
    static func restore(_ windows: [LayoutWindow], completion: ((Result) -> Void)? = nil) {
        let live = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && !$0.isTerminated }
            .reduce(into: [String: pid_t]()) { out, app in
                // First pid wins. Two copies of one app can run at once (two Xcodes, an app and its
                // beta); nothing in a saved layout distinguishes them, so picking consistently beats
                // picking arbitrarily.
                guard let id = app.bundleIdentifier, out[id] == nil else { return }
                out[id] = app.processIdentifier
            }
        let displays = WindowTiler.visibleDisplays()
        let byApp = Dictionary(grouping: windows, by: \.bundleID)
        queue.async {
            var result = Result()
            for (bundleID, saved) in byApp {
                guard let pid = live[bundleID] else {
                    result.missingApps += saved.count
                    continue
                }
                let candidates = switchableWindows(pid: pid)
                // Every Accessibility read for this app happens here, once. Scoring n saved windows
                // against n live ones touches each pair, and reading a title or a frame inside that
                // loop would be n² blocking round-trips into another process to place n windows.
                var frames: [CGRect] = []
                var reduced: [LiveWindow] = []
                for candidate in candidates {
                    let frame =
                        (AX.position(candidate.element).flatMap { origin in
                            AX.size(candidate.element).map { CGRect(origin: origin, size: $0) }
                        }) ?? .zero
                    frames.append(frame)
                    reduced.append(LiveWindow(title: candidate.title, frame: frame))
                }

                // Where each saved window wants to be, in today's coordinates — needed both to score
                // the overlap and, for whatever it matches, to actually place it.
                var expected: [Int: CGRect] = [:]
                for (index, entry) in saved.enumerated() {
                    expected[index] = LayoutGeometry.absolute(entry, displays: displays)
                }

                let assignment = LayoutMatcher.assign(
                    saved: saved, live: reduced, expected: expected)
                for index in saved.indices {
                    guard let liveIndex = assignment[index], let frame = expected[index] else {
                        result.unmatched += 1
                        continue
                    }
                    apply(frame, to: candidates[liveIndex].element)
                    result.placed += 1
                }
            }
            Log.general.notice(
                """
                layout restore: placed \(result.placed, privacy: .public), \
                app not running \(result.missingApps, privacy: .public), \
                no matching window \(result.unmatched, privacy: .public)
                """)
            if let completion {
                DispatchQueue.main.async { completion(result) }
            }
        }
    }

    /// An app's switchable windows with their titles, read in one pass. Runs on `queue`.
    private static func switchableWindows(pid: pid_t)
        -> [(element: AXUIElement, title: String)]
    {
        AX.windows(of: AX.application(pid))
            .filter(AX.isSwitchableWindow)
            .map { ($0, AX.copyString($0, kAXTitleAttribute) ?? "") }
    }

    /// Position → size → position, the order `WindowTiler` uses and for the same reason: some apps
    /// clamp a move against their current size, others clamp a resize against the screen edge from
    /// their old origin, and setting the origin twice around the resize is what makes both land.
    private static func apply(_ frame: CGRect, to window: AXUIElement) {
        AX.setPosition(window, frame.origin)
        AX.setSize(window, frame.size)
        AX.setPosition(window, frame.origin)
    }
}

// MARK: - Store

@MainActor
final class WindowLayoutsStore: ObservableObject {
    static let shared = WindowLayoutsStore()

    private static let layoutsKey = "windowLayouts"
    static let defaultsKeys = [layoutsKey]

    @Published private(set) var layouts: [WindowLayout] = []
    /// What the last restore managed, so the pane can say so rather than leaving the user to notice
    /// that three of their eight windows did not move.
    @Published private(set) var lastResult: (id: String, result: WindowLayoutEngine.Result)?

    /// The layout currently armed for recording. One monitor, one owner — see
    /// `SwitcherShortcutsStore.beginRecording` for why these do not live in the views.
    @Published private(set) var recordingID: String?
    private var recordingMonitor: Any?

    var onChange: (([WindowLayout]) -> Void)?

    private init() { layouts = Self.load() }

    /// Captures the current arrangement under a new name. Asynchronous — the Accessibility walk is
    /// off the main thread, so the layout appears when it comes back.
    func saveCurrent(named name: String) {
        WindowLayoutEngine.capture { [weak self] windows in
            guard let self else { return }
            guard !windows.isEmpty else {
                Log.general.error("layout save: nothing to capture")
                return
            }
            self.layouts.append(
                WindowLayout(id: UUID().uuidString, name: name, windows: windows, hotkey: nil))
            Log.general.notice("layout saved: \(windows.count, privacy: .public) window(s)")
            self.persist()
        }
    }

    /// Re-captures an existing layout in place, keeping its name and chord.
    func update(id: String) {
        WindowLayoutEngine.capture { [weak self] windows in
            guard let self, !windows.isEmpty,
                let index = self.layouts.firstIndex(where: { $0.id == id })
            else { return }
            self.layouts[index].windows = windows
            self.persist()
        }
    }

    func restore(id: String) {
        guard let layout = layouts.first(where: { $0.id == id }) else { return }
        WindowLayoutEngine.restore(layout.windows) { [weak self] result in
            self?.lastResult = (id, result)
        }
    }

    func rename(id: String, to name: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        // A layout with no name is unpickable in its own list, so an empty field keeps the old one
        // rather than being stored.
        guard !trimmed.isEmpty, layouts[index].name != trimmed else { return }
        layouts[index].name = trimmed
        persist()
    }

    func remove(id: String) {
        guard layouts.contains(where: { $0.id == id }) else { return }
        layouts.removeAll { $0.id == id }
        if lastResult?.id == id { lastResult = nil }
        persist()
    }

    func setHotkey(_ hotkey: Hotkey?, for id: String) {
        guard let index = layouts.firstIndex(where: { $0.id == id }) else { return }
        layouts[index].hotkey = hotkey
        persist()
    }

    func hotkey(for id: String) -> Hotkey? {
        layouts.first(where: { $0.id == id })?.hotkey
    }

    /// Layouts sharing a chord with `hotkey`, other than `id` itself — the pane's own clash warning.
    func conflicts(with hotkey: Hotkey, excluding id: String) -> [String] {
        layouts.filter { $0.id != id && $0.hotkey == hotkey }.map(\.name)
    }

    // MARK: Recording

    func beginRecording(_ id: String) {
        stopRecording()
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
                self.setHotkey(nil, for: id)
                return nil
            default:
                break
            }
            let mods = Self.cgFlags(from: event.modifierFlags)
            // A global chord needs a real modifier, or it would fire on every keystroke everywhere.
            guard !mods.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty else {
                return nil
            }
            let candidate = Hotkey(keyCode: Int(event.keyCode), modifierRaw: mods.rawValue)
            self.stopRecording()
            // Off the handler: this tears down the monitor currently executing it.
            DispatchQueue.main.async { self.setHotkey(candidate, for: id) }
            return nil
        }
    }

    func stopRecording() {
        if let recordingMonitor { NSEvent.removeMonitor(recordingMonitor) }
        recordingMonitor = nil
        recordingID = nil
    }

    private static func cgFlags(from flags: NSEvent.ModifierFlags) -> CGEventFlags {
        var out: CGEventFlags = []
        if flags.contains(.command) { out.insert(.maskCommand) }
        if flags.contains(.option) { out.insert(.maskAlternate) }
        if flags.contains(.control) { out.insert(.maskControl) }
        if flags.contains(.shift) { out.insert(.maskShift) }
        return out
    }

    // MARK: Persistence

    func reload() {
        layouts = Self.load()
        onChange?(layouts)
    }

    /// Stored as an array of plist dictionaries. Verbose next to a `Codable` blob, and deliberately
    /// so: this is the one setting whose contents someone might want to read — or fix — in a
    /// `config.json` under version control, and a base64 archive there would be opaque.
    private static func load() -> [WindowLayout] {
        guard let raw = UserDefaults.standard.array(forKey: layoutsKey) as? [[String: Any]] else {
            return []
        }
        return raw.compactMap { entry in
            guard let id = entry["id"] as? String,
                let name = entry["name"] as? String,
                let windows = entry["windows"] as? [[String: Any]]
            else { return nil }
            let parsed: [LayoutWindow] = windows.compactMap { window in
                guard let bundleID = window["bundleID"] as? String,
                    let index = window["index"] as? Int,
                    let x = window["x"] as? Double, let y = window["y"] as? Double,
                    let width = window["width"] as? Double, let height = window["height"] as? Double
                else { return nil }
                return LayoutWindow(
                    bundleID: bundleID,
                    title: window["title"] as? String ?? "",
                    index: index,
                    displayID: window["display"] as? String,
                    relativeFrame: CGRect(x: x, y: y, width: width, height: height))
            }
            // A code with no modifiers is how an unbound layout is stored, since `Hotkey` has no
            // empty form of its own.
            var hotkey: Hotkey?
            if let code = entry["keyCode"] as? Int, let mods = entry["modifiers"] as? Int {
                hotkey = Hotkey(keyCode: code, modifierRaw: UInt64(bitPattern: Int64(mods)))
            }
            return WindowLayout(id: id, name: name, windows: parsed, hotkey: hotkey)
        }
    }

    private func persist() {
        let raw: [[String: Any]] = layouts.map { layout in
            var entry: [String: Any] = [
                "id": layout.id,
                "name": layout.name,
                "windows": layout.windows.map { window -> [String: Any] in
                    var fields: [String: Any] = [
                        "bundleID": window.bundleID,
                        "index": window.index,
                        "x": Double(window.relativeFrame.origin.x),
                        "y": Double(window.relativeFrame.origin.y),
                        "width": Double(window.relativeFrame.size.width),
                        "height": Double(window.relativeFrame.size.height),
                    ]
                    if !window.title.isEmpty { fields["title"] = window.title }
                    if let display = window.displayID { fields["display"] = display }
                    return fields
                },
            ]
            if let hotkey = layout.hotkey {
                entry["keyCode"] = hotkey.keyCode
                entry["modifiers"] = Int(Int64(bitPattern: hotkey.modifierRaw))
            }
            return entry
        }
        UserDefaults.standard.set(raw, forKey: Self.layoutsKey)
        onChange?(layouts)
    }
}

/// The layout chords, as a snapshot the tap callback can match without touching the store.
struct LayoutShortcuts: Equatable {
    /// Chord and the layout it restores, in the store's order so a duplicated chord resolves the
    /// same way every time.
    var entries: [(id: String, hotkey: Hotkey)] = []

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.entries.count == rhs.entries.count
            && zip(lhs.entries, rhs.entries).allSatisfy { $0.id == $1.id && $0.hotkey == $1.hotkey }
    }

    /// The layout a keypress restores, if any.
    func layoutID(code: Int, flags: CGEventFlags) -> String? {
        let pressed = flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift])
        return entries.first { entry in
            entry.hotkey.keyCode == code
                && entry.hotkey.modifiers.intersection(
                    [.maskCommand, .maskAlternate, .maskControl, .maskShift]) == pressed
        }?.id
    }
}
