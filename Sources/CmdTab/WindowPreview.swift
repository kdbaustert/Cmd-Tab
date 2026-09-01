import AppKit
import ScreenCaptureKit
import SwiftUI

/// What the cursor points at, as far as the hover preview is concerned.
enum PreviewTarget: Equatable {
    /// An app tile — the app's pid and the tile's screen rect.
    case tile(pid: pid_t, rect: NSRect)
    /// The floating strip itself, with where on it the cursor is. Carrying the point keeps the strip
    /// alive while the cursor is on it *and* lets it highlight the thumbnail under the pointer;
    /// without a point this case would dedupe to a single event and the highlight could never move.
    case overPreview(NSPoint)
    /// Neither. The coordinator delays the teardown a little so the cursor can cross the gap from a
    /// tile to the strip without it vanishing mid-move.
    case away
}

/// A live thumbnail of one window, as shown in the hover preview.
struct WindowThumb: Identifiable {
    /// Position in the strip, and the identity the view and hit-testing use.
    ///
    /// Deliberately *not* the `CGWindowID`: a minimized window on a host where
    /// `_AXUIElementGetWindow` fails (Electron, Catalyst) resolves to id 0, so an app with two of
    /// them would hand `ForEach` duplicate ids and collide in the frame map — which decides where a
    /// click lands. Position is unique by construction.
    let id: Int
    /// The window to raise when this thumbnail is clicked. 0 when it could not be resolved, which
    /// degrades to activating the app.
    let windowID: CGWindowID
    let image: NSImage
    let title: String
    /// The owning app, so a clicked thumbnail can be raised and activated.
    let pid: pid_t
    /// Whether the window is sitting in the Dock. Drives the badge only — a minimized window
    /// usually still captures, so this says nothing about what `image` holds.
    let isMinimized: Bool
    /// Whether `image` is real window pixels rather than the app icon standing in for them.
    ///
    /// Separate from `isMinimized` because the two came apart: the icon is the fallback for any
    /// window that would not capture, minimized or not, and a minimized window that *did* capture
    /// must still be laid out — and badged — as the real thing.
    let hasCapture: Bool
    /// Which display the window is on, or nil with a single display (or when it can't be placed).
    /// An app's windows are routinely spread across monitors, and the strip gathers all of them —
    /// so without this there is no way to tell which screen a thumbnail will take you to.
    let displayIndex: Int?
    /// Whether clicking this thumbnail can actually get the user to the window.
    ///
    /// False for a window on a Desktop macOS will not travel to, which is decided by the app rather
    /// than by the window: an app with anything on screen anywhere is one macOS declines to travel
    /// for, and a second display holding a single Space makes that permanent for every app with a
    /// window on it. See `SwitchTarget.canReach`, which is the same call the pick itself makes.
    ///
    /// Carried on the thumbnail rather than resolved at click time because the point is to say so
    /// *before* the click — the failure is silent and there is nothing to show afterwards.
    let isReachable: Bool
}

