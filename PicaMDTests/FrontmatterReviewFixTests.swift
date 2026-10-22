import XCTest
import AppKit
import SwiftUI
@testable import PicaMD

/// Cases from the review of the editable front matter: the fence rule's
/// YAML check, quotes inside items, blank lines in an entry, values the
/// writer must not garble, the caret around inserted keys, and Backspace
/// behind the folded block.
final class FrontmatterFenceBodyTests: XCTestCase {

    private func range(_ source: String) -> NSRange? {
        Frontmatter.build(from: source).range
    }

    func testRuleAndProseBetweenRulesIsNotFrontmatter() {
        let src = "---\n\nIntro paragraph of my note.\n\n---\n\n# Heading\n"
        XCTAssertNil(range(src))
        XCTAssertNil(MarkdownRegexes.frontmatter.firstMatch(
            in: src, range: NSRange(location: 0, length: (src as NSString).length)))
        XCTAssertNil(Frontmatter.edit(source: src, field: .title, newValue: "T"),
                     "no key is written into the prose")
        XCTAssertNotNil(Frontmatter.lockReason(for: .title, in: src))
    }

    func testSetextUnderlineAfterARuleIsNotFrontmatter() {
        XCTAssertNil(range("---\nHeading\n---\nText\n"))
    }

    func testEveryYAMLLineShapeIsAccepted() {
        let src = "---\n# comment\ntitle: T\nnote:\n  nested: x\n\ntags:\n- a\n  - b\nurl: http://x.y/z\na:b c: d\n---\nBody"
        XCTAssertEqual(range(src)?.location, 0)
        XCTAssertEqual(Frontmatter.build(from: src).tags, ["a", "b"])
    }

    func testAColonWithoutASpaceIsNotAKeyLine() {
        XCTAssertNil(range("---\nratio 3:2 is common\n---\n"))
    }

    func testLongUnclosedBlockFailsQuickly() {
        let src = "---\n" + String(repeating: "- a: b: c\n", count: 20_000) + "text"
        let start = Date()
        XCTAssertNil(range(src))
        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "no exponential backtracking")
    }
}

final class FrontmatterQuoteAndBlankLineTests: XCTestCase {

    private func applied(_ source: String, _ edit: TextEdit?) throws -> String {
        let edit = try XCTUnwrap(edit)
        return (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
    }

    func testQuoteInsideAnItemIsPartOfIt() {
        XCTAssertEqual(Frontmatter.build(from: "---\ntags: [don't, x]\n---\n").tags, ["don't", "x"])
        XCTAssertEqual(Frontmatter.build(from: "---\ntags: don't, x\n---\n").tags, ["don't", "x"])
        XCTAssertEqual(Frontmatter.build(from: "---\ntags: [say \"hi\", x]\n---\n").tags, ["say \"hi\"", "x"])
        XCTAssertEqual(Frontmatter.build(from: "---\ntags: [\"a, b\", c]\n---\n").tags, ["a, b", "c"])
    }

    func testTagsWithQuotesRoundTripInEveryStyle() throws {
        let tags = ["don't", "say \"hi\"", "x"]
        for src in ["---\ntags: [a, b]\n---\n", "---\ntags: a, b\n---\n",
                    "---\ntags:\n  - a\n---\n", "---\ntags: ['a']\n---\n", "Body\n"] {
            let out = try applied(src, Frontmatter.edit(source: src, tags: tags))
            XCTAssertEqual(Frontmatter.build(from: out).tags, tags, out)
        }
    }

    func testBracketTagsInACommaScalarBecomeAnInlineArray() throws {
        let src = "---\ntags: a, b\n---\n"
        for tags in [["true", "]"], ["["], ["\"a\"", "b"]] {
            let out = try applied(src, Frontmatter.edit(source: src, tags: tags))
            XCTAssertEqual(Frontmatter.build(from: out).tags, tags, out)
        }
        XCTAssertEqual(try applied(src, Frontmatter.edit(source: src, tags: ["c", "d"])),
                       "---\ntags: c, d\n---\n", "plain tags keep the comma style")
    }

    func testBlockScalarWithABlankLineStaysOneEntry() throws {
        let src = "---\ntitle: |\n  a\n\n  b\nfoo: 1\n---\n"
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.title, "a\n\nb")
        XCTAssertEqual(try applied(src, Frontmatter.edit(source: src, field: .title, newValue: "")),
                       "---\nfoo: 1\n---\n")
        XCTAssertEqual(try applied(src, Frontmatter.edit(source: src, field: .title, newValue: "new")),
                       "---\ntitle: new\nfoo: 1\n---\n")
    }

    func testFoldedBlockScalarJoinsLinesAndKeepsParagraphs() {
        let fm = Frontmatter.build(from: "---\ntitle: >\n  a\n  b\n\n  c\n---\n")
        XCTAssertEqual(fm.title, "a b\nc")
    }

