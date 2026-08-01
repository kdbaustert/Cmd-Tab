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
    }

    /// Every key this owns, for export/import/reset.
    static let defaultsKeys = [Key.enabled]

    /// How long a burst of writes is allowed to settle before we mirror it out.
    ///
    /// Dragging a slider posts a `UserDefaults` change per tick, and each one would otherwise be a
    /// separate file write. Long enough to coalesce a drag, short enough that the file is current by
    /// the time anyone alt-tabs to their editor.
    private static let writeDebounce: TimeInterval = 0.4

    @Published private(set) var isEnabled: Bool

    /// The bytes last written or read, so our own writes do not read back as external edits.
    private var lastSynced: Data?
    private var watcher: DispatchSourceFileSystemObject?
    private var watchedDirectory: CInt = -1
    private var writeWorkItem: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// `~/.config/cmdtab/config.json`, honouring `XDG_CONFIG_HOME` where it is set — anyone who has
    /// moved their config root has done so deliberately and expects everything to follow.
    static var url: URL {
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

    /// Where the file is, in the form a person would type — `~` rather than `/Users/…`.
    static var displayPath: String {
        (url.path as NSString).abbreviatingWithTildeInPath
    }

    private init() {
        isEnabled = UserDefaults.standard.bool(forKey: Key.enabled)
    }

    /// Called once at launch. When the file is already in use it wins over what is in
    /// `UserDefaults`: the whole point of the dotfiles workflow is that a machine which has just
    /// checked out the repo comes up configured, and the local defaults on that machine are exactly
    /// the stale copy the file is meant to replace.
    func start() {
        guard isEnabled else { return }
        if FileManager.default.fileExists(atPath: Self.url.path) {
            readFromDisk()
        } else {
            // Enabled but missing — a repo checked out without the file, or someone deleted it.
            // Recreate it from what we have rather than silently doing nothing.
            writeToDisk()
        }
        beginWatching()
        observeSettingsChanges()
    }

    /// Re-reads the switch from `UserDefaults` and starts or stops watching to match.
    ///
    /// Called after an import or a reset, both of which write the key underneath us: "Reset to
    /// defaults" clears it, and without this the app went on mirroring to a file the preferences
    /// said it had stopped using — a watcher running against a setting that was no longer true.
    /// Guarded on an actual change so re-reading cannot tear down a healthy watcher.
    func reload() {
        let stored = UserDefaults.standard.bool(forKey: Key.enabled)
        guard stored != isEnabled else { return }
        isEnabled = stored
        if stored {
            beginWatching()
            observeSettingsChanges()
        } else {
            stopWatching()
        }
    }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        UserDefaults.standard.set(enabled, forKey: Key.enabled)
        if enabled {
            writeToDisk()  // seed it from the current settings; the file starts as a true mirror
            beginWatching()
            observeSettingsChanges()
        } else {
            stopWatching()
            // The file is deliberately left on disk. It may be a symlink into a repo, and deleting
            // a tracked file because a checkbox was unticked is not ours to do.
        }
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

        let url = Self.url
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
