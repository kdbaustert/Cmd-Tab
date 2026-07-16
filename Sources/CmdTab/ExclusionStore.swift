import AppKit
import SwiftUI

/// The apps the user has chosen to keep out of the switcher.
///
/// Keyed by bundle identifier, not pid: an exclusion has to survive the app quitting, coming
/// back under a new pid, and Cmd-Tab itself restarting.
@MainActor
final class ExclusionStore: ObservableObject {
    static let shared = ExclusionStore()

    private static let defaultsKey = "excludedBundleIDs"

    @Published private(set) var excluded: Set<String> = []

    /// Fired after every change so the switcher can rebuild its list. The provider is handed the
    /// new set rather than reaching in here, which keeps it free of any main-thread dependency.
    var onChange: ((Set<String>) -> Void)?

    private init() {
        excluded = Set(UserDefaults.standard.stringArray(forKey: Self.defaultsKey) ?? [])
    }

    func isExcluded(_ bundleID: String) -> Bool { excluded.contains(bundleID) }

    func setExcluded(_ isExcluded: Bool, for bundleID: String) {
        // Excluding ourselves is meaningless — we are never a target — and an entry that can
        // never be seen in the list could never be removed again.
        guard bundleID != Bundle.main.bundleIdentifier else { return }
        if isExcluded { excluded.insert(bundleID) } else { excluded.remove(bundleID) }
        persist()
    }

    func removeAll() {
        guard !excluded.isEmpty else { return }
        excluded.removeAll()
        persist()
    }

    private func persist() {
        UserDefaults.standard.set(excluded.sorted(), forKey: Self.defaultsKey)
        Log.general.notice("exclusions: \(self.excluded.count) app(s) excluded")
        onChange?(excluded)
    }
}
