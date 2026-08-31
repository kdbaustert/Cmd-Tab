import AppKit
import ApplicationServices
import CoreGraphics

// Moving *focus* between windows by direction, and swapping two windows' places.
//
// The tiler has always been able to put a window where you want it, and nothing until now could move
// you between them. Four windows in the four quarters and the only route to the one on the right was
// the switcher — a list, ordered by recency, with no notion that "the one on the right" is something
// a person can mean. These are the chords that make a tiled desk navigable without it.
//
// Deliberately built on `CGWindowListCopyWindowInfo` rather than Accessibility. The whole question is
// "where is every window", and that is one cheap call to the window server against `2n` rounds of IPC
// to every app on the machine — the same trade `MouseWindowDrag.window(at:)` documents for the same
// reason. It also answers in z-order and excludes what should be excluded for free: minimized windows
// and windows on other Desktops are not on screen, and "focus the window to the left" can only ever
// mean one you can see.

/// One of the four directions a window chord can point in.
///
/// Its own type rather than four cases inspected by name: the geometry below is the same reasoning
/// four times over with two axes and two signs swapped, and writing it once against this is what
/// keeps `up` from quietly meaning "larger y" in one of the four.
enum WindowDirection: String, CaseIterable, Identifiable {
    case left, right, up, down

    var id: String { rawValue }

    var title: String {
        switch self {
        case .left: return "left"
        case .right: return "right"
        case .up: return "above"
        case .down: return "below"
        }
    }

    /// Whether this direction is measured along x. The other two are along y.
    var isHorizontal: Bool { self == .left || self == .right }

    /// The primary-axis coordinate of a frame's centre.
    fileprivate func along(_ frame: CGRect) -> CGFloat { isHorizontal ? frame.midX : frame.midY }

    /// The perpendicular-axis coordinate of a frame's centre.
    fileprivate func across(_ frame: CGRect) -> CGFloat { isHorizontal ? frame.midY : frame.midX }

    /// Whether `candidate` lies in this direction from `origin`.
    ///
    /// Compared on centres, and strictly, so two windows stacked exactly on top of each other are in
    /// no direction from one another rather than each being in every direction from the other.
    ///
    /// In Accessibility's coordinates y grows *downward*, so `up` is the smaller value — the one
    /// thing about this maths that is easy to write backwards, and the reason it is stated once here
    /// instead of at each of the four call sites it used to be.
    fileprivate func isAhead(_ candidate: CGRect, of origin: CGRect) -> Bool {
        switch self {
        case .left: return candidate.midX < origin.midX
        case .right: return candidate.midX > origin.midX
        case .up: return candidate.midY < origin.midY
        case .down: return candidate.midY > origin.midY
        }
    }

    /// Whether the two frames overlap on the axis this direction does *not* travel along — the test
    /// for "these are side by side" as opposed to "that one is away over there diagonally".
    fileprivate func overlapsAcross(_ candidate: CGRect, _ origin: CGRect) -> Bool {
        isHorizontal
            ? candidate.minY < origin.maxY && origin.minY < candidate.maxY
            : candidate.minX < origin.maxX && origin.minX < candidate.maxX
    }
}

