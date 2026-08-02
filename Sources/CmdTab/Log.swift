import Foundation
import OSLog

/// Stream these with:
///   log stream --predicate 'subsystem == "com.cmdtab.CmdTab"' --style compact --level debug
///
/// `--level debug` matters: only `notice` and above are written to the persistent store, so the
/// `.debug` lines below (the per-event tap tracing) exist in a live stream and nowhere else. To read
/// back what already happened, `log show --last 30m` with the same predicate — and expect the tap
/// tracing to be missing from it.
///
/// Interpolated strings default to `<private>` in both. Anything worth reading back is tagged
/// `privacy: .public` at the call site; window titles are deliberately left redacted.
enum Log {
    static let general = Logger(subsystem: "com.cmdtab.CmdTab", category: "general")
    static let tap = Logger(subsystem: "com.cmdtab.CmdTab", category: "tap")
    static let targets = Logger(subsystem: "com.cmdtab.CmdTab", category: "targets")
}
