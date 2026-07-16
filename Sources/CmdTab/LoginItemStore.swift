import ServiceManagement
import SwiftUI

/// Whether Cmd-Tab launches itself when the user logs in. Backed by `SMAppService`, so the truth
/// lives in the system's Login Items list rather than in our own defaults — the checkbox only ever
/// mirrors that state.
@MainActor
final class LoginItemStore: ObservableObject {
    static let shared = LoginItemStore()

    @Published private(set) var startAtLogin: Bool

    private init() {
        startAtLogin = SMAppService.mainApp.status == .enabled
    }

    /// Re-reads the system state. Worth calling when the settings window appears, since the user
    /// can flip the item from System Settings → General → Login Items behind our back.
    func refresh() {
        startAtLogin = SMAppService.mainApp.status == .enabled
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
                if SMAppService.mainApp.status == .enabled {
                    try SMAppService.mainApp.unregister()
                }
            }
        } catch {
            Log.general.error("login item toggle failed: \(error.localizedDescription)")
        }
        startAtLogin = SMAppService.mainApp.status == .enabled
    }
}
