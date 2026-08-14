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
    /// When the current turn began, on the uptime clock. Nil between turns — the loop is asleep and
    /// owes us nothing.
    ///
    /// `DispatchTime`, not `CFAbsoluteTimeGetCurrent`, and the difference is the whole reason this
    /// line can be believed. `CFAbsoluteTimeGetCurrent` is wall clock: it steps when NTP corrects it
    /// and it keeps running across a lid close, so a turn that merely *straddled* a sleep or a clock
    /// adjustment was reported as a main thread busy for the whole of it. That is not a hypothetical
    /// — the first week of these reports contained fifteen stalls up to 892ms and not one
    /// `tapDisabledByTimeout` beside them, which is the pairing a real stall of that length would be
    /// expected to produce. `uptimeNanoseconds` is `mach_absolute_time`: monotonic, unaffected by
    /// clock adjustments, and frozen while the machine is asleep, so a sleep-straddling turn now
    /// measures the work either side of it rather than the nap in between.
    private static var wokeAt: UInt64?

    /// The worst turn since launch, and how many crossed the threshold. Logged as a running total
    /// beside each crossing so a single line says both "this happened" and "how often".
    private(set) static var worst: TimeInterval = 0
    private(set) static var stalls = 0

    /// The last labelled piece of main-thread work to run, and when it started.
    ///
    /// A duration on its own is not actionable, which is what the first week of these reports
    /// demonstrated: fifteen crossings, no two adjacent to anything in the log, and so nothing to
    /// investigate. The label is the other half — `marking` wraps the main-thread work this app
    /// already knows to be expensive, and a crossing names whichever of them ran inside the turn it
    /// is reporting.
    ///
    /// `StaticString` so a mark costs a pointer store and no allocation: these wrap paths that run
    /// per keystroke and per click, where anything that allocates would be a worse problem than the
    /// one being measured.
    private static var lastMark: StaticString?
    private static var lastMarkAt: UInt64 = 0

    /// Labels a stretch of main-thread work, so a stall that happens inside it says so.
    ///
    /// Deliberately records the *start* rather than bracketing the call: the report is written at
    /// `beforeWaiting`, long after `work` has returned, so a mark that cleared itself on the way out
    /// would never be there to read. What the timestamp buys is the discipline of only naming a mark
    /// that actually ran inside the turn being reported.
    @discardableResult
    static func marking<T>(_ label: StaticString, _ work: () -> T) -> T {
        lastMark = label
        lastMarkAt = DispatchTime.now().uptimeNanoseconds
        return work()
    }

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
                    wokeAt = DispatchTime.now().uptimeNanoseconds
                } else if activity.contains(.beforeWaiting), let start = wokeAt {
                    wokeAt = nil
                    let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                    record(TimeInterval(elapsed) / 1_000_000_000, since: start)
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

    private static func record(_ duration: TimeInterval, since turnStart: UInt64) {
        if duration > worst { worst = duration }
        guard duration >= threshold else { return }
        stalls += 1
        Log.general.error(
            """
            main loop busy \(Int(duration * 1000), privacy: .public)ms in \
            \(Self.currentMode(), privacy: .public) during \(Self.suspect(since: turnStart), privacy: .public) \
            — the tap was unserviceable for that long (stall \(Self.stalls, privacy: .public), worst \
            \(Int(Self.worst * 1000), privacy: .public)ms)
            """)
    }

    /// Whichever labelled work ran inside the turn being reported, or a placeholder.
    ///
    /// The timestamp check is what keeps this honest: `lastMark` is never cleared, so without it a
    /// stall in some unlabelled code would inherit the name of the last panel layout to have
    /// happened, which is worse than saying nothing — it would send the reader after the one path
    /// that was demonstrably not involved.
    ///
    /// Internal rather than private so that guard can be tested directly. The alternative is a test
    /// that sleeps through a real run-loop turn to provoke a crossing, which is half a second of
    /// wall clock and a timing dependency for a rule that is two comparisons.
    static func suspect(since turnStart: UInt64) -> String {
        guard let lastMark, lastMarkAt >= turnStart else { return "unlabelled work" }
        return "\(lastMark)"
    }

    /// The run-loop mode the stalled turn was running in.
    ///
    /// Read here rather than per turn: this allocates a string, and the observer fires on every turn
    /// the loop takes whereas this runs only on the handful that cross the threshold. Still accurate
    /// — the mode is current until `beforeWaiting` returns, and that is where this is called from.
    /// Worth having because the modes mean quite different things: a stall in `kCFRunLoopDefaultMode`
    /// is this app's own work, while one in a tracking or modal mode is a menu, a drag or a sheet
    /// holding the loop, which is AppKit's to answer for and not a bug here.
    private static func currentMode() -> String {
        (CFRunLoopCopyCurrentMode(CFRunLoopGetMain())?.rawValue as String?) ?? "an unknown mode"
    }
}
