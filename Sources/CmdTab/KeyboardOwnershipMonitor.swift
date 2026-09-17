import AppKit
import Carbon
import IOKit

/// Says, in the log, when the keyboard has been taken away from the tap — and takes it back where
/// it can.
///
/// Two things do that, and both are invisible from inside the tap, because the tap is precisely
/// what stops being called:
///
/// * **Secure event input.** While any process has it on — a password field, 1Password's prompt,
///   `sudo` in a terminal, the lock screen — the window server delivers no keyboard events to a
///   session-level event tap at all. Nothing to do about it but say so.
/// * **The native ⌘-Tab, re-enabled.** The symbolic hot key is global window server state, and the
///   previous instance of this app hands it back on its way out; land that after the new instance
///   has taken over and the window server consumes ⌘-Tab itself, ahead of every tap. See
///   `SystemSwitcher` for the mechanics. This one can be undone, so it is.
///
/// Both were found the same way: the report was "sometimes the switcher doesn't pop up", the log
/// for that minute was empty, and nothing in the app could say why, because the only thing that
/// would have noticed — the tap — is exactly what had been switched off.
///
/// Checked on app activation rather than polled. The tap cannot be the trigger, for the reason
/// above, and a timer would wake the main thread forever to ask questions that only change when
/// focus does: secure input is held for as long as a secure field has focus, and a stale hand-back
/// arrives within moments of a relaunch, when the user is about to switch to whatever they were
/// doing. `NSWorkspace` posts that switch regardless of who owns the keyboard. Two extra checks
/// shortly after launch cover the hand-back that lands before the user touches anything.
///
/// Reported at `.error` when something is wrong, for the reason `MainLoopMonitor` gives: this
/// exists to be read back after a press the user noticed going nowhere, and a level that needs
/// verbose logging switched on beforehand would be useless for exactly that case.
@MainActor
enum KeyboardOwnershipMonitor {
    private static var observer: NSObjectProtocol?
    private static var secureInputWasOn = false

    /// When to look again after launch, on top of every activation. The old instance's teardown is
    /// what these are for: `stop()` runs on its main queue behind whatever that thread was doing,
    /// so the restore can trail the new instance's takeover by a second or more.
    private static let launchChecks: [TimeInterval] = [2, 6]

    static func start() {
        guard observer == nil else { return }
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated { check() }
        }
        check()
        for delay in launchChecks {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                MainActor.assumeIsolated { check() }
            }
        }
    }

    private static func check() {
        SystemSwitcher.reassertIfNeeded()
        checkSecureInput()
    }

    private static func checkSecureInput() {
        let isOn = IsSecureEventInputEnabled()
        guard isOn != secureInputWasOn else { return }
        secureInputWasOn = isOn
        guard isOn else {
            Log.general.notice("secure input: released; the tap receives keys again")
            return
        }
        let holder = holderPID().map { pid in
            let name = NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"
            return "pid \(pid) (\(name))"
        }
        Log.general.error(
            """
            secure input: on, attributed to \(holder ?? "an unknown process", privacy: .public) — the \
            event tap receives no keys until it is released; a trigger pressed now does nothing
            """)
    }

    /// Which process holds secure input, from the window server's console-user record. The only
    /// place macOS writes it down; `IsSecureEventInputEnabled` says only that somebody does.
    ///
    /// Read off the registry *root*. The property is widely documented as living on `IOHIDSystem`,
    /// and on this macOS it does not: measured with a command-line probe that enabled secure input
    /// on itself, `IOHIDSystem` carried no `IOConsoleUsers` at all, while the root entry (and
    /// `IOResources`) carried the array. The pid in it was not the probe's own but Ghostty's — the
    /// frontmost app, hosting the probe's terminal — so what this names is the app the user was in
    /// when the keyboard went away, which is the more useful answer anyway.
    private static func holderPID() -> pid_t? {
        let root = IORegistryGetRootEntry(kIOMainPortDefault)
        guard root != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(root) }
        guard
            let users = IORegistryEntryCreateCFProperty(
                root, "IOConsoleUsers" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [[String: Any]]
        else { return nil }
        for user in users {
            if let pid = user["kCGSSessionSecureInputPID"] as? pid_t, pid > 0 { return pid }
        }
        return nil
    }
}
