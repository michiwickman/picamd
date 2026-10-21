import XCTest
@testable import PicaMD

/// The hardened fence rule, the per-key source map, and the line-level
/// write API behind the inspector's Title, Tags and Date fields.
final class FrontmatterFenceTests: XCTestCase {

    private func range(_ source: String) -> NSRange? {
        Frontmatter.build(from: source).range
    }

    private func highlighterRange(_ source: String) -> NSRange? {
        MarkdownRegexes.frontmatter.firstMatch(
            in: source, range: NSRange(location: 0, length: (source as NSString).length))?.range
    }

    func testHighlighterAndParserShareOneRule() {
        XCTAssertTrue(MarkdownRegexes.frontmatter === Frontmatter.fenceRegex)
    }

    func testClosingFenceMustStandAloneOnItsLine() {
        // Used to match as a block {0,18} with body "title: foo".
        XCTAssertNil(range("---\ntitle: foo---\nrest\n"))
    }

    func testFourDashesAreNotAFence() {
        // Used to match with body "One\n\n-".
        XCTAssertNil(range("---\nOne\n\n----\nTwo\n"))
        let src = "---\na: 1\n----\n---\nBody"
        XCTAssertEqual(range(src), NSRange(location: 0, length: 18))
        XCTAssertEqual(Frontmatter.build(from: src).rawLines, ["a: 1", "----"])
    }

    func testEmptyBlockWithAndWithoutTrailingNewline() {
        XCTAssertEqual(range("---\n---\nBody"), NSRange(location: 0, length: 8))
        XCTAssertEqual(range("---\n---"), NSRange(location: 0, length: 7))
        // The highlighter's old rule missed both.
        XCTAssertEqual(highlighterRange("---\n---\nBody"), NSRange(location: 0, length: 8))
        XCTAssertEqual(highlighterRange("---\n---"), NSRange(location: 0, length: 7))
    }

    func testEmptyBlockIsNotExtendedToALaterFence() {
        XCTAssertEqual(range("---\n---\nText\n---\n"), NSRange(location: 0, length: 8))
    }

    func testBlockEndingTheDocument() {
        let fm = Frontmatter.build(from: "---\ntitle: x\n---")
        XCTAssertEqual(fm.range, NSRange(location: 0, length: 16))
        XCTAssertEqual(fm.title, "x")
    }

    func testTrailingSpacesOnFences() {
        let fm = Frontmatter.build(from: "--- \ntitle: x\n---\t\nBody")
        XCTAssertEqual(fm.range, NSRange(location: 0, length: 19))
        XCTAssertEqual(fm.title, "x")
    }

    func testCRLFFencesAndLines() {
        let src = "---\r\ntitle: \"A\"\r\n---\r\nBody"
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.range, NSRange(location: 0, length: 22))
        XCTAssertEqual(highlighterRange(src), fm.range)
        XCTAssertTrue(fm.usesCRLF)
        XCTAssertEqual(fm.title, "A")
        XCTAssertEqual(fm.entries["title"]?.lineBreak, "\r\n")
    }
}

final class FrontmatterParsingTests: XCTestCase {

