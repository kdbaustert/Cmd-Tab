import AppKit
import Foundation

/// Keeps every preference in a plain JSON file — under `~/.config/cmdtab` so a settings setup can
/// live in a dotfiles repo, or in iCloud Drive so it follows you between Macs.
///
/// Two-way and live: edits made in the file are applied without a relaunch, and changes made in
/// Settings are written back, so the file never goes stale against the app. `UserDefaults` remains
/// the source the app actually reads at runtime — this mirrors it rather than replacing it, which
/// is what keeps every existing store and the export/import path working untouched.
///
/// The two switches are independent and pick between the same machinery — see `resolve`. Syncing is
/// therefore the same feature pointed at a different directory: a change arriving from another Mac
/// reaches the app by exactly the path an edit made in an editor does.
///
/// Opt-in, both of them. A file appearing under `~/.config` unasked is exactly the kind of thing
/// that makes a dotfiles repo noisy, and someone who does not want this should not have to clean up
/// after us.
@MainActor
final class ConfigFile: ObservableObject {
    static let shared = ConfigFile()

    private enum Key {
        static let enabled = "useConfigFile"
        static let iCloudSync = "syncSettingsViaICloud"
    }

    /// Every key this owns, for export/import/reset.
    static let defaultsKeys = [Key.enabled, Key.iCloudSync]

    /// The same two keys, as the ones the mirrored file neither carries nor applies.
    ///
    /// They say how *this Mac* keeps its settings, not what the settings are. Carried in the file,
    /// they travelled: with sync on, one Mac's dotfiles switch landed on every other Mac, so a Mac
    /// that had only ever turned sync on found a `~/.config` file appearing the day sync went off —
    /// and a Mac that unticked its dotfiles switch unticked everyone else's. Export and import
    /// still carry them; that is one person moving their own setup, on purpose.
    static let mirrorKeys = Set(defaultsKeys)

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

    /// The bytes last written or read, so our own writes do not read back as external edits — and
    /// the other way round, so a file that no longer matches them is known to hold an edit nobody
    /// has applied yet. See `writeToDisk`.
    private var lastSynced: Data?
    /// The directories that can announce the file changing — see `beginWatching`.
    private var directoryWatchers: [DispatchSourceFileSystemObject] = []
    /// The file itself, the only thing that sees an edit written in place.
    private var fileWatcher: DispatchSourceFileSystemObject?
    private var writeWorkItem: DispatchWorkItem?
    private var defaultsObserver: NSObjectProtocol?

    /// Where the mirrored file lives. The mechanism is identical either way — the same JSON, the same
    /// watcher, the same two-way mirroring — so this only ever picks a directory.
    enum Location: String, CaseIterable {
        /// `~/.config/cmdtab/config.json`, for a dotfiles repo.
        case local
        /// Inside iCloud Drive, where every Mac signed into the same account sees the same file.
        case iCloud
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

    /// Whether a config file already on disk should switch the mirror on by itself.
    ///
    /// This is the rule that makes "a machine which has just checked out the repo comes up
    /// configured" true, and without it that promise was false in exactly the case it describes.
    /// `start()` opened with `guard isEnabled`, and `isEnabled` is read out of a `UserDefaults`
    /// that a fresh install has nothing in — so the checked-out `config.json` was never opened, and
    /// the `"useConfigFile": true` an older build wrote into it could not help either: it was
    /// inside the file nobody read. (The file no longer carries the switch at all — see
    /// `mirrorKeys`.) The file only started being read once the user ticked the box by hand, which
    /// is the one step a dotfiles setup exists to avoid.
    ///
    /// **Absent, not false.** The distinction is the whole safety of this, and it is the one this
    /// app already leans on for every optional preference — `hotkeyKeyCode`, `loadConfirms`,
    /// `AppearanceStore.read`. Someone who turned the mirror *off* has `false` written to the key,
    /// and the file is deliberately left on disk when they do ("it may be tracked, and deleting a
    /// tracked file because a checkbox changed is not ours to do"). Adopting on the strength of the
    /// file alone would turn their setting back on at the next launch and overwrite their live
    /// settings with the copy they had walked away from. Only a key that has never been written —
    /// which is to say, an install that has never had an opinion — adopts.
    ///
    /// Both keys have to be untouched, not just the first. A user who has been through the sync
    /// switch has had this decision put to them; the mirror they ended up with is theirs.
    ///
    /// Local only, deliberately, even though `adopt` would handle the iCloud copy just as well.
    /// Turning the *local* mirror on is a file this Mac already has; turning sync on would start
    /// publishing into someone's iCloud Drive on their behalf, which is a liberty rather than a
    /// convenience — and the docs' own account of that switch describes it as opt-in-then-adopt,
    /// where this one is the launch-time rule.
    ///
    /// A free function over the three facts so the table can be checked without a real
    /// `UserDefaults` to write to or a file to plant, exactly as `resolve` and `destinationWins`
    /// are.
    static func shouldAdoptExistingFile(
        fileKeyWritten: Bool, syncKeyWritten: Bool, fileExists: Bool
    ) -> Bool {
        !fileKeyWritten && !syncKeyWritten && fileExists
    }

