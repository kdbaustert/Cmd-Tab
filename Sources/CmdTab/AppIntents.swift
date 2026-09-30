import AppIntents
import Foundation

// Native Shortcuts actions — the URL scheme's grammar, surfaced as typed, discoverable steps.
//
// `cmdtab://` already exposes every global action, and the scriptability section of the docs is
// honest about its cost: the grammar is discoverable by reading a settings file, and a Shortcuts
// user reaches it through "Open URL" with a hand-typed string. App Intents is the same surface
// with the platform's own affordances — parameterized steps in the Shortcuts editor, Spotlight
// actions, Siri — and it costs no new permission and claims no chord.
//
// Everything routes through `IntentActions.perform`, which `AppDelegate` points at the same
// `SwitcherController.perform(_:)` the URL handler calls — one implementation, three front doors,
// so a URL, a chord and a Shortcuts step cannot drift apart in what they do. The same boundary
// holds too: nothing that quits an app, force-quits one, or closes a window is reachable here,
// for exactly the reason the URL scheme refuses them — a Shortcuts step can be run by automations
// the user is not watching. And the Desktop-moves switch is still obeyed, downstream in
// `perform`, because consent to a gesture that seizes the pointer is not something a shortcut
// should route around either.

/// The seam between the intents (instantiated by the system) and the running app's controller.
/// A closure set at launch rather than a reference to `AppDelegate`, so the intents know nothing
/// about the app's object graph and the seam is settable from a test.
@MainActor
enum IntentActions {
    static var perform: ((URLCommand) -> Void)?

    /// Runs `command`, or throws when it cannot run. A Shortcuts step that returns success having
    /// done nothing lets an automation carry on as if the window had moved — so a refusal is an
    /// error the step reports, not a silent no-op.
    ///
    /// The Desktop-moves switch is checked here as well as in `perform`, because `perform` returns
    /// nothing to say it declined. Both read the same setting, so they cannot disagree.
    static func run(_ command: URLCommand) throws {
        if case .arrangement(let arrangement) = command, arrangement.isDesktopMove,
            !WindowTilingStore.shared.desktopMoves
        {
            throw IntentError.desktopMovesOff
        }
        guard let perform else { throw IntentError.unavailable }
        perform(command)
    }
}

/// Why a step did nothing, in words Shortcuts shows the user.
enum IntentError: Error, CustomLocalizedStringResourceConvertible {
    case unavailable
    case desktopMovesOff
    case emptyBundleIdentifier

    var localizedStringResource: LocalizedStringResource {
        switch self {
        case .unavailable: "Cmd-Tab is not ready to run this action. Open it and try again."
        case .desktopMovesOff:
            "Moving windows between desktops is switched off. Turn it on in Cmd-Tab's Settings."
        case .emptyBundleIdentifier:
            "Enter the bundle identifier of an app, such as com.apple.Safari."
        }
    }
}

/// `WindowArrangement` as Shortcuts sees it. The conformance lives here rather than on the enum's
/// own file so everything App Intents is confined to one file behind one import.
extension WindowArrangement: AppEnum {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Window Arrangement"

