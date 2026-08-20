import Foundation
import XCTest

@testable import CmdTab

/// The depth rule behind the launch-from-search catalogue.
///
/// It is one of the few things in this app that can be checked against a real directory tree without
/// a window server, an event tap or Accessibility — and it is worth checking, because both ways it
/// can be wrong are silent. Too shallow and a whole vendor's folder of apps is missing from search,
/// which is what `/Applications/Setapp` was; too deep and the scan descends into every bundle's own
/// `Contents`, which does not fail, it just takes seconds while someone is mid-keystroke.
final class InstalledAppsTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("InstalledAppsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func makeDirectory(_ path: String) throws {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(path, isDirectory: true),
            withIntermediateDirectories: true)
    }

    private func found() -> [String] {
        InstalledApps.appBundles(under: root, manager: .default)
            .map(\.lastPathComponent)
            .sorted()
    }

    func testAnAppAtTheTopLevelIsFound() throws {
        try makeDirectory("Safari.app")
        XCTAssertEqual(found(), ["Safari.app"])
    }

    func testAnAppInsideAVendorFolderIsFound() throws {
        // The case this exists for: every Setapp title lives one directory down, and a scan that
        // stopped at the top level offered none of them.
        try makeDirectory("Setapp/CleanShot X.app")
        XCTAssertEqual(found(), ["CleanShot X.app"])
    }

    func testAnAppTwoDirectoriesDownIsNotFound() throws {
        try makeDirectory("Vendor/Archive/Old.app")
        XCTAssertEqual(found(), [])
    }

    func testABundleIsNeverDescendedInto() throws {
        // An `.app` is itself a directory, and the helpers inside one are not apps the user
        // switches to. Descending into them is also how a scan of `/Applications` turns into a walk
        // of every bundle on the disk.
        try makeDirectory("Xcode.app/Contents/Applications/Instruments.app")
        XCTAssertEqual(found(), ["Xcode.app"])
    }

    func testLooseFilesAndUnreadablePathsAreIgnored() throws {
        try makeDirectory("Mail.app")
        try Data().write(to: root.appendingPathComponent("README.txt"))
        XCTAssertEqual(found(), ["Mail.app"])
        XCTAssertEqual(
            InstalledApps.appBundles(
                under: root.appendingPathComponent("nowhere", isDirectory: true), manager: .default),
            [])
    }
}
