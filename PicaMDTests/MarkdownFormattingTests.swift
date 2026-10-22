import XCTest
import AppKit
@testable import PicaMD

/// Format ▸ Bold … Table as text transforms (`MarkdownFormatting.swift`).
final class MarkdownFormattingTests: XCTestCase {

    private func range(of needle: String, in text: String) -> NSRange {
        (text as NSString).range(of: needle)
    }

    private func toggle(_ style: InlineStyle, _ text: String, _ selection: NSRange) -> MarkdownEdits.Result {
        MarkdownEdits.toggleInline(style, in: text, selection: selection)
    }

    // MARK: - Bold, italic, strikethrough, code: selection

    func testBoldWrapsTheSelectionAndKeepsItSelected() {
        let r = toggle(.bold, "Hello world", NSRange(location: 6, length: 5))
        XCTAssertEqual(r.text, "Hello **world**")
        XCTAssertEqual(r.selection, NSRange(location: 8, length: 5))
    }

    func testBoldTogglesOffWhenMarkersAreJustOutside() {
        let r = toggle(.bold, "Hello **world**", NSRange(location: 8, length: 5))
        XCTAssertEqual(r.text, "Hello world")
        XCTAssertEqual(r.selection, NSRange(location: 6, length: 5))
    }

    func testBoldTogglesOffWhenMarkersAreSelectedToo() {
        let r = toggle(.bold, "Hello **world**", NSRange(location: 6, length: 9))
        XCTAssertEqual(r.text, "Hello world")
        XCTAssertEqual(r.selection, NSRange(location: 6, length: 5))
        XCTAssertEqual(toggle(.bold, "Say __hi__", NSRange(location: 4, length: 6)).text, "Say hi",
                       "underscore bold counts too")
    }

    func testOuterSpacesStayOutsideTheMarkers() {
        let r = toggle(.bold, "a  word  b", NSRange(location: 1, length: 8))
        XCTAssertEqual(r.text, "a  **word**  b")
        XCTAssertEqual(r.selection, NSRange(location: 5, length: 4))
    }

    func testItalicAndBoldNest() {
        let bold = "**x**"
        let italicOnBold = toggle(.italic, bold, NSRange(location: 2, length: 1))
        XCTAssertEqual(italicOnBold.text, "***x***")
        XCTAssertEqual(italicOnBold.selection, NSRange(location: 3, length: 1))
        XCTAssertEqual(toggle(.italic, "***x***", NSRange(location: 3, length: 1)).text, "**x**")
        XCTAssertEqual(toggle(.bold, "***x***", NSRange(location: 3, length: 1)).text, "*x*")
        XCTAssertEqual(toggle(.italic, "*x*", NSRange(location: 1, length: 1)).text, "x")
        XCTAssertEqual(toggle(.bold, "*x*", NSRange(location: 1, length: 1)).text, "***x***",
                       "bold on italic adds, it doesn't eat the italic marker")
    }

    func testUnderscoresInsideAWordAreNotItalic() {
        let text = "snake_case_name"
        let r = toggle(.italic, text, range(of: "case", in: text))
        XCTAssertEqual(r.text, "snake_*case*_name")
        XCTAssertEqual(toggle(.italic, "an _idea_ here", NSRange(location: 4, length: 4)).text, "an idea here")
    }

    func testStrikethroughToggles() {
        let on = toggle(.strikethrough, "old price", NSRange(location: 0, length: 3))
        XCTAssertEqual(on.text, "~~old~~ price")
        XCTAssertEqual(toggle(.strikethrough, on.text, on.selection).text, "old price")
    }

    func testInlineCodeUsesALongerFenceAroundBackticks() {
        XCTAssertEqual(toggle(.code, "run ls -la", NSRange(location: 4, length: 6)).text, "run `ls -la`")
        XCTAssertEqual(toggle(.code, "a`b", NSRange(location: 0, length: 3)).text, "``a`b``")
        let padded = toggle(.code, "`x", NSRange(location: 0, length: 2))
        XCTAssertEqual(padded.text, "`` `x ``")
        XCTAssertEqual(padded.selection, NSRange(location: 3, length: 2))
        XCTAssertEqual(toggle(.code, padded.text, padded.selection).text, "`x", "the padding goes with the fence")
        XCTAssertEqual(toggle(.code, "`` `x ``", NSRange(location: 0, length: 8)).text, "`x")
    }

