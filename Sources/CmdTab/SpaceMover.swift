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
