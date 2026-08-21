import AppKit
import SwiftUI

/// The About tab: what this build is, what it is allowed to do, and where it came from.
///
/// Replaces the menu-bar `About Cmd-Tab` item and the standard AppKit about panel it opened. That
/// panel could show the name, icon and version and nothing else — the permission state, which is
/// the thing anyone actually opens About to check when the switcher is not responding, had no
/// place in it.
struct AboutSettings: View {
    @ObservedObject private var behavior = BehaviorStore.shared
    @ObservedObject private var updater = Updater.shared

    /// Re-read whenever the tab appears rather than cached at launch: the usual reason to be
    /// looking at this pane is that you have just granted something in System Settings.
    @State private var isTrusted = Permissions.isTrusted
    @State private var canCapture = Permissions.canCaptureScreen
    /// Momentary "Copied" confirmation on the button below. Nothing else observes it.
    @State private var didCopyCommand = false

    private static let repositoryURL = URL(string: "https://github.com/kdbaustert/Cmd-Tab")!

    /// Reads back everything this app has logged in the last half hour. `--info` is what includes
    /// the `notice` lines the switcher writes; without it `log show` returns only errors and faults.
    private static let logCommand =
        "log show --last 30m --predicate 'subsystem == \"com.cmdtab.CmdTab\"' --style compact --info"

