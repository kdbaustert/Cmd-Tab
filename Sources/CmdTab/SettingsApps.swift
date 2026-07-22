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
    private var reloadPending = false
    /// Name and icon for apps that are not running, which cost a LaunchServices lookup and two disk
    /// reads each. A reload runs on every launch and quit anywhere on the system, and an installed
    /// app's name and icon do not change underneath us often enough to pay that every time.
    private var installedCache: [String: AppEntry] = [:]

    init() {
        let center = NSWorkspace.shared.notificationCenter
        for name: NSNotification.Name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didTerminateApplicationNotification,
        ] {
            observers.append(
                center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.setNeedsReload() }
                })
        }
        reload()
    }

    deinit {
        let center = NSWorkspace.shared.notificationCenter
        for observer in observers { center.removeObserver(observer) }
    }

    /// Coalesces the reloads a single click causes. Setting one control clears the other, so both
    /// stores publish in the same turn — and a rebuild walks every running app for its icon and
    /// hits the disk for every app that is not running, which is not worth doing twice.
    func setNeedsReload() {
        guard !reloadPending else { return }
        reloadPending = true
        Task { @MainActor [weak self] in
            self?.reloadPending = false
            self?.reload()
        }
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
            byID[id] = installedEntry(for: id)
        }

        entries = byID.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    /// Resolves a bundle identifier to something displayable. Falls back to the raw identifier
    /// so an app that has since been uninstalled still gets a row the user can untick. Shares
    /// `appInfo` with the launch tiles so a row cannot read "Xcode.app" where the tile says
    /// "Xcode", or rename itself the moment the app quits.
    private func installedEntry(for bundleID: String) -> AppEntry {
        if let cached = installedCache[bundleID] { return cached }
        guard let info = FavoritesStore.appInfo(for: bundleID) else {
            // Not cached: the app may be installed while the window is open, and the placeholder
            // row is the one worth re-resolving.
            return AppEntry(id: bundleID, name: bundleID, icon: nil, isRunning: false)
        }
        let entry = AppEntry(id: bundleID, name: info.name, icon: info.icon, isRunning: false)
        installedCache[bundleID] = entry
        return entry
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
        .onChange(of: store.excluded) { apps.setNeedsReload() }
        .onChange(of: favorites.favorites) { apps.setNeedsReload() }
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
                // The captions are pinned: scrolled away they would leave exactly the two
                // unlabelled controls per row they exist to explain.
                LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                    Section {
                        ForEach(filtered) { entry in
                            AppRow(
                                entry: entry,
                                isFavorite: Binding(
                                    get: { isFavorite(entry.id) },
                                    set: { setFavorite($0, for: entry.id) }),
                                isExcluded: Binding(
                                    get: { store.isExcluded(entry.id) },
                                    set: { setExcluded($0, for: entry.id) }))
                            Divider().padding(.leading, 44)
                        }
                    } header: {
                        columnCaptions
                    }
                }
            }
        }
    }

    /// Column captions, so the star and the switch are not two unlabelled controls. Rows scroll
    /// underneath it, so it needs its own background — `.bar` rather than a flat colour, which
    /// would have to guess the tab view's content colour and would show as a mismatched band
    /// wherever the guess was wrong.
    private var columnCaptions: some View {
        HStack(spacing: 12) {
            Spacer()
            Text("Favorite").frame(width: 52, alignment: .center)
            Text("Exclude").frame(width: 40, alignment: .center)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(.bar)
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
        let stars = favorites.favorites.count { !store.isExcluded($0) }
        let hidden = store.excluded.count
        guard stars > 0 || hidden > 0 else { return "None set" }
        return "\(stars) favorite\(stars == 1 ? "" : "s") · \(hidden) excluded"
    }

    /// The two settings are contradictory — a favourite is pinned *into* the switcher and an
    /// exclusion keeps the app out of it — so a row must never claim both. Exclusion is what
    /// resolves it, by masking the star rather than deleting the favourite: the provider already
    /// drops an excluded app from the launch tiles, so the switcher behaves the same either way,
    /// and the user gets their star back — in its original position — by turning the switch off.
    /// That also means settings that arrive already contradicting themselves, from a build that
    /// predates this pane or from an import, need no rewriting to display honestly.
    private func isFavorite(_ id: String) -> Bool {
        favorites.isFavorite(id) && !store.isExcluded(id)
    }

    /// Starring is the answer that has to move both settings: with the switch on, the star is
    /// masked, so turning it on can only mean "and stop excluding this".
    private func setFavorite(_ on: Bool, for id: String) {
        if on {
            store.setExcluded(false, for: id)
            favorites.add(id)
        } else {
            favorites.remove(id)
        }
    }

    private func setExcluded(_ on: Bool, for id: String) {
        store.setExcluded(on, for: id)
    }

    private func clearAll() {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "Clear all favorites and exclusions?"
        alert.informativeText = "Every app goes back to the switcher's default behaviour."
        let clear = alert.addButton(withTitle: "Clear")
        alert.addButton(withTitle: "Cancel")
        clear.hasDestructiveAction = true
        // The first button is the default one, and Return should not be what wipes a hand-curated
        // list that nothing can restore. Dropping it leaves the alert with no default rather than
        // moving Return onto Cancel — that would take Cancel's Escape, and being unable to back out
        // of a destructive alert from the keyboard is the worse trade.
        clear.keyEquivalent = ""
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.removeAll()
        favorites.removeAll()
    }

    /// Lets the user reach an app that is not running, which by definition cannot be in the list.
    /// It offers both settings rather than only favouriting: pre-excluding an app you know you never
    /// want in the switcher is exactly the case a row cannot cover, since the row only appears once
    /// the app runs — by which point the switcher has already shown it.
    private func addApps() {
        let choice = NSSegmentedControl(
            labels: ["Favorite", "Exclude"], trackingMode: .selectOne, target: nil, action: nil)
        choice.selectedSegment = 0
        let accessory = NSStackView(views: [NSTextField(labelWithString: "Add as:"), choice])
        accessory.orientation = .horizontal
        accessory.spacing = 8
        accessory.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)

        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to add"
        panel.prompt = "Add"
        panel.accessoryView = accessory
        panel.isAccessoryViewDisclosed = true
        guard panel.runModal() == .OK else { return }

        let excluding = choice.selectedSegment == 1
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            if excluding {
                setExcluded(true, for: id)
            } else {
                setFavorite(true, for: id)
            }
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
                    // Sized inside the label, not around the button: a plain button is only hit
                    // where its label is, so a frame outside it centres a 12pt target rather
                    // than making the whole captioned column clickable.
                    .frame(width: 52, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