/// Captures thumbnails of an app's windows through ScreenCaptureKit.
///
/// The only place in the app that needs Screen Recording: the switcher itself reads pids and titles
/// over Accessibility and deliberately gets by without it. That is why every entry point degrades to
/// an empty list rather than prompting — with the permission withheld the feature is simply absent,
/// and the rest of the switcher carries on.
///
/// An actor because the caches below are touched from overlapping hovers: sweeping the cursor along
/// a row of tiles starts a capture per tile, and they must not race each other rebuilding the same
/// system-wide window list.
actor WindowCapture {
    static let shared = WindowCapture()

    /// One window bound for the strip, before its pixels are fetched.
    /// `@unchecked Sendable` because `SCWindow` is not `Sendable` and an entry is handed to a task
    /// group — the captures run concurrently, which is the whole point of batching them.
    ///
    /// Safe because an `Entry` is a description, not a handle to anything mutable: every field is a
    /// `let`, and `SCWindow` is a read-only snapshot ScreenCaptureKit hands out from
    /// `SCShareableContent` for exactly this purpose — naming a window to capture. Nothing here
    /// writes to it, and the capture API is designed to be called off the main thread.
    private struct Entry: @unchecked Sendable {
        let id: CGWindowID
        let title: String
        /// The capture source, or nil for a window Accessibility named but ScreenCaptureKit did not
        /// list — there is nothing to point a filter at for those.
        let window: SCWindow?
        let isMinimized: Bool
        let displayIndex: Int?
        let isReachable: Bool
    }

    /// Windows narrower or shorter than this are helper surfaces, not something to switch to.
    private static let minWindowSide: CGFloat = 40

    /// What makes two unverifiable surfaces the same window as far as the strip can tell.
    ///
    /// The frame is rounded to whole points rather than compared exactly: a surface kept from before
    /// a resolution change can sit a sub-pixel off, and two tiles a fraction of a point apart are
    /// the same tile to anyone looking at them.
    struct SurfaceKey: Hashable {
        let title: String
        let x: Int, y: Int, width: Int, height: Int

        init(title: String, frame: CGRect) {
            self.title = title
            self.x = Int(frame.origin.x.rounded())
            self.y = Int(frame.origin.y.rounded())
            self.width = Int(frame.width.rounded())
            self.height = Int(frame.height.rounded())
        }
    }

    /// Collapses identical copies of a window the strip cannot verify, keeping the frontmost.
    ///
    /// The window server keeps a layer-0 surface — last title, full-size frame, still capturable —
    /// after a tab or window closes, and nothing it exposes separates one from a live window.
    /// Measured on Ghostty: four surfaces titled `~/Development/cnc-claims`, all at the identical
    /// frame, all capturing 100% opaque pixels, none of them a window any more. Four tiles carrying
    /// the same name and the same picture are not four choices — there is no question a person could
    /// be asking that they are the answer to.
    ///
    /// **Scoped to `unverified`, which is what makes it safe.** Two live windows may legitimately
    /// share a title and a frame — two empty terminals in the same directory, two Finder windows of
    /// one folder — and collapsing those would take a real window off the strip. So this only
    /// touches the set the strip already cannot vouch for: off screen and on no Space. Anything on a
    /// Space, on screen, or named by Accessibility keeps its own tile however many twins it has.
    ///
    /// The frontmost copy is the one kept: `windows` arrives from ScreenCaptureKit front to back, so
    /// the first of a group is the most recently in front and the likeliest to be the live one.
    ///
    /// Generic over the element so the rule can be tested without a window server — `SCWindow` can
    /// only be obtained from one.
    nonisolated static func collapsingDuplicates<T>(
        _ windows: [T], unverified: (T) -> Bool, key: (T) -> SurfaceKey
    ) -> [T] {
        var seen: Set<SurfaceKey> = []
        var out: [T] = []
        out.reserveCapacity(windows.count)
        // An explicit walk rather than `removeAll(where:)`: this depends on visiting front to back,
        // and the standard library promises nothing about the order that predicate is called in.
        for window in windows {
            if unverified(window), !seen.insert(key(window)).inserted { continue }
            out.append(window)
        }
        return out
    }

    /// What Accessibility says an app's windows are.
    ///
    /// Internal rather than private so `WindowPreviewTests` can exercise the two rules built on it —
    /// which answer the veto uses, and how identical surfaces collapse. Both decide whether a
    /// window the user owns appears in the strip, and neither is reachable through the async
    /// capture path without a window server.
    struct AXWindows {
        /// Every window the app reports, by `CGWindowID`.
        let ids: Set<CGWindowID>
        /// The subset sitting in the Dock, with titles, so SC's list can be supplemented.
        let minimized: [(id: CGWindowID, title: String)]
        /// Whether every window in a non-empty list resolved to a real `CGWindowID`, so the ids can
        /// be matched against SC's list at all. Only then may this be used to *remove* what SC
        /// reported; see `thumbnails`.
        ///
        /// Emphatically not "AX enumerated every window the app owns" — it cannot tell us that, and
        /// `AXWindows` is known to under-report. See the veto in `thumbnails` for what that costs.
        let resolvedEveryWindow: Bool
    }

    private var content: SCShareableContent?
    private var contentFetchedAt: Date?
    private var axCache: [pid_t: (windows: AXWindows, at: Date)] = [:]

    /// The most recent answer an app gave that was good enough to veto with, per app.
    ///
    /// Separate from `axCache`, which is a sub-second read-coalescer, and kept for a great deal
    /// longer — because the thing it exists to survive lasts a great deal longer. Ghostty's
    /// `AXWindows` returns *success with zero elements* for long stretches: measured at 2 Hz over
    /// 30 seconds it was empty in 60 samples out of 60, while `AXFocusedWindow` on the same element
    /// resolved fine and the app-level `AXChildren` was `[AXMenuBar]`. It also flaps — watched
    /// going 2, then 1, then 0 with the app neither hidden nor frontmost.
    ///
    /// An empty answer disarms the veto (`resolvedEveryWindow` is false for an empty list), and the
    /// veto is the only thing separating a live window from the dead layer-0 surfaces the window
    /// server keeps after a tab closes. So the app that leaks the most surfaces is also the one that
    /// disarms the only defence against them, and the strip filled with screenshots of tabs that
    /// closed hours ago — seven tiles for two tabs, four of them the same dead tab, every one
    /// capturing 100% opaque pixels so `isBlank` never rejected them.
    ///
    /// Remembering the last usable answer keeps the veto armed across the gap. What it cannot do is
    /// add anything: see `vetoAnswer`.
    private var lastUsableAX: [pid_t: (windows: AXWindows, at: Date)] = [:]

    /// The window entries in each app's menu bar, normalized — see `menuWindowTitles`. Its own cache
    /// rather than a field on `AXWindows` because it is read on a different condition: only when
    /// there is a docked window a veto could act on, which is rarely.
    private var menuCache: [pid_t: (titles: Set<String>, at: Date)] = [:]

    /// How long a remembered answer may still veto with. Long enough to cover the empty stretches
    /// measured above, and bounded because the risk it carries grows with age: a window opened
    /// since the snapshot is not in it, and would be vetoed if it were also off screen and on no
    /// Space. That is a narrow case — a background tab opened during the gap — and it corrects
    /// itself the moment the app answers again.
    private let usableAXLifetime: TimeInterval = 120

    /// How long a fetched window list may be reused. Sub-second: long enough that sweeping the
    /// cursor back across a tile doesn't re-enumerate every window on the system, short enough that
    /// the strip can't show a window that has since closed.
    private let ttl: TimeInterval = 0.75

    /// Ceiling on simultaneous captures. Each is WindowServer and GPU work for a strip the cursor
    /// may be about to sweep straight past, and it stacks with whatever the panel's own behind-window
    /// blur already costs the compositor. Four keeps the round-trips overlapping without the spike.
    private let maxConcurrentCaptures = 4

    /// Thumbnails of `pid`'s windows, front to back. Empty when Screen Recording is not granted, when
    /// ScreenCaptureKit refuses to enumerate, or when the app genuinely has nothing on screen.
    ///
    /// Those three were indistinguishable from outside, and the caller's log line — "0 window(s) for
    /// pid N" — read the same for all of them. That is exactly the shape of "previews stopped
    /// working" with nothing to say why, so each now announces itself. Logged at `.error` because
    /// the first two are broken states rather than ordinary ones, and rate-limited because this runs
    /// on every hover and a withheld permission would otherwise write a line per tile per sweep.
    func thumbnails(for pid: pid_t, maxCount: Int = 12, maxHeight: CGFloat = 150) async
        -> [WindowThumb]
    {
        guard Permissions.canCaptureScreen else {
            reportOnce(
                .permission,
                """
                preview: Screen Recording is not granted to this build, so no window can be \
                captured. Re-grant it in System Settings → Privacy & Security → Screen Recording \
                and relaunch — a re-signed build loses the grant even under the same identity.
                """)
            return []
        }
        guard !Task.isCancelled else { return [] }
        guard let content = await shareableContent() else {
            reportOnce(
                .enumeration,
                "preview: ScreenCaptureKit would not enumerate windows; the capture is unavailable")
            return []
        }
        guard !Task.isCancelled else { return [] }
        // Back to healthy — say so, so a log read after the fact shows the recovery rather than
        // leaving the last word as the failure.
        if reported.remove(.permission) != nil || reported.remove(.enumeration) != nil {
            Log.general.notice("preview: capture is working again")
        }

        // ScreenCaptureKit decides which windows exist. Accessibility deliberately does not.
        //
        // `AXWindows` returns *success with an empty array* for an app whose accessibility tree is
        // not live, and Chromium and Electron build theirs only on demand — so an AX-driven list
        // previewed whichever app happened to be frontmost and showed nothing at all for Chrome,
        // VS Code, Spotify or GitHub Desktop. SC enumerates every app's windows whoever is active,
        // and hands over the window id, title and frame in the same pass.
        //
        // Layer 0 is the ordinary window layer; anything above it is a panel or overlay. Window id 0
        // is the "no id" sentinel and never names a real window.
        //
        // The title is the load-bearing filter, not the size. A single app carries a surprising
        // amount of layer-0 debris — several 2056x39 strips, 1x1 and 64x64 stubs, and for Chrome a
        // couple of full-width dropdown surfaces — and every one of them is untitled, while every
        // window a user could actually switch to has a title. Size alone let the dropdowns through.
        var live = content.windows.filter {
            $0.owningApplication?.processID == pid && $0.windowLayer == 0 && $0.windowID != 0
                && $0.frame.width > Self.minWindowSide && $0.frame.height > Self.minWindowSide
                && !($0.title ?? "").isEmpty
        }

        // Which of those are actually in the Dock.
        //
        // SC does list minimized windows — the comment that used to sit here said it could not see
        // them at all, and that is wrong: they arrive in `live` with a title and a full-size frame,
        // just with nothing to capture. So they were tiled as ordinary windows, and the only reason
        // they looked right was that the capture came back blank and fell through to the icon.
        //
        // A window in the Dock is on no Space and on no screen; a window on another Desktop is off
        // screen but still has a Space. Both reads are one window-server call each for the whole
        // strip, rather than a question per tile.
        let (dockedIDs, placed) = await Task.detached { Self.dockedWindowIDs() }.value

        // Asked once for the app, not once per window: it decides reachability for *every* thumbnail
        // in the strip, and it walks the whole system window list to answer. See `SwitchTarget.canReach`.
        let appOnScreen = await Task.detached {
            SwitchTarget.hasWindowOnScreen(pid: pid, placement: placed)
        }.value

        // Accessibility supplements the list for anything SC missed entirely, and — with the other
        // two channels in `claim` — vetoes what SC reports but the app does not actually have. It
        // still does not *drive* the list: an app that answers nothing through every channel keeps
        // every tile it has, which has to cost a stale thumbnail rather than the entire strip.
        let ax = await axWindows(for: pid)

        // The window server keeps a layer-0 surface — last title, full-size frame, still capturable —
        // long after the app has closed the window. Ghostty is the standing case: measured with two
        // tabs open it owned *seven*, four of them the same closed tab at the identical frame, so the
        // strip filled with convincing screenshots of tabs that had closed hours earlier.
        //
        // Nothing the window server knows separates those from a live window. Measured across every
        // field of `CGWindowListCopyWindowInfo` (alpha, store type, sharing state, memory usage) they
        // are byte-for-byte identical; all of them capture 100% opaque pixels, so `isBlank` never
        // rejects one; and no `CGSCopyWindowsWithOptionsAndTags` option value lists any of them, live
        // or dead. On Ghostty a live *background tab* has every one of those properties too — off
        // screen, on no Space, titled, fully capturable, at the same frame as the dead ones. Only the
        // app can say, and `claim` is where the three ways of asking it are ranked.
        //
        // Confined to the docked set, which is what keeps a mistake here cheap: a window on a Space
        // or on screen is never a candidate, so nothing the user is looking at can be removed by any
        // of this. And nothing is removed at all unless the app's answer accounts for at least one
        // window we can see — see `WindowClaim.vetoing`.
        // The app's Window menu, read only when there is something a veto could act on. Most apps
        // most of the time have no docked window at all, and this walks every menu in the bar.
        let hasDocked = live.contains { dockedIDs.contains($0.windowID) }
        let menuTitles = hasDocked ? await menuWindowTitles(for: pid) : []
        let claim = Self.claim(
            fresh: ax, menuTitles: menuTitles, remembered: lastUsableAX[pid], now: Date(),
            lifetime: usableAXLifetime)

        let vetoed = claim.vetoing(
            candidates: live.map {
                (id: $0.windowID, title: $0.title ?? "", unverified: dockedIDs.contains($0.windowID))
            })
        live.removeAll { vetoed.contains($0.windowID) }

        // And then collapse whatever identical copies are left — see `collapsingDuplicates`.
        //
        // Second line of defence rather than a duplicate of the first. The veto above is the better
        // answer when it can be given, and after it runs there is usually nothing here to collapse:
        // duplicates are unclaimed surfaces, which it has already removed. This is what stands when
        // it cannot be given — an app that says nothing through either channel and has no remembered
        // answer either — and unlike the veto it needs no cooperation from the app at all. It is
        // also the only one of the two that cannot cost a real window: a window the strip can vouch
        // for is never a candidate.
        let unclaimed = live.filter {
            dockedIDs.contains($0.windowID)
                && !claim.claims(id: $0.windowID, title: $0.title ?? "")
        }
        if unclaimed.count > 1 {
            let collapsible = Set(unclaimed.map(\.windowID))
            live = Self.collapsingDuplicates(
                live, unverified: { collapsible.contains($0.windowID) },
                key: { SurfaceKey(title: $0.title ?? "", frame: $0.frame) })
        }

        let liveIDs = Set(live.map(\.windowID))
        let minimized = ax.minimized.filter { !liveIDs.contains($0.id) }
        guard !live.isEmpty || !minimized.isEmpty, !Task.isCancelled else { return [] }

        // `NSScreen` is main-thread-only. Empty with a single display, which is what keeps the
        // display badge off the thumbnails for everyone who has one.
        let screenFrames = await MainActor.run {
            NSScreen.screens.count > 1 ? TargetProvider.screenCGFrames() : []
        }
        let icon = await MainActor.run { NSRunningApplication(processIdentifier: pid)?.icon }

        // SC hands back its windows front to back, which is the order the strip wants; whatever is
        // sitting in the Dock follows the windows that are actually on screen.
        var entries = live.map { window -> Entry in
            let isDocked = dockedIDs.contains(window.windowID)
            return Entry(
                // Docked windows are captured like any other. The comment that used to sit here
                // said their surface was gone and the round-trip would only fail its way to the
                // icon — measured against the docked set this code computes, that is wrong: the
                // window server keeps the backing surface, and every genuinely minimized window
                // returned real, non-blank pixels in 15-60ms. `isBlank` still catches the ones that
                // don't, so the icon remains the fallback rather than the default.
                id: window.windowID, title: window.title ?? "",
                window: window, isMinimized: isDocked,
                // A docked window's frame is where it *was*, which on a multi-display setup is not
                // where clicking it will take you. Badge nothing rather than the wrong monitor.
                displayIndex: isDocked
                    ? nil : WindowTiler.homeDisplay(of: window.frame, in: screenFrames),
                isReachable: SwitchTarget.canReach(
                    state: placed[window.windowID], appHasWindowOnScreen: appOnScreen))
        }
        entries += minimized.map {
            Entry(
                id: $0.id, title: $0.title, window: nil, isMinimized: true, displayIndex: nil,
                // In the Dock, so on no Space: `restoreFromDock` reaches it without a Desktop change.
                isReachable: true)
        }

        // Captured in bounded batches but reassembled by index, so the strip reads in the order
        // above rather than in whichever order the captures happened to come back.
        let wanted = Array(entries.prefix(maxCount))
        var built: [(Int, WindowThumb)] = []
        for start in stride(from: 0, to: wanted.count, by: maxConcurrentCaptures) {
            guard !Task.isCancelled else { break }
            let end = min(start + maxConcurrentCaptures, wanted.count)
            built += await withTaskGroup(of: (Int, WindowThumb?).self) { group in
                for index in start..<end {
                    let entry = wanted[index]
                    group.addTask {
                        let thumb = await Self.thumb(
                            at: index, for: entry, icon: icon, pid: pid, maxHeight: maxHeight)
                        return (index, thumb)
                    }
                }
                var out: [(Int, WindowThumb)] = []
                for await (index, thumb) in group {
                    if let thumb { out.append((index, thumb)) }
                }
                return out
            }
        }
        return built.sorted { $0.0 < $1.0 }.map { $0.1 }
    }

    /// Drops the caches when a session ends.
    ///
    /// Both TTLs are sub-second, so nothing would legitimately reuse these across sessions — but
    /// `content` holds an `SCWindow` for every window on the system and `axCache` gains an entry
    /// per app hovered. Left alone they stay resident for the life of the process, which for a
    /// menu-bar agent is the life of the login.
    func clearCaches() {
        content = nil
        contentFetchedAt = nil
        axCache.removeAll()
        // `lastUsableAX` deliberately survives. This runs at the end of *every* session, and the gap
        // it exists to bridge is far longer than one — an app that answers nothing for half a minute
        // answers nothing for the whole of the session too, so a remembered answer dropped here
        // would never once be there when it was wanted. It is also the cheap one: a set of window
        // ids per app hovered, against an `SCWindow` for every window on the system, and it ages out
        // on its own in `axWindows`.
    }

    /// One window's thumbnail: a live capture when there is one to be had, the app icon when there
    /// isn't. Returns nil for windows not worth a tile at all.
    private static func thumb(
        at index: Int, for entry: Entry, icon: NSImage?, pid: pid_t, maxHeight: CGFloat
    ) async -> WindowThumb? {
        guard !Task.isCancelled else { return nil }
        if let window = entry.window {
            if let image = try? await capture(window, maxHeight: maxHeight), !isBlank(image) {
                let size = NSSize(width: image.width, height: image.height)
                return WindowThumb(
                    id: index, windowID: entry.id, image: NSImage(cgImage: image, size: size),
                    title: entry.title, pid: pid, isMinimized: entry.isMinimized, hasCapture: true,
                    displayIndex: entry.displayIndex, isReachable: entry.isReachable)
            }
            // Captured blank: one of the invisible helper surfaces Electron and friends keep around
            // rather than a window anyone could switch to. An untitled one is dropped outright; a
            // titled one is real enough to earn the icon fallback below.
            guard !entry.title.isEmpty else { return nil }
        }
        let fallback =
            icon ?? NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil) ?? NSImage()
        return WindowThumb(
            id: index, windowID: entry.id, image: fallback, title: entry.title, pid: pid,
            isMinimized: entry.isMinimized, hasCapture: false, displayIndex: entry.displayIndex,
            isReachable: entry.isReachable)
    }

    /// The broken states worth one line each rather than one per hover.
    private enum CaptureFault { case permission, enumeration }
    private var reported: Set<CaptureFault> = []

    /// Logs `message` the first time a fault is seen, and stays quiet until it clears.
    private func reportOnce(_ fault: CaptureFault, _ message: String) {
        guard reported.insert(fault).inserted else { return }
        Log.general.error("\(message, privacy: .public)")
    }

    /// The full window list, reused for `ttl` so a sweep across tiles doesn't re-run the whole
    /// system-wide enumeration for each one.
    private func shareableContent() async -> SCShareableContent? {
        if let content, let contentFetchedAt, Date().timeIntervalSince(contentFetchedAt) < ttl {
            return content
        }
        guard
            let fresh = try? await SCShareableContent.excludingDesktopWindows(
                true, onScreenWindowsOnly: false)
        else { return nil }
        content = fresh
        contentFetchedAt = Date()
        return fresh
    }

    /// The windows that are sitting in the Dock: on no Space, and on no screen.
    ///
    /// Both halves are load-bearing. "On no Space" alone would also swallow a window whose Space
    /// read came back short, and "off screen" alone would swallow every window on another Desktop —
    /// which are exactly the ones the strip must keep offering as ordinary, capturable tiles.
    ///
    /// Empty when the Space read is unavailable at all, so a machine without the private symbols
    /// degrades to the old behaviour (docked windows tiled as live ones) rather than to labelling
    /// every window minimized.
    ///
    /// Hands back the placement map it had to build anyway. `windowSpaces` costs a window-server
    /// round trip *per Space*, and the reachability badge needs exactly the same map — asking twice
    /// would double the most expensive read on the hover path to learn something already in hand.
    private static func dockedWindowIDs() -> (
        docked: Set<CGWindowID>, placed: [CGWindowID: SpaceMover.SpaceState]
    ) {
        let placed = SpaceMover.windowSpaces()
        guard !placed.isEmpty else { return ([], [:]) }
        guard
            let list = CGWindowListCopyWindowInfo(
                [.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return ([], placed) }
        var out: Set<CGWindowID> = []
        for window in list {
            guard (window[kCGWindowLayer as String] as? Int) == 0,
                let id = window[kCGWindowNumber as String] as? CGWindowID, id != 0,
                placed[id] == nil,
                // Absent rather than false when the window is not being displayed.
                (window[kCGWindowIsOnscreen as String] as? Bool) != true
            else { continue }
            out.insert(id)
        }
        return (out, placed)
    }

    /// What the app itself says its windows are — cached for `ttl`.
    ///
    /// Best-effort by design: this is the one thing Accessibility is still asked for, and it answers
    /// with an empty list for any app whose tree is not live. Losing a minimized thumbnail for such
    /// an app — or keeping a stale tile it could have vetoed — is a far smaller failure than letting
    /// AX decide the whole strip, which is what it used to do. `resolvedEveryWindow` is what keeps
    /// the veto off those apps: an empty list is no answer, and a window that resolves to no
    /// `CGWindowID` (the Electron/Catalyst case) cannot be matched against SC's list either way, so
    /// a list carrying one is treated as unusable for removal rather than as proof the rest are gone.
    ///
    /// The AX work runs off the actor, on a detached task. Those calls are synchronous and do
    /// several `AXUIElementCopyAttributeValue` round-trips per window, each of which can burn the
    /// full AX timeout against a beach-balling app. Run inline there is no suspension point, so
    /// every other hover would queue behind the one wedged app and previews would stop appearing
    /// entirely until it cleared.
    /// A title with its leading decoration removed, for comparing one the app reports against one
    /// the window server does.
    ///
    /// They are the same string and they are read a moment apart, which for a terminal is long
    /// enough to matter: the title carries a status glyph that changes several times a second —
    /// measured on Ghostty, `◐ Features and improvements` from the window server against
    /// `◑ Features and improvements` from the menu, the same window a frame later. Everything
    /// before the first letter or digit goes, which covers spinner glyphs, the SF Symbols apps put
    /// in the private use area, and the dot an editor uses for unsaved changes.
    ///
    /// Applied to both sides, so over-stripping cannot make two different windows match — it can
    /// only fail to distinguish two that were already going to collide, which the collapse rule
    /// handles.
    nonisolated static func normalizedTitle(_ title: String) -> String {
        var rest = Substring(title)
        while let first = rest.first, !first.isLetter, !first.isNumber { rest = rest.dropFirst() }
        return rest.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// What the app is prepared to say are its own windows, and whether that is worth acting on.
    struct WindowClaim {
        /// Window ids Accessibility named.
        let ids: Set<CGWindowID>
        /// Normalized titles the app's Window menu named.
        let titles: Set<String>
        /// Whether any source answered at all. False means the app said nothing and nothing may be
        /// removed on its behalf.
        let canVeto: Bool

        func claims(id: CGWindowID, title: String) -> Bool {
            if ids.contains(id) { return true }
            let normalized = WindowCapture.normalizedTitle(title)
            return !normalized.isEmpty && titles.contains(normalized)
        }

        /// Which of `candidates` to drop — the unverifiable ones the app does not claim.
        ///
        /// `unverified` is the docked set: off screen *and* on no Space. Nothing on screen or on a
        /// Space is ever a candidate, which is what keeps a window the user is looking at safe from
        /// any mistake below.
        ///
        /// **Nothing is dropped unless something was kept.** If not one candidate is claimed, the
        /// answer does not describe the windows in front of us — a title scheme that does not
        /// correspond, an app whose menu names something else entirely — and removing everything on
        /// the strength of an answer we cannot corroborate is how a working preview becomes an empty
        /// one. One match is enough to show the two lists are talking about the same app.
        func vetoing(
            candidates: [(id: CGWindowID, title: String, unverified: Bool)]
        ) -> Set<CGWindowID> {
            guard canVeto else { return [] }
            guard candidates.contains(where: { claims(id: $0.id, title: $0.title) }) else { return [] }
            return Set(
                candidates.filter { $0.unverified && !claims(id: $0.id, title: $0.title) }
                    .map(\.id))
        }
    }

    /// Which source the veto acts on, in order of how well it describes the app *now*.
    ///
    /// Three channels, because the first one fails and the second one does not exist everywhere.
    ///
    /// **Accessibility's window list** is exact where it works, and it is the only one that yields
    /// ids. It also returns success with zero elements for long stretches — measured on Ghostty over
    /// three minutes, empty 30% of the time in unbroken runs of up to 27 seconds — and it
    /// under-reports for an app using native window tabbing, publishing one tab's window and not its
    /// siblings.
    ///
    /// **The app's Window menu** is the one AppKit maintains itself, one item per window, minimized
    /// windows included. It answers when the window list does not: measured with `AXWindows` at
    /// zero, the menu named both live Ghostty tabs and none of the four dead surfaces sharing their
    /// frame. It is found by the action selector its items carry rather than by the menu's title,
    /// which is localized. It gives titles rather than ids, which is why the comparison is
    /// normalized, and some apps populate no window items at all — Spotify names none — so it
    /// cannot be the only channel either.
    ///
    /// The two current sources are **unioned**, never ranked: each under-reports in a way the other
    /// does not, and a union can only keep more windows than either alone. Ghostty is the case that
    /// needs it — Accessibility named one tab, the menu named both.
    ///
    /// **The last usable Accessibility answer** is the fallback of last resort, used only when
    /// neither current source says anything. Stale by definition, so it is bounded by `lifetime`,
    /// and it contributes ids only.
    nonisolated static func claim(
        fresh: AXWindows, menuTitles: Set<String>,
        remembered: (windows: AXWindows, at: Date)?, now: Date, lifetime: TimeInterval
    ) -> WindowClaim {
        if fresh.resolvedEveryWindow || !menuTitles.isEmpty {
            return WindowClaim(
                ids: fresh.resolvedEveryWindow ? fresh.ids : [], titles: menuTitles, canVeto: true)
        }
        guard let remembered, remembered.windows.resolvedEveryWindow,
            now.timeIntervalSince(remembered.at) < lifetime
        else { return WindowClaim(ids: [], titles: [], canVeto: false) }
        return WindowClaim(ids: remembered.windows.ids, titles: [], canVeto: true)
    }

    private func axWindows(for pid: pid_t) async -> AXWindows {
        let now = Date()
        if let entry = axCache[pid], now.timeIntervalSince(entry.at) < ttl { return entry.windows }
        // Shed everything else that has aged out while we are here.
        axCache = axCache.filter { now.timeIntervalSince($0.value.at) < ttl }
        let windows = await Task.detached { () -> AXWindows in
            let elements = AX.windows(of: AX.application(pid)).filter(AX.isWindow)
            var ids: Set<CGWindowID> = []
            var minimized: [(id: CGWindowID, title: String)] = []
            var resolvedEvery = !elements.isEmpty
            for element in elements {
                let id = TargetProvider.windowID(element) ?? 0
                if id == 0 { resolvedEvery = false } else { ids.insert(id) }
                guard AX.isMinimized(element) else { continue }
                minimized.append((id, AX.copyString(element, kAXTitleAttribute) ?? ""))
            }
            return AXWindows(
                ids: ids, minimized: minimized, resolvedEveryWindow: resolvedEvery)
        }.value
        // Remembered before the substitution, so only a genuinely fresh answer ever becomes the one
        // future gaps fall back on — otherwise a remembered answer would keep renewing its own
        // timestamp and never age out.
        if windows.resolvedEveryWindow { lastUsableAX[pid] = (windows, now) }
        lastUsableAX = lastUsableAX.filter { now.timeIntervalSince($0.value.at) < usableAXLifetime }
        axCache[pid] = (windows, now)
        return windows
    }

    /// The normalized titles of the window entries in an app's menu bar — cached for `ttl`.
    ///
    /// Found by the **action selector** its items carry (`makeKeyAndOrderFront:`) rather than by
    /// looking for a menu called "Window", which is localized and would find nothing on a French
    /// system. AppKit sets that action on every item it adds to the windows menu, so the test is
    /// structural: these are the entries that raise a window, whatever the menu is called.
    ///
    /// Read only when the caller has something a veto could remove — see `thumbnails`. It walks
    /// every menu in the bar reading one attribute per item, measured at 11–34ms per app, which is
    /// cheap for a background queue and not cheap enough to pay for on every hover of every tile.
    ///
    /// Off the actor for the same reason `axWindows` is: these are synchronous Accessibility calls
    /// into another process, and one beach-balling app must not stall every other preview behind it.
    private func menuWindowTitles(for pid: pid_t) async -> Set<String> {
        let now = Date()
        if let entry = menuCache[pid], now.timeIntervalSince(entry.at) < ttl { return entry.titles }
        menuCache = menuCache.filter { now.timeIntervalSince($0.value.at) < ttl }
        let titles = await Task.detached { () -> Set<String> in
            guard let bar = AX.copyElement(AX.application(pid), kAXMenuBarAttribute as String)
            else { return [] }
            var out: Set<String> = []
            for top in AX.children(of: bar) {
                for menu in AX.children(of: top) {
                    for item in AX.children(of: menu) {
                        guard AX.copyString(item, kAXIdentifierAttribute as String)
                            == Self.raiseWindowAction,
                            let title = AX.copyString(item, kAXTitleAttribute as String)
                        else { continue }
                        let normalized = Self.normalizedTitle(title)
                        if !normalized.isEmpty { out.insert(normalized) }
                    }
                }
            }
            return out
        }.value
        menuCache[pid] = (titles, now)
        return titles
    }

    /// The AppKit action every windows-menu item carries. Not localized, unlike the menu's title.
    private static let raiseWindowAction = "makeKeyAndOrderFront:"

    private static func capture(_ window: SCWindow, maxHeight: CGFloat) async throws -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        // Rendered straight to thumbnail size rather than captured full-res and scaled after.
        let scale = min(1, maxHeight / max(window.frame.height, 1))
        config.width = max(Int(window.frame.width * scale), 1)
        config.height = max(Int(window.frame.height * scale), 1)
        config.showsCursor = false
        return try await SCScreenshotManager.captureImage(
            contentFilter: filter, configuration: config)
    }

    /// Shared with `TileThumbnails`, which needs the identical verdict: the phantom windows this
    /// rejects are a property of the *app*, not of which feature is looking at it.
    nonisolated static func isBlankImage(_ image: CGImage) -> Bool { isBlank(image) }

    /// Whether a capture came back essentially empty. Downsamples to a small grid and counts pixels
    /// carrying any alpha, which separates a real (opaque) window from a hidden helper window's
    /// fully transparent surface.
    private static func isBlank(_ image: CGImage) -> Bool {
        let side = 16
        var data = [UInt8](repeating: 0, count: side * side * 4)
        let space = CGColorSpaceCreateDeviceRGB()
        // Created, drawn and read entirely inside the closure. Passing `&data` to `CGContext` would
        // be an inout-to-pointer conversion, valid only for the duration of the initializer call —
        // but the context keeps the pointer and writes through it during `draw`, after that call
        // has returned. The compiler may hand over a temporary buffer and copy back, in which case
        // `draw` scribbles on freed memory and the verdict below is read from uninitialized bytes.
        return data.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress,
                let ctx = CGContext(
                    data: base, width: side, height: side, bitsPerComponent: 8,
                    bytesPerRow: side * 4, space: space,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: side, height: side))
            var opaque = 0
            for i in stride(from: 3, to: raw.count, by: 4) where raw[i] > 8 { opaque += 1 }
            // A real window fills nearly the whole frame; a transparent phantom leaves it near-empty.
            return opaque < (side * side) / 10
        }
    }
}