    // MARK: - Caret

    func testCaretInAWordStylesTheWord() {
        let r = toggle(.bold, "Hello world", NSRange(location: 8, length: 0))
        XCTAssertEqual(r.text, "Hello **world**")
        XCTAssertEqual(r.selection, NSRange(location: 10, length: 0), "caret stays on the same letter")
        let back = toggle(.bold, r.text, r.selection)
        XCTAssertEqual(back.text, "Hello world")
        XCTAssertEqual(back.selection, NSRange(location: 8, length: 0))
    }

    func testCaretAtTheEndOfAWordStylesIt() {
        XCTAssertEqual(toggle(.italic, "don't stop", NSRange(location: 5, length: 0)).text, "*don't* stop")
        XCTAssertEqual(toggle(.bold, "a well-known fact", NSRange(location: 4, length: 0)).text,
                       "a **well-known** fact")
    }

    func testCaretInsideAStyledPhraseUnwrapsThePhrase() {
        let text = "a **two words** b"
        let caret = range(of: "words", in: text).location + 2
        let r = toggle(.bold, text, NSRange(location: caret, length: 0))
        XCTAssertEqual(r.text, "a two words b")
        XCTAssertEqual(r.selection, NSRange(location: caret - 2, length: 0))
        XCTAssertEqual(toggle(.italic, "make it *pop* now", NSRange(location: 10, length: 0)).text,
                       "make it pop now")
        XCTAssertEqual(toggle(.code, "use `git log` here", NSRange(location: 9, length: 0)).text,
                       "use git log here")
    }

    func testCaretOutsideAWordInsertsAnEmptyPairAndTakesItOutAgain() {
        let r = toggle(.bold, "Hello ", NSRange(location: 6, length: 0))
        XCTAssertEqual(r.text, "Hello ****")
        XCTAssertEqual(r.selection, NSRange(location: 8, length: 0))
        let back = toggle(.bold, r.text, r.selection)
        XCTAssertEqual(back.text, "Hello ")
        XCTAssertEqual(back.selection, NSRange(location: 6, length: 0))
        XCTAssertEqual(toggle(.code, "", NSRange(location: 0, length: 0)).text, "``")
    }

    // MARK: - Several lines, lists, CRLF

    func testSeveralLinesAreStyledLineByLineAndBack() {
        let text = "- one\n- two\n"
        let on = toggle(.bold, text, NSRange(location: 0, length: 11))
        XCTAssertEqual(on.text, "- **one**\n- **two**\n", "bullets stay outside, markers don't cross lines")
        XCTAssertEqual(on.selection, NSRange(location: 4, length: 13))
        let off = toggle(.bold, on.text, on.selection)
        XCTAssertEqual(off.text, text)
    }

    func testPartialLinesAndPrefixes() {
        let text = "alpha beta\ngamma delta"
        let sel = NSRange(location: 6, length: 10) // "beta\ngamma"
        XCTAssertEqual(toggle(.italic, text, sel).text, "alpha *beta*\n*gamma* delta")
        XCTAssertEqual(toggle(.bold, "# Title", NSRange(location: 0, length: 7)).text, "# **Title**")
        XCTAssertEqual(toggle(.bold, "> - [ ] task", NSRange(location: 0, length: 12)).text, "> - [ ] **task**")
        XCTAssertEqual(toggle(.bold, "  1. step", NSRange(location: 0, length: 9)).text, "  1. **step**")
    }

    func testMixedLinesAllGetTheStyle() {
        let text = "**one**\ntwo"
        XCTAssertEqual(toggle(.bold, text, NSRange(location: 0, length: 11)).text, "**one**\n**two**")
    }

    func testCRLFLinesKeepTheirBreaks() {
        let r = toggle(.bold, "one\r\ntwo", NSRange(location: 0, length: 8))
        XCTAssertEqual(r.text, "**one**\r\n**two**")
        XCTAssertEqual(toggle(.bold, r.text, r.selection).text, "one\r\ntwo")
    }

    // MARK: - Several spans in one selection

