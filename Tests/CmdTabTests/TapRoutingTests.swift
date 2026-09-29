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
        TapRouting.Event(keyCode: code, flags: flags, isAutorepeat: isRepeat)
    }

    /// Every binding in the app pointed at one chord, so precedence questions have a single answer
    /// to compare against.
    private func allClaiming(_ code: Int, _ flags: CGEventFlags) -> TapRouting.Bindings {
        TapRouting.Bindings(
            openerMatches: { c, _ in c == code },
            sameAppMatches: { c, _ in c == code },
            scopedMatch: { c, f in
                c == code
                    ? ScopedTrigger(
                        id: "t", hotkey: Hotkey(keyCode: c, modifierRaw: f.rawValue),
                        scope: .allWindows)
                    : nil
            },
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
            .openScoped(
                trigger: ScopedTrigger(
                    id: "t", hotkey: Hotkey(keyCode: tab, modifierRaw: cmd.rawValue),
                    scope: .allWindows),
                backwards: false))
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

    // MARK: - Key repeat

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

    /// …until a recorder is listening. Recording the same-app trigger as the main trigger's chord
    /// (or the other way round) never reached the recorder: the live trigger swallowed it first.
    func testTheBuiltInTriggersStandDownWhileARecorderIsListening() {
        var bindings = allClaiming(tab, cmd)
        bindings.scopedMatch = { _, _ in nil }
        bindings.activationMatch = { _, _ in nil }
        bindings.allWindowsMatch = { _, _ in nil }
        bindings.tilingMatch = { _, _ in nil }
        let decision = TapRouting.idle(
            down(tab, cmd), bindings: bindings, isAppActive: true, isRecording: true)
        XCTAssertEqual(decision, .pass)
        XCTAssertFalse(decision.swallows, "the recorder has to see the chord it is recording")
    }

    /// A recorder hears keys only while Cmd-Tab is in front. One left armed behind another app is
    /// not listening, and must not take ⌘-Tab away from that app.
    func testAnArmedRecorderBehindAnotherAppDoesNotStandTheTriggersDown() {
        let bindings = TapRouting.Bindings(openerMatches: { c, _ in c == self.tab })
        XCTAssertEqual(
            TapRouting.idle(
                down(tab, cmd), bindings: bindings, isAppActive: false, isRecording: true),
            .open(backwards: false))
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
            .openScoped(
                trigger: ScopedTrigger(
                    id: "t", hotkey: Hotkey(keyCode: 46, modifierRaw: cmd.rawValue),
                    scope: .minimized),
                backwards: false),
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

/// A key-up goes wherever its key-down went. Each case is a gesture where the switcher's state had
/// moved on between the two edges, which is when deciding the key-up separately got it wrong.
final class KeyPairingTests: XCTestCase {
    private let tab = 48
    private let letter = 0

    /// ⌘ released a moment before Tab — the ordinary end of a ⌘-Tab. The session has already
    /// committed when Tab comes up, and its key-up used to escape to the app with no press before
    /// it.
    func testAWithheldPressHasItsKeyUpWithheldAfterTheSessionEnds() {
        var pairing = KeyPairing()
        pairing.keyDown(tab, isAutorepeat: false, swallowed: true)
        XCTAssertTrue(pairing.keyUp(tab))
    }

    /// A key already held when the panel opened reached the app on the way down, so its key-up must
    /// too — withholding it left a key stuck down in a VNC or RDP session.
    func testAPressThatReachedTheAppHasItsKeyUpDelivered() {
        var pairing = KeyPairing()
        pairing.keyDown(letter, isAutorepeat: false, swallowed: false)
        XCTAssertFalse(pairing.keyUp(letter))
    }

    /// A key-up with no press seen at all — held before the tap started — belongs to the app.
    func testAKeyUpWithNoRecordedPressIsDelivered() {
        var pairing = KeyPairing()
        XCTAssertFalse(pairing.keyUp(letter))
    }

    /// Once any key-down of a press reaches the app, the receiver has the key down, so the key-up
    /// has to follow — including a repeat let through after the session that withheld the first
    /// press has ended.
    func testARepeatThatReachesTheAppReleasesTheKeyUp() {
        var pairing = KeyPairing()
        pairing.keyDown(tab, isAutorepeat: false, swallowed: true)
        pairing.keyDown(tab, isAutorepeat: true, swallowed: false)
        XCTAssertFalse(pairing.keyUp(tab))
    }

    /// And the other way: a withheld repeat of a press the app already has does not take the key-up
    /// away from it.
    func testAWithheldRepeatOfADeliveredPressDoesNotWithholdTheKeyUp() {
        var pairing = KeyPairing()
        pairing.keyDown(tab, isAutorepeat: false, swallowed: false)
        pairing.keyDown(tab, isAutorepeat: true, swallowed: true)
        XCTAssertFalse(pairing.keyUp(tab))
    }

    /// Each key-up settles its own press, so the next press starts clean.
    func testAKeyUpClearsTheRecord() {
        var pairing = KeyPairing()
        pairing.keyDown(tab, isAutorepeat: false, swallowed: true)
        XCTAssertTrue(pairing.keyUp(tab))
        XCTAssertFalse(pairing.keyUp(tab))
    }
}
