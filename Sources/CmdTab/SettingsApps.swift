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

    /// The row for a bundle identifier whether or not it is in `entries` — a direct-activation
    /// target that is not running and is neither favourited nor excluded, or a favourite being
    /// listed a second time in its own order. Shares `installedCache`, so a settings pane that asks
    /// on every render pays the LaunchServices lookup once.
    func entry(for bundleID: String) -> AppEntry {
        if let listed = entries.first(where: { $0.id == bundleID }) { return listed }
        return installedEntry(for: bundleID)
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
    @ObservedObject private var globals = GlobalActionsStore.shared
    @ObservedObject private var rules = AppRulesStore.shared
    @ObservedObject private var behavior = BehaviorStore.shared
    @State private var query = ""

    private var filtered: [AppEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return apps.entries }
        return apps.entries.filter { $0.name.localizedCaseInsensitiveContains(trimmed) }
    }

    var body: some View {
        SettingsPage(
            title: "Apps",
            subtitle: "Star an app to keep it in the switcher even when it isn't running; picking "
                + "it launches it. Excluded apps never appear."
        ) {
            SettingsSection(
                title: "Direct activation", anchor: SettingsAnchor.directActivation,
                footer: "For the handful of apps you reach for all day, the switcher is overhead. "
                    + "These jump straight there, launching the app if it isn't running."
            ) {
                if globals.activations.entries.isEmpty {
                    SettingsWideRow {
                        HStack {
                            Text("No apps assigned.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Add App…", action: addDirectActivation)
                        }
                    }
                } else {
                    ForEach(globals.activations.entries) { entry in
                        SettingsRow(
                            title: name(for: entry.bundleID),
                            subtitle: activationSubtitle(for: entry),
                            controlWidth: 210
                        ) {
                            HStack(spacing: 6) {
                                GlobalShortcutRecorder(
                                    id: entry.bundleID,
                                    hotkey: globals.hotkey(for: entry.bundleID),
                                    assign: { globals.setHotkey($0, for: entry.bundleID) },
                                    store: globals)
                                Button {
                                    globals.remove(bundleID: entry.bundleID)
                                } label: {
                                    Image(systemName: "trash")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .help("Remove this app")
                            }
                        }
                    }
                    SettingsWideRow {
                        HStack {
                            Spacer()
                            Button("Add App…", action: addDirectActivation)
                        }
                    }
                }
            }

            SettingsSection(
                title: "Per-app overrides", anchor: SettingsAnchor.overrides,
                footer: "Only apps with an override are listed. Everything else follows the global "
                    + "settings."
            ) {
                if rules.configured.isEmpty {
                    SettingsWideRow {
                        HStack {
                            Text("No overrides.")
                                .font(.system(size: 12))
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button("Add App…", action: addOverride)
                        }
                    }
                } else {
                    ForEach(rules.configured, id: \.self) { bundleID in
                        SettingsRow(
                            title: name(for: bundleID),
                            subtitle: overrideSubtitle(for: bundleID),
                            controlWidth: 300
                        ) {
                            AppOverrideControls(bundleID: bundleID, rules: rules)
                        }
                    }
                    SettingsWideRow {
                        HStack {
                            Spacer()
                            Button("Add App…", action: addOverride)
                        }
                    }
                }
            }

            SettingsSection(
                title: "Favorite order", anchor: SettingsAnchor.favorites, footer: favoriteFooter
            ) {
                SettingsRow(
                    title: "Pin favorites to the front",
                    subtitle: "Application mode only — a window list has as many tiles per app as "
                        + "the app has windows, so no app can hold a slot in it."
                ) {
                    Toggle("", isOn: $behavior.pinFavoritesFirst)
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                favoriteOrderList
            }

            SettingsSection(title: "App rules", anchor: SettingsAnchor.appRules, footer: summary) {
                SettingsWideRow {
                    HStack(spacing: 8) {
                        SettingsSearchField(text: $query)
                        Button("Add App…", action: addApps)
                        Button("Clear All", action: clearAll)
                            .disabled(store.excluded.isEmpty && favorites.favorites.isEmpty)
                    }
                }
                columnCaptions
                list
            }
        }
        // An app that is not running needs a row of its own once it is favourited or excluded, so
        // the list is rebuilt rather than just re-rendered.
        .onChange(of: store.excluded) { apps.setNeedsReload() }
        .onChange(of: favorites.favorites) { apps.setNeedsReload() }
    }

    @ViewBuilder
    private var list: some View {
        if filtered.isEmpty {
            Text(query.isEmpty ? "No apps running" : "No matches")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
        } else {
            // The page scrolls as a whole, so the rows go straight into the card rather than into a
            // scroll view of their own — a list that scrolls inside a page that also scrolls is two
            // wheels fighting over one gesture.
            LazyVStack(spacing: 0) {
                ForEach(filtered) { entry in
                    AppRow(
                        entry: entry,
                        isFavorite: Binding(
                            get: { isFavorite(entry.id) },
                            set: { setFavorite($0, for: entry.id) }),
                        isExcluded: Binding(
                            get: { store.isExcluded(entry.id) },
                            set: { setExcluded($0, for: entry.id) }))
                }
            }
        }
    }

    /// What the order actually decides depends on the switch above it, so the footer says which of
    /// the two it is rather than describing a behaviour that is currently off.
    private var favoriteFooter: String {
        let common = "Drag a row onto another to put it in that place."
        guard behavior.pinFavoritesFirst else {
            return "Favourites that aren't running appear as launch tiles at the end of the "
                + "switcher, in this order. \(common)"
        }
        return "These take the first slots of the switcher in application mode, in this order, "
            + "running or not — so a favourite is in the same place every time, and \u{2318}-Tab "
            + "then a number reaches it. A tap still goes back to your last app wherever it now "
            + "sits. \(common)"
    }

    /// The favourites in the order the launch tiles use them, which is the one thing the
    /// alphabetical rules list below cannot show. Excluded favourites are left out: their star is
    /// masked there, so a row here would be the pane contradicting itself about whether the app is
    /// a favourite at all. They keep their place in the stored list regardless — a drag across one
    /// steps over it rather than dropping it.
    @ViewBuilder
    private var favoriteOrderList: some View {
        let ordered = favorites.favorites.filter { !store.isExcluded($0) }
        if ordered.isEmpty {
            SettingsWideRow {
                Text("No favorites yet — star an app below.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        } else {
            LazyVStack(spacing: 0) {
                ForEach(Array(ordered.enumerated()), id: \.element) { position, id in
                    FavoriteOrderRow(
                        position: position + 1,
                        entry: apps.entry(for: id),
                        unstar: { setFavorite(false, for: id) },
                        accept: { dragged in favorites.move(dragged, toPositionOf: id) })
                }
            }
        }
    }

    /// Column captions, so the star and the switch are not two unlabelled controls.
    private var columnCaptions: some View {
        HStack(spacing: 12) {
            Spacer()
            Text("Favorite").frame(width: 52, alignment: .center)
            Text("Exclude").frame(width: 40, alignment: .center)
        }
        .font(.system(size: 10))
        .foregroundStyle(.secondary)
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 5)
        .overlay(alignment: .top) {
            Rectangle().fill(Color.primary.opacity(0.07)).frame(height: 0.5)
        }
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

    // MARK: - Direct activation

    /// A displayable name for a bundle identifier, whether or not the app is running.
    ///
    /// Falls through to the raw identifier rather than hiding the row: an app that has since been
    /// uninstalled still needs to be removable, which it cannot be if it does not appear.
    ///
    /// The not-running lookup is cached. `FavoritesStore.appInfo` is a LaunchServices call plus two
    /// disk reads, and this is called from a view body — once per direct-activation row, on every
    /// render, including every keystroke into the search field above it. `AppListModel` caches the
    /// same lookup for exactly this reason.
    private func name(for bundleID: String) -> String {
        apps.entry(for: bundleID).name
    }

    private func activationSubtitle(for entry: DirectActivation) -> String? {
        guard globals.hotkey(for: entry.bundleID) != nil else {
            return "No shortcut yet — click Not set and press a combination."
        }
        let clashes = globals.activations.conflicts(with: entry.bundleID)
        guard !clashes.isEmpty else { return nil }
        return "Same shortcut as \(clashes.map(name(for:)).joined(separator: ", "))."
    }

    private func overrideSubtitle(for bundleID: String) -> String? {
        let rule = rules.rule(for: bundleID)
        var parts: [String] = []
        if rule.expandWindows { parts.append("listed window-by-window") }
        if rule.neverTile { parts.append("never tiled") }
        if rule.hideWhenFrontmost { parts.append("hidden when already front") }
        if !rule.displayName.isEmpty { parts.append("shown as “\(rule.displayName)”") }
        if let arrangement = rule.launchArrangement {
            parts.append("opens \(arrangement.title.lowercased())")
        }
        // Clear them all and the row deletes itself on the next change, so say so rather than
        // leaving a row that looks like it still does something.
        return parts.isEmpty ? "No overrides left — this row will disappear." : parts.joined(separator: ", ")
    }

    private func addOverride() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to override"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            // Seeded with the more common of the two so the new row does something immediately.
            rules.setExpandWindows(true, for: id)
        }
    }

    /// Reuses the same open panel the rules list uses, minus the favourite/exclude choice — there is
    /// only one thing adding an app means here.
    private func addDirectActivation() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.message = "Choose apps to give their own shortcut"
        panel.prompt = "Add"
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            guard let id = Bundle(url: url)?.bundleIdentifier else { continue }
            globals.add(bundleID: id)
        }
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

/// One favourite in the ordered list, draggable onto any other row.
///
/// Drop-on-a-row rather than drop-between-rows: an insertion line asks the user to hit a 2pt gap,
/// and the answer they want — "this app goes where that one is" — is a whole row wide.
private struct FavoriteOrderRow: View {
    let position: Int
    let entry: AppEntry
    let unstar: () -> Void
    /// Called with the dragged app's bundle identifier when it is dropped on this row.
    let accept: (String) -> Void

    @State private var isTargeted = false

    var body: some View {
        HStack(spacing: 12) {
            Text("\(position)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)

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

            Button(action: unstar) {
                Image(systemName: "star.slash")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Remove this app from favorites")

            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .help("Drag to reorder")
        }
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 6)
        // The whole row is the drag handle and the drop target, so it has to be hit anywhere on it
        // and not just where the text happens to be.
        .contentShape(Rectangle())
        .background(isTargeted ? Color.accentColor.opacity(0.18) : .clear)
        .draggable(entry.id)
        .dropDestination(for: String.self) { items, _ in
            guard let dragged = items.first else { return false }
            accept(dragged)
            return true
        } isTargeted: { targeted in
            isTargeted = targeted
        }
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: SettingsChrome.hairline)
                .padding(.leading, 44)
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
        .padding(.horizontal, SettingsChrome.rowInset)
        .padding(.vertical, 6)
        // The whole row used to toggle the exclusion switch. With two controls on it there is no
        // single thing a row-wide tap should mean, so each control is hit on its own now.
        .contentShape(Rectangle())
        // Rows sit directly in the section card, so each carries the hairline that separates it
        // from the one above — the same treatment `SettingsRow` gives itself.
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.07))
                .frame(height: SettingsChrome.hairline)
                .padding(.leading, 44)
        }
    }
}

