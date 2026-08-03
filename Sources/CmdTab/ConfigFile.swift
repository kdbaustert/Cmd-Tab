import AppKit
import Foundation

/// Keeps every preference in a plain JSON file at `~/.config/cmdtab/config.json`, so a settings
/// setup can live in a dotfiles repo and be symlinked onto a new machine.
///
/// Two-way and live: edits made in the file are applied without a relaunch, and changes made in
/// Settings are written back, so the file never goes stale against the app. `UserDefaults` remains
/// the source the app actually reads at runtime — this mirrors it rather than replacing it, which
/// is what keeps every existing store and the export/import path working untouched.
///
/// Opt-in. A file appearing under `~/.config` unasked is exactly the kind of thing that makes a
/// dotfiles repo noisy, and someone who does not want this should not have to clean up after us.
@MainActor
final class ConfigFile: ObservableObject {
    static let shared = ConfigFile()

    private enum Key {
        static let enabled = "useConfigFile"
        static let iCloudSync = "syncSettingsViaICloud"
    }

    /// Every key this owns, for export/import/reset.
    static let defaultsKeys = [Key.enabled, Key.iCloudSync]

    /// How long a burst of writes is allowed to settle before we mirror it out.
    ///
    /// Dragging a slider posts a `UserDefaults` change per tick, and each one would otherwise be a
    /// separate file write. Long enough to coalesce a drag, short enough that the file is current by
    /// the time anyone alt-tabs to their editor.
    private static let writeDebounce: TimeInterval = 0.4

    /// The dotfiles switch: keep a config file on this Mac.
    @Published private(set) var isFileEnabled: Bool
    /// The sync switch: keep that file in iCloud Drive, where the other Macs see it.
    @Published private(set) var isICloudSyncEnabled: Bool

    /// Whether anything is being mirrored at all. Either switch is reason enough — they ask for the
    /// same machinery and differ only in which directory it points at, which is what lets iCloud
    /// sync be turned on without first opting into a dotfiles file.
    var isEnabled: Bool { Self.resolve(file: isFileEnabled, sync: isICloudSyncEnabled).enabled }

    /// Where the one mirror lives.
    var location: Location { Self.resolve(file: isFileEnabled, sync: isICloudSyncEnabled).location }

    /// What the two switches mean together.
    ///
    /// One mirror, never two: when both are on the file lives in iCloud Drive, because that is the
    /// copy that syncs and a second one under `~/.config` would start diverging from it the moment
    /// either changed — two files each claiming to be the settings, with nothing to say which wins.
    ///
    /// A function rather than a pair of stored flags so the table can be checked without a real
    /// `UserDefaults` to write to.
    static func resolve(file: Bool, sync: Bool) -> (enabled: Bool, location: Location) {
        (file || sync, sync ? .iCloud : .local)
    }

    /// The bytes last written or read, so our own writes do not read back as external edits.
    private var lastSynced: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDirectory: CInt = -1
    private var writeWorkItem: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// Where the mirrored file lives. The mechanism is identical either way — the same JSON, the same
    /// watcher, the same two-way mirroring — so this only ever picks a directory.
    enum Location: String, CaseIterable {
        /// `~/.config/cmdtab/config.json`, for a dotfiles repo.
        case local
        /// Inside iCloud Drive, where every Mac signed into the same account sees the same file.
        case iCloud

        var title: String {
            switch self {
            case .local: return "This Mac"
            case .iCloud: return "iCloud Drive"
            }
        }
    }

    /// The file, wherever it currently lives.
    ///
    /// Reads the location straight out of `UserDefaults` rather than from `shared`, so the static
    /// accessors stay usable from anywhere without hopping onto the main actor for a path.
    static var url: URL { url(for: storedLocation) }

    static var storedLocation: Location {
        UserDefaults.standard.bool(forKey: Key.iCloudSync) ? .iCloud : .local
    }

    static func url(for location: Location) -> URL {
        switch location {
        case .local: return localURL
        case .iCloud: return iCloudURL ?? localURL
        }
    }

