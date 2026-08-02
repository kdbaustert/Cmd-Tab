import CoreGraphics
import Foundation

/// Turns the Dock's built-in ⌘-Tab switcher on and off.
///
/// This goes through `CGSSetSymbolicHotKeyEnabled`, a private SkyLight entry point. It is
/// resolved with `dlsym` rather than linked, so if a future macOS drops the symbol we lose
/// the takeover instead of failing to launch. The change lives in the window server's
/// in-memory state — it is not written to `com.apple.symbolichotkeys`, so logging out
/// restores the system switcher even if we never get to run our cleanup.
enum SystemSwitcher {
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32

    /// Identifiers from the window server's symbolic hot key table.
    private static let commandTab: Int32 = 1
    private static let commandShiftTab: Int32 = 2

    private static let setEnabled: SetEnabledFn? = {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY),
                  let symbol = dlsym(handle, "CGSSetSymbolicHotKeyEnabled") else { continue }
            return unsafeBitCast(symbol, to: SetEnabledFn.self)
        }
        return nil
    }()

    /// False when the private symbol could not be resolved, which means we cannot take over ⌘-Tab.
    static var isAvailable: Bool { setEnabled != nil }

    private(set) static var isNativeDisabled = false

    @discardableResult
    static func setNativeEnabled(_ enabled: Bool) -> Bool {
        guard let setEnabled else { return false }
        let tab = setEnabled(commandTab, enabled)
        let shiftTab = setEnabled(commandShiftTab, enabled)
        let ok = tab == 0 && shiftTab == 0
        // The bookkeeping is asymmetric on purpose, because the cost of being wrong is asymmetric.
        //
        // Taking over: *either* key changing hands means the system switcher has been altered and
        // there is something to undo. Recording only the clean case meant a partial takeover — one
        // key accepted, the other refused — left `isNativeDisabled` false, so the restore on quit
        // was skipped and the user was left with a ⌘-Tab that did nothing until they logged out.
        //
        // Handing back: only a complete restore counts, so a partial one leaves the flag set and
        // the next teardown path tries again rather than assuming the job is done.
        if enabled {
            if ok { isNativeDisabled = false }
        } else if tab == 0 || shiftTab == 0 {
            isNativeDisabled = true
        }
        return ok
    }

    /// Safe to call from teardown paths that may run more than once.
    static func restoreNativeIfNeeded() {
        guard isNativeDisabled else { return }
        setNativeEnabled(true)
    }
}
