import ServiceManagement
import SwiftUI

/// Whether Cmd-Tab launches itself when the user logs in. Backed by `SMAppService`, so the truth
/// lives in the system's Login Items list rather than in our own defaults — the checkbox only ever
/// mirrors that state.
@MainActor
final class LoginItemStore: ObservableObject {
    static let shared = LoginItemStore()

    @Published private(set) var startAtLogin: Bool

    /// The system's own answer to the last question asked of it, and the last refusal if there was
    /// one. Both exist so the row can say *why* a toggle did not take. The snap-back itself is
    /// deliberate — this checkbox mirrors system truth rather than intent — but a switch that flips
    /// back in silence reads as a bug in this app, which is the same argument `iCloudSyncSubtitle`
    /// makes for the row two sections below it.
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastError: String?

    /// `.requiresApproval` counts as on.
    ///
    /// It is not a rejection: registration *succeeded* and macOS is waiting for the user to allow
    /// the item in Login Items. Testing `== .enabled` collapsed it in with genuine failures, so the
    /// toggle snapped back on a call that had worked — the one reading guaranteed to send someone
    /// looking for a fault here rather than at the pane holding the approval.
    private static func isOn(_ status: SMAppService.Status) -> Bool {
        status == .enabled || status == .requiresApproval
    }

    private init() {
        let status = SMAppService.mainApp.status
        self.status = status
        startAtLogin = Self.isOn(status)
    }

    /// Re-reads the system state. Worth calling when the settings window appears, since the user
    /// can flip the item from System Settings → General → Login Items behind our back.
    func refresh() {
        lastError = nil
        sync()
    }

    /// Pulls `status` and `startAtLogin` from the system in one place, so the two cannot disagree.
    private func sync() {
        status = SMAppService.mainApp.status
        startAtLogin = Self.isOn(status)
    }

    /// What the row shows under "Start at login", or nil when there is nothing to explain.
    ///
    /// Deliberately silent for the ordinary on and off states: a subtitle that is always there
    /// stops being read, and the switch already says those two things itself.
    var subtitle: String? {
        if let lastError {
            return "macOS would not change this: \(lastError)"
        }
        if status == .requiresApproval {
            return "Waiting to be allowed in System Settings → General → Login Items. Cmd-Tab "
                + "will start at login once it is enabled there."
        }
        return nil
    }

    /// Registers or unregisters the app as a login item. The published value is set from the
    /// resulting system status, not the requested one, so a rejected change simply snaps back.
    func setStartAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                // `isOn`, not `== .enabled`: the toggle reads on for `.requiresApproval` too, and
                // that is a registration `unregister` can withdraw. Testing only `.enabled` left it
                // stuck — nothing was called, `sync()` read the same status back, and the switch
                // snapped on with no error to explain why.
                if Self.isOn(SMAppService.mainApp.status) {
                    try SMAppService.mainApp.unregister()
                }
            }
            lastError = nil
        } catch {
            Log.general.error(
                "login item toggle failed: \(error.localizedDescription, privacy: .public)")
            // Held rather than only logged. An os_log line is not a user-visible surface, and the
            // failure this reports is one the user is looking straight at.
            lastError = error.localizedDescription
        }
        sync()
    }
}