    func testTwoSpansAreNotTakenForOne() {
        let text = "**a** **b**"
        let inner = toggle(.bold, text, NSRange(location: 2, length: 7)) // "a** **b"
        XCTAssertEqual(inner.text, "a b", "each span loses its own markers")
        XCTAssertEqual(inner.selection, NSRange(location: 0, length: 3))

        let line = "**Note:** text **important**"
        let off = toggle(.bold, line, NSRange(location: 0, length: (line as NSString).length))
        XCTAssertEqual(off.text, "Note: text important")
        XCTAssertEqual(off.selection, NSRange(location: 0, length: 20))
        XCTAssertEqual(toggle(.bold, off.text, off.selection).text, "**Note: text important**",
                       "a second toggle styles the whole selection")

        XCTAssertEqual(toggle(.italic, "*a* *b*", NSRange(location: 1, length: 5)).text, "a b")
        XCTAssertEqual(toggle(.italic, "_a_ and _b_", NSRange(location: 0, length: 11)).text, "a and b")
        XCTAssertEqual(toggle(.strikethrough, "~~a~~ ~~b~~", NSRange(location: 0, length: 11)).text, "a b")
        XCTAssertEqual(toggle(.code, "`a` `b`", NSRange(location: 0, length: 7)).text, "a b")
    }

    func testOneSpanWithMarkersInsideStillUnwraps() {
        XCTAssertEqual(toggle(.bold, "**a *b* c**", NSRange(location: 0, length: 11)).text, "a *b* c",
                       "italic inside bold doesn't close the bold")
        XCTAssertEqual(toggle(.italic, "*a **b** c*", NSRange(location: 0, length: 11)).text, "a **b** c",
                       "bold inside italic doesn't close the italic")
        XCTAssertEqual(toggle(.italic, "_snake_case_", NSRange(location: 0, length: 12)).text, "snake_case",
                       "an underscore inside a word closes nothing")
        XCTAssertEqual(toggle(.code, "``a`b``", NSRange(location: 2, length: 3)).text, "a`b",
                       "a shorter backtick run inside the fence is code text")
    }

    func testSelectionInsideASpanUnwrapsIt() {
        let r = toggle(.bold, "**a b c**", NSRange(location: 4, length: 1)) // "b"
        XCTAssertEqual(r.text, "a b c", "no `**a **b** c**`")
        XCTAssertEqual(r.selection, NSRange(location: 2, length: 1))
    }

    func testSeveralSpansOnSeveralLines() {
        let text = "**a** **b**\n**c**"
        let off = toggle(.bold, text, NSRange(location: 0, length: 17))
        XCTAssertEqual(off.text, "a b\nc")
        XCTAssertEqual(off.selection, NSRange(location: 0, length: 5))
        XCTAssertEqual(toggle(.bold, "**a** **b**\nc", NSRange(location: 0, length: 13)).text,
                       "**a** **b**\n**c**", "the unstyled line gets the style, the styled one stays")
    }

    func testBlankSelectionChangesNothing() {
        let r = toggle(.bold, "a\n\nb", NSRange(location: 1, length: 2))
        XCTAssertEqual(r.text, "a\n\nb")
    }

    // MARK: - Link

    func testLinkWrapsTheSelection() {
        let r = MarkdownEdits.setLink(url: "https://a.example", in: "see docs", selection: NSRange(location: 4, length: 4))
        XCTAssertEqual(r.text, "see [docs](https://a.example)")
        XCTAssertEqual(r.selection, NSRange(location: 29, length: 0), "caret after the link")
    }

    func testLinkWithoutURLPutsTheCaretIntoTheURL() {
        let r = MarkdownEdits.setLink(url: "  ", in: "see docs", selection: NSRange(location: 4, length: 4))
        XCTAssertEqual(r.text, "see [docs]()")
        XCTAssertEqual(r.selection, NSRange(location: 11, length: 0))
    }

    func testLinkWithoutTextPutsTheCaretIntoTheText() {
        let r = MarkdownEdits.setLink(url: "https://x.example", in: "see ", selection: NSRange(location: 4, length: 0))
        XCTAssertEqual(r.text, "see [](https://x.example)")
        XCTAssertEqual(r.selection, NSRange(location: 5, length: 0))
    }

