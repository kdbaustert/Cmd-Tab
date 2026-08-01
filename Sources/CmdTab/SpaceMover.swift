import CoreGraphics
import Foundation

/// Moves a window to an adjacent Space. There is no public API for this, so it goes through private
/// SkyLight symbols resolved with `dlsym` — the same approach (and framework) as `SystemSwitcher`'s
/// ⌘-Tab takeover. If any symbol is missing on a future macOS, the move is a graceful no-op rather
/// than a crash. Inherently best-effort and fragile across OS versions.
enum SpaceMover {
    private typealias MainConnectionFn = @convention(c) () -> Int32
    private typealias CopyManagedFn = @convention(c) (Int32) -> Unmanaged<CFArray>?
    private typealias CopySpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias MoveWindowsFn = @convention(c) (Int32, CFArray, UInt64) -> Void
    private typealias SetCurrentSpaceFn = @convention(c) (Int32, CFString, UInt64) -> Void

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let mainConnection = symbol("CGSMainConnectionID", MainConnectionFn.self)
    private static let copyManaged = symbol("CGSCopyManagedDisplaySpaces", CopyManagedFn.self)
    private static let copySpacesForWindows =
        symbol("CGSCopySpacesForWindows", CopySpacesForWindowsFn.self)
    private static let moveWindows = symbol("CGSMoveWindowsToManagedSpace", MoveWindowsFn.self)
    private static let setCurrentSpace =
        symbol("CGSManagedDisplaySetCurrentSpace", SetCurrentSpaceFn.self)

    static var isAvailable: Bool {
        mainConnection != nil && copyManaged != nil && copySpacesForWindows != nil
            && moveWindows != nil
    }

    /// Moves `window` `delta` user-Spaces along, on whichever display it currently lives, clamped to
    /// the ends (no wrap). No-op if the symbols are unavailable or the Space layout can't be read.
    static func move(window: CGWindowID, bySpaces delta: Int) {
        guard delta != 0,
            let mainConnection, let copyManaged, let copySpacesForWindows, let moveWindows
        else {
            Log.general.error("space move: private SkyLight symbols unavailable")
            return
        }
        let cid = mainConnection()
        let windowArray = [NSNumber(value: window)] as CFArray

        // The window's current Space (mask 0x7 = all Space types).
        guard let spacesRaw = copySpacesForWindows(cid, 0x7, windowArray)?.takeRetainedValue(),
            let currentSpace = (spacesRaw as? [NSNumber])?.first?.uint64Value
        else {
            Log.general.error("space move: could not read window \(window, privacy: .public)'s Space")
            return
        }

        // Walk the displays to the one holding this Space, and take its ordered user Spaces.
        guard let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]] else {
            Log.general.error("space move: could not read the display/Space layout")
            return
        }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids =
                spaces
                .filter { ($0["type"] as? Int) == 0 }  // standard Spaces only, not fullscreen tiles
                .compactMap(spaceID(from:))
            guard let index = ids.firstIndex(of: currentSpace) else { continue }
            let target = index + delta
            guard ids.indices.contains(target) else {
                Log.general.notice(
                    "space move: at the end (space \(index, privacy: .public) of \(ids.count, privacy: .public))")
                return
            }
            Log.general.notice(
                "space move: window \(window, privacy: .public) \(index, privacy: .public) -> \(target, privacy: .public)")
            moveWindows(cid, windowArray, ids[target])
            return
        }
        // Fell through every display without matching. The usual cause is a fullscreen or tiled
        // window: its Space is not `type == 0`, so the filter above drops it and no display claims
        // it. Logged because the caller has already reported success by this point, and silence here
        // is indistinguishable from the action never running.
        Log.general.notice(
            "space move: window \(window, privacy: .public) is on no standard Space (fullscreen?)")
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
    /// lying". nil when the layout can't be read at all.
    private static func spaceState(of window: CGWindowID) -> SpaceState? {
        guard window != 0, let mainConnection, let copyManaged, let copySpacesForWindows else {
            return nil
        }
        let cid = mainConnection()
        guard
            let raw = copySpacesForWindows(cid, 0x7, [NSNumber(value: window)] as CFArray)?
                .takeRetainedValue(),
            let occupied = (raw as? [NSNumber])?.map({ $0.uint64Value }).filter({ $0 != 0 }),
            !occupied.isEmpty,
            let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]]
        else { return nil }
        // A window can sit on several Spaces at once — an app set to "All Desktops" in the Dock's
        // options being the everyday case. Whichever of them is already in front is the answer:
        // taking the first would report a window the user is looking at as living elsewhere, and
        // `reveal` would then animate them off the Desktop they are on to "reach" it.
        var elsewhere: SpaceState?
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]],
                let identifier = display["Display Identifier"] as? String
            else { continue }
            let current = (display["Current Space"] as? [String: Any]).flatMap(spaceID(from:)) ?? 0
            for space in spaces.compactMap(spaceID(from:)) where occupied.contains(space) {
                let state = SpaceState(
                    windowSpace: space, currentSpace: current, display: identifier)
                if space == current { return state }
                if elsewhere == nil { elsewhere = state }
            }
        }
        return elsewhere
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
    @discardableResult
    static func reveal(window: CGWindowID) -> Reveal {
        guard let state = spaceState(of: window) else {
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
        setCurrentSpace(mainConnection(), state.display as CFString, state.windowSpace)
        return Reveal(state: state, switched: true)
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
    /// display behaviour — a badge reading "1" on every tile is pure noise. Costs one cheap CGS
    /// call per window and no Accessibility round-trips, but is still meant for the background
    /// refresh rather than anything on the key path.
    static func spaceIndices(of windows: [CGWindowID]) -> [CGWindowID: Int] {
        guard !windows.isEmpty, let mainConnection, let copySpacesForWindows else { return [:] }
        let ordered = userSpaceIDs()
        guard ordered.count > 1 else { return [:] }

        let cid = mainConnection()
        var out: [CGWindowID: Int] = [:]
        for window in windows {
            guard
                let raw = copySpacesForWindows(cid, 0x7, [NSNumber(value: window)] as CFArray)?
                    .takeRetainedValue(),
                let space = (raw as? [NSNumber])?.first?.uint64Value,
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
