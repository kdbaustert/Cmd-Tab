import AppKit
import ApplicationServices

/// Finds the tabs of a browser or terminal's frontmost window through Accessibility, for the
/// `.tabs` scoped-trigger session.
///
/// There is no `AXTab` role and no app tells us it has tabs at all, so this is a search rather than
/// a read: walk the frontmost window, depth-bounded, for the first `AXTabGroup` whose descendants
/// include at least two `AXRadioButton`s, and treat those as the tabs. One algorithm rather than a
/// per-app table, because the shape is the same everywhere it has been measured, only the depth to
/// it differs:
///
/// - Safari: `AXWindow > AXSplitGroup > AXTabGroup > AXGroup > AXOpaqueProviderGroup >
///   AXRadioButton`. The active tab reports `AXValue == 1`; `AXSelected` is nil.
/// - Chrome/Brave/other Chromium hosts: the `AXTabGroup` sits about six anonymous `AXGroup`s down,
///   and its radio buttons are its direct children. The active tab reports `AXSelected == true`.
///   Chromium's bookmark bar also carries buttons sharing the open tabs' titles, which is why only
///   the matched `AXTabGroup`'s own descendants are ever collected — a sibling bar is never walked.
/// - Ghostty: `AXWindow > AXTabGroup > AXRadioButton`, active marked by `AXValue`. Ghostty reports
///   no windows at all while backgrounded, which is not a failure worth logging — see `enumerate`.
///
/// VS Code and Xcode are not supported: VS Code's tab strip is not an `AXTabGroup` within the depth
/// bound below, and Xcode is slow enough answering Accessibility that it is not worth the wait on
/// every tabs-scoped session. Neither gets a denylist entry — they simply find nothing, the same
/// outcome as any other app with no tabs — because a denylist keyed on bundle identifiers is a table
/// this file was written to avoid, and nothing measured here shows a false positive to justify one.
enum TabEnumeration {
    /// How far down a window to search for the tab group. Chromium's is the deepest measured case,
    /// six anonymous groups down; this leaves headroom without letting a search wander through an
    /// app's entire, possibly enormous, accessibility tree.
    static let maxSearchDepth = 12

    /// How far below a matched `AXTabGroup` to collect radio buttons from. Safari's sit three levels
    /// down, behind a group and an opaque provider; this covers that with headroom to spare without
    /// reopening the search to unrelated siblings once the tab group itself is found.
    static let maxCollectDepth = 6

    /// Total wall time a tabs-scoped session's enumeration is allowed across every app, so one slow
    /// responder cannot stall the panel — see `enumerate`.
    static let enumerationBudget: TimeInterval = 0.15

    /// One discovered tab: enough to show a tile and to act on a pick.
    struct TabRef {
        let pid: pid_t
        let window: AXUIElement
        let element: AXUIElement
        let title: String
        let isActive: Bool
    }

    // MARK: - Pure search

    /// The facts the search needs from a node in an accessibility tree, generic so the search below
    /// can be exercised against a fake tree in tests — real `AXUIElement`s only exist inside a
    /// trusted, running process, and this is the one part of the tab feature that can be tested
    /// exhaustively without one.
    protocol Node {
        var role: String? { get }
        var children: [Self] { get }
        var title: String? { get }
        /// `AXSelected`, when the host sets it (Chromium, Ghostty). nil when it does not (Safari).
        var isSelected: Bool? { get }
        /// `AXValue`, when the host uses it to mark the active tab (Safari, Ghostty). nil otherwise.
        var axValue: Int? { get }
    }

    /// The tabs of `root` — the radio-button descendants of the first `AXTabGroup` found with at
    /// least two of them — or nil when nothing in `root` looks like a tab strip at all.
    static func findTabs<N: Node>(in root: N, maxSearchDepth: Int = maxSearchDepth,
        maxCollectDepth: Int = maxCollectDepth
    ) -> [N]? {
        guard let group = findTabGroup(in: root, depth: 0, maxDepth: maxSearchDepth) else {
            return nil
        }
        let radios = collectRadioButtons(under: group, depth: 0, maxDepth: maxCollectDepth)
        guard radios.count >= 2 else { return nil }
        return radios
    }