    func testLinkInsideALinkChangesOrRemovesIt() {
        let text = "a [t](old) b"
        let caret = NSRange(location: 3, length: 0)
        XCTAssertEqual(MarkdownEdits.link(enclosing: caret, in: text)?.url, NSRange(location: 6, length: 3))
        let changed = MarkdownEdits.setLink(url: "new", in: text, selection: caret)
        XCTAssertEqual(changed.text, "a [t](new) b")
        XCTAssertEqual(changed.selection, NSRange(location: 3, length: 1))
        let removed = MarkdownEdits.setLink(url: "", in: text, selection: caret)
        XCTAssertEqual(removed.text, "a t b")
        XCTAssertEqual(removed.selection, NSRange(location: 2, length: 1))
    }

    func testLinkDetectionSkipsImagesAndCaretsBehindALink() {
        XCTAssertNil(MarkdownEdits.link(enclosing: NSRange(location: 3, length: 0), in: "![alt](x.png)"))
        XCTAssertNil(MarkdownEdits.link(enclosing: NSRange(location: 6, length: 0), in: "[t](u) more"),
                     "a caret right after a link starts a new one")
    }

    func testLinkURLWithSpacesIsBracketed() {
        let r = MarkdownEdits.setLink(url: "my file.md", in: "x", selection: NSRange(location: 0, length: 1))
        XCTAssertEqual(r.text, "[x](<my file.md>)")
    }

    func testLinkSpansSeveralLinesAsSelected() {
        let r = MarkdownEdits.setLink(url: "u", in: "one\ntwo", selection: NSRange(location: 0, length: 7))
        XCTAssertEqual(r.text, "[one\ntwo](u)")
    }

    func testPasteboardURLCandidates() {
        XCTAssertEqual(MarkdownEdits.linkCandidate(fromPasteboard: " https://example.com/a?b=1 \n"),
                       "https://example.com/a?b=1")
        XCTAssertEqual(MarkdownEdits.linkCandidate(fromPasteboard: "mailto:me@example.com"), "mailto:me@example.com")
        XCTAssertNil(MarkdownEdits.linkCandidate(fromPasteboard: "just words"))
        XCTAssertNil(MarkdownEdits.linkCandidate(fromPasteboard: "example.com"))
        XCTAssertNil(MarkdownEdits.linkCandidate(fromPasteboard: "javascript:alert(1)"))
        XCTAssertNil(MarkdownEdits.linkCandidate(fromPasteboard: "https://"))
        XCTAssertNil(MarkdownEdits.linkCandidate(fromPasteboard: nil))
    }

    // MARK: - Checklist

    private func checklist(_ text: String, _ selection: NSRange) -> MarkdownEdits.Result {
        MarkdownEdits.toggleChecklist(in: text, selection: selection)
    }

    func testChecklistOnAPlainLine() {
        let r = checklist("Buy milk", NSRange(location: 3, length: 0))
        XCTAssertEqual(r.text, "- [ ] Buy milk")
        XCTAssertEqual(r.selection, NSRange(location: 9, length: 0), "caret stays on its letter")
        XCTAssertEqual(checklist(r.text, r.selection).text, "Buy milk")
    }

    func testChecklistConvertsListItems() {
        let r = checklist("- one\n* two\n1. three", NSRange(location: 0, length: 19))
        XCTAssertEqual(r.text, "- [ ] one\n* [ ] two\n1. [ ] three")
        XCTAssertEqual(r.selection, NSRange(location: 0, length: 31))
    }

    func testChecklistOffRemovesBoxesAndBullets() {
        XCTAssertEqual(checklist("- [ ] one\n- [x] two", NSRange(location: 0, length: 19)).text, "one\ntwo")
        XCTAssertEqual(checklist("1. [ ] first", NSRange(location: 0, length: 0)).text, "1. first",
                       "a numbered item keeps its number")
    }

    func testChecklistKeepsIndentQuotesAndBlankLines() {
        XCTAssertEqual(checklist("  - nested", NSRange(location: 4, length: 0)).text, "  - [ ] nested")
        XCTAssertEqual(checklist("> note", NSRange(location: 3, length: 0)).text, "> - [ ] note")
        XCTAssertEqual(checklist("a\n\nb", NSRange(location: 0, length: 4)).text, "- [ ] a\n\n- [ ] b")
        XCTAssertEqual(checklist("- [ ] a\nb", NSRange(location: 0, length: 9)).text, "- [ ] a\n- [ ] b",
                       "mixed: only the lines without a box get one")
    }