/// The controls for one app's overrides: three switches on the first line, the name override and
/// the launch arrangement on the second.
///
/// A view of its own rather than an inline stack. Five controls, each with a `Binding` built from
/// two closures over the same store, is enough for the type-checker to give up on the enclosing
/// `body` — and it fails as a timeout, so the build gets slower long before it breaks.
private struct AppOverrideControls: View {
    let bundleID: String
    @ObservedObject var rules: AppRulesStore

    private var expandWindows: Binding<Bool> {
        Binding(
            get: { rules.rule(for: bundleID).expandWindows },
            set: { rules.setExpandWindows($0, for: bundleID) })
    }

    private var neverTile: Binding<Bool> {
        Binding(
            get: { rules.rule(for: bundleID).neverTile },
            set: { rules.setNeverTile($0, for: bundleID) })
    }

    private var hideWhenFrontmost: Binding<Bool> {
        Binding(
            get: { rules.rule(for: bundleID).hideWhenFrontmost },
            set: { rules.setHideWhenFrontmost($0, for: bundleID) })
    }

    private var displayName: Binding<String> {
        Binding(
            get: { rules.rule(for: bundleID).displayName },
            set: { rules.setDisplayName($0, for: bundleID) })
    }

    private var launchArrangement: Binding<WindowArrangement?> {
        Binding(
            get: { rules.rule(for: bundleID).launchArrangement },
            set: { rules.setLaunchArrangement($0, for: bundleID) })
    }

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            HStack(spacing: 10) {
                Toggle("Windows", isOn: expandWindows)
                    .help(
                        "Always list this app's windows individually, even in application mode.")
                Toggle("No tiling", isOn: neverTile)
                    .help("Never let a tiling shortcut move or resize its windows.")
                Toggle("Hide if front", isOn: hideWhenFrontmost)
                    .help(
                        "Switching to this app while it is already frontmost hides it instead, so "
                        + "one chord toggles it away and back.")
            }
            .toggleStyle(.checkbox)
            HStack(spacing: 6) {
                TextField("Name", text: displayName)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 120)
                    .help(
                        "Shown on this app's tiles in place of its own name. Empty uses the app's.")
                Picker("", selection: launchArrangement) {
                    Text("Opens anywhere").tag(WindowArrangement?.none)
                    Divider()
                    ForEach(WindowArrangement.launchable) { arrangement in
                        Text(arrangement.title).tag(WindowArrangement?.some(arrangement))
                    }
                }
                .labelsHidden()
                .frame(width: 160)
                .help("Snap this app's first window here as it opens.")
            }
        }
        .font(.system(size: 11))
    }
}
