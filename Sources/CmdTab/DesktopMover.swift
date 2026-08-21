import AppKit
import ApplicationServices
import CoreGraphics

// Moves a window to another Desktop (Space) by performing the gesture a person would: pick the
// window up by its title bar, open Mission Control while still holding it, and drop it on the
// destination's thumbnail in the Spaces Bar.
//
// This exists because there is no API for it and there is not going to be one. `SpaceMover`'s
// header lists the SkyLight routes — `CGSMoveWindowsToManagedSpace`, `SLSMoveWindowsToManagedSpace`,
// the `RemoveWindowsFromSpaces`/`AddWindowsToSpaces` pair — and every one of them is accepted and
// then silently ignored. Re-measured on macOS 26.6.2 against a window owned by a *second process of
// our own*, so the failure is not an artefact of picking a hostile target: all four did nothing,
// and the same call moved the calling process's **own** window on the first try. So the calls are
// alive and gated on ownership, exactly as the old note said, and the only way to move somebody
// else's window is to be the window server's own drag machinery — or to drive it.
//
// Three cheaper routes were measured dead before settling on this one, and they are recorded here
// so the next person does not spend the afternoon re-measuring them:
//
//   - **Synthetic ⌃-arrow.** Mission Control's own "move one space" chord, posted as a faithful
//     press (a real `flagsChanged` for Control, then the arrow down/up) across all three
//     `CGEventSourceStateID`s. Nothing moved. The symbolic hotkeys were verified *enabled* in
//     `com.apple.symbolichotkeys` first, so this is the window server refusing synthetic input for
//     its own hotkeys rather than an unbound shortcut.
//   - **Drag plus the private switch.** Pick the window up, then switch Spaces with the
//     `CGSShowSpaces`/`CGSHideSpaces`/`CGSManagedDisplaySetCurrentSpace` trio `SpaceMover.reveal`
//     uses. The display switched and the window stayed behind: the carry is tied to a real
//     transition, and that trio is a bookkeeping write.
//   - **Drag to the screen edge and hold.** Three seconds pinned against the right edge mid-drag,
//     no switch. macOS does not do edge-switching for window drags.
//
// What is left is the real gesture, and it does work — verified end to end before any of this was
// written. It is slower and more visible than a private call would be (Mission Control opens for
// roughly half a second), and it drives the pointer, which is why `WindowTilingBindings.desktopMoves`
// keeps it behind a switch of its own rather than shipping it live like the display moves.
enum DesktopMover {
    /// Serial on purpose. A move holds the mouse button down for the length of the gesture; two of them
    /// interleaved would fight over the pointer and leave a button stuck down. Key repeat on a
    /// bound chord makes that the *likely* case, not the exotic one — `isMoving` below turns the
    /// second press into a no-op rather than queueing it up to run the whole gesture again.
    private static let queue = DispatchQueue(label: "com.cmdtab.desktopmove", qos: .userInitiated)

    /// Whether a move is in flight, claimed by `move` *before* it dispatches.
    ///
    /// The claim has to happen on the caller's thread, and that is the whole point of the lock. This
    /// used to be set inside the `queue.async` block, which cannot work: the queue is serial, so a
    /// second block does not run until the first has finished and already cleared the flag. The
    /// guard could therefore never fire, and holding the chord down — key auto-repeat, which is the
    /// ordinary way this gets pressed twice — queued a move per repeat and walked the window across
    /// several Desktops. Measured before the fix: a burst of five presses moved it two Desktops.
    ///
    /// Rejecting rather than coalescing. A held key means "go one Desktop", not "keep going".
    private nonisolated(unsafe) static var isMoving = false

    /// Guards `isMoving` across the tap callback and `queue`. `NSLock` to match the other
    /// cross-thread flags in this app; uncontended in every real case.
    private static let lock = NSLock()

    private typealias CoreDockSendNotificationFn = @convention(c) (CFString, Int32) -> Void

    /// `nonisolated(unsafe)` for the same reason as `SpaceMover.handle`: a dyld handle is an opaque
    /// pointer and so not `Sendable`, but it is a `let` initialised once by the runtime's
    /// thread-safe lazy-static machinery, and `dlsym` against it is itself thread-safe.
    private nonisolated(unsafe) static let dockNotify: CoreDockSendNotificationFn? = {
        guard
            let handle = dlopen(
                "/System/Library/Frameworks/ApplicationServices.framework/Versions/A/ApplicationServices",
                RTLD_LAZY),
            let symbol = dlsym(handle, "CoreDockSendNotification")
        else { return nil }
        return unsafeBitCast(symbol, to: CoreDockSendNotificationFn.self)
    }()

