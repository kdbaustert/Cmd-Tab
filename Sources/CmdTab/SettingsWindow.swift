import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row in the settings list: an app that can be excluded from the switcher.
struct AppEntry: Identifiable {
    /// The bundle identifier, which is also what the exclusion is keyed on.
    let id: String
    let name: String
    let icon: NSImage?
    let isRunning: Bool
}

/// The list of apps offered in settings: everything currently running, plus anything already
/// excluded. Excluded apps have to appear even when they are not running, or an exclusion could
/// never be undone once the app quit.
@MainActor
final class AppListModel: ObservableObject {
    @Published private(set) var entries: [AppEntry] = []

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.reload() }
                })
        }
        reload()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    func reload() {
        let excluded = ExclusionStore.shared.excluded
        var byID: [String: AppEntry] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  !app.isTerminated else { continue }
            byID[id] = AppEntry(
                id: id, name: app.localizedName ?? id, icon: app.icon, isRunning: true)
        }

        // Fold in excluded apps that are not running right now.
        for id in excluded where byID[id] == nil {
            byID[id] = Self.installedEntry(for: id)
        }

        entries = byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolves a bundle identifier to something displayable. Falls back to the raw identifier
    /// so an app that has since been uninstalled still gets a row the user can untick.
    private static func installedEntry(for bundleID: String) -> AppEntry {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return AppEntry(id: bundleID, name: bundleID, icon: nil, isRunning: false)
        }
        return AppEntry(
            id: bundleID,
            name: FileManager.default.displayName(atPath: url.path),
            icon: NSWorkspace.shared.icon(forFile: url.path),
            isRunning: false)
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            AppearanceSettings(appearance: .shared)
                .tabItem { Label("Appearance", systemImage: "slider.horizontal.3") }
            ExcludedAppsSettings(store: .shared)
                .tabItem { Label("Excluded Apps", systemImage: "eye.slash") }
        }
        .padding(12)
        .frame(width: 470, height: 620)
    }
}

struct AppearanceSettings: View {
    @ObservedObject var appearance: AppearanceStore
    @StateObject private var apps = AppListModel()

    private var metrics: Metrics { appearance.metrics }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            preview
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    SliderRow(
                        title: "Icon size",
                        help: "Window mode uses a smaller icon, and scales in step.",
                        value: $appearance.iconSize,
                        range: Metrics.iconSizeRange,
                        step: 8)
                    SliderRow(
                        title: "Icon spacing",
                        help: "Slack around each icon, inside its highlight.",
                        value: $appearance.iconSpacing,
                        range: Metrics.iconSpacingRange,
                        step: 2)
                    SliderRow(
                        title: "Title spacing",
                        help: "Gap between an icon and its name.",
                        value: $appearance.titleSpacing,
                        range: Metrics.titleSpacingRange,
                        step: 1)
                }
                .padding(12)
            }

            Divider()
            HStack {
                Text("Changes apply live, including to an open switcher.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Reset", action: appearance.reset)
                    .disabled(appearance.isDefault)
            }
            .padding(12)
        }
    }

    /// A real panel: same glass, same metrics, real icons. The switcher itself cannot be seen
    /// while the settings window is frontmost, so this has to stand in for it faithfully.
    private var preview: some View {
        let tile = metrics.tile(for: .apps)
        let entries = Array(apps.entries.prefix(4))
        return ScrollView([.horizontal, .vertical], showsIndicators: false) {
            VStack(spacing: metrics.titleSpacing) {
                HStack(spacing: Metrics.tileGap) {
                    ForEach(Array(entries.enumerated()), id: \.element.id) { i, entry in
                        PreviewTile(
                            icon: entry.icon,
                            tile: tile,
                            iconSize: metrics.iconSize,
                            isSelected: i == min(1, entries.count - 1))
                    }
                }
                Text(entries.count > 1 ? entries[1].name : "Preview")
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(1)
            }
            .padding(Metrics.panelPadding)
            .background(VisualEffectBackground())
            .clipShape(RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.corner, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
            )
            .fixedSize()
            .padding(14)
            .frame(maxWidth: .infinity)
        }
        // Fixed, so the window does not jump around as the sliders move.
        .frame(height: 210)
        .background(Color.primary.opacity(0.04))
    }
}

private struct SliderRow: View {
    let title: String
    let help: String
    @Binding var value: CGFloat
    let range: ClosedRange<CGFloat>
    let step: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text(title).font(.system(size: 12, weight: .medium))
                Spacer()
                Text("\(Int(value)) pt")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
            Text(help).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

private struct PreviewTile: View {
    let icon: NSImage?
    let tile: CGSize
    let iconSize: CGFloat
    let isSelected: Bool

    var body: some View {
        Group {
            if let icon {
                Image(nsImage: icon).resizable().interpolation(.high)
            } else {
                Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
            }
        }
        .scaledToFit()
        .frame(width: iconSize, height: iconSize)
        .frame(width: tile.width, height: tile.height)
        .background {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(isSelected ? 0.16 : 0))
        }
    }
}

struct ExcludedAppsSettings: View {
    @ObservedObject var store: ExclusionStore
    @StateObject private var apps = AppListModel()
    @State private var query = ""

    private var filtered: [AppEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps.entries }
        return apps.entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            list
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A newly excluded app that is not running needs a row of its own, so the list is rebuilt
        // rather than just re-rendered.
        .onChange(of: store.excluded) { apps.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Excluded Apps").font(.system(size: 13, weight: .semibold))
            Text("Apps ticked here never appear in the switcher, in either mode.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                TextField("Search", text: $query)
                    .textFieldStyle(.plain)
                if !query.isEmpty {
                    Button {
                        query = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.06)))
            .padding(.top, 8)
        }
        .padding(12)
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            VStack {
                Spacer()
                Text(query.isEmpty ? "No apps running" : "No matches")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filtered) { entry in
                        AppRow(
                            entry: entry,
                            isExcluded: Binding(
                                get: { store.isExcluded(entry.id) },
                                set: { store.setExcluded($0, for: entry.id) }))
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Button("Add App…", action: addApps)
            Spacer()
            Text(store.excluded.isEmpty ? "None excluded" : "\(store.excluded.count) excluded")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Include All", action: store.removeAll)
                .disabled(store.excluded.isEmpty)
        }
        .padding(12)
    }

    /// Lets the user exclude an app that is not running, which by definition cannot be in the list.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to exclude from the switcher"
        panel.prompt = "Exclude"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            store.setExcluded(true, for: id)
        }
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @Binding var isExcluded: Bool

    var body: some View {
        HStack(spacing: 8) {
            Group {
                if let icon = entry.icon {
                    Image(nsImage: icon).resizable().interpolation(.high)
                } else {
                    Image(systemName: "app.dashed").resizable().foregroundStyle(.secondary)
                }
            }
            .scaledToFit()
            .frame(width: 22, height: 22)

            Text(entry.name).font(.system(size: 12)).lineLimit(1)
            if !entry.isRunning {
                Text("not running")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Toggle("", isOn: $isExcluded)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { isExcluded.toggle() }
    }
}

/// Hosts the settings window. Kept alive by the delegate so the window survives being closed.
@MainActor
final class SettingsWindowController: NSObject {
    private var window: NSWindow?

    func show() {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView()))
            window.title = "Cmd-Tab Settings"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        // We run as an accessory app, so nothing activates us implicitly: without this the
        // window opens behind the frontmost app and never takes the keyboard.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}
