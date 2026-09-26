import AppKit
import CoreGraphics
import Foundation

// Putting an app back on the Desktop macOS was already told it belongs on, after a display change
// has moved it somewhere else.
//
// macOS has had the *assignment* half of this for years — right-click an app in the Dock, Options,
// Assign To, This Desktop — and it keeps the answer in `com.apple.spaces` under `app-bindings`. What
// it does not have is any attempt to honour that assignment again once a window is already open.
// The binding is consulted when a window is created and then never revisited, so unplugging a
// display, which evacuates that display's windows onto whatever Desktop is in front of the one that
// remains, leaves an assigned app sitting somewhere it has been explicitly told not to live. There
// is no undo, and re-sorting a dozen windows by hand across six Desktops is exactly the chore the
// assignment was set up to avoid.
//
// **The destination comes from macOS, not from us.** Nothing here records where a window "was" —
// this stores no state at all between display changes, and that is deliberate. A remembered
// snapshot has to answer "was this where the user wanted it, or just where it happened to be when I
// looked?", and it cannot: the reading taken before an unplug is a photograph of a desk mid-use. An
// assignment carries no such doubt, because somebody sat down and set it. So the only apps this
// touches are the ones already carrying a binding, and the Desktop it puts them on is the one the
// binding names. `DisplayLayouts` is the sibling feature that restores *frames*, and it takes the
// opposite approach for the opposite reason — there is no system-wide record of where a window
// should sit on screen, so remembering is the only option it has.
//
// The move itself is `DesktopMover`'s gesture, with everything that implies: Mission Control opens
// for about half a second per window and the pointer is driven. That is not an implementation
// detail that can be optimised away — `SpaceMover`'s header records the four private calls that
// would do it silently and the ownership gate that makes every one of them a no-op against another
// process's window. It is also why this is off by default and why `limit` exists.
@MainActor
final class DesktopAssignments {
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            isEnabled ? start() : stop()
        }
    }

    /// Per-app overrides, pushed by the controller. `neverTile` means "do not rearrange my windows",
    /// and this is a rearrangement however well meant — the same reading `DisplayLayouts` makes of
    /// the same rule.
    var appRules: [String: AppRule] = [:]

    /// Per-window rules, pushed by the controller alongside `appRules` and unioned with them the
    /// way every other store does: a `.neverTile` title rule protects the one window it names from
    /// being moved, as the app rule protects all of them. Matched against the window the move would
    /// actually take — the app's front one, see `plan`.
    var titleRules: [CompiledTitleRule] = []

    private var observer: NSObjectProtocol?
    private var settle: DispatchWorkItem?
    /// The desk the last notification was judged against. Nil while stopped.
    private var desk: String?

    /// Where `plan` runs. Its per-app front-window resolution is Accessibility IPC to other apps,
    /// and the main thread — where the notification, the settle timer and this class all live — is
    /// the thread the event tap is serviced from. Right after a display change is also exactly when
    /// apps are busiest re-laying out their windows and slowest to answer.
    private static let queue = DispatchQueue(
        label: "com.cmdtab.desktopassignments", qos: .utility)

    /// How long to wait after the desk changes before moving anything.
    ///
    /// Longer than `DisplayLayouts.settleDelay`, and the gap between them is the point rather than
    /// an accident of tuning. That feature writes frames over Accessibility from a background queue
    /// at 1.2s; this one picks windows up by the title bar. A gesture that started while those
    /// writes were still landing would be dragging a window that is being moved underneath it, and
    /// the grab-point hit test — which checks that the point still belongs to the window before it
    /// presses — would simply fail, silently, on whichever windows lost the race. Starting after
    /// that queue has drained costs a second of waiting and removes the interaction entirely.
    ///
    /// macOS's own tidying after a display change is the other thing being waited out, and it is
    /// the reason `DisplayLayouts` waits at all.
    private static let settleDelay: TimeInterval = 2.5

    /// The most windows one desk change will move.
    ///
    /// Each is seconds of Mission Control and a pointer that is not the user's, run unattended at a
    /// moment — a laptop being docked or undocked — when they are quite likely not watching the
    /// screen. A handful of assigned apps landing back where they belong is the feature; twenty
    /// windows of gesture is a machine that appears to have been possessed, so past this many it
    /// stops and says so in the log rather than working through the list.
    private static let limit = 6

    private func start() {
        desk = Self.signature()
        observer = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.deskMayHaveChanged() }
        }
        Log.general.notice("desktop assignments: watching")
    }

    private func stop() {
        settle?.cancel()
        settle = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        desk = nil
    }

    /// A screen-parameters notification arrived. Only a change of *desk* is acted on.
    ///
    /// The same guard, for the same reason, as `DisplayLayouts.deskMayHaveChanged`: AppKit posts
    /// this notification for the Dock sliding in and out and for the menu bar auto-hiding as
    /// readily as for a cable being pulled. Driving Mission Control because somebody moved the
    /// pointer to the bottom of the screen would be indefensible.
    private func deskMayHaveChanged() {
        let now = Self.signature()
        guard now != desk else { return }
        desk = now
        Log.general.notice("desktop assignments: desk changed to \(now, privacy: .public)")
        settle?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.restore() }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.settleDelay, execute: work)
    }

    /// What the desk is, as one comparable string: the attached displays' UUIDs, sorted.
    ///
    /// `DisplayLayouts` asks the same question of the same primitive and keeps its own copy of the
    /// answer. Two independent observers of one event rather than one shared one — they run on
    /// different delays and either can be switched off without the other noticing, and a line this
    /// small is cheaper duplicated than it is coupled.
    private static func signature() -> String {
        WindowTiler.visibleDisplays().map { $0.id ?? "?" }.sorted().joined(separator: "|")
    }

    // MARK: - The bindings

    /// Every app assignment macOS currently holds, as lowercased bundle identifier to Space UUID.
    ///
    /// Read straight from `com.apple.spaces` rather than kept in sync, because it is not ours: the
    /// user changes it from the Dock's context menu, with nothing published when they do, and a
    /// cached copy would be wrong from the first time they used the feature this exists to serve.
    /// One preferences read per display change is nothing beside the gesture that may follow it.
    ///
    /// **The keys are lowercased and the bundle identifiers they are compared against are not.**
    /// Measured: `com.brave.browser` in this dictionary against `com.brave.Browser` from both
    /// `NSRunningApplication` and the Dock's own plist. An exact-match lookup finds nothing, for
    /// every app whose identifier is not already lower case, and it fails silently — which is the
    /// whole feature quietly doing nothing on precisely the app it was set up for.
    ///
    /// An empty value means "All Desktops" and is dropped here, so callers never have to spot it:
    /// an app on every Desktop is on the right one by definition.
    /// `nonisolated` for the reason `DisplayLayouts` gives for the same annotation on its own
    /// statics: this reads a preferences key and touches no instance state, and without it the
    /// `@MainActor` on the class would drag it onto the main actor — which a test cannot reach
    /// from a synchronous context, and which this needs no part of.
    nonisolated static func bindings() -> [String: String] {
        guard
            let raw = CFPreferencesCopyAppValue(
                "app-bindings" as CFString, "com.apple.spaces" as CFString) as? [String: String]
        else { return [:] }
        return raw.filter { !$0.value.isEmpty }
    }

    // MARK: - The restore

    /// One running app that has an assignment, as read on the main thread for `plan` to take off it.
    private struct RunningApp: Sendable {
        let pid: pid_t
        let bundleID: String
        let name: String
    }

    /// One move `plan` settled on.
    private typealias Move = (pid: pid_t, space: UInt64, name: String)

    /// Reads what only the main thread may, hands the rest to `queue`, and starts the moves back
    /// here. `NSRunningApplication` is read here and nowhere else; everything that asks another app
    /// a question is in `plan`.
    ///
    /// The desk is checked again on the way back. Planning takes as long as the slowest app takes
    /// to answer, and a desk that changed again meanwhile — or a feature switched off — has a
    /// restore of its own coming, or none: this one's moves were worked out for a desk that is
    /// gone.
    private func restore() {
        settle = nil
        guard let planned = desk else { return }
        // A preferences read, cheap enough for here, and the reason most desk changes end at once.
        let bindings = Self.bindings()
        guard !bindings.isEmpty else { return }
        let apps = NSWorkspace.shared.runningApplications.compactMap { app -> RunningApp? in
            guard let bundleID = app.bundleIdentifier, bindings[bundleID.lowercased()] != nil
            else { return nil }
            return RunningApp(
                pid: app.processIdentifier, bundleID: bundleID,
                name: app.localizedName ?? bundleID)
        }
        guard !apps.isEmpty else { return }
        let appRules = self.appRules
        let titleRules = self.titleRules
        // `[self]`, strong, and said out loud: the hop back needs `self`, so the planning block
        // holds it whatever this says — a `[weak self]` on the inner block alone is a warning that
        // it does not do what it reads as. Harmless: the controller owns this for the life of the
        // process, and the hold ends when planning does.
        Self.queue.async { [self] in
            let work = Self.plan(
                apps: apps, bindings: bindings, appRules: appRules, titleRules: titleRules)
            guard !work.isEmpty else { return }
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard self.desk == planned else { return }
                    self.start(work, planned: planned)
                }
            }
        }
    }

    /// The moves this desk needs, worked out on `queue`: every assigned app whose front window is
    /// off the Desktop it is assigned to, and not protected by a rule.
    private nonisolated static func plan(
        apps: [RunningApp], bindings: [String: String], appRules: [String: AppRule],
        titleRules: [CompiledTitleRule]
    ) -> [Move] {
        // UUID to the id the window server is using for that Space *now*. An assignment naming a
        // Desktop that no longer exists — the everyday case being one on the display that has just
        // been unplugged, whose Spaces go with it — resolves to nothing and is skipped. There is no
        // sensible substitute to pick: a window cannot be moved to a Desktop that is gone, and
        // inventing a nearby one would be this feature putting windows somewhere nobody asked for.
        let live = SpaceMover.spaceIDsByUUID()
        let placed = SpaceMover.windowSpaces()
        guard !placed.isEmpty else { return [] }
        let occupied = spacesByPID(in: placed)

        var work: [Move] = []
        for app in apps {
            guard let uuid = bindings[app.bundleID.lowercased()], let target = live[uuid] else {
                continue
            }
            if appRules[app.bundleID]?.neverTile == true { continue }
            // Two filters, the cheap one first. An app with every window on its Desktop needs
            // nothing, and the one window-server reading already in hand says so for all of them
            // at once.
            guard occupied[app.pid]?.contains(where: { $0 != target }) == true else { continue }
            // Then the window that would actually move. `DesktopMover` takes the app's *front*
            // window and nothing else, so that window's Desktop is the one that decides — not any
            // window's. Tested per app, this queued a move for an app whose front window was
            // already where it belonged, and the mover then refused it on the grab and logged it
            // as covered. Resolving the front window walks that app's window list, which is why
            // it is paid only for apps the first filter let through.
            guard let front = AX.frontWindow(ofApplication: app.pid),
                let window = TargetProvider.windowID(front)
                    ?? TargetProvider.windowID(matching: front, pid: app.pid),
                let space = placed[window]?.windowSpace, space != target
            else { continue }
            // The title rule is about that same window, so it is asked of that window — and only
            // when there is a rule to ask, since the title is one more round trip.
            if !titleRules.isEmpty,
                CompiledTitleRule.matches(
                    titleRules, bundleID: app.bundleID,
                    title: AX.copyString(front, kAXTitleAttribute) ?? "", action: .neverTile)
            {
                continue
            }
            work.append((app.pid, target, app.name))
        }
        return work
    }

    /// Starts a planned restore, or declines it when there is more to do than one desk change
    /// should.
    private func start(_ work: [Move], planned: String) {
        if work.count > Self.limit {
            Log.general.notice(
                """
                desktop assignments: \(work.count, privacy: .public) apps are off their assigned \
                desktop, more than the \(Self.limit, privacy: .public) one change will move; \
                leaving them
                """)
            return
        }
        Log.general.notice(
            "desktop assignments: restoring \(work.count, privacy: .public) app(s)")
        move(work, planned: planned)
    }

    /// Which Spaces each app's windows currently sit on.
    ///
    /// Built from the all-Spaces window list rather than `WindowNavigator.onScreen()`, which passes
    /// `.optionOnScreenOnly` and so reports only the Desktop in front — the exact windows this
    /// feature is *not* interested in. A window parked on the wrong Desktop is by definition one
    /// you cannot currently see. The same join `TargetProvider.appSpaceIndices` makes, for the same
    /// reason.
    ///
    /// Every app in one walk rather than a walk per app: the caller has a dozen assignments to test
    /// and this list is the whole machine's windows each time it is read.
    private nonisolated static func spacesByPID(in placed: [CGWindowID: SpaceMover.SpaceState])
        -> [pid_t: [UInt64]]
    {
        guard
            let info = CGWindowListCopyWindowInfo([.excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return [:] }
        var out: [pid_t: [UInt64]] = [:]
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let number = window[kCGWindowNumber as String] as? CGWindowID,
                let space = placed[number]?.windowSpace
            else { continue }
            out[pid, default: []].append(space)
        }
        return out
    }

    /// Runs the moves one after another.
    ///
    /// Strictly serial, and not by choice: a move holds the mouse button down for the length of its
    /// gesture, so two in flight would fight over the pointer and can leave a button stuck down.
    /// `DesktopMover` refuses a second move while one is running, which means a loop that fired them
    /// all at once would perform the first and silently drop the rest. Chained on the completion
    /// instead, so each starts once the last has finished and Mission Control is gone.
    ///
    /// A move the mover refuses — the user's own Desktop-move chord got there first — still calls
    /// back, after the move that refused it, so the chain carries on past it. The refused window is
    /// not retried: it stays where the unplug left it until the next desk change, with the refusal
    /// in the log beside this line's "moving".
    ///
    /// `follow: false` throughout. Following would leave the user looking at whichever Desktop the
    /// last window happened to land on, which after an unplug is a worse place to be left than the
    /// one they were on — and this runs unattended, where a Desktop switch nobody asked for is
    /// startling rather than helpful.
    ///
    /// Each link re-checks the desk it was planned for, the same test `restore` makes before the
    /// first one. A chain is seconds of gesture per window, and it used to run to the end whatever
    /// happened meanwhile: switching the feature off left the remaining moves driving the pointer,
    /// and a second desk change started a second chain racing this one for `DesktopMover`'s claim.
    /// `stop()` clears `desk`, so one comparison answers both — and the newer desk's own restore,
    /// already on its way, is the one that knows where windows belong now.
    private func move(_ work: [Move], planned: String) {
        guard let next = work.first else { return }
        guard desk == planned else {
            Log.general.notice(
                """
                desktop assignments: desk changed or switched off; dropping \
                \(work.count, privacy: .public) planned move(s)
                """)
            return
        }
        // `let`, and the tail taken by value rather than mutated in place: the completion below is
        // an escaping `@Sendable` closure, and capturing a `var` the enclosing scope could still
        // write to is a data race the compiler refuses outright.
        let remaining = Array(work.dropFirst())
        Log.general.notice(
            """
            desktop assignments: moving \(next.name, privacy: .public) to space \
            \(next.space, privacy: .public)
            """)
        DesktopMover.move(pid: next.pid, to: .space(next.space), follow: false) { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self?.move(remaining, planned: planned) }
            }
        }
    }
}