    func testChecklistOnAnEmptyLineAndCRLF() {
        let empty = checklist("", NSRange(location: 0, length: 0))
        XCTAssertEqual(empty.text, "- [ ] ")
        XCTAssertEqual(empty.selection, NSRange(location: 6, length: 0))
        XCTAssertEqual(checklist("a\r\nb", NSRange(location: 0, length: 4)).text, "- [ ] a\r\n- [ ] b")
        XCTAssertEqual(checklist("-", NSRange(location: 1, length: 0)).text, "- [ ] ")
    }

    // MARK: - Quote

    private func quote(_ text: String, _ selection: NSRange) -> MarkdownEdits.Result {
        MarkdownEdits.toggleQuote(in: text, selection: selection)
    }

    func testQuoteToggles() {
        let on = quote("text", NSRange(location: 2, length: 0))
        XCTAssertEqual(on.text, "> text")
        XCTAssertEqual(on.selection, NSRange(location: 4, length: 0))
        XCTAssertEqual(quote(on.text, on.selection).text, "text")
    }

    func testQuoteOverParagraphsKeepsOneQuote() {
        let on = quote("a\n\nb", NSRange(location: 0, length: 4))
        XCTAssertEqual(on.text, "> a\n>\n> b")
        XCTAssertEqual(quote(on.text, on.selection).text, "a\n\nb")
    }

    func testQuoteOnListsMixedLinesAndCRLF() {
        XCTAssertEqual(quote("- item", NSRange(location: 0, length: 0)).text, "> - item")
        XCTAssertEqual(quote("> a\nb", NSRange(location: 0, length: 5)).text, "> a\n> b")
        XCTAssertEqual(quote("a\r\nb", NSRange(location: 0, length: 4)).text, "> a\r\n> b")
        XCTAssertEqual(quote(">> nested", NSRange(location: 0, length: 0)).text, "> nested",
                       "one level comes off")
    }

    func testSelectionEndingAtALineStartLeavesThatLine() {
        XCTAssertEqual(quote("a\nb", NSRange(location: 0, length: 2)).text, "> a\nb")
    }

    // MARK: - Table

    private var table: String { MarkdownEdits.tableSkeleton.joined(separator: "\n") }

    func testTableInEmptyDocumentSelectsTheFirstHeaderCell() {
        let r = MarkdownEdits.insertTable(in: "", selection: NSRange(location: 0, length: 0))
        XCTAssertEqual(r.text, table + "\n")
        XCTAssertEqual(r.selection, NSRange(location: 2, length: 8))
        XCTAssertEqual((r.text as NSString).substring(with: r.selection), "Column 1")
        XCTAssertEqual(MarkdownEdits.tableSkeleton.count, 4, "header, separator, two rows")
        XCTAssertEqual(MarkdownEdits.tableSkeleton[0].filter { $0 == "|" }.count, 4, "three columns")
    }

    func testTableGetsLinesOfItsOwn() {
        let r = MarkdownEdits.insertTable(in: "Intro", selection: NSRange(location: 5, length: 0))
        XCTAssertEqual(r.text, "Intro\n\n" + table + "\n")
        XCTAssertEqual((r.text as NSString).substring(with: r.selection), "Column 1")

        let middle = MarkdownEdits.insertTable(in: "Intro\n\nMore", selection: NSRange(location: 6, length: 0))
        XCTAssertEqual(middle.text, "Intro\n\n" + table + "\n\nMore")

        let split = MarkdownEdits.insertTable(in: "abcdef", selection: NSRange(location: 3, length: 0))
        XCTAssertEqual(split.text, "abc\n\n" + table + "\n\ndef")
    }

