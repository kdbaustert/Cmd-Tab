import XCTest

@testable import CmdTab

/// The Shortcuts surface's one duplication: `caseDisplayRepresentations` has to be a source
/// literal (the metadata extractor rejects anything computed), so it repeats every arrangement's
/// title. These assertions are what let it — adding an arrangement without a row here, or with a
/// name that drifts from `title`, fails the suite rather than shipping a nameless or mislabelled
/// Shortcuts step.
final class AppIntentsTests: XCTestCase {
    func testEveryArrangementHasAShortcutsName() {
        for arrangement in WindowArrangement.allCases {
            XCTAssertNotNil(
                WindowArrangement.caseDisplayRepresentations[arrangement],
                "\(arrangement.rawValue) has no Shortcuts display name")
        }
        XCTAssertEqual(
            WindowArrangement.caseDisplayRepresentations.count,
            WindowArrangement.allCases.count,
            "no stale rows for cases that no longer exist")
    }

    func testTheShortcutsNamesMatchTheTitles() {
        for arrangement in WindowArrangement.allCases {
            guard let representation = WindowArrangement.caseDisplayRepresentations[arrangement]
            else { continue }
            XCTAssertEqual(
                String(localized: representation.title), arrangement.title,
                "\(arrangement.rawValue)'s Shortcuts name drifted from its title")
        }
    }

    /// A step that cannot run must say so rather than report success.
    @MainActor
    func testARefusedIntentThrowsInsteadOfSucceeding() async {
        let saved = IntentActions.perform
        defer { IntentActions.perform = saved }

        IntentActions.perform = nil
        XCTAssertThrowsError(try IntentActions.run(.allWindows(.hide)), "no handler is a failure")

        var received: [URLCommand] = []
        IntentActions.perform = { received.append($0) }
        XCTAssertNoThrow(try IntentActions.run(.allWindows(.show)))
        XCTAssertEqual(received.count, 1)

        var intent = ActivateAppIntent()
        intent.bundleIdentifier = " \n "
        do {
            _ = try await intent.perform()
            XCTFail("a blank bundle identifier must not report success")
        } catch {}
        XCTAssertEqual(received.count, 1, "and must not reach the handler")

        intent.bundleIdentifier = "com.apple.Safari\n"
        _ = try? await intent.perform()
        XCTAssertEqual(received.last, .activate(bundleID: "com.apple.Safari"), "newline trimmed")
    }

    /// An identifier no app has is the same silent no-op one layer down — `GlobalActions.activate`
    /// logs it and returns — so the step has to refuse it before the handler ever sees it.
    @MainActor
    func testAnUnknownAppIsRefusedBeforeItReachesTheHandler() async {
        let saved = IntentActions.perform
        defer { IntentActions.perform = saved }
        var received: [URLCommand] = []
        IntentActions.perform = { received.append($0) }

        var intent = ActivateAppIntent()
        intent.bundleIdentifier = "com.example.cmdtab.no-such-app"
        do {
            _ = try await intent.perform()
            XCTFail("an app that does not exist must not report success")
        } catch let error as IntentError {
            guard case .unknownApp("com.example.cmdtab.no-such-app") = error else {
                return XCTFail("wrong refusal: \(error)")
            }
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        XCTAssertTrue(received.isEmpty, "and must not reach the handler")
    }
}