/// Which window lies in a given direction from another.
///
/// Pure, and separate from everything that reads the window server, so the rule can be exercised
/// against a desk laid out in a test rather than one that has to be arranged by hand on a machine
/// with the right number of monitors.
enum WindowNeighbors {
    /// The index of the window in `direction` from `origin`, or nil when there is none.
    ///
    /// Three rules, applied in order, and each one is here because the rule above it is not enough
    /// on a desk that is not a clean grid.
    ///
    /// **1. Overlap beats distance.** A candidate whose perpendicular span overlaps the origin's is
    /// always preferred over one that does not, however much nearer the second is. Without it, a
    /// window sitting down-and-to-the-right is "to the right" of you, and ⌃⌘→ from a small window
    /// wanders diagonally across the screen instead of going to the thing beside it.
    ///
    /// **2. Then the smallest gap between the two windows' facing edges** — not between their
    /// centres. This is the rule that took a test to find. Picture a full-height window on the left,
    /// a half-screen window filling the right, and a small palette floating just inside the right
    /// window's leading edge: the palette's *centre* is much nearer, so a nearest-centre measure
    /// sends the keyboard to the palette every time, while the gap from the origin's trailing edge
    /// is 0 for the window that is genuinely adjacent and larger for the palette behind it. Measured
    /// from the edges, "next to" means what it looks like.
    ///
    /// The gap is floored at zero, so overlapping candidates all tie rather than competing on how
    /// deeply they overlap — otherwise the *most* overlapped window would read as the nearest, which
    /// inverts the answer for windows layered over one another.
    ///
    /// **3. Then nearest across the axis of travel**, which is what separates two windows stacked in
    /// the next column: both are adjacent, and the one more nearly abeam is the one you meant.
    ///
    /// Ties resolve to the earliest index, and callers pass the window list in z-order, so two
    /// candidates that are equally good resolve to whichever is nearer the front — the one the user
    /// was more recently looking at.
    static func pick(
        from origin: CGRect, among frames: [CGRect], direction: WindowDirection
    ) -> Int? {
        let ahead = frames.indices.filter { direction.isAhead(frames[$0], of: origin) }
        guard !ahead.isEmpty else { return nil }
        let overlapping = ahead.filter { direction.overlapsAcross(frames[$0], origin) }
        let pool = overlapping.isEmpty ? ahead : overlapping
        return pool.min { a, b in
            let (gapA, acrossA) = distances(from: origin, to: frames[a], direction: direction)
            let (gapB, acrossB) = distances(from: origin, to: frames[b], direction: direction)
            return gapA == gapB ? acrossA < acrossB : gapA < gapB
        }
    }

    /// How far apart the two windows' facing edges are, and how far the candidate's centre sits off
    /// the axis of travel.
    private static func distances(
        from origin: CGRect, to candidate: CGRect, direction: WindowDirection
    ) -> (gap: CGFloat, across: CGFloat) {
        let gap: CGFloat
        switch direction {
        case .left: gap = origin.minX - candidate.maxX
        case .right: gap = candidate.minX - origin.maxX
        // Top-left origin again: the window *above* is the one whose bottom edge is above this
        // window's top edge, which in this space means the smaller y on both counts.
        case .up: gap = origin.minY - candidate.maxY
        case .down: gap = candidate.minY - origin.maxY
        }
        return (max(gap, 0), abs(direction.across(candidate) - direction.across(origin)))
    }
}

/// Performs the two directional chords against the live desk.
enum WindowNavigator {
    /// Where the Accessibility half of a swap runs. Focus needs none at all — see the file header —
    /// but a swap writes two frames, and every Accessibility call in this app is IPC that can block
    /// on a wedged app. The tap callback runs on the main run loop, and a tap that overruns the
    /// system's deadline is disabled outright, taking every keystroke on the machine with it.
    private static let queue = DispatchQueue(label: "com.cmdtab.navigation", qos: .userInitiated)

    /// One on-screen window, as the window server describes it.
    struct Window {
        let id: CGWindowID
        let pid: pid_t
        let frame: CGRect
    }

    /// Every ordinary window on screen, front to back.
    ///
    /// `layer == 0` is the filter that keeps this to real windows: it drops the Dock, the menu bar,
    /// wallpaper surfaces, and this app's own switcher panel and snap overlays, all of which sit
    /// above the normal window level. The Settings window is *not* dropped, and should not be — it
    /// is an ordinary window, and being unable to reach the one window this app definitely owns is
    /// the most obvious thing that could be wrong with a navigation chord.
    static func onScreen() -> [Window] {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return info.compactMap { window in
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                let id = window[kCGWindowNumber as String] as? CGWindowID,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let frame = CGRect(dictionaryRepresentation: raw as CFDictionary),
                // A zero-area surface is not somewhere focus can go. Several hosts publish one —
                // the Electron and Catalyst phantom backing windows the capture code drops by a
                // different test — and they are invisible, so landing on one looks like the chord
                // having done nothing at all.
                frame.width > 1, frame.height > 1
            else { return nil }
            return Window(id: id, pid: pid, frame: frame)
        }
    }

    /// The frontmost window of `pid`, and every other window that could be a destination.
    ///
    /// The origin is taken as the first window of the frontmost app in z-order rather than read back
    /// over Accessibility: the list is already in hand, already in z-order, and asking the app the
    /// same question costs IPC to arrive at the same answer.
    private static func origin(pid: pid_t, in windows: [Window]) -> (Window, [Window])? {
        guard let index = windows.firstIndex(where: { $0.pid == pid }) else { return nil }
        var rest = windows
        let origin = rest.remove(at: index)
        return (origin, rest)
    }