    func testTableKeepsTheSelectionAndCRLF() {
        let r = MarkdownEdits.insertTable(in: "Intro\r\nxx", selection: NSRange(location: 7, length: 2))
        let crlfTable = MarkdownEdits.tableSkeleton.joined(separator: "\r\n")
        XCTAssertEqual(r.text, "Intro\r\nxx\r\n\r\n" + crlfTable + "\r\n", "the selected text stays, the table follows it")
        XCTAssertEqual((r.text as NSString).substring(with: r.selection), "Column 1")

        let paragraph = "First.\n\nSecond.\n"
        let afterParagraph = MarkdownEdits.insertTable(in: paragraph, selection: NSRange(location: 0, length: 6))
        XCTAssertEqual(afterParagraph.text, "First.\n\n" + table + "\n\nSecond.\n")
    }

    // MARK: - Helpers

    func testLineContentsCoverTheTouchedLines() {
        let ns = "a\r\nbb\n" as NSString
        XCTAssertEqual(MarkdownEdits.lineContents(covering: NSRange(location: 0, length: 4), in: ns),
                       [NSRange(location: 0, length: 1), NSRange(location: 3, length: 2)])
        XCTAssertEqual(MarkdownEdits.lineContents(covering: NSRange(location: 6, length: 0), in: ns),
                       [NSRange(location: 6, length: 0)], "the empty line after the last break")
    }
}

/// The editor runs the commands as one named undo step.
@MainActor
final class EditorCommandTests: XCTestCase {

    @MainActor
    private final class UndoProvider: NSObject, NSTextViewDelegate {
        let undoManager = UndoManager()
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
    }

    private var provider: UndoProvider?

    private func makeEditor(_ text: String) -> PicaMDTextView {
        let textView = PicaMDTextView()
        textView.isEditable = true
        textView.allowsUndo = true
        textView.string = text
        let provider = UndoProvider()
        self.provider = provider
        textView.delegate = provider
        return textView
    }

    func testBoldIsOneNamedUndoStep() throws {
        let textView = makeEditor("Hello world")
        textView.setSelectedRange(NSRange(location: 6, length: 5))
        textView.runCommand(.bold)
        XCTAssertEqual(textView.string, "Hello **world**")
        let undo = try XCTUnwrap(provider?.undoManager)
        XCTAssertEqual(undo.undoActionName, "Bold")
        undo.undo()
        XCTAssertEqual(textView.string, "Hello world")
    }

    func testMenuSenderReachesTheEditor() throws {
        let textView = makeEditor("item")
        textView.performEditorCommand(EditorCommandSender(.checklist))
        XCTAssertEqual(textView.string, "- [ ] item")
        XCTAssertEqual(provider?.undoManager.undoActionName, "Checklist")
        textView.performEditorCommand(nil)
        XCTAssertEqual(textView.string, "- [ ] item", "no command, no change")
    }

    func testFormatMenuReachesOnlyTheKeyWindowsEditor() {
        let editor = makeEditor("x")
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                              styleMask: [.titled], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        window.contentView = editor
        XCTAssertTrue(window.makeFirstResponder(editor))
        XCTAssertTrue(PicaMDTextView.formatMenuTarget(in: window) === editor)

        // A sheet or other window in front: its first responder isn't an
        // editor, so the editor in the window behind stays untouched.
        let sheet = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100),
                             styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        let field = NSTextView()
        sheet.contentView = field
        XCTAssertTrue(sheet.makeFirstResponder(field))
        XCTAssertNil(PicaMDTextView.formatMenuTarget(in: sheet))
        XCTAssertNil(PicaMDTextView.formatMenuTarget(in: nil))

        window.makeFirstResponder(nil)
        XCTAssertNil(PicaMDTextView.formatMenuTarget(in: window), "editor not focused")
    }

    func testTableAndHeadingNames() {
        let textView = makeEditor("Title")
        textView.runCommand(.headingH2)
        XCTAssertEqual(textView.string, "## Title")
        XCTAssertEqual(provider?.undoManager.undoActionName, "Heading 2")
        textView.setSelectedRange(NSRange(location: 8, length: 0))
        textView.runCommand(.table)
        XCTAssertEqual(provider?.undoManager.undoActionName, "Insert Table")
        XCTAssertEqual(textView.selectedRange().length, 8, "first header cell selected")
    }

    func testReadOnlyEditorIgnoresCommands() {
        let textView = makeEditor("x")
        textView.isEditable = false
        textView.runCommand(.quote)
        XCTAssertEqual(textView.string, "x")
    }
}