    /// `~/.config/cmdtab/config.json`, honouring `XDG_CONFIG_HOME` where it is set — anyone who has
    /// moved their config root has done so deliberately and expects everything to follow.
    static var localURL: URL {
        let base: URL
        if let xdg = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            base = URL(fileURLWithPath: xdg, isDirectory: true)
        } else {
            base = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".config", isDirectory: true)
        }
        return base.appendingPathComponent("cmdtab", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// `~/Library/Mobile Documents/com~apple~CloudDocs/Cmd-Tab/config.json`, or nil when iCloud Drive
    /// is not set up on this Mac.
    ///
    /// The user-visible iCloud Drive folder, reached by its own path rather than through
    /// `url(forUbiquityContainerIdentifier:)`. That call wants the ubiquity-container entitlement and
    /// a provisioning profile naming a team; this app ships neither and is signed for direct
    /// distribution, where a plain file in CloudDocs syncs perfectly well and needs no entitlement at
    /// all. The trade is that the file is visible to the user in Finder — which, for a config file
    /// whose whole point is being editable, is the right side of the trade anyway.
    static var iCloudURL: URL? {
        let cloudDocs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Mobile Documents/com~apple~CloudDocs", isDirectory: true)
        guard FileManager.default.fileExists(atPath: cloudDocs.path) else { return nil }
        return cloudDocs.appendingPathComponent("Cmd-Tab", isDirectory: true)
            .appendingPathComponent("config.json")
    }

    /// Whether iCloud Drive is available to sync to. False means the account is signed out or iCloud
    /// Drive is switched off, and the option has to be refused rather than silently writing to a
    /// folder that syncs nowhere.
    static var isICloudAvailable: Bool { iCloudURL != nil }

    /// Where the file is, in the form a person would type — `~` rather than `/Users/…`.
    static var displayPath: String { displayPath(for: storedLocation) }

    static func displayPath(for location: Location) -> String {
        (url(for: location).path as NSString).abbreviatingWithTildeInPath
    }

    private init() {
        isFileEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
        isICloudSyncEnabled = UserDefaults.standard.bool(forKey: Key.iCloudSync)
    }

    /// Called once at launch. When the file is already in use it wins over what is in
    /// `UserDefaults`: the whole point of the dotfiles workflow is that a machine which has just
    /// checked out the repo comes up configured, and the local defaults on that machine are exactly
    /// the stale copy the file is meant to replace.
    func start() {
        guard isEnabled else { return }
        let waiting = requestDownload()
        if FileManager.default.fileExists(atPath: Self.url.path) {
            readFromDisk()
        } else if !waiting {
            // Enabled but missing — a repo checked out without the file, or someone deleted it.
            // Recreate it from what we have rather than silently doing nothing.
            //
            // Not when a download is pending: "missing" then means iCloud has the file and has not
            // handed it over yet, and writing would publish this Mac's settings over the ones on
            // their way down. The watcher picks them up when they land.
            writeToDisk()
        }
        beginWatching()
        observeSettingsChanges()
    }

    /// Re-reads both switches from `UserDefaults` and starts, stops or moves the mirror to match.
    ///
    /// Called after an import or a reset, both of which write the keys underneath us: "Reset to
    /// defaults" clears them, and without this the app went on mirroring to a file the preferences
    /// said it had stopped using — a watcher running against a setting that was no longer true.
    /// Guarded on an actual change so re-reading cannot tear down a healthy watcher.
    func reload() {
        let file = UserDefaults.standard.bool(forKey: Key.enabled)
        let sync = UserDefaults.standard.bool(forKey: Key.iCloudSync)
        guard file != isFileEnabled || sync != isICloudSyncEnabled else { return }
        let before = state
        isFileEnabled = file
        isICloudSyncEnabled = sync
        transition(from: before)
    }

    /// The dotfiles switch. Turning it off while iCloud sync is on leaves the mirror running — it
    /// just moves back to `~/.config` if sync is off too, and stops entirely when neither wants it.
    func setFileEnabled(_ on: Bool) {
        guard on != isFileEnabled else { return }
        let before = state
        isFileEnabled = on
        UserDefaults.standard.set(on, forKey: Key.enabled)
        transition(from: before)
    }

    /// The sync switch. Independent of the dotfiles one: turning this on alone starts mirroring
    /// straight into iCloud Drive, which is the whole point of it being its own control.
    ///
    /// Refused when iCloud Drive is not set up, rather than writing into a folder that syncs
    /// nowhere — that would look exactly like sync that silently never works.
    func setICloudSyncEnabled(_ on: Bool) {
        guard on != isICloudSyncEnabled else { return }
        if on, !Self.isICloudAvailable {
            Log.general.error("config file: iCloud Drive is unavailable; sync not enabled")
            return
        }
        let before = state
        isICloudSyncEnabled = on
        UserDefaults.standard.set(on, forKey: Key.iCloudSync)
        transition(from: before)
        Log.general.notice(
            "config file: iCloud sync \(on ? "on" : "off", privacy: .public), mirroring to \(Self.displayPath, privacy: .public)")
    }

    /// Whether anything is mirrored and where, as one value — so a transition can be described by
    /// what it was before rather than by which switch the user happened to touch.
    private struct State {
        let enabled: Bool
        let location: Location
    }

    private var state: State { State(enabled: isEnabled, location: location) }

    /// Brings the watcher and the file into line after either switch moves.
    ///
    /// Three outcomes, and only three: nothing is mirrored any more, the mirror moved to a different
    /// file, or nothing about the file changed and a healthy watcher is left alone.
    private func transition(from before: State) {
        guard isEnabled else {
            stopWatching()
            // The file is deliberately left on disk. It may be a symlink into a repo, or the copy
            // the *other* Macs are still syncing against, and deleting either because a checkbox
            // was unticked is not ours to do.
            return
        }
        // Already mirroring the same file: the switches moved, the destination did not.
        guard !before.enabled || before.location != location else { return }
        stopWatching()
        lastSynced = nil  // a different file entirely; nothing about the old one's bytes applies
        adopt(
            destination: Self.url,
            seedingFrom: before.enabled ? Self.url(for: before.location) : Self.url)
        beginWatching()
        observeSettingsChanges()
    }

    /// What the file at a newly chosen location means. Three cases, and getting them the wrong way
    /// round is precisely how a sync loses somebody's settings:
    ///
    /// - Something is already there — another Mac's copy, or an older one of ours. It wins, exactly
    ///   as the file wins at launch.
    /// - iCloud has it and has not sent it down yet. Wait; writing now would overwrite it.
    /// - Nothing there at all. Seed it from the file we were using, so turning sync on publishes
    ///   this Mac's settings rather than blanking them.
    private func adopt(destination: URL, seedingFrom previous: URL) {
        if FileManager.default.fileExists(atPath: destination.path) {
            readFromDisk()
            return
        }
        if requestDownload() { return }
        if let data = try? Data(contentsOf: previous) {
            write(data, to: destination)
        } else {
            writeToDisk()
        }
    }

    /// The file iCloud has but this Mac has not pulled down yet, if there is one.
    ///
    /// An undownloaded item is a `.name.icloud` placeholder sitting beside where the real file goes.
    /// Worth the check because "nothing here" and "it exists, on another Mac" call for opposite
    /// responses, and treating the second as the first is how setting up a second Mac would
    /// overwrite the settings of the first.
    private var pendingDownload: URL? {
        guard location == .iCloud else { return nil }
        let url = Self.url
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        return FileManager.default.fileExists(atPath: placeholder.path) ? url : nil
    }

    /// Asks iCloud for the file, and says whether anything is now being waited on.
    @discardableResult
    private func requestDownload() -> Bool {
        guard let url = pendingDownload else { return false }
        try? FileManager.default.startDownloadingUbiquitousItem(at: url)
        Log.general.notice("config file: waiting for iCloud to send the file down")
        return true
    }


    /// Reveals the file in Finder, creating it first if it is somehow missing.
    func revealInFinder() {
        if !FileManager.default.fileExists(atPath: Self.url.path) { writeToDisk() }
        NSWorkspace.shared.activateFileViewerSelecting([Self.url])
    }

    // MARK: - Writing

    private func observeSettingsChanges() {
        guard defaultsObserver == nil else { return }
        // Every store persists through `UserDefaults`, so one observer covers all five rather than
        // five `onChange` hooks that would each have to remember to call us.
        defaultsObserver = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification, object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.scheduleWrite() }
        }
    }

    private func scheduleWrite() {
        guard isEnabled else { return }
        writeWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.writeToDisk() }
        }
        writeWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.writeDebounce, execute: work)
    }

    private func writeToDisk() {
        guard let data = SettingsIO.encode(SettingsIO.currentPayload()) else { return }
        // Nothing changed since the last sync — skip the write entirely rather than touch the file's
        // mtime, which would wake the watcher and (harmlessly, but pointlessly) re-read it.
        guard data != lastSynced else { return }
        // Never over a copy iCloud is still sending down: that is this Mac's settings overwriting
        // the ones it is in the middle of receiving. Self-correcting — once the file lands, the
        // placeholder is gone and writes resume.
        guard pendingDownload == nil else { return }
        write(data, to: Self.url)
    }

    private func write(_ data: Data, to url: URL) {
        do {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            // Written in place rather than atomically. An atomic write replaces the file with a new
            // inode, which would silently break a symlink into a dotfiles repo — turning the whole
            // feature into a one-shot export the first time any setting changed.
            try data.write(to: url, options: [])
            lastSynced = data
        } catch {
            Log.general.error(
                "config file write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Reading

    private func readFromDisk() {
        guard let data = try? Data(contentsOf: Self.url) else { return }
        guard data != lastSynced else { return }  // our own write coming back around
        guard let payload = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            // Reported rather than swallowed: a config file with a stray comma otherwise looks
            // exactly like one the app is ignoring for no reason.
            Log.general.error("config file is not valid JSON; leaving settings alone")
            return
        }
        lastSynced = data
        SettingsIO.apply(payload)
    }

    // MARK: - Watching

    /// Watches the *containing directory*, not the file.
    ///
    /// Editors save by writing a temporary file and renaming it over the target, and `git checkout`
    /// does much the same. A watch on the file's own descriptor follows the old inode into the bin
    /// and goes deaf after the first external edit; the directory keeps reporting.
    private func beginWatching() {
        stopWatching()
        let directory = Self.url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fd = open(directory.path, O_EVTONLY)
        guard fd >= 0 else { return }
        watchedDirectory = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.readFromDisk() }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        watcher = source
    }

    private func stopWatching() {
        watcher?.cancel()  // its cancel handler closes the descriptor
        watcher = nil
        watchedDirectory = -1
        writeWorkItem?.cancel()
        writeWorkItem = nil
    }
}
