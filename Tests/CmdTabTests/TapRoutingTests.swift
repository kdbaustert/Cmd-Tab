import CoreGraphics
import XCTest

@testable import CmdTab

/// The idle-path precedence: which binding claims a keystroke, and whether it is swallowed.
///
/// This was previously reachable only through a live `CGEventTap`, so every rule in it could only
/// be checked by pressing keys and watching a running app. The rules are not obvious — several of
/// them exist because of a specific failure, and two of them are deliberate *asymmetries* that read
/// like bugs until you know why.
final class TapRoutingTests: XCTestCase {

    private let tab = 48
    private let cmd: CGEventFlags = [.maskCommand]
    private let ctrlCmd: CGEventFlags = [.maskControl, .maskCommand]

    private func down(_ code: Int, _ flags: CGEventFlags, repeat isRepeat: Bool = false)
        -> TapRouting.Event
    {
        TapRouting.Event(type: .keyDown, keyCode: code, flags: flags, isAutorepeat: isRepeat)
    }

    private func up(_ code: Int, _ flags: CGEventFlags) -> TapRouting.Event {
        TapRouting.Event(type: .keyUp, keyCode: code, flags: flags)
    }

    /// Every binding in the app pointed at one chord, so precedence questions have a single answer
    /// to compare against.
    private func allClaiming(_ code: Int, _ flags: CGEventFlags) -> TapRouting.Bindings {
        TapRouting.Bindings(
            openerMatches: { c, _ in c == code },
            sameAppMatches: { c, _ in c == code },
            scopedMatch: { c, f in c == code ? (scope: .allWindows, held: f) : nil },
            activationMatch: { c, _ in c == code ? "com.example.App" : nil },
            allWindowsMatch: { c, _ in c == code ? .hide : nil },
            tilingMatch: { c, _ in c == code ? .leftHalf : nil })
    }

    // MARK: - Openers win

    /// Nothing a user or a hand-edited config.json binds can take ⌘-Tab away from the switcher. The
    /// recorders refuse such a chord, but a config file is not a recorder.
    func testTheOpenerBeatsEveryOtherBinding() {
        let decision = TapRouting.idle(
            down(tab, cmd), bindings: allClaiming(tab, cmd), isAppActive: false)
        XCTAssertEqual(decision, .open(backwards: false))
    }

