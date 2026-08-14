import AppKit
import CoreGraphics

/// Everything `SwitcherController.handle` needs in order to decide, as one value.
///
/// The keyboard tap is serviced by the main run loop, which is the reason the controller's whole
/// invariant exists: main has to stay free or the tap starves. Moving the tap to a thread of its own
/// is the change that would retire that constraint, and the thing standing in the way is not the
/// decision logic — `TapRouting`, `SessionRelease`, `TriggerModifiers` and `SwitcherShortcuts` are
/// already pure and tested, and would run unchanged from any thread. It is the *inputs*: they live
/// as main-actor properties spread across the controller, and a tap on another thread cannot read
/// them.
///
/// This is that set gathered into one `Sendable` value, so it can be published to a lock and read
/// from anywhere. Deliberately built and adopted *before* the tap moves: while the tap is still on
/// main, both the mirror and the live properties are available on the same thread, which is what
/// makes `TapStateMirror.verify` possible — the missed-publish bug that would otherwise be silent
/// and intermittent is caught loudly, in ordinary use, with the old threading still protecting
/// everyone. The thread move becomes a small step on top of something already proven.
///
/// `Equatable` for exactly that check, and it is the reason every member has to be a value: an
/// object reference would compare equal while its contents drifted, which is the failure this is
/// built to detect.
struct TapState: Equatable, Sendable {

    // MARK: Session lifecycle
    //
    // The five flags that say which of the handler's branches an event takes. Every one of them is
    // written from several places, which is why the controller publishes from `didSet` rather than
    // from the call sites — see `SwitcherController.publishTapState`.

    var isVisible = false
    var armed = false
    var pendingSameApp = false
    var isSticky = false
    /// Modifiers of whichever hotkey opened the session; releasing them ends it.
    ///
    /// Stored as the raw bits rather than as `CGEventFlags`, because this type has to be `Sendable`
    /// and an imported C option set carries no such promise. `flags` converts back at the two places
    /// that care.
    var activeHeldRaw: UInt64 = CGEventFlags.maskCommand.rawValue

    var activeHeld: CGEventFlags { CGEventFlags(rawValue: activeHeldRaw) }

    /// The session's end-of-life rules. Derived rather than stored, exactly as on the controller, so
    /// the two cannot disagree.
    var release: SessionRelease { SessionRelease(isSticky: isSticky, activeHeld: activeHeld) }

    // MARK: Bindings
    //
    // Pushed from Settings, changing rarely. They are in here because the routing decision reads
    // them on every keystroke and a tap on another thread could not reach a main-actor store.

    var hotkey: Hotkey = .commandTab
    var sameAppHotkey: Hotkey?
    var scopedTriggers = ScopedTriggers()
    var activations = DirectActivations()
    var allWindows = AllWindowsShortcuts()
    var tiling: WindowTilingBindings = .defaults
    var shortcuts: SwitcherShortcuts = .defaults
    var actionsEnabled = false

    // MARK: Ambient

    /// Whether Cmd-Tab itself is frontmost, which makes every global chord deliberately inert.
    ///
    /// The one genuine obstacle in the whole set. `NSApp.isActive` is a main-thread-only AppKit read
    /// sitting directly on the decision path, so it cannot simply be called from a tap thread; it
    /// has to be mirrored off the activation notifications instead. See
    /// `SwitcherController.startActiveMirror`.
    var isAppActive = false

    /// Whether a filter query is being typed, which decides whether a digit jumps to a tile or types
    /// into the query. The query text itself is never needed — only whether there is one.
    var hasQuery = false
}

/// Holds the published `TapState` behind a lock, and checks it against the truth.
///
/// The lock rather than an actor: the reader will be a tap callback, which must answer
/// swallow-or-pass synchronously and cannot await anything. This is the same arrangement
/// `MouseWindowDrag` uses for its own tap-thread state, and for the same reason.
final class TapStateMirror: @unchecked Sendable {
    private let lock = NSLock()
    private var stored = TapState()

