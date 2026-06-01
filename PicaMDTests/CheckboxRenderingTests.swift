import XCTest
import AppKit
@testable import PicaMD

/// Coverage for the inline task-list checkbox feature: source
/// extraction, highlighter concealment + strike-through, and the
/// toggle-roundtrip via NSTextStorage edits.
@MainActor
final class CheckboxRenderingTests: XCTestCase {

    // MARK: - Source extraction

    func testExtractMatches_basicUnchecked() {
        let source = "- [ ] Buy milk\n"
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 1)
        guard let m = matches.first else { return }
        XCTAssertFalse(m.checked)
        // boxRange must point at exactly the 3 chars `[ ]`
        XCTAssertEqual(m.boxRange.length, 3)
        let box = (source as NSString).substring(with: m.boxRange)
        XCTAssertEqual(box, "[ ]")
        // textRange covers the trailing prose
        let text = (source as NSString).substring(with: m.textRange)
        XCTAssertEqual(text, "Buy milk")
    }

    func testExtractMatches_basicChecked() {
        let source = "- [x] Buy milk\n"
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches.first?.checked ?? false)
    }

    func testExtractMatches_uppercaseXAlsoChecked() {
        let source = "- [X] Already done\n"
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 1)
        XCTAssertTrue(matches.first?.checked ?? false)
    }

    func testExtractMatches_alternativeBullets() {
        let source = """
        - [ ] dash
        * [x] star
        + [ ] plus
        """
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 3)
        XCTAssertEqual(matches.map(\.checked), [false, true, false])
    }

    func testExtractMatches_indentedNestedListItem() {
        let source = "  - [ ] nested item\n"
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 1)
        let box = (source as NSString).substring(with: matches[0].boxRange)
        XCTAssertEqual(box, "[ ]")
    }

    func testExtractMatches_inlineBracketsNotMatched() {
        // `[ ]` not at start of a list item — should NOT be treated as
        // a task-list checkbox. Otherwise prose like "the array [ ]"
        // would render a checkbox in the middle of a sentence.
        let source = "Some text with [ ] brackets inside.\n"
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertTrue(matches.isEmpty)
    }

    func testExtractMatches_emptyAndWhitespaceSource() {
        XCTAssertTrue(CheckboxOverlayManager.extractMatches(from: "").isEmpty)
        XCTAssertTrue(CheckboxOverlayManager.extractMatches(from: "   \n   \n").isEmpty)
    }

    func testExtractMatches_mixedDocPreservesOrder() {
        let source = """
        # Tasks

        - [x] Done item
        - [ ] Pending item
        - [X] Another done
        - [ ] Last
        """
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 4)
        XCTAssertEqual(matches.map(\.checked), [true, false, true, false])
        // Ranges must be monotonically increasing.
        for i in 1..<matches.count {
            XCTAssertGreaterThan(matches[i].lineRange.location,
                                 matches[i - 1].lineRange.location)
        }
    }

    // MARK: - Highlighter concealment + strike-through

    private func makeStorage(_ text: String) -> NSTextStorage {
        let storage = NSTextStorage(string: text)
        let base = NSFont.systemFont(ofSize: 15)
        storage.addAttributes([.font: base],
                              range: NSRange(location: 0, length: storage.length))
        return storage
    }

    func testCheckboxMarkupIsConcealedWhenCursorAway() {
        let highlighter = SyntaxHighlighter()
        // Two checkbox lines plus a buffer paragraph so the cursor at
        // doc-end is not within `touches(...)` reach of either box.
        let source = "- [ ] Task one\n- [x] Task two\n\n\nfar away\n"
        let storage = makeStorage(source)
        let cursor = NSRange(location: source.utf16.count, length: 0)
        highlighter.highlight(textStorage: storage,
                              isDark: false,
                              cursorRange: cursor)

        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 2)
        for match in matches {
            // foreground colour on box-range chars should be `.clear`.
            let attr = storage.attribute(.foregroundColor,
                                          at: match.boxRange.location,
                                          effectiveRange: nil) as? NSColor
            XCTAssertNotNil(attr)
            XCTAssertEqual(attr?.alphaComponent, 0,
                           "Box markup should be concealed (clear colour) off-cursor")
        }
    }

    func testCheckboxMarkupRevealsWhenCursorOnLine() {
        let highlighter = SyntaxHighlighter()
        let source = "- [ ] Task one\n"
        let storage = makeStorage(source)
        // Cursor just inside the line.
        let cursor = NSRange(location: 4, length: 0)  // position of `]`
        highlighter.highlight(textStorage: storage,
                              isDark: false,
                              cursorRange: cursor)

        let matches = CheckboxOverlayManager.extractMatches(from: source)
        guard let match = matches.first else {
            XCTFail("No match"); return
        }
        let attr = storage.attribute(.foregroundColor,
                                      at: match.boxRange.location,
                                      effectiveRange: nil) as? NSColor
        XCTAssertNotNil(attr)
        XCTAssertNotEqual(attr?.alphaComponent, 0,
                          "Box markup should be visible when cursor is on the line")
    }

    func testCheckedItemHasStrikethrough() {
        let highlighter = SyntaxHighlighter()
        let source = "- [x] Done item\n- [ ] Open item\n"
        let storage = makeStorage(source)
        let cursor = NSRange(location: source.utf16.count, length: 0)
        highlighter.highlight(textStorage: storage,
                              isDark: false,
                              cursorRange: cursor)

        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 2)

        // First item is checked → strike-through on textRange.
        let checkedMatch = matches[0]
        XCTAssertTrue(checkedMatch.checked)
        let strike = storage.attribute(.strikethroughStyle,
                                        at: checkedMatch.textRange.location,
                                        effectiveRange: nil) as? Int
        XCTAssertNotNil(strike, "Checked item should carry .strikethroughStyle")
        XCTAssertEqual(strike, NSUnderlineStyle.single.rawValue)

        // Second item is unchecked → no strike-through on textRange.
        let openMatch = matches[1]
        XCTAssertFalse(openMatch.checked)
        let strike2 = storage.attribute(.strikethroughStyle,
                                         at: openMatch.textRange.location,
                                         effectiveRange: nil) as? Int
        XCTAssertNil(strike2,
                     "Unchecked item must not have strike-through")
    }

    func testStrikethroughLiftsWhenCursorMovesOntoLine() {
        let highlighter = SyntaxHighlighter()
        let source = "- [x] Done item\n"
        let storage = makeStorage(source)
        // Cursor is *inside* the checked line — so even though the item
        // is checked, we want to show raw markup, no strike-through.
        let cursor = NSRange(location: 6, length: 0)
        highlighter.highlight(textStorage: storage,
                              isDark: false,
                              cursorRange: cursor)

        let matches = CheckboxOverlayManager.extractMatches(from: source)
        guard let match = matches.first else { XCTFail("No match"); return }
        let strike = storage.attribute(.strikethroughStyle,
                                        at: match.textRange.location,
                                        effectiveRange: nil) as? Int
        XCTAssertNil(strike,
                     "Strike-through should lift when the cursor is on the line")
    }

    // MARK: - Toggle roundtrip via NSTextStorage

    func testToggleReplacementRoundtrip() {
        // We don't drive the full Coordinator here (NSTextView fixture
        // is heavy); instead we exercise the same string transformation
        // that `Coordinator.toggleCheckbox(at:to:)` does, and verify
        // the next extract picks up the new state.
        var source = "- [ ] item\n"
        let firstMatches = CheckboxOverlayManager.extractMatches(from: source)
        guard let first = firstMatches.first else { XCTFail(); return }
        XCTAssertFalse(first.checked)

        let ns = NSMutableString(string: source)
        ns.replaceCharacters(in: first.boxRange, with: "[x]")
        source = ns as String

        let after = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(after.count, 1)
        XCTAssertTrue(after.first?.checked ?? false,
                      "After replacing `[ ]` with `[x]`, the next extract must report checked = true")

        // Round-trip back to unchecked.
        let ns2 = NSMutableString(string: source)
        guard let secondMatch = after.first else { XCTFail(); return }
        ns2.replaceCharacters(in: secondMatch.boxRange, with: "[ ]")
        let roundtrip = CheckboxOverlayManager.extractMatches(from: ns2 as String)
        XCTAssertFalse(roundtrip.first?.checked ?? true)
    }

    // MARK: - Protected ranges (code-fence / math) — Q8

    func testProtectedRangesCoverFencedCode() {
        let source = """
        - [ ] real task

        ```
        - [ ] fake task inside code
        ```
        """
        let ranges = CheckboxOverlayManager.protectedRanges(in: source)
        XCTAssertEqual(ranges.count, 1, "the fenced block should be one protected range")

        // The real task line is NOT protected; the fenced one IS.
        let matches = CheckboxOverlayManager.extractMatches(from: source)
        XCTAssertEqual(matches.count, 2)
        let realInside = ranges.contains { NSLocationInRange(matches[0].lineRange.location, $0) }
        let fakeInside = ranges.contains { NSLocationInRange(matches[1].lineRange.location, $0) }
        XCTAssertFalse(realInside, "the top-level task must not be inside a protected range")
        XCTAssertTrue(fakeInside, "the checkbox inside ``` must be inside a protected range")
    }

    func testCheckboxInsideCodeFenceIsNotConcealed() {
        // The highlighter must leave a `- [ ]` inside a code fence alone —
        // no concealment, so the overlay manager (which excludes protected
        // ranges) and the highlighter agree it's not a real checkbox.
        let highlighter = SyntaxHighlighter()
        let source = "```\n- [x] inside code\n```\n"
        let storage = makeStorage(source)
        let cursor = NSRange(location: source.utf16.count, length: 0)
        highlighter.highlight(textStorage: storage, isDark: false, cursorRange: cursor)

        let matches = CheckboxOverlayManager.extractMatches(from: source)
        guard let match = matches.first else { XCTFail("No match"); return }
        // boxRange should NOT be concealed to clear — it's code, styled as code.
        let attr = storage.attribute(.foregroundColor,
                                     at: match.boxRange.location,
                                     effectiveRange: nil) as? NSColor
        XCTAssertNotEqual(attr?.alphaComponent, 0,
                          "checkbox markup inside a code fence must not be concealed")
    }

    func testOffViewportCheckboxStillConcealed() {
        // F2-new-code: even when the highlight pass is viewport-restricted
        // to a slice that excludes the checkbox line, the box markup must
        // still be concealed (the overlay sits on top regardless of
        // viewport, so an un-concealed `[ ]` would peek through).
        let highlighter = SyntaxHighlighter()
        let body = Array(repeating: "filler line\n", count: 50).joined()
        let source = "- [ ] task at top\n" + body
        let storage = makeStorage(source)
        // Viewport far below the checkbox; cursor also far away.
        let farViewport = NSRange(location: source.utf16.count - 40, length: 40)
        let cursor = NSRange(location: source.utf16.count, length: 0)
        highlighter.highlight(textStorage: storage,
                              isDark: false,
                              cursorRange: cursor,
                              viewportRange: farViewport)

        let match = CheckboxOverlayManager.extractMatches(from: source)[0]
        let attr = storage.attribute(.foregroundColor,
                                     at: match.boxRange.location,
                                     effectiveRange: nil) as? NSColor
        XCTAssertEqual(attr?.alphaComponent, 0,
                       "off-viewport checkbox markup must still be concealed")
    }
}
