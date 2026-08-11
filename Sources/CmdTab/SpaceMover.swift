import CoreGraphics
import Foundation

/// Reads which Space a window is on, and switches a display to a Space. There is no public API for
/// either, so both go through private SkyLight symbols resolved with `dlsym` — the same approach
/// (and framework) as `SystemSwitcher`'s ⌘-Tab takeover. A missing symbol on a future macOS is a
/// graceful no-op rather than a crash. Inherently best-effort and fragile across OS versions.
///
/// Deliberately read-and-reveal only. *Moving* a window to another Space is not here because it
/// cannot be done from an ordinary process on macOS 26: `CGSMoveWindowsToManagedSpace`,
/// `SLSMoveWindowsToManagedSpace` and the remove-then-add pair all resolve, are all accepted, and
/// all silently do nothing for a window this process does not own. The tools that manage it inject
/// into Dock, which requires SIP to be partially disabled.
enum SpaceMover {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopyWindowsForSpacesFn = @convention(c) (
        Int32, UInt32, CFArray, UInt32,
        UnsafeMutablePointer<UInt64>, UnsafeMutablePointer<UInt64>
    ) -> Unmanaged<CFArray>?
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void
    private typealias ShowHideSpacesFn = @convention(c) (Int32, CFArray) -> Void

    /// `nonisolated(unsafe)` because a dyld handle is an opaque pointer and so not `Sendable`.
    /// Safe: it is a `let`, initialised once by the runtime's thread-safe lazy-static machinery and
    /// never written again, and `dlsym` against it is itself thread-safe.
    private nonisolated(unsafe) static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnection = symbol("CGSMainConnectionID", MainConnectionFn.self)
    private static let copyManaged = symbol("CGSCopyManagedDisplaySpaces", CopyManagedFn.self)
    private static let copyWindowsForSpaces =
        symbol("CGSCopyWindowsWithOptionsAndTags", CopyWindowsForSpacesFn.self)
    private static let setCurrentSpace =
        symbol("CGSManagedDisplaySetCurrentSpace", SetCurrentSpaceFn.self)
    private static let showSpaces = symbol("CGSShowSpaces", ShowHideSpacesFn.self)
    private static let hideSpaces = symbol("CGSHideSpaces", ShowHideSpacesFn.self)

    /// Breadth of the per-Space window query. `0x0` misses a window or two per Space and `0x7` pulls
    /// in shadow and helper surfaces that name no switchable window; `0x2` is the setting that
    /// returned exactly the real windows when checked against `CGWindowListCopyWindowInfo`.
    private static let spaceWindowOptions: UInt32 = 0x2

    static var isAvailable: Bool {
        mainConnection != nil && copyManaged != nil && copyWindowsForSpaces != nil
    }

    /// Where a window lives and what is currently in front on that window's display.
    struct SpaceState {
        let windowSpace: UInt64
        let currentSpace: UInt64
        let display: String
    }

    /// What `reveal` found and did. The state comes back with it so callers can log where the
    /// window was without paying for the whole display/Space enumeration a second time.
    struct Reveal {
        /// nil when the layout could not be read at all.
        let state: SpaceState?
        /// Whether a Space switch was actually needed and issued.
        let switched: Bool
    }

    /// Where `window` lives and what is currently in front on that window's display.
    ///
    /// The single source of truth for every Space decision here, so the two ids can be logged side
    /// by side — the only way to tell "the window really is on this Desktop" from "the lookup is
    /// lying". nil when the layout can't be read at all, and also nil for a minimized window: one
    /// sitting in the Dock occupies no Space, which is a distinction callers need before they decide
    /// whether a pick is a Desktop switch or an unminimize.
    ///
    /// Read-only, unlike `reveal` — callers that only need to *know* where a window is must not pay
    /// a Space animation to find out.
    static func spaceState(of window: CGWindowID) -> SpaceState? {
        guard window != 0 else { return nil }
        return windowSpaces()[window]
    }