    /// Moves focus to the window in `direction` from the frontmost one.
    ///
    /// Routed through `SwitchTarget.focusWindow`, the same call a tile pick makes, rather than a
    /// bare `AXRaise`: that function already knows how to unhide an app, restore a window from the
    /// Dock and travel to another Desktop, and re-deriving any of it here would be a second, worse
    /// copy of logic that took a long time to get right. Every window this can reach is on screen,
    /// so most of that machinery is a no-op — but "on screen" includes a window on a Desktop the
    /// user is not looking at when two displays each show their own.
    static func focus(_ direction: WindowDirection, from pid: pid_t) {
        let windows = onScreen()
        guard let (from, rest) = origin(pid: pid, in: windows) else {
            Log.tap.notice("focus \(direction.rawValue, privacy: .public): no window to move from")
            return
        }
        guard
            let index = WindowNeighbors.pick(
                from: from.frame, among: rest.map(\.frame), direction: direction)
        else {
            Log.tap.notice(
                "focus \(direction.rawValue, privacy: .public): nothing \(direction.title, privacy: .public)")
            return
        }
        let target = rest[index]
        Log.tap.notice(
            "focus \(direction.rawValue, privacy: .public): window \(target.id, privacy: .public) of pid \(target.pid, privacy: .public)")
        SwitchTarget.focusWindow(id: target.id, pid: target.pid)
    }

    /// Exchanges the frontmost window's frame with that of the window in `direction`.
    ///
    /// The two frames are swapped exactly as they are — no gap, no fraction, no restore point. A
    /// swap's meaning is "these two change places", its inverse is the same chord in the opposite
    /// direction, and insetting either window on the way would make the pair drift every time.
    ///
    /// `rules` is consulted for *both* windows: an app the user has told us never to tile must not
    /// be moved because something beside it was.
    static func swap(_ direction: WindowDirection, from pid: pid_t, rules: [String: AppRule]) {
        let windows = onScreen()
        guard let (from, rest) = origin(pid: pid, in: windows) else {
            Log.tap.notice("swap \(direction.rawValue, privacy: .public): no window to move")
            return
        }
        guard
            let index = WindowNeighbors.pick(
                from: from.frame, among: rest.map(\.frame), direction: direction)
        else {
            Log.tap.notice(
                "swap \(direction.rawValue, privacy: .public): nothing \(direction.title, privacy: .public)")
            return
        }
        let target = rest[index]
        if let blocked = neverTile(from.pid, target.pid, rules: rules) {
            Log.tap.notice("swap: \(blocked, privacy: .public) is set to never tile")
            return
        }
        queue.async {
            // Resolved by frame, not by "the app's front window": the neighbour is by definition not
            // the focused window, and for an app with several windows open the two come apart in
            // exactly the case this chord exists for. No fallback to the front window either, unlike
            // the tiler's — a swap that could not find one of its two windows must move neither,
            // where a tile that misses has only one window to be wrong about.
            guard
                let source = AX.window(ofApplication: from.pid, matching: from.frame),
                let destination = AX.window(ofApplication: target.pid, matching: target.frame)
            else {
                Log.tap.notice("swap: could not resolve both windows over Accessibility")
                return
            }
            AX.setFrame(source, target.frame, sizing: true, repositionAfterSizing: true)
            AX.setFrame(destination, from.frame, sizing: true, repositionAfterSizing: true)
        }
    }

    /// The bundle identifier of whichever of the two apps is excluded from tiling, if either is.
    ///
    /// The origin is checked again here even though `SwitcherController.applyTiling` has already
    /// refused a front app carrying the rule: a swap moves *two* windows, and a function that took
    /// one of its two guards from its caller would be one refactor away from moving a window the
    /// user has explicitly protected.
    private static func neverTile(
        _ first: pid_t, _ second: pid_t, rules: [String: AppRule]
    ) -> String? {
        guard !rules.isEmpty else { return nil }
        for pid in [first, second] {
            guard let id = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier,
                rules[id]?.neverTile == true
            else { continue }
            return id
        }
        return nil
    }
}