// MARK: - The floating strip

/// Backing store for the strip's SwiftUI content.
@MainActor
private final class PreviewStripModel: ObservableObject {
    @Published var thumbs: [WindowThumb] = []
    /// The app whose windows are shown, as a heading over the strip.
    @Published var appName: String = ""
    /// The thumbnail under the cursor, so the click target is visible before it is clicked.
    @Published var hovered: Int?
    /// Bumped on every `present`. See `ThumbKey` — this is what keeps a click honest.
    @Published var generation = 0
    /// Each thumbnail's frame in the panel's content coordinates (top-left origin), reported by the
    /// view so the panel can hit-test a click. Not `@Published` — it only feeds the panel.
    var thumbFrames: [ThumbKey: CGRect] = [:]
}

/// Identifies a reported thumbnail frame: which strip it belongs to, and which position in it.
///
/// The generation is what makes a click safe. `onPreferenceChange` only fires when the reported
/// value actually *changes*, so the frame map cannot simply be cleared on each present — an app
/// whose strip lays out identically to the previous one would report identical frames, no callback
/// would arrive, and the map would sit empty and unclickable. Carrying the generation in the key
/// means every present reports a value that differs from the last, *and* frames left over from the
/// previous strip fail to match the current generation rather than resolving, by position, to
/// whatever window now happens to occupy that slot.
private struct ThumbKey: Hashable {
    let generation: Int
    let index: Int
}

