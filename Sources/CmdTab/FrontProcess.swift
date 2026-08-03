import ApplicationServices
import CoreGraphics
import Foundation

/// Brings **one window** forward, rather than the app that owns it.
///
/// `NSRunningApplication.activate()` is an app-level operation, and on a machine with several
/// Desktops that is not a small difference: activating an app gathers its windows from other Spaces
/// onto the Space in front of you. Picking one Ghostty window on Desktop 1 therefore dragged the
/// Ghostty window the user had left on Desktop 4 across with it — the window "vanished" from the
/// Desktop it lived on, and reappeared somewhere else. `.activateAllWindows` makes that worse, but
/// plain activation does it too, to every sibling of the window actually picked.
///
/// There is no public API that focuses a single window. This is the technique AltTab and yabai use:
/// tell the window server which *window* of a process is being fronted, then post the two event
/// records that a real click on that window's title bar would have produced, so the app itself
/// agrees about which of its windows is key.
///
/// Private symbols, resolved with `dlsym` like `SpaceMover`'s and just as fragile: a missing one is
/// a `false` return and the caller falls back to ordinary activation, which is wrong about Spaces
/// but never worse than doing nothing.
enum FrontProcess {
    private typealias SetFrontFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, CGWindowID, UInt32
    ) -> CGError
    private typealias PostEventFn = @convention(c) (
        UnsafeMutablePointer<ProcessSerialNumber>, UnsafePointer<UInt8>
    ) -> CGError
    /// Carbon's pid → serial number lookup. Deprecated since 10.9 and marked *unavailable* to
    /// Swift, so it is resolved by name like everything else here rather than called directly —
    /// there is no replacement, and the window-server calls below are addressed by serial number.
    private typealias GetProcessForPIDFn = @convention(c) (
        pid_t, UnsafeMutablePointer<ProcessSerialNumber>
    ) -> OSStatus

    /// The window server's name for "the user asked for this", as opposed to an app fronting
    /// itself. Anything else and the front change is not treated as a real activation.
    private static let userGenerated: UInt32 = 0x2

    private static let handle = dlopen(
        "/System/Library/PrivateFrameworks/SkyLight.framework/Versions/A/SkyLight", RTLD_LAZY)

    private static func symbol<T>(_ name: String, _ type: T.Type) -> T? {
        guard let handle, let pointer = dlsym(handle, name) else { return nil }
        return unsafeBitCast(pointer, to: T.self)
    }

    private static let setFront = symbol("_SLPSSetFrontProcessWithOptions", SetFrontFn.self)
    private static let postEvent = symbol("SLPSPostEventRecordTo", PostEventFn.self)

    /// Resolved out of the ApplicationServices umbrella by path, not out of the already-loaded
    /// images: `RTLD_DEFAULT` does not find this one. Measured on macOS 26 — `import
    /// ApplicationServices` is not enough to bring the image that vends `GetProcessForPID` in, so
    /// the search over loaded images came up empty, `isAvailable` was false, and every call here
    /// silently fell back to the app-level activation this file exists to avoid. The umbrella is
    /// already a dependency of this target; `dlopen` only forces it to be resident.
    private static let getProcessForPID: GetProcessForPIDFn? = {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/ApplicationServices",
                RTLD_LAZY),
            let pointer = dlsym(handle, "GetProcessForPID")
        else { return nil }
        return unsafeBitCast(pointer, to: GetProcessForPIDFn.self)
    }()

    static var isAvailable: Bool {
        setFront != nil && postEvent != nil && getProcessForPID != nil
    }

    /// Fronts `window` without disturbing the rest of `pid`'s windows. False when the private
    /// symbols are gone or the process has no serial number, both of which mean "fall back".
    static func focus(window: CGWindowID, pid: pid_t) -> Bool {
        guard let setFront, let postEvent, let getProcessForPID, window != 0 else { return false }
        var psn = ProcessSerialNumber()
        guard getProcessForPID(pid, &psn) == noErr else { return false }
        guard setFront(&psn, window, userGenerated) == .success else { return false }
        // The front change alone moves the window server's idea of what is in front; the app's own
        // idea follows only from the events a click would have sent it. Without these, apps that
        // track key state themselves (which is most of them) draw the window as inactive — focused
        // by the system, dimmed by the app.
        var bytes = [UInt8](repeating: 0, count: 0xf8)
        bytes[0x04] = 0xf8
        bytes[0x3a] = 0x10
        withUnsafeBytes(of: window.littleEndian) { raw in
            for (offset, byte) in raw.enumerated() { bytes[0x3c + offset] = byte }
        }
        for index in 0x20..<0x30 { bytes[index] = 0xff }
        bytes[0x08] = 0x01  // window is becoming key
        _ = postEvent(&psn, &bytes)
        bytes[0x08] = 0x02  // and is now key
        _ = postEvent(&psn, &bytes)
        return true
    }
}
