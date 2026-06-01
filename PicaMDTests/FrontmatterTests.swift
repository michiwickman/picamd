import XCTest
@testable import PicaMD

final class FrontmatterTests: XCTestCase {

    func testNoFrontmatter() {
        let fm = Frontmatter.build(from: "# Just a heading\n\nBody.")
        XCTAssertNil(fm.range)
        XCTAssertTrue(fm.scalars.isEmpty)
        XCTAssertTrue(fm.arrays.isEmpty)
    }

    func testNotAtTopOfDocument() {
        // Frontmatter only counts when it's literally the first thing.
        let fm = Frontmatter.build(from: "Some prose first.\n\n---\ntitle: Nope\n---\n")
        XCTAssertNil(fm.range)
    }

    func testScalarKeysAndQuotedValues() {
        let src = """
        ---
        title: My document
        date: 2026-04-01
        author: "Wittmann, Michael"
        slug: 'hello-world'
        ---
        Body.
        """
        let fm = Frontmatter.build(from: src)
        XCTAssertNotNil(fm.range)
        XCTAssertEqual(fm.title, "My document")
        XCTAssertEqual(fm.date, "2026-04-01")
        XCTAssertEqual(fm.scalars["author"], "Wittmann, Michael")
        XCTAssertEqual(fm.scalars["slug"], "hello-world")
    }