/// Reports each thumbnail's laid-out frame up to the panel for click hit-testing.
private struct ThumbFrameKey: PreferenceKey {
    static let defaultValue: [ThumbKey: CGRect] = [:]
    static func reduce(value: inout [ThumbKey: CGRect], nextValue: () -> [ThumbKey: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { first, _ in first })
    }
}

private struct PreviewStripView: View {
    @ObservedObject var model: PreviewStripModel

    /// The coordinate space the reported frames are measured in — the panel's own content, so a
    /// screen click maps onto them after nothing more than a flip.
    static let space = "windowPreview"

    /// How many thumbnails sit in a row before wrapping, so an app with many windows grows downward
    /// rather than off the side of the screen.
    private static let perRow = 4

    private var rows: [[WindowThumb]] {
        stride(from: 0, to: model.thumbs.count, by: Self.perRow).map {
            Array(model.thumbs[$0..<min($0 + Self.perRow, model.thumbs.count)])
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !model.appName.isEmpty {
                Text(model.appName)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 2)
            }
            VStack(alignment: .leading, spacing: 10) {
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(row) { thumb in
                            cell(thumb)
                        }
                    }
                }
            }
        }
        .padding(12)
        .background(VisualEffectBackground(material: .hudWindow))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        )
        .fixedSize()
        .coordinateSpace(name: Self.space)
        .onPreferenceChange(ThumbFrameKey.self) { model.thumbFrames = $0 }
    }

    @ViewBuilder
    private func cell(_ thumb: WindowThumb) -> some View {
        let isHovered = model.hovered == thumb.id
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                image(thumb)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .strokeBorder(
                                isHovered ? Color.accentColor : Color.primary.opacity(0.15),
                                lineWidth: isHovered ? 3 : 1)
                    )
                if thumb.isMinimized {
                    Image(systemName: "minus.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .orange)
                        .padding(4)
                }
            }
            // Dimmed as well as badged. The badge says *why*; the dimming is what stops the tile
            // reading as an ordinary click target in the half-second before anyone reads a badge.
            .opacity(thumb.isReachable ? 1 : 0.45)
            .overlay(alignment: .topTrailing) {
                if let display = thumb.displayIndex {
                    DisplayBadge(number: display + 1)  // 1-based for humans
                        .padding(4)
                }
            }
            .overlay(alignment: .bottomLeading) {
                if !thumb.isReachable {
                    // Its own corner: a window can be both minimized and unreachable in principle,
                    // and two badges stacked in one corner would occlude each other.
                    //
                    // A two-layer symbol, like the minimized badge, so the fill carries the colour
                    // and the glyph stays white. A single-layer one (`nosign`) takes only the
                    // primary style and would draw white-on-white over a pale thumbnail.
                    Image(systemName: "exclamationmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(.white, .red)
                        .padding(4)
                }
            }
            if !thumb.title.isEmpty {
                Text(thumb.title)
                    .font(.system(size: 10))
                    .foregroundStyle(isHovered ? .primary : .secondary)
                    .lineLimit(1)
                    .frame(maxWidth: 160)
            }
        }
        // The whole cell — image and title — is the click target, so report its frame rather than
        // the image's.
        .background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: ThumbFrameKey.self,
                    value: [
                        ThumbKey(generation: model.generation, index: thumb.id):
                            geo.frame(in: .named(Self.space))
                    ])
            })
    }

    @ViewBuilder
    private func image(_ thumb: WindowThumb) -> some View {
        if !thumb.hasCapture {
            // The app icon, padded into a tile the size a real capture would be, so a window that
            // wouldn't capture doesn't collapse the row it is in.
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: 64, height: 64)
                .padding(20)
                .background(Color.primary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        } else {
            Image(nsImage: thumb.image)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: 220, maxHeight: 150)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
    }
}

