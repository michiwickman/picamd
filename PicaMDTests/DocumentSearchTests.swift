import XCTest
@testable import PicaMD

final class DocumentSearchTests: XCTestCase {

    private func substrings(_ source: String, _ ranges: [NSRange]) -> [String] {
        let ns = source as NSString
        return ranges.map { ns.substring(with: $0) }
    }

    // MARK: - Literal matching

    func testLiteralMatchesAreCaseInsensitiveByDefault() {
        let src = "Foo foo FOO bar"
        let m = DocumentSearch.matches(in: src, query: "foo", options: SearchOptions())
        XCTAssertEqual(m.count, 3)
        XCTAssertEqual(substrings(src, m), ["Foo", "foo", "FOO"])
    }

    func testCaseSensitiveMatching() {
        let src = "Foo foo FOO"
        var opts = SearchOptions(); opts.caseSensitive = true
        let m = DocumentSearch.matches(in: src, query: "foo", options: opts)
        XCTAssertEqual(substrings(src, m), ["foo"])
    }

    func testEmptyQueryReturnsNothing() {
        XCTAssertTrue(DocumentSearch.matches(in: "anything", query: "", options: SearchOptions()).isEmpty)
    }

    func testLiteralSpecialCharactersAreEscaped() {
        // A dot is literal, not "any char", outside regex mode.
        let src = "a.b axb a.b"
        let m = DocumentSearch.matches(in: src, query: "a.b", options: SearchOptions())
        XCTAssertEqual(substrings(src, m), ["a.b", "a.b"])
    }

    func testMatchesAreInDocumentOrder() {
        let src = "x_1 x_2 x_3"
        let m = DocumentSearch.matches(in: src, query: "x_", options: SearchOptions())
        XCTAssertEqual(m.map(\.location), [0, 4, 8])
    }

    // MARK: - Whole word

    func testWholeWord() {
        let src = "cat category cat"
        var opts = SearchOptions(); opts.wholeWord = true
        let m = DocumentSearch.matches(in: src, query: "cat", options: opts)
        XCTAssertEqual(m.count, 2)
        XCTAssertEqual(m.map(\.location), [0, 13])
    }

    // MARK: - Regex

    func testRegexMatching() {
        let src = "P1 PX P2 P33"
        var opts = SearchOptions(); opts.regex = true
        let m = DocumentSearch.matches(in: src, query: #"P\d"#, options: opts)
        XCTAssertEqual(substrings(src, m), ["P1", "P2", "P3"])
    }

    func testInvalidRegexReturnsEmptyAndIsInvalid() {
        var opts = SearchOptions(); opts.regex = true
        XCTAssertTrue(DocumentSearch.matches(in: "abc", query: "(", options: opts).isEmpty)
        XCTAssertFalse(DocumentSearch.isValid(query: "(", options: opts))
        XCTAssertTrue(DocumentSearch.isValid(query: "(a)", options: opts))
    }

    func testRegexWholeWordCombined() {
        let src = "id7 id77 zid7"
        var opts = SearchOptions(); opts.regex = true; opts.wholeWord = true
        let m = DocumentSearch.matches(in: src, query: #"id\d+"#, options: opts)
        XCTAssertEqual(substrings(src, m), ["id7", "id77"])
    }

    // MARK: - Ignore formatting (Markdown-aware)

    func testIgnoreFormattingFindsBold() {
        let src = "this is **bold** text"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "bold", options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(substrings(src, m), ["bold"])  // inner text, markers excluded
    }

    func testIgnoreFormattingSpansConcealedMarkers() {
        // "abc" rendered from "a**b**c" — the source range must cover the
        // whole visible run including the concealed markers.
        let src = "a**b**c"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "abc", options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(substrings(src, m), ["a**b**c"])
    }

    func testIgnoreFormattingMatchesPhraseSpanningMarkers() {
        // Literal "bold word" is NOT contiguous in the source (the `**`
        // sit between), so plain search must find BOTH the marker-split
        // occurrence and the plain one.
        let src = "This is a **bold** word and another bold word here."
        var literal = SearchOptions()
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "bold word", options: literal).count, 1,
                       "literal only finds the contiguous plain occurrence")
        literal.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "bold word", options: literal)
        XCTAssertEqual(m.count, 2, "ignore-formatting finds both")
        XCTAssertEqual(substrings(src, m), ["bold** word", "bold word"])
    }

    func testIgnoreFormattingFindsLinkText() {
        let src = "see [the docs](https://example.com) now"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "the docs", options: opts)
        XCTAssertEqual(substrings(src, m), ["the docs"])
    }

    func testIgnoreFormattingFindsHeadingText() {
        let src = "## Important Section"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "Important", options: opts)
        XCTAssertEqual(substrings(src, m), ["Important"])
    }

    func testIgnoreFormattingDoesNotMatchMarkersThemselves() {
        // Searching the visible text "bold" must not be confused by the
        // literal asterisks; searching "**" should find nothing in plain text.
        let src = "**bold**"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "**", options: opts)
        XCTAssertTrue(m.isEmpty)
    }

    func testPlainTextStripsInlineMarkup() {
        let (plain, map) = DocumentSearch.plainText(from: "a *b* `c` ~~d~~ ==e==")
        XCTAssertEqual(plain, "a b c d e")
        // Map is one entry per plain char, all within source bounds.
        XCTAssertEqual(map.count, (plain as NSString).length)
        let srcLen = ("a *b* `c` ~~d~~ ==e==" as NSString).length
        XCTAssertTrue(map.allSatisfy { $0 >= 0 && $0 < srcLen })
        // Map is monotonically non-decreasing.
        XCTAssertEqual(map, map.sorted())
    }

    func testPlainTextLeavesFencedCodeVerbatim() {
        let src = "```\nlet x = *not italic*\n```"
        let (plain, _) = DocumentSearch.plainText(from: src)
        XCTAssertTrue(plain.contains("*not italic*"),
                      "Fenced code body should keep its asterisks: \(plain)")
    }

    // MARK: - Replace

    func testLiteralReplacementIsVerbatim() {
        let src = "hello world"
        let match = (src as NSString).range(of: "world")
        let out = DocumentSearch.replacementText(forMatch: match, in: src,
                                                 query: "world", template: "there",
                                                 options: SearchOptions())
        XCTAssertEqual(out, "there")
    }

    func testRegexReplacementExpandsCaptures() {
        let src = "2026-06-17"
        var opts = SearchOptions(); opts.regex = true
        let query = #"(\d{4})-(\d{2})-(\d{2})"#
        let match = (src as NSString).range(of: src)
        let out = DocumentSearch.replacementText(forMatch: match, in: src,
                                                 query: query, template: "$3.$2.$1",
                                                 options: opts)
        XCTAssertEqual(out, "17.06.2026")
    }
}
