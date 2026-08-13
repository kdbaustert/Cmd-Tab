import CoreFoundation
import Foundation

/// Measures how long the main run loop stays busy between turns.
///
/// This is the one measurement the whole architecture rests on and the one nothing has ever taken.
/// `Signpost.tap` times the tap callback, which answers only half the question: the tap's run-loop
/// source lives on the main loop (see `EventTap.start`), and the system's deadline runs from when an
/// event is *posted* rather than from when the callback is entered — so a main thread busy with
/// anything at all starves the tap exactly as effectively as a slow callback would. The number that
/// decides whether the tap survives is therefore not "how long did `handle` take" but "how long did
/// main go without returning to its wait", which is what this records.
///
/// A run-loop observer rather than a polling timer, and the difference is why this can be left on:
/// the observer is called on turns the loop was taking anyway, so it adds no wakeups of its own, and
/// the work per turn is one clock read and a comparison. A 100ms timer would wake the main thread
/// ten times a second forever to measure whether the main thread is busy, which is its own answer.
///
/// Reported at `.error` deliberately. Only `notice` and above reach the persistent store, and this
/// exists to be read back *after* a stall the user noticed — a level that needs verbose logging
/// switched on beforehand would be useless for exactly the case it is for.
@MainActor
enum MainLoopMonitor {
    /// Turns longer than this are logged.
    ///
    /// 150ms is chosen to sit between the two things it has to tell apart. It is comfortably inside
    /// the tap's deadline, so a line here is a warning rather than a report of damage already done —
    /// and it is comfortably outside anything the main thread has business doing between keystrokes,
    /// so it is not a line per SwiftUI relayout. It is also below `AX.timeout`, which means a single
    /// Accessibility call that leaked onto this thread crosses it on its own.
    private static let threshold: TimeInterval = 0.15

    private static var observer: CFRunLoopObserver?
    /// When the current turn began. Nil between turns — the loop is asleep and owes us nothing.
    private static var wokeAt: CFAbsoluteTime?

    /// The worst turn since launch, and how many crossed the threshold. Logged as a running total
    /// beside each crossing so a single line says both "this happened" and "how often".
    private(set) static var worst: TimeInterval = 0
    private(set) static var stalls = 0

    static func start() {
        guard observer == nil else { return }
        let created = CFRunLoopObserverCreateWithHandler(
            kCFAllocatorDefault,
            CFRunLoopActivity.afterWaiting.rawValue | CFRunLoopActivity.beforeWaiting.rawValue,
            true,  // repeats
            // Order: run last within each activity, so a turn is measured around everything else
            // scheduled on it rather than around whatever happens to sort after us.
            CFIndex.max
        ) { _, activity in
            // The observer is called on the loop it is attached to, which is main by construction —
            // the same formality `EventTap.dispatch` documents.
            MainActor.assumeIsolated {
                if activity.contains(.afterWaiting) {
                    wokeAt = CFAbsoluteTimeGetCurrent()
                } else if activity.contains(.beforeWaiting), let start = wokeAt {
                    wokeAt = nil
                    record(CFAbsoluteTimeGetCurrent() - start)
                }
            }
        }
        guard let created else {
            Log.general.error("main loop monitor: could not create the observer")
            return
        }
        // `.commonModes` for the same reason the tap's source uses it: AppKit puts modal panels and
        // event tracking in that set, and a stall during a menu or a modal is still a stall.
        CFRunLoopAddObserver(CFRunLoopGetMain(), created, .commonModes)
        observer = created
        Log.general.notice(
            "main loop monitor: watching, threshold \(Int(Self.threshold * 1000), privacy: .public)ms")
    }

    private static func record(_ duration: TimeInterval) {
        if duration > worst { worst = duration }
        guard duration >= threshold else { return }
        stalls += 1
        Log.general.error(
            """
            main loop busy \(Int(duration * 1000), privacy: .public)ms — the tap was unserviceable \
            for that long (stall \(Self.stalls, privacy: .public), worst \
            \(Int(Self.worst * 1000), privacy: .public)ms)
            """)
    }
}