/// The small non-activating panel that floats the thumbnails next to the hovered tile.
///
/// It never takes the keyboard and never becomes key, but a click on a thumbnail becomes a pick —
/// the same arrangement, for the same reason, as the switcher panel's own tile clicks.
@MainActor
final class WindowPreviewPanel: NSPanel {
    private let content = PreviewStripModel()
    private var host: NSHostingView<PreviewStripView>?

    /// Gap between the switcher and the strip.
    private let gap: CGFloat = 10

    /// Invoked when a thumbnail is clicked, so the controller can focus that window and dismiss.
    var onPick: ((WindowThumb) -> Void)?
    /// A scroll that landed on the strip instead of the switcher, forwarded so scroll-to-navigate
    /// keeps working (the switcher's global monitor cannot see events delivered to our own panel).
    var onScroll: ((NSEvent) -> Void)?

    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 10, height: 10),
            styleMask: [.nonactivatingPanel, .borderless],
            backing: .buffered,
            defer: false)
        isFloatingPanel = true
        level = .popUpMenu
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle, .stationary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovable = false
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A non-activating panel receives clicks without bringing our app forward, so a click on a
    /// thumbnail can be turned straight into a pick. Handled here rather than in SwiftUI because the
    /// panel is never key, which leaves SwiftUI's own gesture recognisers dormant.
    override func sendEvent(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown:
            if let thumb = thumb(at: NSEvent.mouseLocation) {
                onPick?(thumb)
                return
            }
        case .scrollWheel:
            onScroll?(event)
            return
        default:
            break
        }
        super.sendEvent(event)
    }

    /// Whether the strip is up and covering `point`. Hover tracking asks this so the strip stays
    /// alive — and stays clickable — while the cursor is on it.
    func isShowing(_ screenPoint: NSPoint) -> Bool {
        isVisible && frame.contains(screenPoint)
    }

    /// Moves the hover highlight to whatever the cursor is over. Driven from the switcher's cursor
    /// poll: mouse-moved events only go to the key window, and this panel is never key.
    func setHover(at screenPoint: NSPoint) {
        let id = thumb(at: screenPoint)?.id
        guard content.hovered != id else { return }
        content.hovered = id
    }

    /// The thumbnail under a screen point, from the frames the view reported for the strip that is
    /// on screen now. A frame from an earlier strip is ignored rather than trusted — see `ThumbKey`.
    private func thumb(at screenPoint: NSPoint) -> WindowThumb? {
        // Content coordinates are top-left origin; flip the bottom-up screen point into them.
        let point = CGPoint(x: screenPoint.x - frame.minX, y: frame.maxY - screenPoint.y)
        let generation = content.generation
        guard
            let key = content.thumbFrames.first(where: {
                $0.key.generation == generation && $0.value.contains(point)
            })?.key
        else { return nil }
        return content.thumbs.first { $0.id == key.index }
    }

    /// Shows `thumbs` for `appName`, centred on the hovered tile and clear of the switcher panel
    /// that tile belongs to — which under mirroring is not necessarily the one under the cursor.
    func present(
        thumbs: [WindowThumb], appName: String, over tileRect: NSRect,
        placement: PanelGroup.PreviewPlacement
    ) {
        // Driven through the observed model: the hosting view is built once and reused, sizing
        // itself to the content rather than being torn down and rebuilt on every hover.
        content.generation &+= 1
        content.thumbs = thumbs
        content.appName = appName
        content.hovered = nil
        self.appearance = placement.appearance

        let host: NSHostingView<PreviewStripView>
        if let existing = self.host {
            host = existing
        } else {
            host = NSHostingView(rootView: PreviewStripView(model: content))
            host.sizingOptions = [.intrinsicContentSize]
            self.host = host
            contentView = host
        }
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        setContentSize(size)
        setFrameOrigin(origin(for: size, over: tileRect, placement: placement))
        orderFrontRegardless()
        // Geometry only — where a floating panel landed is the first thing worth knowing when it
        // lands somewhere wrong, and a rect names no windows, apps or documents.
        Log.general.notice("preview strip at \(NSStringFromRect(self.frame), privacy: .public)")
    }

    /// Centres the strip on the hovered tile but places it above or below the *whole* switcher panel,
    /// so it never floats over the other tiles — which, since it takes clicks, would make them
    /// unhoverable and unclickable.
    private func origin(
        for size: CGSize, over tileRect: NSRect, placement: PanelGroup.PreviewPlacement
    ) -> NSPoint {
        let visible = placement.visibleFrame
        let switcher = placement.panelFrame
        let above = switcher.maxY + gap
        let below = switcher.minY - gap - size.height
        let roomAbove = visible.maxY - above
        let roomBelow = (switcher.minY - gap) - visible.minY

        // Prefer above, then below. When it fits in neither, anchor it into the larger gap and let
        // it run off the screen edge rather than clamping it back on — clamping drops the strip on
        // top of the switcher, which is precisely the overlap this placement exists to avoid.
        let y: CGFloat
        if size.height <= roomAbove {
            y = above
        } else if size.height <= roomBelow {
            y = below
        } else {
            y = roomAbove >= roomBelow ? above : below
        }

        let maxX = max(visible.minX, visible.maxX - size.width)
        let x = (tileRect.midX - size.width / 2).clamped(to: visible.minX...maxX)
        return NSPoint(x: x, y: y)
    }

    func dismiss() {
        orderOut(nil)
        content.hovered = nil
        // Dropped rather than left for the next `present` to overwrite. A thumb holds a live
        // ScreenCaptureKit capture and the window title beside it, and this panel outlives every
        // session — a user who hovers once and never again would keep that set resident for the
        // life of the login. Same rule `WindowCapture.clearCaches` and `TileThumbnails.cancel`
        // already follow. Safe: `thumb(at:)` and `setHover(at:)` are gated on `isShowing`, and
        // `present` reassigns every field before ordering back in.
        content.thumbs = []
        content.appName = ""
    }
}
