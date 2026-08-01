import AppKit
import SwiftUI

/// The About tab: what this build is, what it is allowed to do, and where it came from.
///
/// Replaces the menu-bar `About Cmd-Tab` item and the standard AppKit about panel it opened. That
/// panel could show the name, icon and version and nothing else — the permission state, which is
/// the thing anyone actually opens About to check when the switcher is not responding, had no
/// place in it.
struct AboutSettings: View {
    /// Re-read whenever the tab appears rather than cached at launch: the usual reason to be
    /// looking at this pane is that you have just granted something in System Settings.
    @State private var isTrusted = Permissions.isTrusted
    @State private var canCapture = Permissions.canCaptureScreen

    private static let repositoryURL = URL(string: "https://github.com/kdbaustert/Cmd-Tab")!

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

            Text(Self.copyright)
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