    /// Where a disagreement is announced.
    ///
    /// Injectable for one reason, and it is not testing the report text. `verify` failing to notice
    /// a drift is the defect that matters most here, so the tests have to call it — and calling it
    /// writes `.error` lines into `com.cmdtab.CmdTab`, the app's own subsystem, from `xctest`. A
    /// week of ordinary development left 156 of them in the unified log, all of them deliberate, all
    /// of them indistinguishable at a glance from the real thing that this mechanism exists to
    /// report. Handing the tests a silent reporter keeps `log show` on this subsystem meaning what
    /// it says.
    private let report: @Sendable (String) -> Void

    init(report: @escaping @Sendable (String) -> Void = TapStateMirror.warn) {
        self.report = report
    }

    /// The production reporter. `.public` because the message is field names and a count — there is
    /// nothing here that came from a window title.
    static func warn(_ message: String) {
        Log.tap.error("\(message, privacy: .public)")
    }

    /// The last published state. Safe from any thread — the point of the type.
    var current: TapState { lock.withLock { stored } }

    func publish(_ state: TapState) {
        lock.withLock { stored = state }
    }

    /// How many times the mirror has been found to disagree with the truth.
    ///
    /// A count rather than a trap. A mismatch is a publish that some new code path forgot, which is
    /// a bug worth shouting about but never worth taking the user's switcher down over — and the
    /// handler is about to read the live properties anyway, so the wrong answer is not acted on
    /// while the tap still runs on main.
    private(set) var mismatches = 0

    /// Compares the mirror against freshly-read live state, and reports the first disagreement.
    ///
    /// This is the whole reason the mirror is being built a step ahead of the thread move. Once the
    /// tap runs elsewhere, a missed publish is invisible: the tap decides on stale state, the user
    /// sees the wrong thing happen once, and nothing is written down. Called here — while both sides
    /// are still readable from the same thread — the same bug is a log line naming the field.
    ///
    /// Cheap enough for the key path: one lock, one `==` over a flat value, and nothing at all in
    /// the overwhelming case where they agree.
    func verify(against live: TapState) {
        let published = current
        guard published != live else { return }
        mismatches += 1
        report(
            """
            tap state mirror is stale (\(mismatches) so far): \
            \(TapStateMirror.difference(published, live)) — a mutation published nothing. The tap \
            is still reading live state, so behaviour is unaffected; fix before moving the tap off \
            the main run loop.
            """)
    }

    /// Names the fields that differ, so the log line points at the property whose `didSet` is
    /// missing rather than merely announcing that something is wrong.
    private static func difference(_ published: TapState, _ live: TapState) -> String {
        var fields: [String] = []
        if published.isVisible != live.isVisible { fields.append("isVisible") }
        if published.armed != live.armed { fields.append("armed") }
        if published.pendingSameApp != live.pendingSameApp { fields.append("pendingSameApp") }
        if published.isSticky != live.isSticky { fields.append("isSticky") }
        if published.activeHeldRaw != live.activeHeldRaw { fields.append("activeHeld") }
        if published.hotkey != live.hotkey { fields.append("hotkey") }
        if published.sameAppHotkey != live.sameAppHotkey { fields.append("sameAppHotkey") }
        if published.scopedTriggers != live.scopedTriggers { fields.append("scopedTriggers") }
        if published.activations != live.activations { fields.append("activations") }
        if published.allWindows != live.allWindows { fields.append("allWindows") }
        if published.tiling != live.tiling { fields.append("tiling") }
        if published.shortcuts != live.shortcuts { fields.append("shortcuts") }
        if published.actionsEnabled != live.actionsEnabled { fields.append("actionsEnabled") }
        if published.isAppActive != live.isAppActive { fields.append("isAppActive") }
        if published.hasQuery != live.hasQuery { fields.append("hasQuery") }
        return fields.isEmpty ? "unknown field" : fields.joined(separator: ", ")
    }
}
