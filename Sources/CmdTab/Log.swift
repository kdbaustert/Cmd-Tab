import Foundation
import OSLog

/// Stream these with:
///   log stream --predicate 'subsystem == "com.cmdtab.CmdTab"' --style compact --level debug
///
/// `--level debug` matters: only `notice` and above are written to the persistent store, so the
/// per-event tap tracing below exists in a live stream and nowhere else. To read back what already
/// happened, `log show --last 30m` with the same predicate — and expect the tap tracing to be
/// missing from it, unless Settings → About → Diagnostics has verbose logging switched on. That is
/// what `traceLevel` exists for.
///
/// Interpolated strings default to `<private>` in both. Anything worth reading back is tagged
/// `privacy: .public` at the call site; window titles are deliberately left redacted.
enum Log {
    static let general = Logger(subsystem: "com.cmdtab.CmdTab", category: "general")
    static let tap = Logger(subsystem: "com.cmdtab.CmdTab", category: "tap")
    static let targets = Logger(subsystem: "com.cmdtab.CmdTab", category: "targets")

    /// Whether the tracing below is promoted into the persistent store. Pushed from
    /// `AppDelegate.applyBehavior`, so it follows the setting without anything here reading defaults.
    ///
    /// `nonisolated(unsafe)` for the same reason as the other cross-thread statics in this app: it
    /// is read from the tap callback on the main run loop and from `InstalledApps.warm()` on a
    /// background queue. A `Bool` cannot tear, so the worst a race can do is log one line at the
    /// level that was in force a moment ago.
    nonisolated(unsafe) static var isVerbose = false

    /// The level the per-event tracing logs at.
    ///
    /// `.debug` is the right default — the tracing is a line per keystroke, and the persistent store
    /// is not the place for that. But it also means a session that misbehaved cannot be read back
    /// afterwards at all: it has to be reproduced under a live stream, which for anything
    /// intermittent is the hard part. Verbose promotes it to `.default` — the level `Logger.notice`
    /// writes, and the lowest one `log show` keeps.
    ///
    /// Passed to `Logger.log(level:_:)` rather than hidden behind a `trace(_:)` wrapper: os_log
    /// constant-folds its message at the call site, so a function taking an `OSLogMessage` does not
    /// compile. The *level* is an ordinary runtime argument, which is what makes this work at all.
    static var traceLevel: OSLogType { isVerbose ? .default : .debug }
}
