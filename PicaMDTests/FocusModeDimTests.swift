import XCTest
import AppKit
@testable import PicaMD

/// Focus-Mode dimming must be reversible without a full re-highlight (F8):
/// the dim pass stashes each run's pre-dim colour, and `removeFocusDim`
/// restores it with a cheap attribute walk.
@MainActor
final class FocusModeDimTests: XCTestCase {

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        storage.addAttributes([.font: NSFont.systemFont(ofSize: 15)],
                              range: NSRange(location: 0, length: storage.length))
        return storage
    }

    func testFocusDimStashesThenRestoresExactly() {
        let highlighter = SyntaxHighlighter()
        // Two paragraphs; cursor in the first → the second gets dimmed.
        let source = "paragraph A\n\nparagraph B here\n"
        let storage = makeStorage(source)
        let cursor = NSRange(location: 2, length: 0)   // inside paragraph A

        highlighter.highlight(textStorage: storage, isDark: false,
                              cursorRange: cursor, focusMode: true)

        // Pick a location inside paragraph B.
        let bLoc = (source as NSString).range(of: "paragraph B").location
        XCTAssertNotEqual(bLoc, NSNotFound)

        let dimmed = storage.attribute(.foregroundColor, at: bLoc, effectiveRange: nil) as? NSColor
        let stash = storage.attribute(.qmdUndimmedForeground, at: bLoc, effectiveRange: nil) as? NSColor
        XCTAssertNotNil(dimmed)
        XCTAssertNotNil(stash, "dimmed run must stash its original colour")
        if let dimmed, let stash {
            XCTAssertLessThan(dimmed.alphaComponent, stash.alphaComponent,
                              "dimmed colour must be more transparent than the stashed original")
        }

        // Restore: removeFocusDim must put the exact original colour back
        // and drop the stash marker — no regex re-run.
        highlighter.removeFocusDim(textStorage: storage)
        let restored = storage.attribute(.foregroundColor, at: bLoc, effectiveRange: nil) as? NSColor
        let stashAfter = storage.attribute(.qmdUndimmedForeground, at: bLoc, effectiveRange: nil)
        XCTAssertNil(stashAfter, "stash marker must be removed after restore")
        XCTAssertEqual(restored, stash, "restored colour must equal the stashed original")
    }

    func testCursorParagraphIsNotDimmed() {
        let highlighter = SyntaxHighlighter()
        let source = "paragraph A\n\nparagraph B here\n"
        let storage = makeStorage(source)
        let cursor = NSRange(location: 2, length: 0)   // inside paragraph A

        highlighter.highlight(textStorage: storage, isDark: false,
                              cursorRange: cursor, focusMode: true)

        let aLoc = (source as NSString).range(of: "paragraph A").location
        let stash = storage.attribute(.qmdUndimmedForeground, at: aLoc, effectiveRange: nil)
        XCTAssertNil(stash, "the cursor's own paragraph must not be dimmed/stashed")
    }

    func testRemoveFocusDimIsNoOpWhenNothingDimmed() {
        let highlighter = SyntaxHighlighter()
        let source = "plain text only\n"
        let storage = makeStorage(source)
        highlighter.highlight(textStorage: storage, isDark: false,
                              cursorRange: NSRange(location: 0, length: 0), focusMode: false)
        let before = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        highlighter.removeFocusDim(textStorage: storage)   // must not crash / change anything
        let after = storage.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(before, after)
    }
}
