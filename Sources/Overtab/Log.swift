import Foundation
import OSLog

/// Stream these with:
///   log stream --predicate 'subsystem == "com.overtab.Overtab"' --style compact
enum Log {
    static let general = Logger(subsystem: "com.overtab.Overtab", category: "general")
    static let tap = Logger(subsystem: "com.overtab.Overtab", category: "tap")
    static let targets = Logger(subsystem: "com.overtab.Overtab", category: "targets")
}
