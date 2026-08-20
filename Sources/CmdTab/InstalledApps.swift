import AppKit

/// A catalogue of installed applications, for the switcher's launch-from-search fallback.
///
/// The favourites feature already puts *chosen* non-running apps in the list as launchable tiles;
/// this widens that to everything installed, but only when a query has matched nothing running —
/// so the switcher stays a switcher and quietly becomes a launcher at the moment it would otherwise
/// have shown "No matches".
@MainActor
enum InstalledApps {
    struct Entry {
        let bundleID: String
        let name: String
        let url: URL
    }

    /// Where apps live. Each is scanned to a depth of one — see `appBundles(under:manager:)` for
    /// what that covers and why it stops there.
    ///
    /// `Utilities` used to be listed here twice over, as `/Applications/Utilities` and
    /// `/System/Applications/Utilities`, standing in for a descent that did not happen. The descent
    /// reaches both, so they are gone.
    private static let roots: [URL] = {
        var urls = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
        ]
        urls.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true))
        return urls
    }()

    private static var catalogue: [Entry] = []
    private static var isLoading = false

    /// Every bundle id the catalogue has ever held, plus every one that has been seen to launch.
    ///
    /// A ledger, not a mirror of `catalogue`: it only ever grows. Its job is to answer "have we
    /// already reacted to this app" once per id for the life of the process, which means an app that
    /// no scan can find — run straight from a disk image or `~/Downloads` — costs one rescan rather
    /// than one per launch.
    private static var knownBundleIDs: Set<String> = []

    /// The launch observer, held so it is installed exactly once.
    private static var launchObserver: NSObjectProtocol?

    /// Builds the catalogue off the main thread, and keeps it current.
    ///
    /// Called once at launch rather than on the first query: reading a couple of hundred `Info.plist`
    /// files takes long enough to be visible if it happens while someone is mid-keystroke inside a
    /// session that owns the keyboard.
    static func warm() {
        guard catalogue.isEmpty else { return }
        watchForNewApps()
        rescan()
    }

    /// Re-reads the roots. Safe to call repeatedly; a call while one is in flight is a no-op.
    private static func rescan() {
        guard !isLoading else { return }
        isLoading = true
        let roots = Self.roots
        DispatchQueue.global(qos: .utility).async {
            let found = scan(roots)
            DispatchQueue.main.async {
                catalogue = found
                knownBundleIDs.formUnion(found.map(\.bundleID))
                isLoading = false
                Log.general.log(
                    level: Log.traceLevel,
                    "installed apps catalogued: \(found.count, privacy: .public)")
            }
        }
    }

    /// Rebuilds the catalogue when an app it has never heard of starts.
    ///
    /// The scan used to happen once, at launch, and never again — and this app is a login item that
    /// stays up for weeks. An app installed on Tuesday was therefore unreachable from search until
    /// Cmd-Tab was restarted, and one uninstalled on Wednesday stayed in the list as a tile that
    /// could only fail to open.
    ///
    /// A launch is the cheapest signal that the disk changed that does not involve watching it: it
    /// costs one set lookup per app start, and the rescan behind it happens the first time a given
    /// bundle id is seen and never again. Installing an app is very nearly always followed by
    /// running it, which is the case this catches; the one it does not is an app installed and left
    /// alone, and that one waits for the next launch of Cmd-Tab as it always did.
    private static func watchForNewApps() {
        guard launchObserver == nil else { return }
        launchObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main
        ) { note in
            // The id is lifted out of the notification before the hop, not inside it. The block runs
            // on the main queue either way, but the compiler types it as nonisolated, and a
            // `Notification` captured into a main-actor closure is a `sending` violation. A `String?`
            // is `Sendable` and crosses for free.
            let id = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?
                .bundleIdentifier
            MainActor.assumeIsolated {
                guard let id, !knownBundleIDs.contains(id) else { return }
                // Recorded before the scan rather than after it, so the ledger holds even if the
                // rescan does not find the app.
                knownBundleIDs.insert(id)
                Log.general.log(
                    level: Log.traceLevel,
                    "unknown app launched (\(id, privacy: .public)); re-cataloguing")
                rescan()
            }
        }
    }

    /// Best matches for a query, strongest first.
    ///
    /// `excluding` carries the bundle ids already on screen — running apps and favourites — so a
    /// suggestion never duplicates a tile the user is already looking at.
    static func matches(_ query: String, excluding: Set<String>, limit: Int = 5) -> [Entry] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !catalogue.isEmpty else { return [] }
        return catalogue
            .filter { !excluding.contains($0.bundleID) }
            .compactMap { entry -> (Entry, Int)? in
                guard let score = FuzzyMatch.score(entry.name, query: trimmed) else { return nil }
                return (entry, score)
            }
            .sorted { $0.1 > $1.1 }
            .prefix(limit)
            .map(\.0)
    }

    private nonisolated static func scan(_ roots: [URL]) -> [Entry] {
        let manager = FileManager.default
        let mine = Bundle.main.bundleIdentifier
        var seen = Set<String>()
        var out: [Entry] = []

        for root in roots {
            for url in appBundles(under: root, manager: manager) {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                    // Ourselves. The other two stores that hold app identities guard against this
                    // — `ExclusionStore.setExcluded` and `FavoritesStore.add` both refuse our own
                    // bundle id — and this one is the same idea for a different reason: the
                    // switcher is never a target, so nothing downstream can filter it out, and a
                    // pick would reopen us, which puts Settings up and makes us frontmost. That is
                    // the one state that shifts ⌘-Tab ordering by one.
                    id != mine,
                    !seen.contains(id)
                else { continue }
                seen.insert(id)
                let name =
                    (bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                    ?? (bundle.object(forInfoDictionaryKey: "CFBundleName") as? String)
                    ?? url.deletingPathExtension().lastPathComponent
                out.append(Entry(bundleID: id, name: name, url: url))
            }
        }
        return out
    }

    /// Every `.app` directly inside `root`, plus every `.app` one directory below it.
    ///
    /// The one level of nesting is where whole vendors' worth of apps hide: `/Applications/Setapp`
    /// holds every Setapp title, Adobe keeps a folder per version, and `Utilities` is the same shape
    /// under both `/Applications` and `/System/Applications`. A scan that stops at the top level
    /// silently offers none of them, which on a machine with Setapp installed is dozens of apps the
    /// launcher cannot see.
    ///
    /// It stops at one because an `.app` is itself a directory: an unbounded walk descends into
    /// every bundle's own `Contents` and takes seconds. `.app` entries are therefore never descended
    /// into, and everything else is read exactly once.
    nonisolated static func appBundles(under root: URL, manager: FileManager) -> [URL] {
        var found: [URL] = []
        for url in children(of: root, manager: manager) {
            if url.pathExtension == "app" {
                found.append(url)
            } else {
                found += children(of: url, manager: manager).filter { $0.pathExtension == "app" }
            }
        }
        return found
    }

    /// A directory's contents, or nothing. An unreadable path and a plain file both answer the same
    /// way, which is what lets the caller offer every non-bundle entry without checking first.
    private nonisolated static func children(of directory: URL, manager: FileManager) -> [URL] {
        (try? manager.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles, .skipsPackageDescendants])) ?? []
    }
}