    /// Writes `false` to the dotfiles switch after "Reset to defaults", when there is a file this
    /// install could otherwise re-adopt.
    ///
    /// A reset removes both switches, which is exactly the "never had an opinion" state
    /// `shouldAdoptExistingFile` reads — and it leaves the file on disk, as turning the mirror off
    /// always does. So the next launch adopted that file and applied it, and every setting the
    /// reset had cleared came back. A reset is an opinion; this records it, and only where a
    /// leftover file makes the difference, so a Mac with no file stays free to adopt a dotfiles
    /// checkout later.
    static func recordResetDecision() {
        guard FileManager.default.fileExists(atPath: localURL.path) else { return }
        UserDefaults.standard.set(false, forKey: Key.enabled)
    }

    /// Switches the local mirror on for an install that has never expressed a view, when a config
    /// file is already sitting where one would live. See `shouldAdoptExistingFile`.
    private func adoptExistingFileIfUntouched() {
        let defaults = UserDefaults.standard
        guard Self.shouldAdoptExistingFile(
            fileKeyWritten: defaults.object(forKey: Key.enabled) != nil,
            syncKeyWritten: defaults.object(forKey: Key.iCloudSync) != nil,
            fileExists: FileManager.default.fileExists(atPath: Self.localURL.path))
        else { return }
        isFileEnabled = true
        defaults.set(true, forKey: Key.enabled)
        Log.general.notice(
            """
            config file: adopting \(Self.displayPath(for: .local), privacy: .public) — it was \
            already there and this install had never chosen
            """)
    }