    /// A literal, not `allCases.map` over `title`, and not by preference: the metadata extractor
    /// reads this at *compile* time, out of the source, and rejects anything computed ("Value of
    /// 'caseDisplayRepresentations' must be a dictionary"). The duplication is pinned by
    /// `AppIntentsTests`, which asserts every entry against the live `title` — so adding an
    /// arrangement without a row here fails the suite rather than shipping a nameless step.
    static let caseDisplayRepresentations: [WindowArrangement: DisplayRepresentation] = [
        .leftHalf: "Left half",
        .rightHalf: "Right half",
        .topHalf: "Top half",
        .bottomHalf: "Bottom half",
        .leftThird: "Left third",
        .centerThird: "Middle third",
        .rightThird: "Right third",
        .topThird: "Top third",
        .bottomThird: "Bottom third",
        .leftTwoThirds: "Left two-thirds",
        .rightTwoThirds: "Right two-thirds",
        .topLeft: "Top-left corner",
        .topRight: "Top-right corner",
        .bottomLeft: "Bottom-left corner",
        .bottomRight: "Bottom-right corner",
        .maximize: "Maximize",
        .maximizeHeight: "Maximize height",
        .maximizeWidth: "Maximize width",
        .almostMaximize: "Almost maximize",
        .center: "Center",
        .restore: "Restore previous size",
        .larger: "Make larger",
        .smaller: "Make smaller",
        .growLeft: "Grow left edge",
        .growRight: "Grow right edge",
        .growUp: "Grow top edge",
        .growDown: "Grow bottom edge",
        .shrinkLeft: "Shrink left edge",
        .shrinkRight: "Shrink right edge",
        .shrinkUp: "Shrink top edge",
        .shrinkDown: "Shrink bottom edge",
        .nudgeLeft: "Nudge left",
        .nudgeRight: "Nudge right",
        .nudgeUp: "Nudge up",
        .nudgeDown: "Nudge down",
        .previousDisplay: "Move to previous display",
        .nextDisplay: "Move to next display",
        .display1: "Move to display 1",
        .display2: "Move to display 2",
        .display3: "Move to display 3",
        .display4: "Move to display 4",
        .previousDesktop: "Move to previous desktop",
        .nextDesktop: "Move to next desktop",
        .desktop1: "Move to desktop 1",
        .desktop2: "Move to desktop 2",
        .desktop3: "Move to desktop 3",
        .desktop4: "Move to desktop 4",
        .desktop5: "Move to desktop 5",
        .desktop6: "Move to desktop 6",
        .desktop7: "Move to desktop 7",
        .desktop8: "Move to desktop 8",
        .desktop9: "Move to desktop 9",
        .focusLeft: "Focus window to the left",
        .focusRight: "Focus window to the right",
        .focusUp: "Focus window above",
        .focusDown: "Focus window below",
        .swapLeft: "Swap with window to the left",
        .swapRight: "Swap with window to the right",
        .swapUp: "Swap with window above",
        .swapDown: "Swap with window below",
        .firstFourth: "First fourth",
        .secondFourth: "Second fourth",
        .thirdFourth: "Third fourth",
        .lastFourth: "Last fourth",
        .leftThreeFourths: "Left three-fourths",
        .rightThreeFourths: "Right three-fourths",
        .topLeftSixth: "Top-left sixth",
        .topCenterSixth: "Top-middle sixth",
        .topRightSixth: "Top-right sixth",
        .bottomLeftSixth: "Bottom-left sixth",
        .bottomCenterSixth: "Bottom-middle sixth",
        .bottomRightSixth: "Bottom-right sixth",
        .topLeftNinth: "Top-left ninth",
        .topCenterNinth: "Top-middle ninth",
        .topRightNinth: "Top-right ninth",
        .middleLeftNinth: "Middle-left ninth",
        .middleCenterNinth: "Center ninth",
        .middleRightNinth: "Middle-right ninth",
        .bottomLeftNinth: "Bottom-left ninth",
        .bottomCenterNinth: "Bottom-middle ninth",
        .bottomRightNinth: "Bottom-right ninth",
        .tileAll: "Tile all windows",
        .cascadeAll: "Cascade all windows",
    ]
}

/// One step for the whole tiling grammar: pick an arrangement, and the focused window takes it —
/// the `cmdtab://tile/…` verb as a typed parameter instead of a string.
struct TileWindowIntent: AppIntent {
    static let title: LocalizedStringResource = "Tile the Focused Window"
    // Literals throughout, not concatenations: the metadata extractor and these initializers both
    // want compile-time strings, and a `+` is neither.
    static let description = IntentDescription(
        """
        Applies a window arrangement to the focused window — halves, thirds, corners, moves \
        between displays and desktops, focus and swap. The same set the cmdtab:// scheme \
        exposes; moving between desktops obeys its own switch in Settings.
        """)

    @Parameter(title: "Arrangement")
    var arrangement: WindowArrangement

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentActions.run(.arrangement(arrangement))
        return .result()
    }
}

/// `cmdtab://activate/<bundle id>` as a step: bring an app forward, launching it if needed.
struct ActivateAppIntent: AppIntent {
    static let title: LocalizedStringResource = "Activate an App"
    static let description = IntentDescription(
        """
        Brings an app forward by bundle identifier, launching it if it is not running — \
        com.apple.Safari, for example.
        """)

    @Parameter(title: "Bundle Identifier")
    var bundleIdentifier: String

    @MainActor
    func perform() async throws -> some IntentResult {
        let trimmed = bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw IntentError.emptyBundleIdentifier }
        try IntentActions.run(.activate(bundleID: trimmed))
        return .result()
    }
}

/// Hide or show every app — `cmdtab://windows/hideAll` and `showAll`.
struct AllWindowsIntent: AppIntent {
    static let title: LocalizedStringResource = "Hide or Show All Windows"
    static let description = IntentDescription(
        "Hides every app to clear the screen, or brings back exactly what Hide All hid.")

    @Parameter(title: "Action")
    var action: AllWindowsIntentAction

    @MainActor
    func perform() async throws -> some IntentResult {
        try IntentActions.run(.allWindows(action == .hide ? .hide : .show))
        return .result()
    }
}

/// The two-way choice for `AllWindowsIntent`, mirrored rather than conforming `AllWindowsAction`
/// itself: that enum belongs to `GlobalActions`, and two raw cases are cheaper than exporting it.
enum AllWindowsIntentAction: String, AppEnum {
    case hide
    case show

    static let typeDisplayRepresentation: TypeDisplayRepresentation = "All Windows Action"

    static let caseDisplayRepresentations: [AllWindowsIntentAction: DisplayRepresentation] = [
        .hide: "Hide All Windows",
        .show: "Show All Windows",
    ]
}
