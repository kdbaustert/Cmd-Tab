import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// One row in the settings list: an app that can be favourited or excluded.
struct AppEntry: Identifiable {
    /// The bundle identifier, which is also what both settings are keyed on.
    let id: String
    let name: String
    let icon: NSImage?
    let isRunning: Bool
}

/// The list of apps offered in settings: everything currently running, plus anything already
/// favourited or excluded. Those have to appear even when they are not running — a favourite is
/// *about* not running, and an exclusion could never be undone once the app quit.
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
        var byID: [String: AppEntry] = [:]

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let id = app.bundleIdentifier,
                  id != Bundle.main.bundleIdentifier,
                  !app.isTerminated else { continue }
            byID[id] = AppEntry(
                id: id, name: app.localizedName ?? id, icon: app.icon, isRunning: true)
        }

        // Fold in settings-bearing apps that are not running right now.
        let pinned = ExclusionStore.shared.excluded.union(FavoritesStore.shared.favorites)
        for id in pinned where byID[id] == nil {
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

/// Favourites and exclusions in one list. They are opposite answers to the same question — should
/// this app be in the switcher — so they belong on the same row rather than in two panes listing
/// the same apps twice.
struct AppsSettings: View {
    @ObservedObject var store: ExclusionStore
    @ObservedObject var favorites: FavoritesStore
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
        // An app that is not running needs a row of its own once it is favourited or excluded, so
        // the list is rebuilt rather than just re-rendered.
        .onChange(of: store.excluded) { apps.reload() }
        .onChange(of: favorites.favorites) { apps.reload() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Apps").font(.system(size: 13, weight: .semibold))
            Text(
                "Star an app to keep it in the switcher even when it isn't running; picking it "
                + "launches it. Excluded apps never appear, in either mode.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                    // Column captions, so the star and the switch are not two unlabelled controls.
                    HStack(spacing: 12) {
                        Spacer()
                        Text("Favorite").frame(width: 52, alignment: .center)
                        Text("Exclude").frame(width: 40, alignment: .center)
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 4)

                    ForEach(filtered) { entry in
                        AppRow(
                            entry: entry,
                            isFavorite: Binding(
                                get: { favorites.favorites.contains(entry.id) },
                                set: { setFavorite($0, for: entry.id) }),
                            isExcluded: Binding(
                                get: { store.isExcluded(entry.id) },
                                set: { setExcluded($0, for: entry.id) }))
                        Divider().padding(.leading, 44)
                    }
                }
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Button("Add App…", action: addApps)
            Spacer()
            Text(summary)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            Button("Clear All", action: clearAll)
                .disabled(store.excluded.isEmpty && favorites.favorites.isEmpty)
        }
        .padding(12)
    }

    private var summary: String {
        let stars = favorites.favorites.count
        let hidden = store.excluded.count
        guard stars > 0 || hidden > 0 else { return "None set" }
        return "\(stars) favorite\(stars == 1 ? "" : "s") · \(hidden) excluded"
    }

    /// The two settings are contradictory — a favourite is pinned *into* the switcher and an
    /// exclusion keeps the app out of it — so turning one on turns the other off rather than
    /// leaving a row whose state does not describe what the switcher will do.
    private func setFavorite(_ on: Bool, for id: String) {
        if on {
            store.setExcluded(false, for: id)
            favorites.add(id)
        } else {
            favorites.remove(id)
        }
    }

    private func setExcluded(_ on: Bool, for id: String) {
        if on { favorites.remove(id) }
        store.setExcluded(on, for: id)
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.messageText = "Clear all favorites and exclusions?"
        alert.informativeText = "Every app goes back to the switcher's default behaviour."
        alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeAll()
        favorites.removeAll()
    }

    /// Lets the user reach an app that is not running, which by definition cannot be in the list.
    /// It is added as a favourite: a row only survives a reload once something is set on it, and
    /// pinning is the reason to reach for an app that is not running — excluding one that never
    /// appears in the switcher anyway is a no-op. The switch on the row overrides it.
    private func addApps() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to add as favourites"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            favorites.add(id)
        }
    }
}

private struct AppRow: View {
    let entry: AppEntry
    @Binding var isFavorite: Bool
    @Binding var isExcluded: Bool

    var body: some View {
        HStack(spacing: 12) {
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

            Button {
                isFavorite.toggle()
            } label: {
                Image(systemName: isFavorite ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(isFavorite ? Color.accentColor : Color.secondary)
            }
            .buttonStyle(.plain)
            .frame(width: 52, alignment: .center)
            .help("Show in the switcher even when not running; picking it launches the app.")

            Toggle("", isOn: $isExcluded)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
                .frame(width: 40, alignment: .center)
                .help("Never show this app in the switcher.")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        // The whole row used to toggle the exclusion switch. With two controls on it there is no
        // single thing a row-wide tap should mean, so each control is hit on its own now.
        .contentShape(Rectangle())
    }
}