    /// The notification that toggles Mission Control. The Dock listens for this itself, which is
    /// what makes it work mid-drag — posting the keyboard shortcut instead is the route measured
    /// dead in the header.
    /// Held as a `String` and bridged at the call site: a `CFString` constant is not `Sendable`,
    /// and this type is reached from `queue`.
    private static let missionControl = "com.apple.expose.awake"

    static var isAvailable: Bool { dockNotify != nil }

    /// Moves the focused window of `pid` `step` Desktops along, clamped to the ends.
    ///
    /// Clamped rather than wrapped, unlike the display moves. Wrapping a window from the last
    /// Desktop round to the first is a long way for a key to throw something, and the Desktop a
    /// window lands on is much harder to find again than the display it landed on — a display is in
    /// front of you either way.
    ///
    /// Returns immediately; everything happens on `queue`. The caller is the event-tap callback,
    /// where a stall costs the user every keystroke on the machine, and this gesture takes seconds.
    /// `follow` switches the display to the destination once the window lands, so you arrive with
    /// the window instead of watching it leave.
    static func move(pid: pid_t, step: Int, follow: Bool) {
        guard step != 0 else { return }
        guard beginIfIdle() else {
            Log.general.notice("desktop move: already moving a window; ignoring")
            return
        }
        queue.async {
            defer { end() }
            perform(pid: pid, step: step, follow: follow)
        }
    }

