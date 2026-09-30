import AppKit
import XCTest

@testable import CmdTab

/// The disk stamp that lets a cached icon notice its app changed: `Contents/Info.plist`'s
/// modification date. Both icon caches compare a stored stamp against a fresh one each pass and
/// re-read the icon on any difference — so these pin down what "difference" means.
final class IconRefreshTests: XCTestCase {

    private var bundle: URL!

    override func setUpWithError() throws {
        bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("IconRefreshTests-\(UUID().uuidString)/Fake.app")
        try FileManager.default.createDirectory(
            at: bundle.appendingPathComponent("Contents"), withIntermediateDirectories: true)
        try Data("plist".utf8).write(to: bundle.appendingPathComponent("Contents/Info.plist"))
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: bundle.deletingLastPathComponent())
    }

    func testStampIsStableWhileTheBundleIsUntouched() {
        XCTAssertNotNil(TargetProvider.bundleStamp(bundle))
        XCTAssertEqual(TargetProvider.bundleStamp(bundle), TargetProvider.bundleStamp(bundle))
    }

    /// An updated app is detected by its plist's date moving — set explicitly here rather than
    /// rewritten, so the test never races filesystem timestamp granularity.
    func testStampMovesWhenInfoPlistIsReplaced() throws {
        let before = TargetProvider.bundleStamp(bundle)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)],
            ofItemAtPath: bundle.appendingPathComponent("Contents/Info.plist").path)
        XCTAssertNotEqual(TargetProvider.bundleStamp(bundle), before)
    }

    /// No answer for a missing bundle, a missing plist, or no URL at all — the callers decide what
    /// nil means, so it must be nil rather than a default date that would compare equal to itself.
    func testUnreadableBundlesAnswerNil() throws {
        XCTAssertNil(TargetProvider.bundleStamp(nil))
        XCTAssertNil(
            TargetProvider.bundleStamp(bundle.deletingLastPathComponent()
                .appendingPathComponent("Missing.app")))
        try FileManager.default.removeItem(at: bundle.appendingPathComponent("Contents/Info.plist"))
        XCTAssertNil(TargetProvider.bundleStamp(bundle))
    }
}