    var body: some View {
        SettingsPage(title: "About") {
            hero

            SettingsSection(
                title: "Permissions", anchor: SettingsAnchor.permissions,
                footer: "Accessibility is granted per binary. A rebuild signed with a different "
                    + "certificate looks like a new app to macOS and has to be granted again."
            ) {
                SettingsRow(
                    title: "Accessibility",
                    subtitle: "Required. Without it the event tap cannot see ⌘-Tab, and windows "
                        + "cannot be raised."
                ) {
                    HStack(spacing: 8) {
                        StatusPill(ok: isTrusted, granted: "Granted", missing: "Not granted")
                        Button("Open…") { Permissions.openAccessibilitySettings() }
                    }
                }
                SettingsRow(
                    title: "Screen Recording",
                    subtitle: "Only for window previews on hover. Everything else works without it."
                ) {
                    HStack(spacing: 8) {
                        StatusPill(ok: canCapture, granted: "Granted", missing: "Not granted")
                        Button("Open…") { Permissions.openScreenRecordingSettings() }
                    }
                }
            }

            SettingsSection(
                title: "Diagnostics", anchor: SettingsAnchor.diagnostics,
                footer: "Off, the switcher records what it did — sessions opening, picks, tiling, "
                    + "anything that failed. On, it also records every key it saw getting there. "
                    + "Leave it off unless you are chasing something; it is a line per keystroke."
            ) {
                SettingsToggle(
                    title: "Verbose logging",
                    subtitle: "Keep the per-key tracing in the system log, so a problem can be read "
                        + "back afterwards instead of having to happen again while you watch.",
                    isOn: $behavior.verboseLogging)
                SettingsRow(
                    title: "Console command",
                    subtitle: "Paste into Terminal to read back what was logged."
                ) {
                    Button(didCopyCommand ? "Copied" : "Copy") { copyLogCommand() }
                        .disabled(didCopyCommand)
                }
            }

            SettingsSection(
                title: "Updates", anchor: SettingsAnchor.updates,
                footer: Updater.isConfigured
                    ? "Updates are downloaded over HTTPS and checked against this app's signing key "
                        + "before anything is installed, so a replaced download cannot install a "
                        + "different app."
                    : "This build has no update feed — it was produced by build.sh rather than a "
                        + "release, and updating itself out from under you is not something a local "
                        + "build should do."
            ) {
                SettingsRow(
                    title: "Check for updates",
                    subtitle: Self.lastCheckDescription(updater.lastCheck)
                ) {
                    Button("Check Now") { updater.checkForUpdates() }
                        .disabled(!updater.canCheck || !Updater.isConfigured)
                }
                SettingsToggle(
                    title: "Check automatically",
                    subtitle: "Look for a new version in the background, about once a day, and say "
                        + "so when one turns up.",
                    isOn: Binding(
                        get: { updater.automaticallyChecks },
                        set: { updater.automaticallyChecks = $0 }))
                    .disabled(!Updater.isConfigured)
                SettingsToggle(
                    title: "Install automatically",
                    subtitle: "Download and install without asking, applying it the next time "
                        + "Cmd-Tab starts. Off keeps the decision yours — this app owns ⌘-Tab for "
                        + "the whole machine, so replacing itself mid-session is worth a prompt.",
                    isOn: Binding(
                        get: { updater.automaticallyDownloads },
                        set: { updater.automaticallyDownloads = $0 }))
                    .disabled(!Updater.isConfigured || !updater.automaticallyChecks)
            }

            SettingsSection(title: "Build", anchor: SettingsAnchor.build) {
                SettingsRow(title: "Version") {
                    Text(Self.version)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                SettingsRow(title: "Source", subtitle: "Open the repository in your browser.") {
                    Button("View on GitHub") { NSWorkspace.shared.open(Self.repositoryURL) }
                }
            }

            VStack(spacing: 2) {
                Text(Self.copyright)
                Text("Developed by Kenny Baustert")
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .onAppear(perform: refresh)
    }

    private var hero: some View {
        HStack(spacing: 16) {
            Group {
                if let icon = NSImage(named: "AppIcon") {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "square.stack.3d.up.fill").resizable()
                }
            }
            .scaledToFit()
            .frame(width: 72, height: 72)

            VStack(alignment: .leading, spacing: 4) {
                Text("Cmd-Tab").font(.system(size: 20, weight: .semibold))
                Text("Version \(Self.version)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Text(
                    "A ⌘-Tab replacement for macOS. Switches between applications or individual "
                    + "windows, driven entirely from the menu bar.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                .fill(SettingsChrome.cardFill))
        .overlay(
            RoundedRectangle(cornerRadius: SettingsChrome.cardCorner, style: .continuous)
                .strokeBorder(SettingsChrome.cardBorder, lineWidth: SettingsChrome.hairline))
    }

    private func refresh() {
        isTrusted = Permissions.isTrusted
        canCapture = Permissions.canCaptureScreen
    }

    private func copyLogCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(Self.logCommand, forType: .string)
        didCopyCommand = true
        // Back to "Copy" on its own, so the button does not sit there claiming a copy that happened
        // a quarter of an hour ago.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { didCopyCommand = false }
    }

    /// The subtitle under the Check button. "Never" is a real answer worth showing rather than
    /// hiding behind an empty string: a background updater that has never once run is the failure
    /// this row exists to make visible.
    private static func lastCheckDescription(_ date: Date?) -> String {
        guard let date else { return "Never checked." }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "Last checked \(formatter.localizedString(for: date, relativeTo: Date()))."
    }

    /// `1.2.3 (45)`, or just the short string when there is no separate build number to add.
    private static var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "—"
        let build = info?["CFBundleVersion"] as? String
        guard let build, build != short else { return short }
        return "\(short) (\(build))"
    }

    private static var copyright: String {
        Bundle.main.infoDictionary?["NSHumanReadableCopyright"] as? String ?? ""
    }
}

/// Granted / not granted, as a coloured pill rather than a word — the whole point of this row is to
/// be readable at a glance by someone who is already frustrated.
private struct StatusPill: View {
    let ok: Bool
    let granted: String
    let missing: String

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 10))
            Text(ok ? granted : missing)
                .font(.system(size: 11, weight: .medium))
        }
        .foregroundStyle(ok ? Color.green : Color.orange)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            Capsule().fill((ok ? Color.green : Color.orange).opacity(0.14)))
    }
}
