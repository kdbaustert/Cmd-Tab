import AppKit
import ApplicationServices

/// Reads the notification badges apps put on their Dock icons ("3", "12", "•").
///
/// There is no public API for another app's badge — it is set inside that app's own process via
/// `NSApp.dockTile.badgeLabel`, and `NSRunningApplication` does not expose it. The Dock itself does,
/// on each of its item elements, as the `AXStatusLabel` attribute; walking the Dock's Accessibility
/// tree is how every other switcher reads them.
///
/// Best-effort by nature. The Dock's AX structure is not API, badges are absent far more often than
/// present, and the whole thing degrades to "no badges" rather than failing.
enum DockBadges {
    /// Badge text keyed by bundle identifier.
    ///
    /// Keyed on bundle id rather than the item's title because the title is the display name, which
    /// is localised and collides across apps.
    ///
    /// Accessibility IPC to another process — belongs on a background queue, never the event tap.
    static func current() -> [String: String] {
        guard
            let dock = NSWorkspace.shared.runningApplications
                .first(where: { $0.bundleIdentifier == "com.apple.dock" })
        else { return [:] }

        let app = AX.application(dock.processIdentifier)
        // The Dock nests its items one list down; take every list so a future rearrangement does not
        // silently return nothing.
        var badges: [String: String] = [:]
        for list in children(of: app) {
            for item in children(of: list) {
                guard let label = AX.copyString(item, "AXStatusLabel"),
                    !label.isEmpty,
                    let id = bundleID(of: item)
                else { continue }
                badges[id] = label
            }
        }
        return badges
    }

    /// The bundle identifier behind a Dock item, via the file URL it points at.
    ///
    /// `Bundle(url:)` rather than parsing the path: an app can live anywhere, and the URL is the only
    /// stable identity the Dock exposes.
    private static func bundleID(of item: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(item, "AXURL" as CFString, &value) == .success,
            let url = value as? URL
        else { return nil }
        return Bundle(url: url)?.bundleIdentifier
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        var value: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &value)
                == .success,
            let children = value as? [AXUIElement]
        else { return [] }
        return children
    }
}
