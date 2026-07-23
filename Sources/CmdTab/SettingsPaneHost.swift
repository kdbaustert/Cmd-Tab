import AppKit
import Settings

// This file deliberately does **not** import SwiftUI.
//
// The settings package nests `Pane` and `PaneIdentifier` inside a namespace enum called `Settings`,
// and SwiftUI exports a `Settings` scene type of its own. In any file importing both, the qualified
// path `Settings.PaneIdentifier` is ambiguous, and there is no way out at the use site: writing the
// module-qualified `Settings.Settings.PaneIdentifier` leaves the *first* component ambiguous too.
// SwiftPM's `moduleAliases` does not help either — it renames the built module but keeps the
// original name as what source refers to it by, which is the opposite of what is needed here.
//
// Naming those nested types here, where only one `Settings` is in scope, is what makes them
// reachable from the SwiftUI side. Everything the rest of the app needs is re-exported below under
// a name that cannot collide.

/// The settings package's pane identifier, under a name the SwiftUI side can say.
typealias SettingsPaneID = Settings.PaneIdentifier

extension Settings.PaneIdentifier {
    static let general = Self("general")
    static let appearance = Self("appearance")
    static let apps = Self("apps")
}

/// Adapts an already-built view controller into a `SettingsPane`.
///
/// The package's own `Settings.Pane` does this job, but it is generic over a SwiftUI `View` and so
/// can only be *named* from a file that imports SwiftUI — which is precisely the file where
/// `Settings` is ambiguous. Taking a plain `NSViewController` here sidesteps that: the caller builds
/// the `NSHostingController` on the SwiftUI side and hands it over already type-erased.
///
/// `view` is set to the content's own view rather than wrapping it in a container, matching what the
/// package's `PaneHostingController` does — it *is* an `NSHostingController`, so the window sizes
/// itself from the SwiftUI content's fitting size. A container view in between would size from
/// nothing until constraints resolved, and the window controller reads `panes[0].view.bounds`
/// during its own initialiser.
final class SettingsHostedPane: NSViewController, SettingsPane {
    let paneIdentifier: Settings.PaneIdentifier
    let paneTitle: String
    let toolbarItemIcon: NSImage

    private let content: NSViewController

    init(identifier: SettingsPaneID, title: String, icon: NSImage, content: NSViewController) {
        self.paneIdentifier = identifier
        self.paneTitle = title
        self.toolbarItemIcon = icon
        self.content = content
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SettingsHostedPane is never loaded from a nib")
    }

    override func loadView() {
        addChild(content)
        view = content.view
    }
}