    /// Depth-first, stopping at the first qualifying `AXTabGroup` rather than the best one — the
    /// first real tab strip a window exposes is the one this feature means, and continuing past it
    /// only risks a second, unrelated group (a settings pane's own tab control, say) winning by
    /// virtue of being walked later.
    private static func findTabGroup<N: Node>(in node: N, depth: Int, maxDepth: Int) -> N? {
        guard depth <= maxDepth else { return nil }
        if node.role == "AXTabGroup",
            collectRadioButtons(under: node, depth: 0, maxDepth: maxCollectDepth).count >= 2 {
            return node
        }
        for child in node.children {
            if let found = findTabGroup(in: child, depth: depth + 1, maxDepth: maxDepth) {
                return found
            }
        }
        return nil
    }

    /// Every `AXRadioButton` under `node`, depth-bounded. Used both to qualify a candidate
    /// `AXTabGroup` and to collect the tabs of the one that is chosen.
    private static func collectRadioButtons<N: Node>(under node: N, depth: Int, maxDepth: Int) -> [N] {
        guard depth <= maxDepth else { return [] }
        var found: [N] = []
        for child in node.children {
            if child.role == "AXRadioButton" { found.append(child) }
            found += collectRadioButtons(under: child, depth: depth + 1, maxDepth: maxDepth)
        }
        return found
    }

    /// A tab counts as active on `AXSelected` where the host sets it, falling back to `AXValue == 1`
    /// where it does not (Safari never sets `AXSelected` at all).
    static func isActive<N: Node>(_ node: N) -> Bool {
        if let selected = node.isSelected { return selected }
        if let value = node.axValue { return value == 1 }
        return false
    }

    // MARK: - Real accessibility tree

    /// Adapts a live `AXUIElement` to the pure search above.
    private struct AXNode: Node {
        let element: AXUIElement
        var role: String? { AX.copyString(element, kAXRoleAttribute) }
        var children: [AXNode] { AX.children(of: element).map(AXNode.init) }
        var title: String? { AX.copyString(element, kAXTitleAttribute) }
        var isSelected: Bool? { AX.copyBool(element, kAXSelectedAttribute) }
        var axValue: Int? { AX.copyInt(element, kAXValueAttribute) }
    }

    /// The tabs of one app's frontmost window, active tab first — cheaper for a caller that only
    /// wants to show it ahead of its siblings than tagging every tile and sorting downstream.
    static func tabs(pid: pid_t, frontWindow window: AXUIElement) -> [TabRef] {
        guard let radios = findTabs(in: AXNode(element: window)) else { return [] }
        let refs = radios.map { node in
            TabRef(
                pid: pid, window: window, element: node.element,
                title: node.title ?? "", isActive: isActive(node))
        }
        return refs.sorted { $0.isActive && !$1.isActive }
    }

    /// Every tab of every given app's frontmost window, gathered within `deadline` — see
    /// `enumerationBudget`. An app that reports no windows (Ghostty while backgrounded) is skipped
    /// silently rather than logged, since "not running a window right now" is routine for it, not a
    /// failure. An app the deadline catches mid-walk is simply not asked about again this pass; its
    /// tiles come back on the next tabs-scoped session, the same as any other app the switcher was
    /// too slow to reach.
    ///
    /// Accessibility IPC throughout, so this belongs on the caller's background queue — same
    /// constraint as everything else in `AX`.
    static func enumerate(pids: [pid_t], deadline: DispatchTime) -> [TabRef] {
        var all: [TabRef] = []
        for pid in pids {
            guard DispatchTime.now() < deadline else { break }
            guard let window = AX.frontWindow(ofApplication: pid) else { continue }
            all += tabs(pid: pid, frontWindow: window)
        }
        return all
    }
}
