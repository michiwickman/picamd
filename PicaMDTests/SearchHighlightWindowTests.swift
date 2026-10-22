import XCTest
import AppKit
@testable import PicaMD

/// The find highlight draws only matches inside the rect being redrawn. That
/// rect arrives in view coordinates; the layout manager works in container
/// coordinates. A partial redraw — the strip a scroll exposes — must still
/// find the matches on its first line.
@MainActor
final class SearchHighlightWindowTests: XCTestCase {

    func testDirtyRectIsConvertedToContainerCoordinates() throws {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.textContainerInset = NSSize(width: 250, height: 20)
        tv.string = (1...12).map { "line \($0) alpha beta gamma" }.joined(separator: "\n")
        let lm = try XCTUnwrap(tv.layoutManager)
        let tc = try XCTUnwrap(tv.textContainer)
        lm.ensureLayout(for: tc)

        let ns = tv.string as NSString
        let line5 = ns.range(of: "line 5 ")
        let gamma = ns.range(of: "gamma", range: NSRange(location: line5.location,
                                                         length: ns.length - line5.location))
        // The match's own rect, in view coordinates: exactly what AppKit
        // passes when only that strip needs drawing.
        let glyphs = lm.glyphRange(forCharacterRange: gamma, actualCharacterRange: nil)
        let origin = tv.textContainerOrigin
        let dirty = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            .offsetBy(dx: origin.x, dy: origin.y)

        let covered = PicaMDTextView.characterRange(coveredBy: dirty, origin: origin,
                                                    layoutManager: lm, textContainer: tc)
        XCTAssertNotNil(covered.intersection(gamma),
                        "the redrawn strip holds the match, so the match must be in the window")
    }
}
