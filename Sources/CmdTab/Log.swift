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

/// Instruments the two timing claims this app's architecture rests on.
///
/// Both are currently arguments rather than measurements. *"Enumeration never happens inside the
/// tap callback"* and *"per-app Accessibility messaging is capped at 250ms so one hung app cannot
/// hang the switcher"* are the reasons the code is shaped the way it is — the off-thread cache, the
/// `DispatchQueue.main.async` hop in `frontAppWindowTargets`, the messaging timeout in
/// `AX.application` — and nothing anywhere proves either one holds. A regression in them does not
/// fail a test; it shows up as the system killing the tap and the user losing every keystroke on
/// the machine, which is both the worst failure this app has and the hardest to catch by hand.
///
/// Signposts rather than logging, because the question is *how long* rather than *what happened*,
/// and because they cost close to nothing when no tool is attached — `OSSignposter` checks whether
/// anyone is listening before formatting anything, which matters when the instrumented region is a
/// per-keystroke callback.
///
/// Record with:
///   xcrun xctrace record --template 'os_signpost' --attach Cmd-Tab --output trace.trace
/// or add an os_signpost instrument to a Time Profiler session in Instruments and filter to the
/// `com.cmdtab.CmdTab` subsystem.
enum Signpost {
    /// The tap callback. The system kills a tap that overruns its deadline, so this interval is the
    /// one that must stay short — everything else is a comfort measurement by comparison.
    static let tap = OSSignposter(subsystem: "com.cmdtab.CmdTab", category: "tap")

    /// Target enumeration, which is the work the tap callback is kept away from.
    static let targets = OSSignposter(subsystem: "com.cmdtab.CmdTab", category: "targets")
}