    /// Claims the gesture, or reports that one is already running.
    ///
    /// Split out from `move` so the invariant can be tested without a window, a Desktop or three
    /// seconds — the bug this replaced was not in the gesture but in *where* the claim happened, and
    /// that is exactly what a test can pin down cheaply. Internal for the same reason.
    static func beginIfIdle() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !isMoving else { return false }
        isMoving = true
        return true
    }

    /// Releases the claim taken by `beginIfIdle`.
    static func end() {
        lock.lock()
        isMoving = false
        lock.unlock()
    }

    // MARK: - The gesture

    private static func perform(pid: pid_t, step: Int, follow: Bool) {
        guard let dockNotify else {
            Log.general.notice("desktop move: CoreDockSendNotification unavailable")
            return
        }
        // Not while the user is holding the button themselves. The gesture posts its own press and
        // release, and interleaving those with a real drag in progress leaves the window server with
        // a press it never sees released — and drops whatever the user was actually dragging.
        guard !CGEventSource.buttonState(.combinedSessionState, button: .left) else {
            Log.general.notice("desktop move: the mouse button is already down; ignoring")
            return
        }
        guard let plan = plan(pid: pid, step: step) else { return }

        // From here the mouse button is down and Mission Control is on its way up, so every exit
        // has to put both back. A `defer` rather than a tidy path at the bottom: the middle of this
        // gives up in five different places, and a button left down is the one failure the user
        // cannot recover from without clicking something themselves.
        let cursor = CGEvent(source: nil)?.location
        var released = false
        // Hoisted above the `defer` so the cleanup can see whether the window was ever picked up.
        var grabbed = false
        defer {
            // Only if the gesture did not get as far as its own release. A second `leftMouseUp` is
            // not free — it lands wherever the pointer is, which after a follow is the menu bar —
            // and posting one for tidiness on the path that already released is how a stray click
            // gets into somebody's session.
            if !released { release(at: CGEvent(source: nil)?.location ?? plan.grab) }
            closeMissionControlIfOpen()
            awaitMissionControlGone()
            // Every path that picked the window up puts it back, not just the one that finished.
            // The engage drag nudges the window before Mission Control is even asked for, so a
            // gesture that gives up after that — the Spaces Bar never appearing is the realistic
            // case — used to leave the window sitting a few dozen pixels from where it started, with
            // nothing to say why. Restoring here covers the successful path too, which is why there
            // is no longer a separate call at the end.
            if grabbed { restore(plan) }
            if let cursor {
                CGWarpMouseCursorPosition(cursor)
                CGAssociateMouseAndMouseCursorPosition(1)
            }
        }

        CGWarpMouseCursorPosition(plan.grab)
        usleep(cursorSettle)
        post(.leftMouseDown, plan.grab)
        usleep(pressSettle)

        // Small drags until the window actually moves. The window server does not treat a bare
        // mouse-down as a drag in progress, and opening Mission Control without one leaves the
        // window behind and simply shows Mission Control — so something has to convince it first.
        //
        // How many events that takes varies with what the owning app does on its mouse-down, and a
        // fixed count has to be the worst case for everyone. `didGrab` is the exact signal, so it is
        // the loop condition rather than a check afterwards.
        var point = plan.grab
        for index in 1...engageStepLimit {
            point = CGPoint(x: plan.grab.x + CGFloat(index) * 5, y: plan.grab.y - CGFloat(index) * 2)
            post(.leftMouseDragged, point, dx: 5, dy: -2)
            usleep(stepInterval)
            if didGrab(window: plan.window, from: plan.bounds) {
                grabbed = true
                break
            }
        }
        guard grabbed else {
            Log.general.notice(
                "desktop move: window \(plan.window, privacy: .public) did not follow the drag")
            return
        }

        dockNotify(missionControl as CFString, 0)
        // Polled rather than slept. Mission Control's open animation is not a fixed cost — it is
        // slower with many windows on the Desktop, and a fixed wait long enough for the worst case
        // is a wait everyone pays. The drag has to be kept alive while we wait, or the window server
        // drops it.
        guard let target = awaitSpacesBar(
            holdingAt: point, index: plan.destination, on: plan.display)
        else {
            Log.general.notice("desktop move: Mission Control's Spaces Bar never appeared")
            return
        }

        // Ease onto the thumbnail rather than jumping. A single event at the destination is a
        // teleport, and the Spaces Bar does not light up as a drop target for one.
        for index in 1...travelSteps {
            let t = CGFloat(index) / CGFloat(travelSteps)
            let next = CGPoint(
                x: point.x + (target.x - point.x) * t, y: point.y + (target.y - point.y) * t)
            post(.leftMouseDragged, next, dx: next.x - point.x, dy: next.y - point.y)
            point = next
            usleep(stepInterval)
        }
        // Settle on the target so the Spaces Bar registers the hover before the drop.
        for _ in 1...hoverSteps {
            post(.leftMouseDragged, target)
            usleep(stepInterval)
        }
        release(at: target)
        released = true
        // One line, either way. This used to log "did not land" and then "dropped on desktop N"
        // immediately after, which is a contradiction to read back at three in the morning.
        if awaitLanding(plan) {
            Log.general.notice(
                """
                desktop move: window \(plan.window, privacy: .public) dropped on desktop \
                \(plan.destination + 1, privacy: .public)
                """)
        } else {
            Log.general.notice(
                """
                desktop move: window \(plan.window, privacy: .public) did not land on desktop \
                \(plan.destination + 1, privacy: .public); leaving it where it is
                """)
        }

        // Only the follow happens here. Closing Mission Control, waiting for it to go and putting
        // the window back are all in the `defer`, because they have to happen however this ends —
        // and the frame write in particular has to come after the overlay has gone, since a window
        // is still the drag's to place while it is up.
        if follow { followTo(plan.destination, on: plan.display) }
    }

    /// Waits for the window to actually arrive on the destination Desktop.
    ///
    /// The drop is what moves the window and it is not synchronous, so something has to wait for it.
    /// Polling the window's Space is waiting for the thing itself; the fixed sleep this replaced had
    /// to be long enough for the worst case, which meant every move paid it. Returns false if it
    /// never arrives, which is a real outcome — a drop that misses the thumbnail leaves the window
    /// where it was.
    ///
    /// This calls `spaceState` in a loop, which its own documentation warns against — it costs a
    /// window-server round trip per Space every time. The warning is aimed at callers placing *many*
    /// windows, which should take one `windowSpaces()` map instead; here there is one window and the
    /// answer changes underneath us, so re-reading is the point. It is bounded twice over: the loop
    /// gives up after `landingTimeout`, and in practice it is measured to return on the first or
    /// second look, because the drop has usually landed before the release finishes.
    private static func awaitLanding(_ plan: Plan) -> Bool {
        for _ in 0..<Int(landingTimeout / pollInterval) {
            if SpaceMover.spaceState(of: plan.window)?.windowSpace == plan.destinationSpace {
                return true
            }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        return false
    }

    /// Waits for Mission Control to leave the screen, so the frame write below is not swallowed.
    ///
    /// Same trade as `awaitLanding`: the Spaces Bar vanishing from the Dock's Accessibility tree is
    /// the exact signal, where the sleep it replaced was a guess sized for a slow machine.
    private static func awaitMissionControlGone() {
        for _ in 0..<Int(closeTimeout / pollInterval) {
            if spacesBarFrame() == nil { return }
            usleep(useconds_t(pollInterval * 1_000_000))
        }
        Log.general.notice("desktop move: Mission Control did not close; restoring anyway")
    }

    /// Puts the window back on the frame it had before the gesture.
    ///
    /// The drag is a real drag, so the window genuinely travels with the cursor — up to the Spaces
    /// Bar at the top of the screen, which is nowhere near where it started — and macOS drops it on
    /// the destination Desktop wherever the gesture left it, not where it began. Left alone that
    /// reads as the feature moving the window *and* shoving it into a corner, which is the reported
    /// "it offsets to the left".
    ///
    /// A restore rather than a cleverer drag path: there is no cursor route to the Spaces Bar that
    /// also leaves the window where it started, because the window follows the cursor by
    /// construction. The frame is known exactly — it was read before anything moved — so writing it
    /// back is both simpler and more accurate than trying not to disturb it.
    ///
    /// `sizing: true` even though a move should not have resized anything: dropping onto a Desktop
    /// whose display has a different resolution can hand the window back a different size, and the
    /// promise here is the frame it had, not merely the origin.
    private static func restore(_ plan: Plan) {
        guard let now = windowBounds(plan.window), now != plan.bounds else { return }
        Log.general.notice(
            """
            desktop move: restoring window \(plan.window, privacy: .public) to its original frame
            """)
        AX.setFrame(plan.element, plan.bounds, sizing: true, repositionAfterSizing: true)
    }

    /// Switches the display to the Desktop the window landed on, by pressing its thumbnail.
    ///
    /// Pressed repeatedly until Mission Control actually goes away, rather than once and hopefully.
    /// The press is accepted (`AXError` 0) well before it is *acted on*: coming straight off a drop
    /// that has only just landed, the first press is reliably swallowed, and the old code's cover
    /// for that was a fixed 400ms sleep before it — which every move paid whether it needed it or
    /// not, and which this loop replaces with the signal itself. Mission Control leaving the Dock's
    /// Accessibility tree is that signal.
    ///
    /// Repeating is safe: a press that was acted on takes the Spaces Bar with it, so the loop stops
    /// before it can press anything twice. Returns false if it never closes, and the caller falls
    /// back to shutting Mission Control the ordinary way.
    @discardableResult
    private static func followTo(_ destination: Int, on display: CGRect?) -> Bool {
        // Pressing the thumbnail is the whole of the follow, and it is a better switch than
        // anything this app could issue itself.
        //
        // The obvious alternative is `SpaceMover.reveal`, which is right there and already knows how
        // to point a display at a Space. It is the wrong tool here: that trio is a bookkeeping write
        // — measured, in this file's own header, to move the window server's record without making
        // the display perform a transition — and it is the exact mechanism behind the "the window
        // came over to my Desktop and went back" bug `SpaceMover.reveal` documents at length.
        //
        // This button is the control macOS itself draws for "go to that Desktop": its
        // `AXDescription` is literally "exit to Desktop 3". Pressing it is a real transition,
        // performed by the window server, and it closes Mission Control on the way out — so the
        // `defer` above finds the Spaces Bar already gone and leaves it alone.
        //
        // Re-read rather than reused from `awaitSpacesBar`: a window has just landed on that
        // thumbnail, which re-lays out the Spaces Bar, and an element captured before the drop can
        // be stale by the time we get here.
        for attempt in 1...followAttempts {
            // Re-read every time: the drop re-lays out the Spaces Bar, and a press already
            // half-accepted can leave a stale element behind.
            let buttons = desktopButtons(on: display)
            guard buttons.indices.contains(destination) else {
                Log.general.notice("desktop move: no thumbnail to follow to; staying put")
                return false
            }
            let result = AXUIElementPerformAction(
                buttons[destination].element, kAXPressAction as CFString)
            for _ in 0..<Int(followPressTimeout / pollInterval) {
                usleep(useconds_t(pollInterval * 1_000_000))
                guard spacesBarFrame() == nil else { continue }
                Log.general.notice(
                    """
                    desktop move: followed to desktop \(destination + 1, privacy: .public) \
                    on press \(attempt, privacy: .public) (\(result.rawValue, privacy: .public))
                    """)
                return true
            }
        }
        Log.general.notice("desktop move: Mission Control ignored the follow press")
        return false
    }

    /// Everything the gesture needs, resolved before a single event is posted.
    private struct Plan {
        let window: CGWindowID
        /// The Accessibility element, kept so the original frame can be written back after the
        /// gesture. Resolving it again afterwards would be a second walk of the app's window list
        /// for a window we already have in hand.
        let element: AXUIElement
        /// The frame the window had *before* the gesture. Both the reference `didGrab` compares
        /// against and the frame restored at the end.
        let bounds: CGRect
        /// Where to take hold of the window: the middle of its title bar.
        let grab: CGPoint
        /// 0-based index of the destination Desktop within its display's Spaces Bar.
        let destination: Int
        /// The destination's Space id. The drop is confirmed against this rather than slept
        /// through — see `awaitLanding`.
        let destinationSpace: UInt64
        /// The rectangle of the display the window is on, used to pick that display's Spaces Bar out
        /// of Mission Control. nil when it cannot be worked out, which falls back to taking the
        /// whole screen's worth — see `desktopButtons(on:)`.
        let display: CGRect?
    }

    /// Resolves the window, checks it can actually be dragged, and works out which Desktop to aim
    /// at. nil when any of that fails, and each failure says why — a gesture this visible must not
    /// start at all if it cannot finish.
    private static func plan(pid: pid_t, step: Int) -> Plan? {
        guard let element = AX.frontWindow(ofApplication: pid) else {
            Log.general.notice("desktop move: no front window for pid \(pid, privacy: .public)")
            return nil
        }
        // A full-screen window has no title bar to grab and occupies a Space of its own, so there
        // is nothing here for it to move between.
        if AX.copyBool(element, "AXFullScreen") == true {
            Log.general.notice("desktop move: window is full screen; nothing to move")
            return nil
        }
        if AX.isMinimized(element) {
            Log.general.notice("desktop move: window is minimized; nothing to drag")
            return nil
        }
        guard let window = TargetProvider.windowID(element)
            ?? TargetProvider.windowID(matching: element, pid: pid)
        else {
            Log.general.notice("desktop move: could not resolve a window number")
            return nil
        }
        guard let bounds = windowBounds(window) else {
            Log.general.notice("desktop move: window \(window, privacy: .public) has no bounds")
            return nil
        }

        // The title bar's midpoint, and then a check that the point really belongs to this window.
        // Without it a covered window would hand the drag to whatever is on top of it, and the
        // gesture would move a window the user never selected — much worse than doing nothing.
        let grab = CGPoint(x: bounds.midX, y: bounds.minY + titlebarInset)
        guard topWindow(at: grab) == window else {
            Log.general.notice(
                "desktop move: window \(window, privacy: .public) is covered at its title bar")
            return nil
        }

        guard let state = SpaceMover.spaceState(of: window) else {
            Log.general.notice("desktop move: window \(window, privacy: .public) is on no Desktop")
            return nil
        }
        guard let spaces = Optional(SpaceMover.userSpaceIDs(ofDisplay: state.display)),
            let current = spaces.firstIndex(of: state.windowSpace)
        else {
            Log.general.notice("desktop move: window's Desktop is not a standard one")
            return nil
        }
        let destination = current + step
        guard spaces.indices.contains(destination) else {
            Log.general.notice(
                """
                desktop move: already on desktop \(current + 1, privacy: .public) of \
                \(spaces.count, privacy: .public); nothing beyond it
                """)
            return nil
        }
        return Plan(
            window: window, element: element, bounds: bounds, grab: grab,
            destination: destination, destinationSpace: spaces[destination],
            display: displayBounds(containing: bounds))
    }

    /// Whether the drag actually took hold, judged by the window having moved.
    ///
    /// Worth checking rather than assuming. A synthetic drag lands on whatever the window server has
    /// under the point, and a title bar that has just been covered — a notification banner, a sheet
    /// the app threw up between the resolve and the press — takes the events instead. Bailing here
    /// leaves the user with a window nudged a few pixels; carrying on regardless would open Mission
    /// Control and drop *something else* on another Desktop.
    private static func didGrab(window: CGWindowID, from original: CGRect) -> Bool {
        guard let now = windowBounds(window) else { return false }
        return abs(now.origin.x - original.origin.x) > 2 || abs(now.origin.y - original.origin.y) > 2
    }

    /// Waits for Mission Control's Spaces Bar and returns the point to drop on, keeping the drag
    /// alive while it waits. nil if it never appears, or has no such Desktop.
    private static func awaitSpacesBar(
        holdingAt point: CGPoint, index: Int, on display: CGRect?
    ) -> CGPoint? {
        for _ in 0..<Int(spacesBarTimeout / spacesBarPoll) {
            post(.leftMouseDragged, point)
            usleep(useconds_t(spacesBarPoll * 1_000_000))
            let buttons = desktopButtons(on: display)
            guard buttons.indices.contains(index) else { continue }
            // The button's own rectangle is the *label* under the thumbnail, and its reported y sits
            // outside the Spaces Bar group. The x is right, so take that and aim at the middle of
            // the bar itself, which is the thumbnail the label belongs to.
            let bar = spacesBarFrame() ?? CGRect(x: 0, y: 0, width: 0, height: defaultSpacesBarHeight)
            return CGPoint(x: buttons[index].frame.midX, y: bar.minY + bar.height / 2)
        }
        return nil
    }

    // MARK: - Mission Control's Accessibility tree

    /// Every "Desktop N" thumbnail in the Spaces Bar, in the order they are shown.
    ///
    /// Matched on the `AXDescription` — "exit to Desktop 3" — rather than the title, because the
    /// title is localized and the description has proved the stable one. Both come from the Dock,
    /// which is the process that draws Mission Control.
    /// The display a frame sits on, by its centre, falling back to the largest overlap.
    ///
    /// `CGDisplayBounds` rather than `NSScreen`, because everything here is already in the window
    /// server's top-left coordinate space and this runs off the main thread, where `NSScreen` may
    /// not be touched.
    private static func displayBounds(containing frame: CGRect) -> CGRect? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return nil }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return nil }
        let centre = CGPoint(x: frame.midX, y: frame.midY)
        var best: CGRect?
        var bestArea: CGFloat = 0
        for id in ids {
            let bounds = CGDisplayBounds(id)
            if bounds.contains(centre) { return bounds }
            let overlap = bounds.intersection(frame)
            let area = overlap.isNull || overlap.isEmpty ? 0 : overlap.width * overlap.height
            if area > bestArea {
                bestArea = area
                best = bounds
            }
        }
        return best
    }

    /// The Desktop thumbnails belonging to one display.
    ///
    /// Mission Control draws a Spaces Bar per display, and `plan.destination` counts Desktops within
    /// the window's *own* display — `SpaceMover.userSpaceIDs(ofDisplay:)` is per display too. Taking
    /// every "exit to Desktop" button in the Dock's tree and indexing into the concatenation means
    /// that on two displays the index can name a thumbnail on the other one, and the window lands on
    /// the wrong Desktop entirely.
    ///
    /// Matched on x alone: the buttons report a y outside the Spaces Bar's own group (they are the
    /// labels beneath the thumbnails), so it is not usable for this, while displays are laid out
    /// side by side and x separates them cleanly. The unfiltered list is the fallback, which is
    /// exactly the old behaviour and is what a single-display setup gets either way — every button
    /// is on the one display, so the filter keeps all of them.
    ///
    /// Reasoned rather than measured: this was written on a one-display machine, so the two-display
    /// case has not been observed. The fallback is what keeps that honest — a filter that matches
    /// nothing degrades to what shipped before rather than to no move at all.
    private static func desktopButtons(on display: CGRect?) -> [(element: AXUIElement, frame: CGRect)] {
        let all = desktopButtons()
        guard let display else { return all }
        let scoped = all.filter { $0.frame.midX >= display.minX && $0.frame.midX < display.maxX }
        return scoped.isEmpty ? all : scoped
    }

    private static func desktopButtons() -> [(element: AXUIElement, frame: CGRect)] {
        var out: [(element: AXUIElement, frame: CGRect)] = []
        walk(dockElement()) { element, role, description in
            guard role == "AXButton", description.hasPrefix(exitToDesktop),
                let frame = elementFrame(element)
            else { return }
            out.append((element, frame))
        }
        return out
    }

    /// The Spaces Bar's own rectangle, which is what gives the drop its y.
    private static func spacesBarFrame() -> CGRect? {
        var found: CGRect?
        walk(dockElement()) { element, role, _ in
            guard found == nil, role == "AXGroup",
                AX.copyString(element, kAXTitleAttribute as String) == spacesBarTitle
            else { return }
            found = elementFrame(element)
        }
        return found
    }

    /// Whether Mission Control is still showing. Checked before toggling it shut, because the
    /// notification is a *toggle*: sending it to a Mission Control that has already closed itself
    /// would open it again and leave it up.
    private static func closeMissionControlIfOpen() {
        guard let dockNotify, spacesBarFrame() != nil else { return }
        dockNotify(missionControl as CFString, 0)
    }

    private static func dockElement() -> AXUIElement? {
        guard
            let dock = NSRunningApplication.runningApplications(
                withBundleIdentifier: "com.apple.dock"
            ).first
        else { return nil }
        return AXUIElementCreateApplication(dock.processIdentifier)
    }

    /// Depth-first walk of an Accessibility tree, handing each element to `visit` with the two
    /// attributes every caller here matches on.
    ///
    /// Depth-capped. Mission Control's tree is shallow — the Spaces Bar is five levels down — and a
    /// cap keeps a cycle or a pathological app from turning this into an unbounded walk while the
    /// mouse button is held down.
    private static func walk(
        _ element: AXUIElement?, depth: Int = 0,
        _ visit: (AXUIElement, String, String) -> Void
    ) {
        guard let element, depth <= maximumDepth else { return }
        let role = AX.copyString(element, kAXRoleAttribute as String) ?? ""
        let description = AX.copyString(element, kAXDescriptionAttribute as String) ?? ""
        visit(element, role, description)
        var raw: CFTypeRef?
        guard
            AXUIElementCopyAttributeValue(element, kAXChildrenAttribute as CFString, &raw)
                == .success, let children = raw as? [AXUIElement]
        else { return }
        for child in children { walk(child, depth: depth + 1, visit) }
    }

    private static func elementFrame(_ element: AXUIElement) -> CGRect? {
        guard let origin = AX.position(element), let size = AX.size(element) else { return nil }
        return CGRect(origin: origin, size: size)
    }

    // MARK: - Window geometry

    /// The window server's own rectangle for a window, in the top-left origin space `CGEvent` uses.
    ///
    /// Read from `CGWindowListCopyWindowInfo` rather than Accessibility on purpose: the drag is
    /// posted in window-server coordinates, and Electron and Catalyst hosts report Accessibility
    /// frames that drift from them — which is the difference between grabbing the title bar and
    /// grabbing whatever is a few points above it.
    private static func windowBounds(_ window: CGWindowID) -> CGRect? {
        guard
            let info = CGWindowListCopyWindowInfo([.optionIncludingWindow], window)
                as? [[String: Any]],
            let raw = info.first?[kCGWindowBounds as String] as? [String: CGFloat]
        else { return nil }
        return CGRect(dictionaryRepresentation: raw as CFDictionary)
    }

    /// The frontmost ordinary window at a point, which is the one a click there would reach.
    private static func topWindow(at point: CGPoint) -> CGWindowID? {
        guard
            let info = CGWindowListCopyWindowInfo(
                [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }
        for window in info {
            guard let layer = window[kCGWindowLayer as String] as? Int, layer == 0,
                let raw = window[kCGWindowBounds as String] as? [String: CGFloat],
                let bounds = CGRect(dictionaryRepresentation: raw as CFDictionary),
                bounds.contains(point)
            else { continue }
            return window[kCGWindowNumber as String] as? CGWindowID
        }
        return nil
    }

    // MARK: - Synthetic mouse

    private static func post(_ type: CGEventType, _ point: CGPoint, dx: CGFloat = 0, dy: CGFloat = 0)
    {
        let source = CGEventSource(stateID: .combinedSessionState)
        guard
            let event = CGEvent(
                mouseEventSource: source, mouseType: type, mouseCursorPosition: point,
                mouseButton: .left)
        else { return }
        // Some drop targets read the deltas rather than differencing successive positions, and the
        // Spaces Bar is one of them: without these it never lights up as a target.
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(dy))
        // Stamped as ours, so this app's *other* mouse gestures leave it alone.
        //
        // The drag below is a real drag as far as the system is concerned, which is the point — and
        // it means `DragSnap`'s global `NSEvent` monitors and `MouseWindowDrag`'s tap both see it,
        // exactly as they would see a hand on the mouse. That is not hypothetical trouble: the route
        // to the Spaces Bar goes through the top of the screen, which is `DragSnap`'s *maximize*
        // zone, so a mouse-up there is an instruction to snap the window — and with a gap set, a
        // snapped window lands inset from the edge rather than back where it started.
        //
        // One marker read by both, rather than each tap trying to recognise the gesture: see
        // `SyntheticEvent`.
        SyntheticEvent.mark(event)
        // Explicitly unmodified, and this is the whole difference between a gesture that works from
        // a shell and one that works from a hotkey.
        //
        // A new `CGEvent` picks up the *live* hardware modifier state, and the chord that got us
        // here is still under the user's fingers — the key repeat in the log is proof they are.
        // A `leftMouseDown` carrying ⌃ is not a drag at all: macOS reads Control-click as a right
        // click, so the press opened a context menu's worth of nothing and the window never moved.
        // ⌘ and ⌥ are no better — they are the modifiers apps hang alternate drag behaviour off.
        //
        // Measured, not reasoned about: with the flags left alone every hotkey-triggered move
        // logged "did not follow the drag", and every shell-triggered one worked, because a shell
        // has no keys held. Clearing them fixes the first without changing the second.
        event.flags = []
        event.post(tap: .cghidEventTap)
    }

    private static func release(at point: CGPoint) {
        post(.leftMouseUp, point)
    }

    // MARK: - Constants

    // The gesture's pacing. Every one of these is a deliberate wait for something asynchronous —
    // the window server registering a drag, Mission Control laying out, an app answering a frame
    // write — and none of them has an event to wait on instead, which is why they are sleeps.
    //
    // They were first set generously, on the principle that a move that works slowly beats one that
    // works sometimes, and that made the gesture 2.2 seconds. Profiling showed where that went:
    // ~2130ms of it was these, and only ~70ms was actually waiting for macOS — Mission Control's
    // Spaces Bar is laid out and readable barely a frame after it is asked for. So the numbers below
    // are tuned against measurement rather than guessed, and the ones that remain are the ones that
    // failed when cut further. Anything cut too far shows up as `did not follow the drag` or a drop
    // that lands on no thumbnail, not as a subtle glitch.

    /// After warping the pointer, before pressing. The warp is not instantaneous to the window
    /// server, and pressing into a pointer that has not arrived clicks wherever it used to be.
    private static let cursorSettle: useconds_t = 45_000
    /// After the press, before dragging. An app gets to react to a mouse-down in its title bar.
    private static let pressSettle: useconds_t = 70_000
    /// The gap between synthetic drag events. Roughly a frame: fast enough not to dominate the
    /// gesture, slow enough that the window server treats them as a continuous drag rather than a
    /// teleport.
    private static let stepInterval: useconds_t = 16_000
    /// The most engage nudges to try before giving up on the drag taking hold. A ceiling, not a
    /// count — the loop stops as soon as the window moves, which is usually well inside this.
    private static let engageStepLimit = 10
    /// Steps easing the window onto the destination thumbnail. The Spaces Bar wants to see the
    /// pointer approach; a single jump does not light it up as a drop target.
    private static let travelSteps = 12
    /// Steps held on the thumbnail before letting go, so the drop registers on it.
    private static let hoverSteps = 5
    /// How often the two waits below look, and how long each gives up after. Both poll for the
    /// thing itself rather than sleeping a fixed guess, so a fast machine pays only what it needs
    /// and a slow one still gets its time.
    private static let pollInterval: Double = 0.02
    private static let landingTimeout: Double = 1.0
    /// How long one follow press is given to take effect, and how many presses to try. The first is
    /// routinely swallowed — see `followTo` — so this must be more than one.
    private static let followPressTimeout: Double = 0.3
    private static let followAttempts = 4
    private static let closeTimeout: Double = 1.0

    /// How far down a window's top edge the title bar's middle sits. macOS's own title bar height,
    /// halved; nothing depends on it being exact, only on it landing in the bar rather than in the
    /// content below it.
    private static let titlebarInset: CGFloat = 12
    /// How long to wait for Mission Control, and how often to look. Generous — the open animation
    /// stretches with the number of windows on the Desktop, and the cost of being wrong here is a
    /// move that gives up for no visible reason.
    private static let spacesBarTimeout: Double = 2.5
    private static let spacesBarPoll: Double = 0.05
    /// Fallback height for the Spaces Bar if its own frame cannot be read. Its measured height on a
    /// standard display; only ever used to keep the drop on screen rather than at y = 0.
    private static let defaultSpacesBarHeight: CGFloat = 78
    private static let maximumDepth = 12
    private static let exitToDesktop = "exit to Desktop"
    private static let spacesBarTitle = "Spaces Bar"
}
