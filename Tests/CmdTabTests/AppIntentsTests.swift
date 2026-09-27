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
}
