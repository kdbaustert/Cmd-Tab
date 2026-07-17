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
        else { return }
        let cid = mainConnection()
        let windowArray = [NSNumber(value: window)] as CFArray

        // The window's current Space (mask 0x7 = all Space types).
        guard let spacesRaw = copySpacesForWindows(cid, 0x7, windowArray)?.takeRetainedValue(),
            let currentSpace = (spacesRaw as? [NSNumber])?.first?.uint64Value
        else { return }

        // Walk the displays to the one holding this Space, and take its ordered user Spaces.
        guard let displays = copyManaged(cid)?.takeRetainedValue() as? [[String: Any]] else { return }
        for display in displays {
            guard let spaces = display["Spaces"] as? [[String: Any]] else { continue }
            let ids =
                spaces
                .filter { ($0["type"] as? Int) == 0 }  // standard Spaces only, not fullscreen tiles
                .compactMap(spaceID(from:))
            guard let index = ids.firstIndex(of: currentSpace) else { continue }
            let target = index + delta
            guard ids.indices.contains(target) else { return }  // already at an end — nothing to do
            moveWindows(cid, windowArray, ids[target])
            return
        }
    }

    private static func spaceID(from space: [String: Any]) -> UInt64? {
        (space["ManagedSpaceID"] as? NSNumber)?.uint64Value
            ?? (space["id64"] as? NSNumber)?.uint64Value
    }
}
