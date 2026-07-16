import Foundation
import OSLog

/// Stream these with:
///   log stream --predicate 'subsystem == "com.cmdtab.CmdTab"' --style compact
enum Log {
    static let general = Logger(subsystem: "com.cmdtab.CmdTab", category: "general")
    static let tap = Logger(subsystem: "com.cmdtab.CmdTab", category: "tap")
    static let targets = Logger(subsystem: "com.cmdtab.CmdTab", category: "targets")
}
