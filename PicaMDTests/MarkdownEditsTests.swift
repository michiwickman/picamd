import XCTest
@testable import PicaMD

final class MarkdownEditsTests: XCTestCase {

    // MARK: - Heading level

    func testSetH1OnPlainLine() {
        let text = "Hello world\nSecond line"
        let cursor = NSRange(location: 5, length: 0)
        let result = MarkdownEdits.setHeading(level: 1, in: text, selection: cursor)
        XCTAssertEqual(result.text, "# Hello world\nSecond line")
    }

    func testToggleH1OffOnAlreadyH1() {
        let text = "# Hello\nNext"
        let cursor = NSRange(location: 0, length: 0)
        let result = MarkdownEdits.setHeading(level: 1, in: text, selection: cursor)
        XCTAssertEqual(result.text, "Hello\nNext", "Same level toggles back to paragraph")
    }

    func testChangeFromH2ToH3() {
        let text = "## Section"
        let cursor = NSRange(location: 0, length: 0)
        let result = MarkdownEdits.setHeading(level: 3, in: text, selection: cursor)
        XCTAssertEqual(result.text, "### Section")
    }

    func testParagraphFromH4() {
        let text = "#### Subsubsection"
        let cursor = NSRange(location: 0, length: 0)
        let result = MarkdownEdits.setHeading(level: 0, in: text, selection: cursor)
        XCTAssertEqual(result.text, "Subsubsection")
    }

    // MARK: - Move line

    func testMoveLineUp() {
        let text = "line one\nline two\nline three"
        // Cursor in "line two"
        let cursor = NSRange(location: 12, length: 0)
        let result = MarkdownEdits.moveLine(direction: .up, in: text, selection: cursor)
        XCTAssertEqual(result.text, "line two\nline one\nline three")
    }

    func testMoveLineDown() {
        let text = "line one\nline two\nline three"
        let cursor = NSRange(location: 0, length: 0)  // in "line one"
        let result = MarkdownEdits.moveLine(direction: .down, in: text, selection: cursor)
        XCTAssertEqual(result.text, "line two\nline one\nline three")
    }

    func testMoveLineUpAtTopIsNoop() {
        let text = "first\nsecond"
        let cursor = NSRange(location: 0, length: 0)
        let result = MarkdownEdits.moveLine(direction: .up, in: text, selection: cursor)
        XCTAssertEqual(result.text, text)
    }

    func testMoveLineDownAtBottomIsNoop() {
        let text = "first\nsecond"
        let cursor = NSRange(location: 9, length: 0)  // in "second"
        let result = MarkdownEdits.moveLine(direction: .down, in: text, selection: cursor)
        XCTAssertEqual(result.text, text)
    }

    func testMoveMultiLineSelectionUp() {
        let text = "alpha\nbeta\ngamma\ndelta"
        // Select "beta" through middle of "gamma"
        let selection = NSRange(location: 6, length: 8)  // "beta\ngamm"
        let result = MarkdownEdits.moveLine(direction: .up, in: text, selection: selection)
        XCTAssertEqual(result.text, "beta\ngamma\nalpha\ndelta")
    }

    // MARK: - Duplicate

    func testDuplicateCurrentLine() {
        let text = "first\nsecond"
        let cursor = NSRange(location: 8, length: 0)  // in "second"
        let result = MarkdownEdits.duplicate(in: text, selection: cursor)
        XCTAssertEqual(result.text, "first\nsecond\nsecond")
    }

    func testDuplicateSelection() {
        let text = "Hello world"
        let selection = NSRange(location: 6, length: 5)  // "world"
        let result = MarkdownEdits.duplicate(in: text, selection: selection)
        XCTAssertEqual(result.text, "Hello worldworld")
    }

    func testDuplicateLineWithoutTrailingNewline() {
        let text = "alone"
        let cursor = NSRange(location: 2, length: 0)
        let result = MarkdownEdits.duplicate(in: text, selection: cursor)
        XCTAssertEqual(result.text, "alone\nalone")
    }

    // MARK: - Select line

    func testSelectLineSelectsCurrentLine() {
        let text = "first line\nsecond line"
        let cursor = NSRange(location: 5, length: 0)
        let result = MarkdownEdits.selectLine(in: text, selection: cursor)
        XCTAssertEqual(result.selection.location, 0)
        XCTAssertEqual(result.selection.length, 11)  // includes the \n
    }

