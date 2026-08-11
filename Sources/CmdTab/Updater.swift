import AppKit
import Combine
import Sparkle
import SwiftUI

/// Auto-update, over Sparkle.
///
/// The app was notarised and distributable long before it could tell anyone a new build existed:
/// `release.sh` produced a signed zip, and every user who installed it stayed on that version until
/// they happened to revisit the repository. This closes that.
///
/// Sparkle rather than a version check against the GitHub API, because the two are not the same
/// feature. A check can only ever say "go and download it yourself", which for an app whose install
/// step is *quit the running copy, replace the bundle, re-grant nothing because the certificate is
/// stable* is the boring part done by hand. Sparkle does the download, the signature check and the
/// swap, and it does the one thing a hand-rolled updater gets wrong: it verifies an **EdDSA
/// signature over the archive** before running anything, so a compromised download host cannot ship
/// this app's users a different binary.
///
/// ## What this costs
///
/// A framework inside the bundle, which this app did not have before, and which `build.sh` and
/// `release.sh` now have to place, rpath and sign. Those scripts carry the details.
///
/// ## Why the controller is wrapped rather than used directly
///
/// `SPUStandardUpdaterController` is the batteries-included entry point and is fine, but two of its
/// facts are needed as *SwiftUI state*: whether a check is possible right now (it is not, while one
/// is already running) and when the last one happened. Both live behind KVO on `SPUUpdater`, which a
/// `View` cannot observe. This publishes them.
@MainActor
final class Updater: ObservableObject {
    static let shared = Updater()

    /// `startingUpdater: true` begins the scheduled-check timer immediately, which is what makes the
    /// background check happen at all. There is no permission prompt to wait for: Sparkle's
    /// first-launch dialog is suppressed below, since this app already decides its own defaults.
    ///
    /// No `userDriver` of our own. The standard one puts up Sparkle's own window, which is the right
    /// call for a settings-window-sized app: an update flow is exactly the kind of thing where the
    /// familiar, tested UI beats a bespoke one, and it is the only part of this app that is *allowed*
    /// to activate and take focus.
    private let controller: SPUStandardUpdaterController

    /// False while a check is in flight, so the button can disable itself rather than starting a
    /// second one. Mirrored out of KVO — see the class comment.
    @Published private(set) var canCheck = true

    /// When the last check completed, or nil if it never has. Shown in Settings because the useful
    /// question about a background updater is "is it actually running", and a date is the only
    /// answer that distinguishes "up to date" from "silently broken since March".
    @Published private(set) var lastCheck: Date?

    /// Sparkle's own preference, surfaced as a binding. Written straight through to the updater
    /// rather than shadowed in `Defaults`: Sparkle reads its own key at scheduling time, so a second
    /// copy of this value would be a second source of truth that the timer ignores.
    var automaticallyChecks: Bool {
        get { controller.updater.automaticallyChecksForUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyChecksForUpdates = newValue
        }
    }

    /// Download and install without asking, versus notifying and letting the user choose. Off by
    /// default — see `Info.plist`. An app that owns ⌘-Tab machine-wide should not replace itself
    /// mid-session without having been told it may.
    var automaticallyDownloads: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set {
            objectWillChange.send()
            controller.updater.automaticallyDownloadsUpdates = newValue
        }
    }

    private var observers: [NSKeyValueObservation] = []

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheck = controller.updater.canCheckForUpdates
        lastCheck = controller.updater.lastUpdateCheckDate

        // KVO rather than a delegate: `canCheckForUpdates` has no delegate callback, and the two
        // values want the same treatment.
        observers = [
            controller.updater.observe(\.canCheckForUpdates, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.canCheck = updater.canCheckForUpdates }
            },
            controller.updater.observe(\.lastUpdateCheckDate, options: [.new]) { [weak self] updater, _ in
                MainActor.assumeIsolated { self?.lastCheck = updater.lastUpdateCheckDate }
            },
        ]
    }

    /// The explicit check, from the button in Settings → About.
    ///
    /// Distinct from the scheduled one in a way that matters: this one is allowed to report "you are
    /// up to date". A background check that found nothing must stay silent, or the app would
    /// interrupt the user to tell them nothing happened.
    func checkForUpdates() {
        controller.updater.checkForUpdates()
    }

    /// Whether this build can update itself at all.
    ///
    /// False for a `build.sh` bundle — that is signed with the local self-signed certificate, has no
    /// EdDSA public key baked in, and points at no feed. Reporting that plainly is better than
    /// showing a check button that fails: a developer build updating itself out from under the
    /// developer would be worse than one that says it will not try.
    var isConfigured: Bool {
        let info = Bundle.main.infoDictionary
        let feed = info?["SUFeedURL"] as? String
        let key = info?["SUPublicEDKey"] as? String
        return !(feed ?? "").isEmpty && !(key ?? "").isEmpty
    }

    /// Sparkle's user-facing preferences, which export/import should carry — someone moving to a new
    /// Mac means their "do not update behind my back" to come with them.
    static let exportedDefaultsKeys = [
        "SUEnableAutomaticChecks",
        "SUAutomaticallyUpdate",
    ]

    /// Sparkle's bookkeeping, which it should not.
    ///
    /// `SULastCheckTime` and friends describe *this* install's history, not the user's preferences;
    /// carrying them to another Mac in an exported file would misreport when that Mac last checked,
    /// and carrying `SUSkippedVersion` would silently suppress an update the user never skipped
    /// there. Swept on reset all the same — "reset to defaults" should not leave a skipped version
    /// behind, which would look exactly like the updater being broken.
    static let transientDefaultsKeys = [
        "SULastCheckTime",
        "SUSkippedVersion",
        "SUHasLaunchedBefore",
        "SUUpdateGroupIdentifier",
        "SUSendProfileInfo",
    ]
}