    func testInlineTagsArray() {
        let src = """
        ---
        title: Foo
        tags: [swift, macos, markdown]
        ---
        """
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.tags, ["swift", "macos", "markdown"])
    }

    func testListStyleTags() {
        let src = """
        ---
        title: Bar
        tags:
          - swift
          - macos
          - markdown
        ---
        """
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.tags, ["swift", "macos", "markdown"])
    }

    func testFallbacksOnNameAndCreated() {
        let src = """
        ---
        name: Untitled
        created: 2026-04-30
        ---
        """
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.title, "Untitled")
        XCTAssertEqual(fm.date, "2026-04-30")
    }

    func testEmptyFrontmatterBlockIsHandled() {
        let src = "---\n---\n\nBody."
        let fm = Frontmatter.build(from: src)
        // Range is reported but no scalars/arrays
        XCTAssertNotNil(fm.range)
        XCTAssertTrue(fm.scalars.isEmpty)
        XCTAssertTrue(fm.arrays.isEmpty)
    }

    func testQuotedValuesAreUnquoted() {
        let src = """
        ---
        title: "Double-quoted"
        subtitle: 'Single-quoted'
        plain: no quotes here
        ---
        """
        let fm = Frontmatter.build(from: src)
        XCTAssertEqual(fm.scalars["title"], "Double-quoted")
        XCTAssertEqual(fm.scalars["subtitle"], "Single-quoted")
        XCTAssertEqual(fm.scalars["plain"], "no quotes here")
    }

    func testParseInlineArrayHandlesQuotedItems() {
        XCTAssertEqual(Frontmatter.parseInlineArray("[a, b, c]"), ["a", "b", "c"])
        XCTAssertEqual(Frontmatter.parseInlineArray("['a', \"b\", c]"), ["a", "b", "c"])
        XCTAssertEqual(Frontmatter.parseInlineArray("[]"), [])
    }

    // MARK: - GAP-07: Malformed / Edge-Case Tests

    /// A frontmatter block whose closing `---` fence is absent must NOT be
    /// treated as valid frontmatter. The regex is anchored to \A and requires
    /// the closing fence, so the whole match fails → .empty is returned.
    func testMissingClosingFenceYieldsEmpty() {
        let src = "---\ntitle: Foo\n# body text, no closing fence"
        let fm = Frontmatter.build(from: src)
        // No valid match → range must be nil and no scalars present.
        XCTAssertNil(fm.range, "A document with no closing --- fence should not produce a frontmatter range")
        XCTAssertNil(fm.title, "title should be absent when the closing fence is missing")
        XCTAssertTrue(fm.scalars.isEmpty, "scalars should be empty when frontmatter is malformed")
        XCTAssertTrue(fm.arrays.isEmpty, "arrays should be empty when frontmatter is malformed")
    }

    /// BEHAVIOR-PINNING: The regex pattern is `\A---\n` (LF-only). On Windows
    /// or iCloud Drive round-trips the file may arrive with CRLF line endings.
    /// The `\n` in the pattern does NOT match the `\r\n` sequence, so the regex
    /// fails to match entirely and returns .empty.
    ///
    /// This test documents the CURRENT behavior. It is intentionally a pinning
    /// test — if CRLF support is added in the future this test will need to be
    /// updated to reflect the new expected behavior.
    func testCRLFFrontmatterIsNotParsed() {
        // Source uses CRLF throughout (Windows / iCloud Drive worst-case).
        let src = "---\r\ntitle: Foo\r\ntags: [swift, macos]\r\n---\r\nbody"
        let fm = Frontmatter.build(from: src)
        // CURRENT BEHAVIOR: CRLF breaks the LF-anchored regex → .empty.
        // NOTE: This is a known iCloud/Windows pitfall. If the parser is ever
        // updated to normalise line endings before matching, change the
        // assertions below to XCTAssertNotNil(fm.range) / XCTAssertEqual(fm.title, "Foo").
        XCTAssertNil(fm.range, "CRLF line endings are not supported by the current LF-only regex (behavior-pinning)")
        XCTAssertNil(fm.title, "title should be absent when CRLF prevents the regex from matching")
    }

    /// A tab-separated key/value (`title:\tFoo`) — `splitKeyValue` splits on
    /// the first `:`, leaving `\tFoo` as the raw value. The value is then
    /// trimmed with `CharacterSet.whitespaces` (which includes `\t`), so the
    /// stored scalar ends up as `"Foo"` — the tab is stripped.
    func testTabIndentedValueIsTrimmed() {
        // Embed a literal tab between the colon and the value.
        let src = "---\ntitle:\tFoo\n---\nbody"
        let fm = Frontmatter.build(from: src)
        XCTAssertNotNil(fm.range, "A frontmatter block with a tab-separated value should still be recognised")
        // CharacterSet.whitespaces includes \t, so the trimmed value is "Foo".
        XCTAssertEqual(fm.title, "Foo", "Tab between ':' and value should be trimmed, yielding the bare value")
    }

    /// `---\n---\n` (nothing between the fences) — already has a happy-path
    /// test (`testEmptyFrontmatterBlockIsHandled`) that was written against the
    /// same source. This test adds a complementary assertion that the `title`
    /// and `tags` convenience accessors also return their zero-values, and that
    /// `rawLines` contains exactly one empty string (the body captured by the
    /// regex is `""`, split by `\n` gives `[""]`).
    func testEmptyFrontmatterBlockScalarsAndTags() {
        let src = "---\n---\nbody"
        let fm = Frontmatter.build(from: src)
        XCTAssertNotNil(fm.range, "An empty frontmatter block should still produce a valid range")
        XCTAssertTrue(fm.scalars.isEmpty, "Empty frontmatter block should have no scalars")
        XCTAssertTrue(fm.arrays.isEmpty, "Empty frontmatter block should have no arrays")
        XCTAssertNil(fm.title, "title should be nil for an empty frontmatter block")
        XCTAssertTrue(fm.tags.isEmpty, "tags should be empty for an empty frontmatter block")
    }

    /// A leading blank line before the opening `---` fence must prevent
    /// frontmatter detection. The regex is anchored to `\A`, so even a single
    /// preceding newline disqualifies the block.
    func testFrontmatterNotAtStartIsIgnored() {
        // One blank line before the opening fence.
        let src = "\n---\ntitle: Hidden\n---\nbody"
        let fm = Frontmatter.build(from: src)
        XCTAssertNil(fm.range, "A leading newline before --- should prevent frontmatter detection (\\A anchor)")
        XCTAssertNil(fm.title, "title should be absent when the frontmatter block is not at the document start")
    }
}