    func testSelectLineExpandsAcrossSelection() {
        let text = "first\nsecond\nthird"
        let selection = NSRange(location: 3, length: 5)  // crosses lines 1+2
        let result = MarkdownEdits.selectLine(in: text, selection: selection)
        XCTAssertEqual(result.selection.location, 0)
        // First line "first\n" (6) + second line "second\n" (7) = 13
        XCTAssertEqual(result.selection.length, 13)
    }

    // MARK: - Auto-pair

    func testAutoPairWrapsSelection() {
        let text = "Hello world"
        let selection = NSRange(location: 6, length: 5)  // "world"
        let result = MarkdownEdits.autoPair(input: "(", in: text, selection: selection)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.text, "Hello (world)")
        XCTAssertEqual(result?.selection.location, 7)
        XCTAssertEqual(result?.selection.length, 5)
    }

    func testAutoPairInsertsAndPositionsCursorBetween() {
        let text = "Hello "
        let cursor = NSRange(location: 6, length: 0)
        let result = MarkdownEdits.autoPair(input: "[", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "Hello []")
        XCTAssertEqual(result?.selection.location, 7)
    }

    func testAutoPairSkipsUnknownChar() {
        let result = MarkdownEdits.autoPair(input: "x", in: "abc", selection: NSRange(location: 1, length: 0))
        XCTAssertNil(result)
    }

    func testAutoSkipHopsOverClosingBracket() {
        let text = "fn()"
        let cursor = NSRange(location: 3, length: 0)  // before ')'
        let result = MarkdownEdits.autoSkip(closing: ")", in: text, selection: cursor)
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.selection.location, 4)
        XCTAssertEqual(result?.text, text, "Auto-skip should not insert anything")
    }

    func testAutoSkipReturnsNilIfMismatch() {
        let text = "fn()"
        let cursor = NSRange(location: 3, length: 0)
        let result = MarkdownEdits.autoSkip(closing: "}", in: text, selection: cursor)
        XCTAssertNil(result)
    }

    // MARK: - Smart punctuation

    /// The trigger test runs before the document scan in `insertText`, so
    /// it must accept every character smart punctuation can rewrite after
    /// and nothing else.
    func testSmartPunctuationTriggerMatchesTheRewrites() {
        let contexts = ["Hello ", "Hello -", "Hello –", "Hello ..", "x", ""]
        for scalar in (0x20...0x7E).compactMap(UnicodeScalar.init) {
            let input = String(Character(scalar))
            var rewrites = false
            for context in contexts {
                let text = context + input
                let cursor = NSRange(location: (text as NSString).length, length: 0)
                if MarkdownEdits.smartPunctuation(after: input, in: text, selection: cursor) != nil {
                    rewrites = true
                }
            }
            XCTAssertEqual(MarkdownEdits.isSmartPunctuationTrigger(input), rewrites,
                           "trigger set and rewrites disagree on \(input)")
        }
        XCTAssertFalse(MarkdownEdits.isSmartPunctuationTrigger("ab"))
    }

    func testSmartDoubleHyphenToEnDash() {
        // Simulate: text already contains the just-typed second `-`
        let text = "Hello --"
        let cursor = NSRange(location: 8, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: "-", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "Hello –")
    }

    func testSmartTripleHyphenToEmDash() {
        let text = "Hello –-"
        let cursor = NSRange(location: 8, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: "-", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "Hello —")
    }

    func testSmartTripleDotToEllipsis() {
        let text = "Wait..."
        let cursor = NSRange(location: 7, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: ".", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "Wait…")
    }

    func testSmartOpenDoubleQuoteAtSentenceStart() {
        let text = "He said \""
        let cursor = NSRange(location: 9, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: "\"", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "He said “")
    }

    func testSmartCloseDoubleQuoteAfterWord() {
        let text = "the \"world\""
        // Cursor at end, after the closing "
        let cursor = NSRange(location: 11, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: "\"", in: text, selection: cursor)
        // The just-typed quote (last char) should become a closing curly quote
        XCTAssertEqual(result?.text.last, "”")
    }

    func testApostropheBetweenLetters() {
        let text = "don't"
        let cursor = NSRange(location: 4, length: 0)
        let result = MarkdownEdits.smartPunctuation(after: "'", in: text, selection: cursor)
        XCTAssertEqual(result?.text, "don’t")
    }
}
