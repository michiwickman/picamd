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

    func testWholeWordWithPunctuationAtTheEdges() {
        // `\b` can't sit next to `#` or `+`; whole-word must still work.
        var opts = SearchOptions(); opts.wholeWord = true
        XCTAssertEqual(DocumentSearch.matches(in: "#tag and x#tag", query: "#tag", options: opts).map(\.location), [0])
        XCTAssertEqual(DocumentSearch.matches(in: "C++ and C++x", query: "C++", options: opts).map(\.location), [0])
    }

    func testWholeWordHandlesNonASCIILetters() {
        var opts = SearchOptions(); opts.wholeWord = true
        let src = "Maß Maßband Maß"
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "Maß", options: opts).count, 2)
    }

    func testRegexAnchorsMatchEachLine() {
        var opts = SearchOptions(); opts.regex = true
        let src = "# One\ntext\n# Two"
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "^# \\w+", options: opts)),
                       ["# One", "# Two"])
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
        // "a b c" rendered from "a **b** c" — the source range must cover
        // the whole visible run including the concealed markers.
        let src = "a **b** c"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "a b c", options: opts)
        XCTAssertEqual(m.count, 1)
        XCTAssertEqual(substrings(src, m), ["a **b** c"])
    }

    func testIgnoreFormattingKeepsIntrawordMarkerCharacters() {
        // The editor doesn't conceal `_` in snake_case, a lone `=`, or
        // `**` that isn't emphasis, so ignore-formatting must still find
        // them as typed (the old reducer dropped every `_ * = ~` char).
        var opts = SearchOptions(); opts.ignoreFormatting = true
        XCTAssertEqual(DocumentSearch.matches(in: "call snake_case now", query: "snake_case", options: opts).count, 1)
        XCTAssertEqual(DocumentSearch.matches(in: "let a = b", query: "a = b", options: opts).count, 1)
        XCTAssertEqual(DocumentSearch.matches(in: "2 * 3 * 4", query: "2 * 3", options: opts).count, 1)
        XCTAssertEqual(DocumentSearch.matches(in: "a**b**c", query: "a**b**c", options: opts).count, 1)
    }

    func testIgnoreFormattingHidesBoldItalicInnerMarkers() {
        let (plain, _) = DocumentSearch.plainText(from: "x ***both*** y")
        XCTAssertEqual(plain, "x both y")
    }

    func testIgnoreFormattingLeavesMathBlocksAndFrontmatterVerbatim() {
        let src = "---\ntitle: **t**\n---\n$$\na*b*c\n$$\n"
        let (plain, _) = DocumentSearch.plainText(from: src)
        XCTAssertTrue(plain.contains("title: **t**"), plain)
        XCTAssertTrue(plain.contains("a*b*c"), plain)
    }

    func testIgnoreFormattingFindsImageAltText() {
        let src = "before ![a diagram](img.png) after"
        var opts = SearchOptions(); opts.ignoreFormatting = true
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "a diagram", options: opts)),
                       ["a diagram"])
        XCTAssertTrue(DocumentSearch.matches(in: src, query: "img.png", options: opts).isEmpty,
                      "the concealed URL isn't visible text")
    }

    func testIgnoreFormattingReportsInvalidRegex() {
        var opts = SearchOptions(); opts.ignoreFormatting = true; opts.regex = true
        XCTAssertFalse(DocumentSearch.isValid(query: "(", options: opts))
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

    func testReplacementsPairEveryMatchWithItsExpansion() {
        var opts = SearchOptions(); opts.regex = true
        let src = "a1 b2 c3"
        let reps = DocumentSearch.replacements(in: src, query: #"([a-z])(\d)"#, template: "$2$1", options: opts)
        XCTAssertEqual(reps.map(\.text), ["1a", "2b", "3c"])
        XCTAssertEqual(substrings(src, reps.map(\.range)), ["a1", "b2", "c3"])
    }

    func testLiteralReplacementsKeepDollarSignsVerbatim() {
        let reps = DocumentSearch.replacements(in: "cost cost", query: "cost", template: "$1", options: SearchOptions())
        XCTAssertEqual(reps.map(\.text), ["$1", "$1"])
    }

    func testRegexReplacementSeesLookbehindContext() {
        // Re-matching only inside the match range used to hide the text a
        // lookbehind needs, so `$0` came back unexpanded.
        var opts = SearchOptions(); opts.regex = true
        let src = "x=1 y=2"
        let match = (src as NSString).range(of: "2")
        let out = DocumentSearch.replacementText(forMatch: match, in: src, query: #"(?<=y=)\d"#,
                                                 template: "[$0]", options: opts)
        XCTAssertEqual(out, "[2]")
    }

    func testNoReplacementsInIgnoreFormattingMode() {
        var opts = SearchOptions(); opts.ignoreFormatting = true
        XCTAssertTrue(DocumentSearch.replacements(in: "a **b**", query: "b", template: "c", options: opts).isEmpty)
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

    // MARK: - Starts With

    func testStartsWithMatchesAtWordStartsOnly() {
        // Board example: Ignore Case + Starts With finds "tram" and "Trams".
        let src = "tram Trams xtram"
        var opts = SearchOptions(); opts.matchStyle = .startsWith
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "tram", options: opts)),
                       ["tram", "Tram"])
        XCTAssertTrue(DocumentSearch.matches(in: src, query: "rams", options: opts).isEmpty)
        opts.matchStyle = .contains
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "rams", options: opts).count, 1)
    }

    func testStartsWithTreatsUmlautsAsLetters() {
        // "ü" inside "Maßübung" follows a letter, so it starts no word.
        let src = "Übung Maßübung übel"
        var opts = SearchOptions(); opts.matchStyle = .startsWith
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "üb", options: opts)),
                       ["Üb", "üb"])
    }

    func testStartsWithAfterPunctuation() {
        // Punctuation and markup before a word don't count as part of it;
        // a query that itself starts with punctuation (#tag) needs a
        // non-word character before it.
        let src = "(tram) **tram** snake_tram a#tag #tags"
        var opts = SearchOptions(); opts.matchStyle = .startsWith
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "tram", options: opts).count, 2,
                       "`_` joins a word, so snake_tram is no word start")
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "#tag", options: opts)),
                       ["#tag"])
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "#tag", options: opts).first?.location,
                       (src as NSString).range(of: " #tags").location + 1)
    }

    func testStartsWithIgnoringFormatting() {
        let src = "**tram** and xtram"
        var opts = SearchOptions(); opts.matchStyle = .startsWith; opts.ignoreFormatting = true
        let m = DocumentSearch.matches(in: src, query: "tram", options: opts)
        XCTAssertEqual(m, [NSRange(location: 2, length: 4)])
    }

    func testWholeWordCompatSetterMapsToMatchStyle() {
        var opts = SearchOptions()
        opts.wholeWord = true
        XCTAssertEqual(opts.matchStyle, .wholeWord)
        opts.matchStyle = .startsWith
        XCTAssertFalse(opts.wholeWord)
        opts.wholeWord = false
        XCTAssertEqual(opts.matchStyle, .contains)
    }

    func testWrapAroundDoesNotChangeTheMatchSet() {
        var off = SearchOptions(); off.wrapAround = false
        XCTAssertEqual(DocumentSearch.matches(in: "a a a", query: "a", options: off),
                       DocumentSearch.matches(in: "a a a", query: "a", options: SearchOptions()))
    }

    // MARK: - Navigation (Wrap Around)

    private let three = [NSRange(location: 0, length: 1), NSRange(location: 5, length: 1),
                         NSRange(location: 10, length: 1)]
    private let caret0 = NSRange(location: 0, length: 0)

    func testNavigationWrapsAtBothEnds() {
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 3, delta: 1, matches: three,
                                                       selection: caret0, wrapAround: true), 1)
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 1, delta: -1, matches: three,
                                                       selection: caret0, wrapAround: true), 3)
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 2, delta: 1, matches: three,
                                                       selection: caret0, wrapAround: true), 3)
    }

    func testNavigationStopsAtBothEndsWithoutWrapAround() {
        XCTAssertNil(DocumentSearch.navigationTarget(current: 3, delta: 1, matches: three,
                                                     selection: caret0, wrapAround: false))
        XCTAssertNil(DocumentSearch.navigationTarget(current: 1, delta: -1, matches: three,
                                                     selection: caret0, wrapAround: false))
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 2, delta: -1, matches: three,
                                                       selection: caret0, wrapAround: false), 1)
    }

    func testNavigationWithoutCurrentMatchStartsAtTheSelection() {
        // No current match (bar closed, or nothing after the caret): the
        // step starts from the selection, and the selected match itself
        // is skipped going forward.
        let onSecond = NSRange(location: 5, length: 1)
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 0, delta: 1, matches: three,
                                                       selection: onSecond, wrapAround: false), 3)
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 0, delta: -1, matches: three,
                                                       selection: onSecond, wrapAround: false), 1)
        let pastEnd = NSRange(location: 11, length: 0)
        XCTAssertNil(DocumentSearch.navigationTarget(current: 0, delta: 1, matches: three,
                                                     selection: pastEnd, wrapAround: false),
                     "the index-0 branch must not wrap either")
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 0, delta: 1, matches: three,
                                                       selection: pastEnd, wrapAround: true), 1)
        XCTAssertNil(DocumentSearch.navigationTarget(current: 0, delta: -1, matches: three,
                                                     selection: caret0, wrapAround: false))
        XCTAssertEqual(DocumentSearch.navigationTarget(current: 0, delta: -1, matches: three,
                                                       selection: caret0, wrapAround: true), 3)
        XCTAssertNil(DocumentSearch.navigationTarget(current: 0, delta: 1, matches: [],
                                                     selection: caret0, wrapAround: true))
    }

    func testNearestMatchReportsNoneBehindTheLastWithoutWrapAround() {
        XCTAssertEqual(DocumentSearch.nearestMatchIndex(in: three, to: 6, wrapAround: false), 3)
        XCTAssertEqual(DocumentSearch.nearestMatchIndex(in: three, to: 11, wrapAround: true), 1)
        XCTAssertEqual(DocumentSearch.nearestMatchIndex(in: three, to: 11, wrapAround: false), 0)
        let edited = NSRange(location: 12, length: 1)
        XCTAssertEqual(DocumentSearch.sameOccurrenceIndex(in: three, previous: edited, wrapAround: true), 1)
        XCTAssertEqual(DocumentSearch.sameOccurrenceIndex(in: three, previous: edited, wrapAround: false), 0)
    }

    // MARK: - Spaces across soft line breaks (Reflow)

    func testSpaceMatchesASoftLineBreak() {
        let src = "take the tram\nout to Foz"
        let m = DocumentSearch.matches(in: src, query: "tram out", options: SearchOptions())
        XCTAssertEqual(substrings(src, m), ["tram\nout"])
        let crlf = "tram\r\n  out"
        XCTAssertEqual(DocumentSearch.matches(in: crlf, query: "tram out", options: SearchOptions()).count, 1)
    }

    func testSpaceDoesNotCrossAParagraphBreak() {
        XCTAssertTrue(DocumentSearch.matches(in: "tram\n\nout", query: "tram out",
                                             options: SearchOptions()).isEmpty)
    }

    func testSpaceMatchesARunOfSpaces() {
        let src = "tram   out"
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "tram out", options: SearchOptions()).count, 1)
        XCTAssertTrue(DocumentSearch.matches(in: "tramout", query: "tram out",
                                             options: SearchOptions()).isEmpty)
    }

    func testSpaceAcrossSoftBreakIgnoringFormattingAndAsWholeWord() {
        let src = "the **tram**\nout"
        var opts = SearchOptions(); opts.ignoreFormatting = true; opts.matchStyle = .wholeWord
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "tram out", options: opts)),
                       ["tram**\nout"])
    }

    func testRegexSpacesStayLiteral() {
        var opts = SearchOptions(); opts.regex = true
        XCTAssertTrue(DocumentSearch.matches(in: "tram\nout", query: "tram out", options: opts).isEmpty)
    }

    func testLeadingAndTrailingSpacesStayLiteral() {
        XCTAssertTrue(DocumentSearch.matches(in: "tram\nout", query: "tram ", options: SearchOptions()).isEmpty)
        XCTAssertEqual(DocumentSearch.matches(in: "a tram b", query: " tram ", options: SearchOptions()).count, 1)
    }

    func testReplaceAcrossASoftBreakJoinsTheLines() {
        let reps = DocumentSearch.replacements(in: "tram\nout", query: "tram out", template: "bus",
                                               options: SearchOptions())
        XCTAssertEqual(reps.map(\.range), [NSRange(location: 0, length: 8)])
    }

    func testSpaceDoesNotCrossAStructuralLineBreak() {
        // Only a hard wrap inside a paragraph shows as a space. The break
        // after a heading or inside a code or math block is
        // structural: matching it would let Replace merge the two lines.
        let cases = [
            "# Title\nbody text",
            "```\nint x\nreturn\n```",
            "    int x\n    return",
            "$$\nx\nreturn\n$$",
        ]
        for (src, query) in zip(cases, ["Title body", "x return", "x return", "x return"]) {
            XCTAssertTrue(DocumentSearch.matches(in: src, query: query, options: SearchOptions()).isEmpty, src)
            XCTAssertTrue(DocumentSearch.replacements(in: src, query: query, template: "X",
                                                      options: SearchOptions()).isEmpty, src)
            var ignoring = SearchOptions(); ignoring.ignoreFormatting = true
            XCTAssertTrue(DocumentSearch.matches(in: src, query: query, options: ignoring).isEmpty, src)
        }
    }

    func testStructuralBreakStillAllowsMatchesOnOneLine() {
        let src = "# Title\nbody text and Title body"
        XCTAssertEqual(substrings(src, DocumentSearch.matches(in: src, query: "Title body",
                                                              options: SearchOptions())),
                       ["Title body"])
        let reps = DocumentSearch.replacements(in: src, query: "Title body", template: "X",
                                               options: SearchOptions())
        XCTAssertEqual(reps.map(\.range), [NSRange(location: 22, length: 10)])
    }

    func testQueryWithItsOwnLineBreakMatchesAnyBreak() {
        // A multi-line selection taken with ⌘E finds itself again.
        let src = "# Title\nbody"
        XCTAssertEqual(DocumentSearch.matches(in: src, query: "Title\nbody", options: SearchOptions()).count, 1)
    }
}
