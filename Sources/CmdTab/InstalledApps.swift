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

    /// Where apps live. Shallow scans only: `/Applications` nests one level (Utilities, and vendor
    /// folders like Adobe's), which is covered by descending exactly one directory rather than
    /// walking the tree — a deep enumeration of `/Applications` reaches into every bundle's own
    /// Contents and takes seconds.
    private static let roots: [URL] = {
        var urls = [
            URL(fileURLWithPath: "/Applications"),
            URL(fileURLWithPath: "/System/Applications"),
            URL(fileURLWithPath: "/System/Applications/Utilities"),
            URL(fileURLWithPath: "/Applications/Utilities"),
        ]
        urls.append(
            FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Applications", isDirectory: true))
        return urls
    }()

    private static var catalogue: [Entry] = []
    private static var isLoading = false

    /// Builds the catalogue off the main thread. Safe to call repeatedly; the second call while one
    /// is in flight is a no-op.
    ///
    /// Called once at launch rather than on the first query: reading a couple of hundred `Info.plist`
    /// files takes long enough to be visible if it happens while someone is mid-keystroke inside a
    /// session that owns the keyboard.
    static func warm() {
        guard catalogue.isEmpty, !isLoading else { return }
        isLoading = true
        let roots = Self.roots
        DispatchQueue.global(qos: .utility).async {
            let found = scan(roots)
            DispatchQueue.main.async {
                catalogue = found
                isLoading = false
                Log.general.log(
                    level: Log.traceLevel,
                    "installed apps catalogued: \(found.count, privacy: .public)")
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
        var seen = Set<String>()
        var out: [Entry] = []

        for root in roots {
            guard
                let contents = try? manager.contentsOfDirectory(
                    at: root, includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants])
            else { continue }
            for url in contents where url.pathExtension == "app" {
                guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
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
}