    /// Called once at launch. When the file is already in use it wins over what is in
    /// `UserDefaults`: the whole point of the dotfiles workflow is that a machine which has just
    /// checked out the repo comes up configured, and the local defaults on that machine are exactly
    /// the stale copy the file is meant to replace.
    func start() {
        // Before the guard, because on the install this is written for the guard is what shuts the
        // door: nothing is enabled yet, and the file that would enable it has not been read.
        adoptExistingFileIfUntouched()
        guard isEnabled else { return }
        // Sync was switched on, on a Mac where iCloud Drive since went away — signed out, or turned
        // off in System Settings. `url(for:)` falls back to the local path so the settings are still
        // mirrored somewhere, but it is the one state where the app is doing something other than
        // what the switch says, and it should not have to be deduced from the path in Settings.
        if isICloudSyncEnabled, !Self.isICloudAvailable {
            Log.general.error(
                "config file: iCloud sync is on but iCloud Drive is unavailable; mirroring to \(Self.displayPath, privacy: .public) instead")
        }
        if requestDownload() {
            // iCloud has the file and has not handed it over yet. Reading it now would block this
            // thread on the download, and writing would publish this Mac's settings over the ones
            // on their way down. The file watcher reads it once it lands; `writeToDisk` stays shut
            // until then.
        } else if FileManager.default.fileExists(atPath: Self.url.path) {
            readFromDisk()
        } else {
            // Enabled but missing — a repo checked out without the file, or someone deleted it.
            // Recreate it from what we have rather than silently doing nothing.
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
    ///
    /// Never adopts. The settings in `UserDefaults` at this point are the ones an import has just
    /// written — the newest statement there is — and a mirror this turns on publishes them.
    /// Adopting instead applied whatever file was lying at the destination, which on any Mac that
    /// had once mirrored and stopped is a leftover of arbitrary age: the import was reverted in the
    /// same turn it was applied. (The config file's own reads cannot land here with a switch
    /// changed; it does not apply `mirrorKeys`.)
    ///
    /// Sync arriving *on* is held to the same availability check the switch in Settings is. An
    /// import from a Mac that synced went straight past it, and left this one "syncing" into a
    /// folder that syncs nowhere — the state `setICloudSyncEnabled` exists to refuse. Refused here
    /// the same way, and written back as off so the preference and the switch say the same thing.
    func reload() {
        let file = UserDefaults.standard.bool(forKey: Key.enabled)
        var sync = UserDefaults.standard.bool(forKey: Key.iCloudSync)
        if sync, !isICloudSyncEnabled, !Self.isICloudAvailable {
            Log.general.error("config file: iCloud Drive is unavailable; imported sync not enabled")
            UserDefaults.standard.set(false, forKey: Key.iCloudSync)
            sync = false
        }
        guard file != isFileEnabled || sync != isICloudSyncEnabled else { return }
        let before = state
        isFileEnabled = file
        isICloudSyncEnabled = sync
        transition(from: before, adopting: false)
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
    ///
    /// `adopting: false` publishes the live settings wherever the mirror lands, whatever
    /// `destinationWins` would say — see `reload`.
    private func transition(from before: State, adopting: Bool = true) {
        guard isEnabled else {
            stopWatching()
            stopObservingSettingsChanges()
            // The file is deliberately left on disk. It may be a symlink into a repo, or the copy
            // the *other* Macs are still syncing against, and deleting either because a checkbox
            // was unticked is not ours to do.
            return
        }
        // Already mirroring the same file: the switches moved, the destination did not.
        guard !before.enabled || before.location != location else { return }
        stopWatching()
        lastSynced = nil  // a different file entirely; nothing about the old one's bytes applies
        if adopting, Self.destinationWins(wasMirroring: before.enabled, leaving: before.location) {
            adopt(
                destination: Self.url,
                seedingFrom: before.enabled ? Self.url(for: before.location) : Self.url)
        } else {
            writeToDisk(publishing: true)
        }
        beginWatching()
        observeSettingsChanges()
    }

    /// Whether the file already sitting at the destination is the authority, or the settings in
    /// front of the user are.
    ///
    /// It is the file in every case but one — at launch, at a dotfiles checkout, and at an iCloud
    /// folder another Mac has already published to, adopting what is there is the whole point.
    ///
    /// The exception is *leaving* iCloud. The file under `~/.config` is then a leftover from before
    /// sync was turned on, and can be arbitrarily old; adopting it would revert every setting the
    /// moment sync was switched off. That is a silent loss rather than a move, so the live settings
    /// are published over it instead.
    static func destinationWins(wasMirroring: Bool, leaving previous: Location) -> Bool {
        !(wasMirroring && previous == .iCloud)
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
        // First: a file iCloud has not sent down yet still *exists* at its own path — see
        // `pendingDownload` — so the existence check below would take it for one ready to read.
        if requestDownload() { return }
        if FileManager.default.fileExists(atPath: destination.path) {
            readFromDisk()
            return
        }
        if let data = try? Data(contentsOf: previous) {
            write(data, to: destination)
        } else {
            writeToDisk()
        }
    }

    /// The file iCloud has but this Mac has not pulled down yet, if there is one.
    ///
    /// Worth the check because "nothing here" and "it exists, on another Mac" call for opposite
    /// responses, and treating the second as the first is how setting up a second Mac would
    /// overwrite the settings of the first.
    ///
    /// Asked of iCloud's own download status, and looked for as a `.name.icloud` placeholder too.
    /// Placeholders went with the move of iCloud Drive to File Provider in macOS 14: an
    /// undownloaded item now sits at its real path as a *dataless* file, so a placeholder test
    /// alone never fired there, `fileExists` said yes, and reading it blocked the main thread on
    /// the download — or failed outright offline, after which the next write replaced the cloud
    /// copy. Measured on macOS 27: no placeholders anywhere in iCloud Drive, and this key reading
    /// `.notDownloaded` for every dataless file there. macOS 13 is the other way round, with
    /// nothing at the real path for the key to be read from, so the placeholder check stays for it;
    /// on 14 and later it is one `stat` that never matches. Unmeasured on macOS 13 itself.
    private var pendingDownload: URL? {
        guard location == .iCloud else { return nil }
        let url = Self.url
        let placeholder = url.deletingLastPathComponent()
            .appendingPathComponent(".\(url.lastPathComponent).icloud")
        if FileManager.default.fileExists(atPath: placeholder.path) { return url }
        let status = try? url.resourceValues(forKeys: [.ubiquitousItemDownloadingStatusKey])
            .ubiquitousItemDownloadingStatus
        return status == .notDownloaded ? url : nil
    }

    /// Asks iCloud for the file, and says whether anything is now being waited on.
    @discardableResult
    private func requestDownload() -> Bool {
        guard let url = pendingDownload else { return false }
        do {
            try FileManager.default.startDownloadingUbiquitousItem(at: url)
            Log.general.notice("config file: waiting for iCloud to send the file down")
        } catch {
            // Still waiting — writing now would publish over the cloud copy — but without a request
            // in flight nothing may ever arrive, and that should not have to be guessed at.
            Log.general.error(
                """
                config file: iCloud would not start the download: \
                \(error.localizedDescription, privacy: .public)
                """)
        }
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

    /// Writes a debounced change now rather than when its timer fires. Called at quit.
    ///
    /// The timer never fires once the process is on its way out — ⌘Q, a SIGTERM, `build.sh
    /// --install` quitting the old copy — so a change made in the last `writeDebounce` stayed in
    /// `UserDefaults` only. The next launch then read the file, which wins at launch, and put the
    /// old value back: the last thing changed before quitting was silently reverted.
    func flushPendingWrite() {
        guard let work = writeWorkItem else { return }
        work.cancel()
        writeWorkItem = nil
        writeToDisk()
    }

    /// Mirrors the live settings out to the file.
    ///
    /// - Parameter publishing: the caller means to put this Mac's settings over whatever is there —
    ///   a mirror moving onto a leftover file (see `destinationWins` and `reload`). Everywhere else
    ///   the file on disk is checked first; see the body.
    private func writeToDisk(publishing: Bool = false) {
        // Never over a copy iCloud is still sending down: that is this Mac's settings overwriting
        // the ones it is in the middle of receiving. Self-correcting — once the file lands, the
        // status moves on and writes resume.
        guard pendingDownload == nil else { return }
        // Reading, encoding and a filesystem write, on the main thread, from a debounced timer — so
        // it lands in a run-loop turn with no user input anywhere near it. That is the shape of the
        // one stall this app has recorded that nothing could account for (236ms, "unlabelled work",
        // a minute after the last switch), and an unnamed suspect is the only kind
        // `MainLoopMonitor` cannot act on. Marking it does not make it faster; it makes the next
        // one say whether it was this.
        MainLoopMonitor.marking("settings write") {
            // What is on disk now, read rather than assumed. The watchers can miss an edit — one
            // made while a download was pending, say — and this used to compare only against
            // `lastSynced`, so a file holding an edit nobody had applied yet was written straight
            // over: a `git pull` into the dotfiles repo, undone by the next checkbox. A file that
            // differs from what we last synced is taken in first, and one that does not parse is
            // left alone — it is most likely the user's own edit with a missing quote in it, and
            // replacing it would throw away every other line they changed alongside the typo.
            let disk = try? Data(contentsOf: Self.url)
            let onDisk = disk.flatMap(SettingsIO.decode)
            if let disk, disk != lastSynced, !publishing {
                guard let onDisk else {
                    Log.general.error(
                        """
                        config file is not valid JSON; not writing over it. Fix it, or delete it \
                        and it will be written afresh
                        """)
                    return
                }
                absorb(onDisk, read: disk)
            }
            let owned = Set(BehaviorStore.ownedDefaultsKeys)
            let payload = Self.filePayload(
                SettingsIO.currentPayload(ignoring: Self.mirrorKeys), preserving: onDisk,
                known: owned.union(BehaviorStore.retiredDefaultsKeys),
                clearable: owned.subtracting(Self.mirrorKeys))
            guard let data = SettingsIO.encode(payload) else {
                Log.general.error("config file: the settings could not be encoded; nothing written")
                return
            }
            // Nothing changed since the last sync — skip the write rather than touch the file.
            guard data != lastSynced else { return }
            write(data, to: Self.url)
        }
    }

    /// What goes into the file: this Mac's settings, plus every key already in the file that this
    /// build does not know.
    ///
    /// The file used to be rewritten from `currentPayload` alone, so a key written by a newer build
    /// — or a typo, or a note to self — vanished from it the first time anything changed here. With
    /// two Macs on two builds sharing one file through iCloud, the older one quietly erased the
    /// newer one's settings from the shared copy. Keys this build *does* know are not carried
    /// forward: an owned key it has no value for is one that was deliberately cleared, and a
    /// retired one is dead by definition. Pure, so the rule can be checked without a file.
    ///
    /// A cleared key the file still has is written as `null` rather than left out — `clearable`
    /// names the keys that may be. Every store says "back to the default" by removing its key, and
    /// leaving the line out of the file said nothing at all to the other side: `changes` reads an
    /// absent key as "leave alone", as it must for a hand edit that deletes a line, so a reset
    /// never reached the other Mac, and that Mac's next write put the old value back into the file
    /// and from there back onto this one. `null` is the one thing both readers already take as
    /// "remove" — see `SettingsIO.apply`. Only for a key the file has: a key nobody ever set stays
    /// out, so the file does not fill up with a `null` per setting. The `null` stays for as long
    /// as the key stays cleared, since there is no knowing when every Mac has read it.
    ///
    /// Not the retired keys, which are dead here but may be live on an older build sharing the
    /// file, and not the mirror switches, which the file does not carry either way.
    nonisolated static func filePayload(
        _ settings: [String: Any], preserving onDisk: [String: Any]?, known: Set<String>,
        clearable: Set<String>
    ) -> [String: Any] {
        var out = settings
        for (key, value) in onDisk ?? [:] where out[key] == nil {
            if !known.contains(key) {
                out[key] = value
            } else if clearable.contains(key) {
                out[key] = NSNull()
            }
        }
        return out
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
        // Not a file iCloud is still sending down: reading it would block this thread until the
        // download finished, or fail outright offline. The file watcher brings us back once it
        // lands.
        guard pendingDownload == nil else { return }
        let data: Data
        do {
            data = try Data(contentsOf: Self.url)
        } catch {
            // Missing is ordinary — deleted, or caught between an editor's delete and its write —
            // and the next write recreates it. Anything else was a silent `try?`, which left an
            // unreadable file looking like one the app was ignoring for no reason.
            if FileManager.default.fileExists(atPath: Self.url.path) {
                Log.general.error(
                    """
                    config file could not be read: \
                    \(error.localizedDescription, privacy: .public)
                    """)
            }
            return
        }
        guard data != lastSynced else { return }  // our own write coming back around
        guard let payload = SettingsIO.decode(data) else {
            // Reported rather than swallowed: a config file with a stray comma otherwise looks
            // exactly like one the app is ignoring for no reason. `writeToDisk` refuses to write
            // over it until it parses again.
            Log.general.error("config file is not valid JSON; leaving settings alone")
            return
        }
        absorb(payload, read: data)
    }

    /// Applies what the file changed since the copy we last synced, and records it as synced.
    ///
    /// Only the keys that moved, not the whole file. A key the file still holds at its old value
    /// has not been edited, and applying it anyway reverted any change made in Settings since the
    /// last write — the checkbox ticked a moment before the debounced write went out, or everything
    /// changed here while an in-place edit sat unseen. With nothing synced yet — at launch, or on
    /// arriving at a different file — everything in it is new, and the file wins as a whole.
    private func absorb(_ payload: [String: Any], read data: Data) {
        let base = lastSynced.flatMap(SettingsIO.decode)
        lastSynced = data
        let changes = Self.changes(from: base, to: payload)
        guard !changes.isEmpty else { return }
        SettingsIO.apply(changes, ignoring: Self.mirrorKeys)
    }

    /// The entries of `payload` that differ from `base`. An entry `base` has and `payload` lacks is
    /// not a change: absent means "leave alone" here, as it does in `SettingsIO.apply`. A reset
    /// arrives as `null` instead — see `filePayload` — which differs from any value and so is one.
    /// Pure, so the merge can be checked without a file.
    nonisolated static func changes(
        from base: [String: Any]?, to payload: [String: Any]
    ) -> [String: Any] {
        guard let base else { return payload }
        return payload.filter { key, value in
            guard let before = base[key] else { return true }
            return !(before as AnyObject).isEqual(value)
        }
    }

    // MARK: - Watching

    /// Watches the file itself, and the directories it can be replaced from.
    ///
    /// Each of the three catches something the others cannot:
    ///
    /// - **The file.** An edit written in place — `>` in a shell, nano, an editor saving without a
    ///   rename, and every write through a symlink — changes the file and nothing around it, so a
    ///   directory watch never heard of it. Measured: an in-place write produced no event on the
    ///   containing directory at all. Re-armed on every event, because a save that renames a new
    ///   file over the old one leaves this watching the old inode.
    /// - **Its directory**, which is what re-arms the file watch when the file is deleted and
    ///   written back rather than replaced in one rename.
    /// - **The target's directory**, when the file is a symlink into a dotfiles repo. A `git pull`
    ///   replaces the target over there and touches nothing beside the link — measured, no event in
    ///   the link's directory — so the pull went unseen, and the next setting changed here wrote
    ///   the old values back through the link.
    private func beginWatching() {
        stopWatching()
        let url = Self.url
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Resolved, and as a set, so a directory that is itself a symlink — a stow-style
        // `~/.config/cmdtab` — is watched once rather than twice under two names.
        let directories = Set([
            directory.resolvingSymlinksInPath().path,
            url.resolvingSymlinksInPath().deletingLastPathComponent().path,
        ])
        for path in directories.sorted() {
            guard let source = watch(path, for: [.write, .rename, .delete]) else {
                // Every edit made outside the app now waits for the next write to find it, which
                // is late enough that it should be said.
                Log.general.error(
                    "config file: cannot watch \(path, privacy: .public); edits apply on next save")
                continue
            }
            directoryWatchers.append(source)
        }
        watchFile()
    }

    /// (Re)arms the watch on the file itself. Absent is fine — the directory watch calls this again
    /// when it appears.
    private func watchFile() {
        fileWatcher?.cancel()
        fileWatcher = watch(Self.url.path, for: [.write, .extend, .attrib, .rename, .delete])
    }

    private func watch(
        _ path: String, for mask: DispatchSource.FileSystemEvent
    ) -> DispatchSourceFileSystemObject? {
        // `open` follows a symlink, so a watch on the link's path is a watch on its target.
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return nil }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd, eventMask: mask, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.watchFile()
                self?.readFromDisk()
            }
        }
        source.setCancelHandler { [fd] in close(fd) }
        source.resume()
        return source
    }

    private func stopWatching() {
        // Each cancel handler closes its own descriptor.
        directoryWatchers.forEach { $0.cancel() }
        directoryWatchers = []
        fileWatcher?.cancel()
        fileWatcher = nil
        writeWorkItem?.cancel()
        writeWorkItem = nil
    }

    /// Drops the `UserDefaults` observer.
    ///
    /// Only meaningful when mirroring stops for good — a *move* keeps the observer, since the same
    /// settings are still being written, just somewhere else. `scheduleWrite` already declines to
    /// act with both switches off, so leaving one registered was inert rather than wrong; it was
    /// still a live subscription standing behind a preference that says the feature is off, which
    /// is the sort of half-torn-down state `reload` exists to keep this class out of.
    private func stopObservingSettingsChanges() {
        if let defaultsObserver { NotificationCenter.default.removeObserver(defaultsObserver) }
        defaultsObserver = nil
    }
}