    func testDoubleQuotedEscapesAreResolved() {
        let fm = Frontmatter.build(from: #"""
        ---
        title: "Say \"hi\" \\ go\tnow é"
        ---
        """#)
        XCTAssertEqual(fm.title, "Say \"hi\" \\ go\tnow é")
    }

    func testSingleQuotedDoubledQuote() {
        let fm = Frontmatter.build(from: "---\ntitle: 'It''s here'\n---\n")
        XCTAssertEqual(fm.title, "It's here")
    }

    func testCommentsAreNotPartOfValues() {
        let fm = Frontmatter.build(from: "---\n# a comment\ntitle: Foo # note\ndate: \"2026-10-03\" # d\n---\n")
        XCTAssertEqual(fm.title, "Foo")
        XCTAssertEqual(fm.date, "2026-10-03")
        XCTAssertEqual(fm.entries["title"]?.trailing, " # note")
        XCTAssertEqual(fm.scalars.count, 2)
    }

    func testHashInsideAWordIsNotAComment() {
        let fm = Frontmatter.build(from: "---\ntitle: C# in depth\n---\n")
        XCTAssertEqual(fm.title, "C# in depth")
    }

    /// An indented line under a block scalar is text, not a key.
    func testContinuationLinesAreNotKeys() {
        let fm = Frontmatter.build(from: "---\ndescription: |\n  note: x\n  more\ntitle: T\n---\n")
        XCTAssertNil(fm.scalars["note"])
        XCTAssertEqual(fm.scalars["description"], "note: x\nmore")
        XCTAssertEqual(fm.title, "T")
        XCTAssertEqual(fm.entries["description"]?.style, .blockScalar)
    }

    func testInlineArrayWithQuotedCommas() {
        let fm = Frontmatter.build(from: "---\ntags: [\"a, b\", c]\n---\n")
        XCTAssertEqual(fm.tags, ["a, b", "c"])
        XCTAssertEqual(fm.entries["tags"]?.style, .inlineArray(quote: nil))
    }

    func testZeroIndentBlockList() {
        let fm = Frontmatter.build(from: "---\ntags:\n- a\n- 'b'\n---\n")
        XCTAssertEqual(fm.tags, ["a", "b"])
        XCTAssertEqual(fm.entries["tags"]?.style, .blockList(indent: "", gap: " ", quote: nil))
    }

    func testEntryRangesAreAbsoluteAndCoverListItems() {
        let src = "---\ntitle: T\ntags:\n  - a\n  - b\nauthor: Me\n---\nBody"
        let fm = Frontmatter.build(from: src)
        let ns = src as NSString
        XCTAssertEqual(fm.entries["title"].map { ns.substring(with: $0.range) }, "title: T\n")
        XCTAssertEqual(fm.entries["tags"].map { ns.substring(with: $0.range) }, "tags:\n  - a\n  - b\n")
        XCTAssertEqual(fm.entries["author"].map { ns.substring(with: $0.range) }, "author: Me\n")
        XCTAssertEqual(fm.entries["tags"]?.style, .blockList(indent: "  ", gap: " ", quote: nil))
        XCTAssertEqual(fm.closingFenceRange.map { ns.substring(with: $0) }, "---\n")
    }

    func testValueStyles() {
        let fm = Frontmatter.build(from: "---\na: plain\nb: 'single'\nc: \"double\"\nd: [\"x\", \"y\"]\ne:\n---\n")
        XCTAssertEqual(fm.entries["a"]?.style, .plain)
        XCTAssertEqual(fm.entries["b"]?.style, .singleQuoted)
        XCTAssertEqual(fm.entries["c"]?.style, .doubleQuoted)
        XCTAssertEqual(fm.entries["d"]?.style, .inlineArray(quote: "\""))
        XCTAssertEqual(fm.entries["e"]?.style, .empty)
    }
}

final class FrontmatterWriteTests: XCTestCase {

    private func applying(_ edit: TextEdit?, to source: String,
                          file: StaticString = #filePath, line: UInt = #line) -> String {
        guard let edit else {
            XCTFail("expected an edit", file: file, line: line)
            return source
        }
        let ns = source as NSString
        XCTAssertEqual(ns.substring(with: edit.range), edit.expected, file: file, line: line)
        return ns.replacingCharacters(in: edit.range, with: edit.replacement)
    }

    private func set(_ field: Frontmatter.Field, _ value: String, in source: String,
                     file: StaticString = #filePath, line: UInt = #line) -> String {
        applying(Frontmatter.edit(source: source, field: field, newValue: value), to: source,
                 file: file, line: line)
    }

    private func setTags(_ tags: [String], in source: String,
                         file: StaticString = #filePath, line: UInt = #line) -> String {
        applying(Frontmatter.edit(source: source, tags: tags), to: source, file: file, line: line)
    }

    // MARK: Scalars

    func testPlainTitleIsReplacedAndEverythingElseStaysByteIdentical() {
        let src = "---\n# keep me\nlayout: post   # c\ntitle: Old\n\n  odd: indent\ndate: 2026-10-03\n---\nBody\n"
        XCTAssertEqual(set(.title, "New", in: src),
                       "---\n# keep me\nlayout: post   # c\ntitle: New\n\n  odd: indent\ndate: 2026-10-03\n---\nBody\n")
    }

    func testSingleQuotedStyleIsKept() {
        XCTAssertEqual(set(.title, "It's new", in: "---\ntitle: 'Old'\n---\n"),
                       "---\ntitle: 'It''s new'\n---\n")
    }

    func testDoubleQuotedStyleIsKeptAndEscaped() {
        XCTAssertEqual(set(.title, #"Say "hi" \ now"#, in: "---\ntitle: \"Old\"\n---\n"),
                       "---\ntitle: \"Say \\\"hi\\\" \\\\ now\"\n---\n")
    }

    func testPlainValueIsQuotedWhenYAMLWouldMisreadIt() {
        XCTAssertEqual(set(.title, "Part 1: Start", in: "---\ntitle: Old\n---\n"),
                       "---\ntitle: \"Part 1: Start\"\n---\n")
        XCTAssertEqual(set(.title, "2026", in: "---\ntitle: Old\n---\n"),
                       "---\ntitle: \"2026\"\n---\n")
        XCTAssertEqual(set(.title, "yes", in: "---\ntitle: Old\n---\n"),
                       "---\ntitle: \"yes\"\n---\n")
        XCTAssertEqual(set(.title, "#1 hit", in: "---\ntitle: Old\n---\n"),
                       "---\ntitle: \"#1 hit\"\n---\n")
        // A date stays a date.
        XCTAssertEqual(set(.date, "2026-10-04", in: "---\ndate: 2026-10-03\n---\n"),
                       "---\ndate: 2026-10-04\n---\n")
    }

    func testQuotedValuesRoundTrip() {
        for value in [#"a "b" c"#, "back\\slash", "It's", "x: y", "- dash", "trailing #tag"] {
            let written = set(.title, value, in: "---\ntitle: Old\n---\n")
            XCTAssertEqual(Frontmatter.build(from: written).title, value, written)
        }
    }

    func testTrailingCommentIsKept() {
        XCTAssertEqual(set(.title, "New", in: "---\ntitle: Old # keep\n---\n"),
                       "---\ntitle: New # keep\n---\n")
    }

    func testWritesToTheKeyItReadsFrom() {
        XCTAssertEqual(set(.title, "New", in: "---\nname: Old\n---\n"), "---\nname: New\n---\n")
        XCTAssertEqual(set(.date, "2026-10-05", in: "---\ncreated: 2026-10-03\n---\n"),
                       "---\ncreated: 2026-10-05\n---\n")
        // `title:` with no value is reused instead of adding a second key.
        XCTAssertEqual(set(.title, "New", in: "---\ntitle:\nauthor: Me\n---\n"),
                       "---\ntitle: New\nauthor: Me\n---\n")
    }

    func testEmptyValueRemovesTheKeyLineButKeepsTheBlock() {
        XCTAssertEqual(set(.title, "", in: "---\ntitle: X\n---\nBody"), "---\n---\nBody")
        XCTAssertEqual(set(.title, "  ", in: "---\na: 1\ntitle: X\nb: 2\n---\n"), "---\na: 1\nb: 2\n---\n")
    }

    func testNewKeyGoesInFrontOfTheClosingFence() {
        XCTAssertEqual(set(.date, "2026-10-03", in: "---\ntitle: T\n# end\n---\nBody"),
                       "---\ntitle: T\n# end\ndate: 2026-10-03\n---\nBody")
        XCTAssertEqual(set(.title, "T", in: "---\n---\n"), "---\ntitle: T\n---\n")
        XCTAssertEqual(set(.title, "T", in: "---\na: 1\n---"), "---\na: 1\ntitle: T\n---")
    }

    func testDocumentWithoutFrontmatterGetsABlockAtTheTop() {
        XCTAssertEqual(set(.title, "Trip", in: "# Trip\n\nBody"), "---\ntitle: Trip\n---\n# Trip\n\nBody")
        XCTAssertEqual(set(.title, "Trip", in: ""), "---\ntitle: Trip\n---\n")
        // A first edit that clears an absent field changes nothing.
        XCTAssertNil(Frontmatter.edit(source: "Body", field: .title, newValue: ""))
    }

    func testUnchangedValueYieldsNoEdit() {
        XCTAssertNil(Frontmatter.edit(source: "---\ntitle: Same\n---\n", field: .title, newValue: "Same"))
        XCTAssertNil(Frontmatter.edit(source: "---\ntags: [a, b]\n---\n", tags: ["a", "b", "a", " "]))
    }

    func testLineBreaksInTheInputBecomeSpaces() {
        XCTAssertEqual(set(.title, "two\nlines", in: "---\ntitle: x\n---\n"), "---\ntitle: two lines\n---\n")
    }

    func testBlockScalarIsReplacedByOneLine() {
        XCTAssertEqual(set(.title, "Short", in: "---\ntitle: >\n  A long\n  title\nb: 1\n---\n"),
                       "---\ntitle: Short\nb: 1\n---\n")
    }

    // MARK: CRLF

    func testCRLFDocumentsAreWrittenWithCRLF() {
        let src = "---\r\ntitle: Old\r\n---\r\nBody\r\n"
        XCTAssertEqual(set(.title, "New", in: src), "---\r\ntitle: New\r\n---\r\nBody\r\n")
        XCTAssertEqual(set(.date, "2026-10-03", in: src),
                       "---\r\ntitle: Old\r\ndate: 2026-10-03\r\n---\r\nBody\r\n")
        XCTAssertEqual(setTags(["a", "b"], in: "---\r\ntags:\r\n  - a\r\n---\r\n"),
                       "---\r\ntags:\r\n  - a\r\n  - b\r\n---\r\n")
        XCTAssertEqual(set(.title, "T", in: "Body\r\nMore\r\n"), "---\r\ntitle: T\r\n---\r\nBody\r\nMore\r\n")
    }

    // MARK: Tags

    func testInlineArrayKeepsItsStyle() {
        XCTAssertEqual(setTags(["a", "b", "c"], in: "---\ntags: [a, b]\n---\n"),
                       "---\ntags: [a, b, c]\n---\n")
        XCTAssertEqual(setTags(["a", "c"], in: "---\ntags: [\"a\", \"b\"] # t\n---\n"),
                       "---\ntags: [\"a\", \"c\"] # t\n---\n")
        XCTAssertEqual(setTags(["a, b", "c"], in: "---\ntags: [a]\n---\n"),
                       "---\ntags: [\"a, b\", c]\n---\n")
    }

    func testBlockListKeepsIndentAndQuotes() {
        XCTAssertEqual(setTags(["swift", "macos"], in: "---\ntags:   # list\n    -  swift\nb: 1\n---\n"),
                       "---\ntags:   # list\n    -  swift\n    -  macos\nb: 1\n---\n")
        XCTAssertEqual(setTags(["x"], in: "---\ntags:\n- 'a'\n- 'b'\n---\n"),
                       "---\ntags:\n- 'x'\n---\n")
    }

    func testCommaScalarTagsStayAScalar() {
        XCTAssertEqual(setTags(["a", "b", "c"], in: "---\ntags: a, b\n---\n"), "---\ntags: a, b, c\n---\n")
        // A tag with a comma can't live in a comma list: inline array.
        XCTAssertEqual(setTags(["a", "x, y"], in: "---\ntags: a\n---\n"), "---\ntags: [a, \"x, y\"]\n---\n")
    }

    func testRemovingTheLastTagRemovesTheKeyAndItsItems() {
        XCTAssertEqual(setTags([], in: "---\ntitle: T\ntags:\n  - a\n  - b\n---\n"), "---\ntitle: T\n---\n")
    }

    func testNewTagsAreAnInlineArray() {
        XCTAssertEqual(setTags(["travel", "portugal"], in: "---\ntitle: T\n---\n"),
                       "---\ntitle: T\ntags: [travel, portugal]\n---\n")
        XCTAssertEqual(setTags(["true", "a]b"], in: "Body"), "---\ntags: [\"true\", \"a]b\"]\n---\nBody")
    }

    func testCommaSeparatedStringForTags() {
        XCTAssertEqual(set(.tags, "a, b ,, a", in: "Body"), "---\ntags: [a, b]\n---\nBody")
    }

    // MARK: Locks

    func testUnclosedFenceLocksInsertion() {
        let src = "---\ntitle: being typed\n\nBody"
        XCTAssertNotNil(Frontmatter.lockReason(for: .title, in: src))
        XCTAssertNil(Frontmatter.edit(source: src, field: .title, newValue: "X"))
        XCTAssertNil(Frontmatter.lockReason(for: .title, in: "Body"))
        XCTAssertNil(Frontmatter.lockReason(for: .title, in: "---\ntitle: x\n---\n"))
    }

    func testNestedMapLocksItsField() {
        let src = "---\ntitle:\n  en: Hello\n  de: Hallo\n---\n"
        XCTAssertNotNil(Frontmatter.lockReason(for: .title, in: src))
        XCTAssertNil(Frontmatter.edit(source: src, field: .title, newValue: "X"))
        XCTAssertNil(Frontmatter.lockReason(for: .date, in: src))
    }
}

final class TextEditSelectionTests: XCTestCase {

    private let edit = TextEdit(range: NSRange(location: 10, length: 5), replacement: "abcdefgh",
                                expected: "12345")   // delta +3

    func testPointsBeforeTheEditStay() {
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 2, length: 3)), NSRange(location: 2, length: 3))
    }

    func testPointsAfterTheEditMoveByDelta() {
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 15, length: 0)), NSRange(location: 18, length: 0))
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 40, length: 4)), NSRange(location: 43, length: 4))
    }

    func testPointsInsideTheEditMoveToItsEnd() {
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 12, length: 0)), NSRange(location: 18, length: 0))
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 10, length: 0)), NSRange(location: 18, length: 0))
    }

    func testASelectionAcrossTheEditGrows() {
        XCTAssertEqual(edit.adjustedSelection(NSRange(location: 5, length: 20)), NSRange(location: 5, length: 23))
    }

    func testInsertionAtTheCaretPushesIt() {
        let insert = TextEdit(range: NSRange(location: 0, length: 0), replacement: "---\nt: x\n---\n", expected: "")
        XCTAssertEqual(insert.adjustedSelection(NSRange(location: 0, length: 0)), NSRange(location: 13, length: 0))
    }

    func testRemovalPullsLaterPointsBack() {
        let remove = TextEdit(range: NSRange(location: 4, length: 9), replacement: "", expected: "title: X\n")
        XCTAssertEqual(remove.adjustedSelection(NSRange(location: 20, length: 0)), NSRange(location: 11, length: 0))
    }
}