    /// Every window the window server currently places on a Space, and where it is.
    ///
    /// Built by asking each Space which windows it holds rather than asking each window which Space
    /// it is on. `CGSCopySpacesForWindows` is the natural call for the latter and on macOS 26 it no
    /// longer answers: it reports only the Space that is currently in front, and it returns the
    /// *union* over the window array it is handed rather than one entry per window. Measured against
    /// six real windows of one app spread over five Desktops, it returned `[1]` — the Desktop in
    /// front — and nothing at all for the other five, so every off-Desktop lookup came back empty
    /// and `reveal` had no Space to switch to.
    ///
    /// The reverse direction has no such problem, and it is per-display for free: the Space list
    /// arrives grouped by display, so each window carries the display its Space belongs to and
    /// `reveal` switches the monitor that actually holds it. A second monitor keeps its own Space
    /// list and its own "current", which is exactly what a per-window query could not express.
    ///
    /// A window on no Space at all is simply absent, which is the answer callers need rather than a
    /// failure: a minimized window sits in the Dock and occupies no Space, so there is nothing for a
    /// Space switch to reach and the caller must restore it instead.
    ///
    /// One window-server round trip per Space. Callers that need many windows placed should take the
    /// whole map once rather than calling `spaceState` in a loop.
    static func windowSpaces() -> [CGWindowID: SpaceState] {
        guard let mainConnection, let copyManaged, let copyWindowsForSpaces else { return [:] }
        let cid = mainConnection()
        guard let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]] else {
            return [:]
        }
        var out: [CGWindowID: SpaceState] = [:]
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]],
                let identifier = display["Display Identifier"] as? String
            else { continue }
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID(from:)) ?? 0
            for space in spaces.compactMap(spaceID(from:)) {
                var setTags: UInt64 = 0
                var clearTags: UInt64 = 0
                guard
                    let raw = copyWindowsForSpaces(
                        cid, 0, [NSNumber(value: space)] as CFArray, spaceWindowOptions,
                        &setTags, &clearTags)?.takeRetainedValue(),
                    let ids = raw as? [NSNumber]
                else { continue }
                let state = SpaceState(
                    windowSpace: space, currentSpace: current, display: identifier)
                for number in ids {
                    // A window can sit on several Spaces at once — an app set to "All Desktops" in
                    // the Dock's options being the everyday case, and it is then listed by each of
                    // them. Whichever copy is on the Space already in front wins: reporting a window
                    // the user is looking at as living elsewhere would have `reveal` animate them
                    // off the Desktop they are on to "reach" it.
                    let id = number.uint32Value
                    if out[id] == nil || space == current { out[id] = state }
                }
            }
        }
        return out
    }

    /// Switches whichever display holds `window` to the Space that window is on.
    ///
    /// Without this a window on another Desktop cannot be reached at all: `AXRaise` only orders
    /// windows *within* the Space they already occupy, and activating an app does not follow one of
    /// its windows across Desktops. Clicking the preview thumbnail of a window on Desktop 2 while
    /// looking at Desktop 1 therefore brought the app forward on Desktop 1 and left the clicked
    /// window exactly where it was.
    ///
    /// Works per display, so it covers both halves of the same problem: the target Space may be on
    /// another monitor, in which case that monitor is the one switched.
    ///
    /// Takes the placement rather than looking it up, and a nil one is the answer, not a cue to go
    /// and ask: the read behind it walks every Space on every display, and the caller has already
    /// paid for it — it has to know whether the window is on a Desktop or in the Dock before it can
    /// decide to come here at all. `nil` therefore means "on no Space", which is what it reports.
    @discardableResult
    static func reveal(window: CGWindowID, state: SpaceState?) -> Reveal {
        guard let state else {
            Log.general.notice("space reveal: no Space for window \(window, privacy: .public)")
            return Reveal(state: nil, switched: false)
        }
        // Already looking at it. Worth checking — a redundant switch still animates, which on the
        // common case (same Desktop) would put a needless lurch in front of every pick.
        guard state.windowSpace != state.currentSpace else {
            return Reveal(state: state, switched: false)
        }
        guard let setCurrentSpace, let mainConnection else {
            Log.general.notice("space reveal: cannot switch Space, private symbol unavailable")
            return Reveal(state: state, switched: false)
        }
        Log.general.notice(
            "space reveal: window \(window, privacy: .public) space \(state.currentSpace, privacy: .public) -> \(state.windowSpace, privacy: .public)"
        )
        let cid = mainConnection()
        // Show the destination and hide the origin *around* the current-Space write, rather than
        // making that write the whole of the switch.
        //
        // `CGSManagedDisplaySetCurrentSpace` on its own only re-points the window server's "which
        // Space is current" field. It does not swap what is composited, and the two then disagree
        // for as long as nothing forces a redraw: every query in this file reports the new Space and
        // the screen keeps drawing the old one, with the window that was just raised painted on top
        // of it. That is precisely the reported bug — "the app I picked jumped onto the Desktop I
        // was already on, and went back to its own Desktop as soon as I switched Desktops manually."
        // Nothing had moved either time. `windowSpace` is identical before and after in every log of
        // it; the first half was a stale composite, and the second half was the next genuine
        // transition finally re-compositing and revealing where the window had been all along.
        //
        // `CGSShowSpaces`/`CGSHideSpaces` are the calls that move the Space contents, and pairing
        // them with the write is what turns this from a bookkeeping change into a switch the display
        // actually performs. Show before hide: the reverse order takes the outgoing Desktop down
        // first and flashes the empty desktop picture in between.
        //
        // Kept optional rather than required. This is the fallback path — it runs when macOS has
        // already declined to travel on its own — and a future macOS that drops these two symbols is
        // better served by the old bookkeeping-only switch than by no switch at all.
        if let showSpaces, let hideSpaces {
            showSpaces(cid, [NSNumber(value: state.windowSpace)] as CFArray)
            hideSpaces(cid, [NSNumber(value: state.currentSpace)] as CFArray)
        } else {
            Log.general.notice(
                "space reveal: no show/hide symbols; the switch may not re-composite the display")
        }
        setCurrentSpace(cid, state.display as CFString, state.windowSpace)
        return Reveal(state: state, switched: true)
    }

    /// Which Space `display` is showing right now, and nothing else.
    ///
    /// One window-server round trip, where `windowSpaces` costs one *per Space* because it asks each
    /// one for its windows. That difference is the whole reason this exists: a poll waiting for a
    /// Desktop transition wants only this number, and calling `spaceState` in a loop to get it —
    /// which `spaceState` itself warns against — turned a single pick into a hundred round trips on
    /// the queue the pick is waiting on.
    ///
    /// nil when the layout cannot be read, which a caller must not confuse with "not there yet".
    static func currentSpace(ofDisplay display: String) -> UInt64? {
        guard let mainConnection, let copyManaged,
            let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for entry in displays where (entry["Display Identifier"] as? String) == display {
            return (entry["Current Space"] as? [String: Any]).flatMap(spaceID(from:))
        }
        return nil
    }

    /// Whether macOS is set to travel to a window's Desktop when its app is activated — the Mission
    /// Control checkbox "When switching to an application, switch to a Space with open windows for
    /// that application".
    ///
    /// It decides which of two opposite things an ordinary activation does to a window on another
    /// Desktop: with it on, macOS switches Desktops and leaves the window alone; with it off, macOS
    /// drags the window to the Desktop in front of you. Every warning in `SwitchTarget` about
    /// activation "gathering" a window describes the *off* behaviour, so a caller that wants to lean
    /// on the system's own switch has to establish which regime it is in first.
    ///
    /// Absent means on: that is the macOS default, and the key is only written once the user has
    /// touched the checkbox.
    static var systemSwitchesSpaceOnActivate: Bool {
        guard
            let value = CFPreferencesCopyAppValue(
                "workspaces-auto-swoosh" as CFString, "com.apple.dock" as CFString)
        else { return true }
        return (value as? Bool) ?? true
    }

    /// Every user Space in order, flattened across displays.
    ///
    /// Flattened deliberately: the badge numbers Spaces the way the user counts them ("Desktop 3"),
    /// and on the single-display setups where Spaces are actually numbered that is exactly right.
    /// `move` does *not* use this — it has to stay within one display's list to clamp correctly.
    private static func userSpaceIDs() -> [UInt64] {
        guard let mainConnection, let copyManaged,
            let displays = copyManaged(mainConnection())?.takeRetainedValue() as? [[String: Any]]
        else { return [] }
        return displays.flatMap { display -> [UInt64] in
            guard let spaces = display["Spaces"] as? [[String: Any]] else { return [] }
            return spaces.filter { ($0["type"] as? Int) == 0 }.compactMap(spaceID(from:))
        }
    }

    /// The 0-based user-Space index each window sits on, for the Space badge.
    ///
    /// Returns empty when there is only one Space, which is both a cost saving and the right
    /// display behaviour — a badge reading "1" on every tile is pure noise. Costs no Accessibility
    /// round-trips, but is still meant for the background refresh rather than anything on the key
    /// path.
    ///
    /// Placed from one `windowSpaces()` map rather than a query per window: the per-window call this
    /// used to make reported nothing for any window that was not on the Desktop in front, so the
    /// badge went missing on precisely the windows it exists to label.
    static func spaceIndices(of windows: [CGWindowID]) -> [CGWindowID: Int] {
        guard !windows.isEmpty else { return [:] }
        let ordered = userSpaceIDs()
        guard ordered.count > 1 else { return [:] }

        let placed = windowSpaces()
        var out: [CGWindowID: Int] = [:]
        for window in windows {
            guard let space = placed[window]?.windowSpace,
                let index = ordered.firstIndex(of: space)
            else { continue }
            out[window] = index
        }
        return out
    }

    private static func spaceID(from space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            ?? (space["id64"] as? NSNumber)?.uint64Value
    }
}