    func testBlankLinesBeforeTheNextKeyStayOutside() {
        let src = "---\ntitle: T\n\nfoo: 1\n---\n"
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.entries["title"].map { (src as NSString).substring(with: $0.range) }, "title: T\n")
    }

    func testMultiLinePlainScalarIsReadWhole() throws {
        let src = "---\ntitle: Foo\n  bar\ndate: 2026-10-03\n---\n"
        XCTAssertEqual(Frontmatter.build(from: src).title, "Foo bar")
        XCTAssertEqual(try applied(src, Frontmatter.edit(source: src, field: .title, newValue: "X")),
                       "---\ntitle: X\ndate: 2026-10-03\n---\n")
    }

    func testBlockListWithABlankLineBetweenItems() {
        XCTAssertEqual(Frontmatter.build(from: "---\ntags:\n  - a\n\n  - b\n---\n").tags, ["a", "b"])
    }
}

final class TextEditUnchangedEndsTests: XCTestCase {

    /// `a: 1` block; a new title goes in front of the closing fence.
    private let src = "---\na: 1\n---\nbody\n"

    func testCaretOnTheClosingFenceStaysOnIt() throws {
        let edit = try XCTUnwrap(Frontmatter.edit(source: src, field: .title, newValue: "T"))
        let fence = 9
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: fence, length: 0)),
                       NSRange(location: fence + edit.delta, length: 0), "start of the fence")
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: fence + 2, length: 0)),
                       NSRange(location: fence + 2 + edit.delta, length: 0), "inside the fence")
        let fm = Frontmatter.build(from: (src as NSString).replacingCharacters(in: edit.range, with: edit.replacement))
        XCTAssertLessThan(fence + edit.delta, NSMaxRange(try XCTUnwrap(fm.range)), "still inside the block")
    }

    func testCaretBeforeAChangedValueStays() {
        let edit = TextEdit(range: NSRange(location: 4, length: 9), replacement: "title: Longer\n",
                            expected: "title: X\n")
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 6, length: 0)), NSRange(location: 6, length: 0))
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 11, length: 0)), NSRange(location: 11, length: 0))
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 12, length: 0)), NSRange(location: 17, length: 0),
                       "after the old value: after the new one")
    }

    func testSurrogatePairsAreNotSplit() {
        let edit = TextEdit(range: NSRange(location: 0, length: 3), replacement: "a😃",
                            expected: "a😀")
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 1, length: 0)), NSRange(location: 1, length: 0))
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 3, length: 0)), NSRange(location: 3, length: 0))
    }
}

@MainActor
final class FrontmatterBackspaceTests: XCTestCase {

    private let src = "---\ntitle: T\n---\n# Heading\n" as NSString

    func testBackspaceBehindTheFoldedBlockMovesOntoTheFence() {
        let block = NSRange(location: 0, length: 17)
        let caret = FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteBackward:", selection: NSRange(location: 17, length: 0),
            foldedBlock: block, in: src)
        XCTAssertEqual(caret, NSRange(location: 16, length: 0), "end of `---`, before its line break")
    }

    func testOtherCasesDeleteNormally() {
        let block = NSRange(location: 0, length: 17)
        XCTAssertNil(FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteBackward:", selection: NSRange(location: 17, length: 0),
            foldedBlock: nil, in: src), "block open: the line break is visible")
        XCTAssertNil(FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteBackward:", selection: NSRange(location: 18, length: 0),
            foldedBlock: block, in: src))
        XCTAssertNil(FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteForward:", selection: NSRange(location: 17, length: 0),
            foldedBlock: block, in: src))
        XCTAssertNil(FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteBackward:", selection: NSRange(location: 17, length: 3),
            foldedBlock: block, in: src))
    }

    func testCRLFFenceStopsBeforeTheWholeLineBreak() {
        let crlf = "---\r\na: 1\r\n---\r\nBody" as NSString
        let caret = FrontmatterFold.caretInsteadOfDeleting(
            command: "deleteWordBackward:", selection: NSRange(location: 16, length: 0),
            foldedBlock: NSRange(location: 0, length: 16), in: crlf)
        XCTAssertEqual(caret, NSRange(location: 14, length: 0))
    }

    func testCoordinatorKeepsTheFrontmatterOnBackspace() throws {
        let text = src as String
        var binding = text
        let view = MarkdownTextView(text: Binding(get: { binding }, set: { binding = $0 }),
                                    jumpToken: .constant(nil))
        let coordinator = view.makeCoordinator()
        let (scrollView, textView) = PicaMDTextView.makeScrollable()
        textView.string = text
        textView.setSelectedRange(NSRange(location: 17, length: 0))
        coordinator.textView = textView
        coordinator.scrollView = scrollView
        coordinator.applyHighlightingNow()
        XCTAssertEqual(coordinator.highlighter.foldedFrontmatter, NSRange(location: 0, length: 17))

        XCTAssertTrue(coordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))))
        XCTAssertEqual(textView.string, text, "nothing deleted")
        XCTAssertEqual(textView.selectedRange(), NSRange(location: 16, length: 0))
        XCTAssertNil(coordinator.highlighter.foldedFrontmatter, "the block is open")
        XCTAssertFalse(coordinator.textView(textView, doCommandBy: #selector(NSResponder.deleteBackward(_:))),
                       "the next Backspace deletes in plain sight")
    }
}
