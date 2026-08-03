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
    private typealias CopySpacesForWindowsFn =
        @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
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
    private static let setCurrentSpace =
        symbol("CGSManagedDisplaySetCurrentSpace", SetCurrentSpaceFn.self)

    static var isAvailable: Bool {
        mainConnection != nil && copyManaged != nil && copySpacesForWindows != nil
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