    func testTheSameAppTriggerBeatsScopedAndGlobalBindings() {
        var bindings = allClaiming(tab, cmd)
        bindings.openerMatches = { _, _ in false }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: false),
            .openSameApp(backwards: false))
    }

    func testScopedTriggersBeatGlobalActions() {
        var bindings = allClaiming(tab, cmd)
        bindings.openerMatches = { _, _ in false }
        bindings.sameAppMatches = { _, _ in false }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: false),
            .openScoped(scope: .allWindows, held: cmd, backwards: false))
    }

    func testDirectActivationBeatsHideAllWhichBeatsTiling() {
        var bindings = allClaiming(tab, cmd)
        bindings.openerMatches = { _, _ in false }
        bindings.sameAppMatches = { _, _ in false }
        bindings.scopedMatch = { _, _ in nil }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: false),
            .activate(bundleID: "com.example.App"))

        bindings.activationMatch = { _, _ in nil }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: false),
            .allWindows(.hide))

        bindings.allWindowsMatch = { _, _ in nil }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: false),
            .tile(.leftHalf))
    }

    // MARK: - Shift means backwards

    func testShiftOnATriggerRunsTheListBackwards() {
        let bindings = TapRouting.Bindings(openerMatches: { c, _ in c == self.tab })
        XCTAssertEqual(
            TapRouting.idle(
                down(tab, [.maskCommand, .maskShift]), bindings: bindings, isAppActive: false),
            .open(backwards: true))
    }

    // MARK: - Key edges

    /// Openers are keydown-only. A key-up on the trigger chord is not an opener and must not open a
    /// second session.
    func testAKeyUpDoesNotOpenTheSwitcher() {
        let bindings = TapRouting.Bindings(openerMatches: { c, _ in c == self.tab })
        XCTAssertEqual(TapRouting.idle(up(tab, cmd), bindings: bindings, isAppActive: false), .pass)
    }

    /// Global actions match on **both** edges, and the key-up is swallowed even though it does
    /// nothing. Swallowing only the keydown left an unpaired key-up heading for the frontmost app,
    /// which virtualisers, VNC and RDP clients read as a release with no press.
    func testAGlobalActionSwallowsItsKeyUpWithoutFiring() {
        let bindings = TapRouting.Bindings(tilingMatch: { c, _ in c == self.tab ? .leftHalf : nil })
        let decision = TapRouting.idle(up(tab, ctrlCmd), bindings: bindings, isAppActive: false)
        XCTAssertEqual(decision, .consume)
        XCTAssertTrue(decision.swallows, "the key-up must not escape to the app in front")
    }

    /// Key repeat is swallowed but not acted on: cycling ½ → ⅔ → ⅓ under autorepeat would strobe a
    /// window through every width in a fraction of a second.
    func testKeyRepeatIsSwallowedButDoesNotFireAgain() {
        let bindings = TapRouting.Bindings(tilingMatch: { c, _ in c == self.tab ? .leftHalf : nil })
        let decision = TapRouting.idle(
            down(tab, ctrlCmd, repeat: true), bindings: bindings, isAppActive: false)
        XCTAssertEqual(decision, .consume)
        XCTAssertTrue(decision.swallows)
    }

    /// A trigger, by contrast, is not repeat-guarded here: holding it is how the classic cycle
    /// advances, and the controller's armed/visible states own that behaviour.
    func testAnAutorepeatedTriggerStillOpens() {
        let bindings = TapRouting.Bindings(openerMatches: { c, _ in c == self.tab })
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd, repeat: true), bindings: bindings, isAppActive: false),
            .open(backwards: false))
    }

    // MARK: - Inert while Cmd-Tab is frontmost

    /// The asymmetry that reads like a bug: the two built-in triggers still fire while the settings
    /// window has focus, because they are recorded by a different control and opening the switcher
    /// from Settings is long-standing.
    func testTheBuiltInTriggersStillFireWhileCmdTabIsFrontmost() {
        var bindings = allClaiming(tab, cmd)
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: true),
            .open(backwards: false))

        bindings.openerMatches = { _, _ in false }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: true),
            .openSameApp(backwards: false))
    }

    /// Scoped triggers do *not*, unlike the built-ins: they are recorded in the settings window, so
    /// matching one there would swallow it before its own recorder could see it.
    func testScopedTriggersAreInertWhileCmdTabIsFrontmost() {
        var bindings = allClaiming(tab, cmd)
        bindings.openerMatches = { _, _ in false }
        bindings.sameAppMatches = { _, _ in false }
        bindings.activationMatch = { _, _ in nil }
        bindings.allWindowsMatch = { _, _ in nil }
        bindings.tilingMatch = { _, _ in nil }
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: true), .pass)
    }

    /// A tiling chord pressed with the settings window focused is reported rather than swallowed —
    /// the recorder needs to see it, and this is the commonest "my shortcut does nothing".
    func testATilingChordIsReportedButNotSwallowedWhileFrontmost() {
        let bindings = TapRouting.Bindings(tilingMatch: { c, _ in c == self.tab ? .leftHalf : nil })
        let decision = TapRouting.idle(down(tab, ctrlCmd), bindings: bindings, isAppActive: true)
        XCTAssertEqual(decision, .tilingInert(.leftHalf))
        XCTAssertFalse(
            decision.swallows, "the shortcut recorder must be able to see the chord it is binding")
    }

    func testGlobalActionsAreInertWhileCmdTabIsFrontmost() {
        let bindings = TapRouting.Bindings(
            activationMatch: { c, _ in c == self.tab ? "com.example.App" : nil },
            allWindowsMatch: { c, _ in c == self.tab ? .hide : nil })
        XCTAssertEqual(
            TapRouting.idle(down(tab, cmd), bindings: bindings, isAppActive: true), .pass)
    }

    // MARK: - Nothing bound

    func testAnUnboundKeystrokePassesThrough() {
        let decision = TapRouting.idle(
            down(tab, cmd), bindings: TapRouting.Bindings(), isAppActive: false)
        XCTAssertEqual(decision, .pass)
        XCTAssertFalse(decision.swallows)
    }

    /// Every decision that claims a keystroke swallows it, and only those. An event both acted on
    /// and passed through would reach the app in front as well.
    func testOnlyClaimedKeystrokesAreSwallowed() {
        let claimed: [TapRouting.Decision] = [
            .consume, .open(backwards: false), .openSameApp(backwards: true),
            .openScoped(scope: .minimized, held: cmd, backwards: false),
            .activate(bundleID: "x"), .allWindows(.show), .tile(.maximize),
        ]
        for decision in claimed {
            XCTAssertTrue(decision.swallows, "\(decision) claims the event and must swallow it")
        }
        for decision in [TapRouting.Decision.pass, .tilingInert(.leftHalf)] {
            XCTAssertFalse(decision.swallows, "\(decision) must reach the app in front")
        }
    }
}
