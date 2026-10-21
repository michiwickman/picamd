import XCTest
@testable import PicaMD

/// The line operations on documents with Windows line breaks.
///
/// In Swift "\r\n" is one Character, so `hasSuffix("\n")` is false for a
/// CRLF line and `removeLast()` drops both characters at once. The line
/// edits used both to decide where a line ends: Move Line added a bare
/// "\n" behind a CRLF line, Duplicate Line computed the caret from
/// `Character` counts, and a heading change lost the line break entirely
/// and joined the line with the next one. Every edit must keep CRLF as
/// CRLF and leave no lone "\r" or "\n" behind.
final class MarkdownEditsCRLFTests: XCTestCase {

    /// Every "\n" preceded by "\r" and every "\r" followed by "\n".
    private func assertOnlyCRLF(_ text: String, file: StaticString = #filePath, line: UInt = #line) {
        let units = Array(text.utf16)
        for (i, u) in units.enumerated() {
            if u == 0x0A {
                XCTAssertTrue(i > 0 && units[i - 1] == 0x0D, "lone \\n at \(i) in \(text.debugDescription)",
                              file: file, line: line)
            }
            if u == 0x0D {
                XCTAssertTrue(i + 1 < units.count && units[i + 1] == 0x0A,
                              "lone \\r at \(i) in \(text.debugDescription)", file: file, line: line)
            }
        }
    }

    private func caret(_ location: Int) -> NSRange { NSRange(location: location, length: 0) }

    // MARK: - Move line

    func testMoveLineUpKeepsCRLF() {
        let text = "one\r\ntwo\r\nthree\r\n"
        let r = MarkdownEdits.moveLine(direction: .up, in: text, selection: caret(6))
        XCTAssertEqual(r.text, "two\r\none\r\nthree\r\n")
        XCTAssertEqual(r.selection, caret(1))
        assertOnlyCRLF(r.text)
    }

    func testMoveLineDownKeepsCRLF() {
        let text = "one\r\ntwo\r\nthree\r\n"
        let r = MarkdownEdits.moveLine(direction: .down, in: text, selection: caret(1))
        XCTAssertEqual(r.text, "two\r\none\r\nthree\r\n")
        XCTAssertEqual(r.selection, caret(6))
        assertOnlyCRLF(r.text)
    }

    func testMoveLastLineUpWithoutTrailingBreak() {
        let text = "one\r\ntwo"
        let r = MarkdownEdits.moveLine(direction: .up, in: text, selection: caret(6))
        XCTAssertEqual(r.text, "two\r\none")
        XCTAssertEqual(r.selection, caret(1))
        assertOnlyCRLF(r.text)
    }

    func testMoveLineDownOntoLastLineWithoutTrailingBreak() {
        let text = "one\r\ntwo"
        let r = MarkdownEdits.moveLine(direction: .down, in: text, selection: caret(1))
        XCTAssertEqual(r.text, "two\r\none")
        XCTAssertEqual(r.selection, caret(6))
        assertOnlyCRLF(r.text)
    }

    /// Same case with LF: the block used to land glued to the last line
    /// ("ba\n") because only a block without a break was compensated.
    func testMoveLineDownOntoLastLineWithoutTrailingBreakLF() {
        let r = MarkdownEdits.moveLine(direction: .down, in: "a\nb", selection: caret(0))
        XCTAssertEqual(r.text, "b\na")
        XCTAssertEqual(r.selection, caret(2))
    }

    func testMoveMultiLineSelectionKeepsCRLF() {
        let text = "alpha\r\nbeta\r\ngamma\r\ndelta"
        let sel = NSRange(location: 7, length: 9)   // "beta\r\ngam"
        let up = MarkdownEdits.moveLine(direction: .up, in: text, selection: sel)
        XCTAssertEqual(up.text, "beta\r\ngamma\r\nalpha\r\ndelta")
        assertOnlyCRLF(up.text)
        let down = MarkdownEdits.moveLine(direction: .down, in: text, selection: sel)
        XCTAssertEqual(down.text, "alpha\r\ndelta\r\nbeta\r\ngamma")
        assertOnlyCRLF(down.text)
    }

    // MARK: - Duplicate

    func testDuplicateLineKeepsCRLFAndCaretColumn() {
        let text = "first\r\nsecond\r\n"
        let r = MarkdownEdits.duplicate(in: text, selection: caret(9))   // "se|cond"
        XCTAssertEqual(r.text, "first\r\nsecond\r\nsecond\r\n")
        // Same column on the copy: 9 + "second\r\n".utf16.count
        XCTAssertEqual(r.selection, caret(17))
        assertOnlyCRLF(r.text)
    }

    func testDuplicateLastLineWithoutBreakUsesTheDocumentsBreak() {
        let text = "first\r\nsecond"
        let r = MarkdownEdits.duplicate(in: text, selection: caret(9))
        XCTAssertEqual(r.text, "first\r\nsecond\r\nsecond")
        XCTAssertEqual(r.selection, caret(17))
        assertOnlyCRLF(r.text)
    }

