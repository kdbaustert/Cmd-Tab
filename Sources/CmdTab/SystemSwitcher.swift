import CoreGraphics
import Foundation

/// Turns the Dock's built-in ⌘-Tab switcher on and off.
///
/// This goes through `CGSSetSymbolicHotKeyEnabled`, a private SkyLight entry point. It is
/// resolved with `dlsym` rather than linked, so if a future macOS drops the symbol we lose
/// the takeover instead of failing to launch. The change lives in the window server's
/// in-memory state — it is not written to `com.apple.symbolichotkeys`, so logging out
/// restores the system switcher even if we never get to run our cleanup.
///
/// Global state cuts both ways, and `isNativeEnabled` exists for the other direction. Whatever
/// process last wrote the flag wins, and a write from *outside* this process is invisible to the
/// bookkeeping below: the case that actually happens is the previous instance of this app, which
/// hands ⌘-Tab back in `stop()` on its way out — and the installer's `quit` returns before that
/// teardown has run, so a busy old process can land its restore *after* the new one has taken
/// over. From then on the window server consumes ⌘-Tab itself, ahead of every session event tap,
/// and the new instance sees nothing at all: no trace, no error, a trigger that simply does
/// nothing, until something re-disables the hot key. `reassertIfNeeded` is the something.
enum SystemSwitcher {
    private typealias SetEnabledFn = @convention(c) (Int32, Bool) -> Int32
    private typealias IsEnabledFn = @convention(c) (Int32) -> Bool

    /// Identifiers from the window server's symbolic hot key table.
    private static let commandTab: Int32 = 1
    private static let commandShiftTab: Int32 = 2

    private static func resolve(_ name: String) -> UnsafeMutableRawPointer? {
        let paths = [
            "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight",
            "/System/Library/Frameworks/CoreGraphics.framework/Versions/A/CoreGraphics",
        ]
        for path in paths {
            guard let handle = dlopen(path, RTLD_LAZY), let symbol = dlsym(handle, name) else {
                continue
            }
            return symbol
        }
        return nil
    }

    private static let setEnabled: SetEnabledFn? =
        resolve("CGSSetSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: SetEnabledFn.self) }

    /// The read half. `CGSGetSymbolicHotKeyEnabled` is gone on current macOS, and for a while that
    /// was taken to mean the state could not be asked for at all; `CGSIsSymbolicHotKeyEnabled`
    /// resolves and answers. Validated against hot keys whose state is known from
    /// `com.apple.symbolichotkeys`: the three switched off in System Settings on this Mac read
    /// false, Mission Control's read true, and the two this type disables read false while it holds
    /// them — so the answer tracks the window server rather than a default.
    private static let isEnabled: IsEnabledFn? =
        resolve("CGSIsSymbolicHotKeyEnabled").map { unsafeBitCast($0, to: IsEnabledFn.self) }

    /// Whether the window server will act on ⌘-Tab itself right now. nil when it cannot be asked.
    static var isNativeEnabled: Bool? { isEnabled.map { $0(commandTab) } }

    /// False when the private symbol could not be resolved, which means we cannot take over ⌘-Tab.
    static var isAvailable: Bool { setEnabled != nil }

    /// `nonisolated(unsafe)` for the same reason as `Log.isVerbose`: it is written from the main
    /// thread and read from teardown paths that may run on a signal handler's thread. A `Bool`
    /// cannot tear, and the worst a race can do is attempt a restore that is already done — which
    /// `setNativeEnabled` treats as a no-op.
    private(set) nonisolated(unsafe) static var isNativeDisabled = false

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
    ///
    /// Logged, because this is the write that can land in another instance's lap — see the type
    /// header — and without a line here the log of a restart shows the new instance taking over
    /// and nothing about the old one giving it back a moment later.
    static func restoreNativeIfNeeded() {
        guard isNativeDisabled else { return }
        Log.general.notice("system switcher: handing ⌘-Tab back on the way out")
        setNativeEnabled(true)
    }

    /// Takes ⌘-Tab back if the window server has it while this process believes it does not.
    ///
    /// Only while the takeover is meant to be in force — a custom trigger leaves the native
    /// switcher alone, and so does this. Reported at `.error` for the reason `MainLoopMonitor`
    /// gives: it exists to be read back after a ⌘-Tab that did nothing, and by then it is too late
    /// to switch verbose logging on. Returns true when it had to act.
    @discardableResult
    static func reassertIfNeeded() -> Bool {
        guard isNativeDisabled, isNativeEnabled == true else { return false }
        Log.general.error(
            """
            system switcher: the native ⌘-Tab was re-enabled underneath us — every press since went \
            to the window server, not the tap; taking it back
            """)
        return setNativeEnabled(false)
    }
}
