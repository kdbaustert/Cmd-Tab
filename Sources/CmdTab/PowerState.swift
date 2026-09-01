import Foundation
import IOKit.ps

/// Whether the machine is currently running on something it can run out of, and how much to slow a
/// background poll down when it is.
///
/// Two timers in this app poll for a condition that has no notification in front of it — trust
/// being revoked (`AppDelegate.watchForRevokedTrust`) and the window layout worth restoring after a
/// display change (`DisplayLayouts`). Both are cheap, both are defensible, and both are also a
/// wakeup every five seconds for the life of the process on a laptop that may be sitting in a bag.
/// Neither poll is watching for something that happens *quickly*: nobody revokes Accessibility in a
/// hurry, and a layout worth remembering is one that has been sat in for a while. So on battery they
/// go six times slower, and the only thing that costs is how stale the answer may be when it
/// matters — half a minute rather than five seconds.
///
/// Deliberately not a setting. A preference for how often a background timer fires is a question
/// nobody can answer about software they did not write, and the honest default is the one that
/// spends less of the battery for a difference nobody can perceive.
enum PowerState {
    /// How much longer a poll waits while conserving. Six, so a five-second poll becomes a
    /// half-minute one: still comfortably inside "before the user has finished plugging the cable
    /// in", and an order of magnitude fewer wakeups.
    static let conservingScale: Double = 6

    /// Whether to be sparing: on battery, or in Low Power Mode on any power source.
    ///
    /// Low Power Mode is included because it is the user saying so explicitly — a plugged-in Mac
    /// with the setting on is one whose owner has asked every process to do less, and a background
    /// poll is exactly the kind of work that request is about.
    static var isConserving: Bool {
        ProcessInfo.processInfo.isLowPowerModeEnabled || isOnBattery
    }

    /// Whether the current power source is a battery.
    ///
    /// `IOPSGetProvidingPowerSourceType` rather than walking the power-source list: the question is
    /// what is powering the machine right now, which is exactly what it answers, and it answers for
    /// a desktop with no battery too (AC, always). A failure to read anything is treated as being on
    /// AC — the conservative direction is the one that keeps the polls at their normal rate, since a
    /// slower poll is a feature degrading quietly and this should not happen by accident.
    static var isOnBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
            let source = IOPSGetProvidingPowerSourceType(blob)?.takeRetainedValue() as String?
        else { return false }
        return source == kIOPSBatteryPowerValue
    }

    /// `base`, stretched if the machine is conserving. Pure, so the arithmetic is testable without a
    /// battery to unplug.
    static func interval(_ base: TimeInterval, conserving: Bool) -> TimeInterval {
        conserving ? base * conservingScale : base
    }

    /// The interval a poll should use right now.
    static func interval(_ base: TimeInterval) -> TimeInterval {
        interval(base, conserving: isConserving)
    }
}