    func testDuplicateSelectionAcrossCRLFPlacesCaretAfterTheCopy() {
        let text = "a\r\nb"
        let sel = NSRange(location: 0, length: 4)
        let r = MarkdownEdits.duplicate(in: text, selection: sel)
        XCTAssertEqual(r.text, "a\r\nba\r\nb")
        XCTAssertEqual(r.selection, caret(8))
    }

    // MARK: - Headings

    func testHeadingOnCRLFLineKeepsTheBreak() {
        let text = "Title\r\nBody\r\n"
        let r = MarkdownEdits.setHeading(level: 2, in: text, selection: caret(1))
        XCTAssertEqual(r.text, "## Title\r\nBody\r\n")
        assertOnlyCRLF(r.text)
    }

    func testHeadingOffOnCRLFLineKeepsTheBreak() {
        let text = "## Title\r\nBody\r\n"
        let r = MarkdownEdits.setHeading(level: 2, in: text, selection: caret(4))
        XCTAssertEqual(r.text, "Title\r\nBody\r\n")
        assertOnlyCRLF(r.text)
    }

    func testHeadingOverSeveralCRLFLines() {
        let text = "a\r\nb\r\nc"
        let r = MarkdownEdits.setHeading(level: 1, in: text, selection: NSRange(location: 0, length: 7))
        XCTAssertEqual(r.text, "# a\r\n# b\r\n# c")
        assertOnlyCRLF(r.text)
    }

    // MARK: - Format transforms (checklist, quote, inline, table)

    func testChecklistToggleKeepsCRLF() {
        let text = "one\r\ntwo\r\n"
        let on = MarkdownEdits.toggleChecklist(in: text, selection: NSRange(location: 0, length: 8))
        XCTAssertEqual(on.text, "- [ ] one\r\n- [ ] two\r\n")
        assertOnlyCRLF(on.text)
        let off = MarkdownEdits.toggleChecklist(in: on.text, selection: NSRange(location: 0, length: 20))
        XCTAssertEqual(off.text, text)
    }

    func testQuoteToggleKeepsCRLF() {
        let text = "one\r\n\r\ntwo\r\n"
        let on = MarkdownEdits.toggleQuote(in: text, selection: NSRange(location: 0, length: 10))
        XCTAssertEqual(on.text, "> one\r\n>\r\n> two\r\n")
        assertOnlyCRLF(on.text)
        let off = MarkdownEdits.toggleQuote(in: on.text, selection: NSRange(location: 0, length: 16))
        XCTAssertEqual(off.text, "one\r\n\r\ntwo\r\n")
    }

    func testInlineStyleOverCRLFLinesWrapsEachLine() {
        let text = "one\r\ntwo"
        let r = MarkdownEdits.toggleInline(.bold, in: text, selection: NSRange(location: 0, length: 8))
        XCTAssertEqual(r.text, "**one**\r\n**two**")
        assertOnlyCRLF(r.text)
    }

    func testTableInsertUsesCRLF() {
        let text = "Intro\r\n"
        let r = MarkdownEdits.insertTable(in: text, selection: caret(7))
        assertOnlyCRLF(r.text)
        XCTAssertTrue(r.text.hasPrefix("Intro\r\n\r\n| Column 1"))
    }

    /// The overlay's click toggle swaps exactly the three box characters.
    func testCheckboxClickToggleRangeOnCRLFLine() {
        let text = "- [ ] one\r\n- [x] two\r\n"
        let matches = CheckboxOverlayManager.extractMatches(from: text)
        XCTAssertEqual(matches.count, 2)
        let ns = text as NSString
        for m in matches {
            let box = ns.substring(with: m.boxRange)
            XCTAssertTrue(box == "[ ]" || box == "[x]", box)
            XCTAssertFalse(ns.substring(with: m.lineRange).contains("\r"),
                           "the line range must stop before the break")
        }
    }

    // MARK: - Smart punctuation guard

    func testSmartPunctuationStaysOutOfCRLFFrontmatter() {
        let text = "---\r\ntitle: a--\r\n---\r\n"
        XCTAssertFalse(MarkdownEdits.smartPunctuationAllowed(in: text, at: 15))
    }
}

/// Typing Return in a CRLF document.
@MainActor
final class NewlineCRLFTests: XCTestCase {

    private func editor(_ text: String) -> PicaMDTextView {
        let textView = PicaMDTextView()
        textView.isEditable = true
        textView.string = text
        return textView
    }

    func testReturnInsertsCRLFInACRLFDocument() {
        let tv = editor("one\r\ntwo\r\n")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "one\r\n\r\ntwo\r\n")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 5, length: 0))
    }

    func testReturnInsertsLFInAnLFDocument() {
        let tv = editor("one\ntwo\n")
        tv.setSelectedRange(NSRange(location: 3, length: 0))
        tv.insertNewline(nil)
        XCTAssertEqual(tv.string, "one\n\ntwo\n")
    }
}
