import XCTest

@testable import CmdTab

/// Decoding a theme file, whose shape is not under our control: it is shared between machines and
/// read back across app versions, so a field the writing build had and this one does not — or the
/// reverse — must cost that one value rather than the whole theme.
final class ThemeCodingTests: XCTestCase {
    private func decode(_ json: String) throws -> Theme {
        try JSONDecoder().decode(Theme.self, from: Data(json.utf8))
    }

    /// A file written by a *newer* build, carrying a field this one has never heard of. The old
    /// synthesized decoder tolerated this already; the point is that the hand-written one still does.
    func testUnknownFieldsAreIgnored() throws {
        let theme = try decode(
            """
            {"name":"Faded","highlightHex":"#112233","appearance":"dark","material":"sidebar",
             "blurOverride":true,"blurRadius":33,"showNumbers":false,"tileCorner":9,
             "titleFontSize":11,"titleFontName":"Menlo","fade":true,
             "iconSize":50,"iconSpacing":11,"titleSpacing":4,
             "opacity":0.8,"someFutureField":"whatever"}
            """)
        XCTAssertEqual(theme.name, "Faded")
        XCTAssertEqual(theme.titleFontName, "Menlo")
        XCTAssertEqual(theme.blurRadius, 33)
    }

    /// A file written by an *older* build, missing fields this one expects. This is the direction
    /// that used to throw: dropping the required `opacity` field made every theme exported by a new
    /// build unreadable to an old one, and the `try?` at the call site turned that into Import
    /// silently doing nothing.
    func testMissingFieldsFallBackToDefaults() throws {
        // Doubled delimiters: the `"#` in a hex colour would close a single-`#` raw string.
        let theme = try decode(##"{"name":"Sparse","highlightHex":"#ABCDEF"}"##)
        XCTAssertEqual(theme.name, "Sparse")
        XCTAssertEqual(theme.highlightHex, "#ABCDEF")
        // Everything absent takes the built-in default rather than failing the decode.
        XCTAssertEqual(theme.material, PanelMaterial.hud.rawValue)
        XCTAssertEqual(theme.appearance, PanelAppearance.system.rawValue)
        XCTAssertEqual(theme.titleFontName, "")
        XCTAssertEqual(theme.titleFontSize, 10)
        XCTAssertEqual(theme.blurRadius, 20)
        XCTAssertTrue(theme.showNumbers)
        XCTAssertFalse(theme.builtIn)
    }

    /// A field present but of the wrong type is treated as absent, not as a decode failure.
    func testWronglyTypedFieldFallsBackRatherThanThrowing() throws {
        let theme = try decode(#"{"name":"Odd","blurRadius":"twenty","showNumbers":"yes"}"#)
        XCTAssertEqual(theme.name, "Odd")
        XCTAssertEqual(theme.blurRadius, 20)
        XCTAssertTrue(theme.showNumbers)
    }

    /// An encode/decode round trip has to be lossless, or saving and reloading would quietly drift.
    func testRoundTripPreservesEveryField() throws {
        let original = Theme(
            name: "Round", highlightHex: "#0A84FF", appearance: "light", material: "window",
            blurOverride: true, blurRadius: 42, showNumbers: false,
            tileCorner: 7, titleFontSize: 13, titleFontName: "Helvetica Neue",
            fade: true, iconSize: 70, iconSpacing: 21, titleSpacing: 5,
            builtIn: false)
        let decoded = try JSONDecoder().decode(
            Theme.self, from: try JSONEncoder().encode(original))
        XCTAssertEqual(decoded, original)
    }

    /// `sameLook` has to see the title font, or changing it would leave the picker claiming the old
    /// theme is still current while the panel no longer looks like it.
    func testSameLookDistinguishesTitleFont() {
        let base = Theme(
            name: "A", highlightHex: "#CDD7DD", appearance: "system", material: "hud",
            blurOverride: false, blurRadius: 20, showNumbers: true,
            tileCorner: 12, titleFontSize: 10, titleFontName: "",
            fade: false, iconSize: 64, iconSpacing: 18, titleSpacing: 2)
        var restyled = base
        restyled.titleFontName = "Menlo"
        XCTAssertFalse(base.sameLook(as: restyled))

        // Name, built-in flag and icon size stay excluded — identity and a user-level preference,
        // not part of the look.
        var renamed = base
        renamed.name = "B"
        renamed.builtIn = true
        renamed.iconSize = 128
        XCTAssertTrue(base.sameLook(as: renamed))
    }
}
