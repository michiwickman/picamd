import XCTest
import AppKit
@testable import PicaMD

/// The reflow classifier decides which `\n` may be typeset as a space.
///
/// The safety invariant is **asymmetric**: marking a structural newline as
/// soft corrupts layout (block overlays are positioned from glyph rects, so
/// welding a table's boundary newline into the prose above it moves and
/// resizes the overlay), while marking a soft newline as structural merely
/// forfeits reflow on that line. These tests are weighted accordingly — the
/// "must never be soft" cases are the load-bearing ones.
final class ReflowClassifierTests: XCTestCase {

    private func soft(_ source: String,
                      options: ReflowClassifier.Options = ReflowClassifier.Options()) -> Set<Int> {
        ReflowClassifier.softNewlineOffsets(
            in: source,
            blocks: BlockExtractor.extract(from: source),
            protectedRanges: CheckboxOverlayManager.protectedRanges(in: source),
            options: options
        )
    }

    /// Offset of the n-th (0-based) newline in `source`.
    private func newline(_ n: Int, in source: String) -> Int {
        let ns = source as NSString
        var found = -1
        var from = 0
        for _ in 0...n {
            let r = ns.range(of: "\n", options: [],
                             range: NSRange(location: from, length: ns.length - from))
            guard r.location != NSNotFound else { return -1 }
            found = r.location
            from = r.location + 1
        }
        return found
    }

    // MARK: - The positive case

    func testInteriorNewlinesOfAHardWrappedParagraphAreSoft() {
        let doc = """
        Erste Zeile eines hart umgebrochenen Absatzes
        zweite Zeile desselben Absatzes
        dritte Zeile desselben Absatzes

        Zweiter Absatz.
        """
        let s = soft(doc)
        XCTAssertTrue(s.contains(newline(0, in: doc)), "line 1→2 must join")
        XCTAssertTrue(s.contains(newline(1, in: doc)), "line 2→3 must join")
        XCTAssertFalse(s.contains(newline(2, in: doc)), "the newline before a blank line must break")
        XCTAssertFalse(s.contains(newline(3, in: doc)), "a blank line must break")
    }

    // MARK: - Must never be soft

    func testHeadingsAlwaysBreak() {
        let doc = "Ein Absatz davor.\n## Eine Überschrift\nText danach.\n"
        let s = soft(doc)
        XCTAssertFalse(s.contains(newline(0, in: doc)), "the newline before a heading must break")
        XCTAssertFalse(s.contains(newline(1, in: doc)), "the newline after a heading must break")
    }

    func testMarkdownHardBreaksSurvive() {
        let twoSpaces = "Zeile mit hartem Umbruch  \nnächste Zeile\n"
        XCTAssertFalse(soft(twoSpaces).contains(newline(0, in: twoSpaces)),
                       "two trailing spaces are an explicit hard break")
        let backslash = "Zeile mit hartem Umbruch\\\nnächste Zeile\n"
        XCTAssertFalse(soft(backslash).contains(newline(0, in: backslash)),
                       "a trailing backslash is an explicit hard break")
    }

    func testSetextUnderlineIsNotMistakenForAThematicBreak() {
        // `---` matches both patterns; testing thematic-break first would
        // silently misclassify every Setext H2.
        let doc = "Eine Überschrift\n---\nText danach.\n"
        let s = soft(doc)
        XCTAssertFalse(s.contains(newline(0, in: doc)),
                       "a paragraph followed by a setext underline must break")
    }

    func testFencedCodeIsNeverJoined() {
        let doc = """
        Absatz davor.

        ```swift
        let a = 1
        let b = 2
        ```

        Absatz danach.
        """
        let s = soft(doc)
        let ns = doc as NSString
        let fenceStart = ns.range(of: "```swift").location
        let fenceEnd = ns.range(of: "```\n\nAbsatz danach").location
        for offset in s {
            XCTAssertFalse(offset >= fenceStart - 1 && offset <= fenceEnd + 3,
                           "no newline in or around a code fence may be soft (offset \(offset))")
        }
    }

    func testIndentedFencedCodeIsNeverJoined() {
        // The shared `MarkdownRegexes.fencedCode` is anchored at column 0 and
        // misses this entirely — the classifier must track fences itself.
        let doc = """
        Absatz davor.

        1. Ein Listenpunkt:

           ```json
           { "a": 1,
             "b": 2 }
           ```

        Absatz danach.
        """
        let s = soft(doc)
        let ns = doc as NSString
        let fenceStart = ns.range(of: "```json").location
        let closing = ns.range(of: "```\n\nAbsatz danach").location
        for offset in s {
            XCTAssertFalse(offset >= fenceStart - 1 && offset <= closing + 3,
                           "an INDENTED fence must be protected too (offset \(offset))")
        }
    }

    func testFrontmatterIsNeverJoined() {
        let doc = """
        ---
        title: Test
        tags: [a, b]
        ---

        Erster Absatz hier
        zweite Zeile davon.
        """
        let s = soft(doc)
        let ns = doc as NSString
        let closing = ns.range(of: "---\n\nErster").location
        for offset in s {
            XCTAssertGreaterThan(offset, closing + 2,
                                 "nothing inside YAML frontmatter may be soft")
        }
        // ...but the prose after it still reflows.
        XCTAssertTrue(s.contains(newline(5, in: doc)))
    }

    /// A note that opens with a thematic break and has prose before any
    /// further `---` has no front matter by the shared fence rule. Its prose
    /// must reflow like everywhere else.
    func testLeadingThematicBreakIsNotFrontmatter() {
        let doc = "---\n\nErster Absatz hier\nzweite Zeile davon.\n"
        let s = soft(doc)
        XCTAssertTrue(s.contains(newline(2, in: doc)),
                      "the paragraph after a leading rule must reflow")
        XCTAssertFalse(s.contains(newline(0, in: doc)), "the rule itself still breaks")
    }

    func testListItemsDoNotJoinByDefault() {
        let doc = """
        - Erster Punkt
        - Zweiter Punkt
        - Dritter Punkt
        """
        XCTAssertTrue(soft(doc).isEmpty,
                      "list items must keep their own lines until hanging indents exist")
    }

    func testParagraphsStillReflowWhenTheDocumentEndsWithAList() {
        // Rule 13 used to read the list stack after the walk, i.e. the state
        // at the END of the document. A trailing list or checklist then made
        // every top-level paragraph look like a lazy list continuation.
        for tail in ["- Punkt eins\n- Punkt zwei\n\n",
                     "- [ ] offen\n- [x] erledigt\n",
                     "1. Schritt\n   1. Unterschritt"] {
            let doc = "Eins\nZwei\nDrei\n\n" + tail
            let s = soft(doc)
            XCTAssertTrue(s.contains(newline(0, in: doc)), "line 1→2 must join before \(tail.debugDescription)")
            XCTAssertTrue(s.contains(newline(1, in: doc)), "line 2→3 must join before \(tail.debugDescription)")
            XCTAssertEqual(s.count, 2, "nothing in the trailing list may join (\(tail.debugDescription))")
        }
    }

    func testUnindentedLineAfterAListContinuationDoesNotJoin() {
        // The container is the list item the continuation line sits in; an
        // unindented line after it must not be pulled into it.
        let doc = "- Punkt\n  Fortsetzung\nNeue Zeile ohne Einzug\n\nSchluss.\n"
        XCTAssertFalse(soft(doc).contains(newline(1, in: doc)),
                       "an out-dented line must not be welded into the list item above")
    }

    func testIndentedContinuationsInsideAListItemJoin() {
        let doc = "- Punkt\n\n  Zweiter Absatz im Punkt\n  und seine Fortsetzung\n"
        XCTAssertTrue(soft(doc).contains(newline(2, in: doc)),
                      "a paragraph inside a list item reflows like any other paragraph")
    }

    func testBlockquotesOfEqualDepthJoin() {
        let doc = "> Erste Zeile des Zitats\n> zweite Zeile des Zitats\n"
        XCTAssertTrue(soft(doc).contains(newline(0, in: doc)),
                      "blockquote continuation joins — the pass sets equal first-line and head indents")
    }

    func testBlockquotesOfDifferentDepthDoNotJoin() {
        let doc = "> Äussere Ebene\n>> Innere Ebene\n"
        XCTAssertFalse(soft(doc).contains(newline(0, in: doc)))
    }

    func testOrphanTableRowWithoutSeparatorStillBreaks() {
        // Not an extracted block (no separator row), but the highlighter still
        // paints it as a table row, so it must hold its own line.
        let doc = "Absatz davor.\n| a | b |\n| c | d |\nAbsatz danach.\n"
        let s = soft(doc)
        for i in 0..<3 {
            XCTAssertFalse(s.contains(newline(i, in: doc)),
                           "orphan table row \(i) must not be joined")
        }
    }

    // MARK: - The load-bearing invariant, on real documents

    /// Checks every soft newline in `src` against every block and protected
    /// range and returns how many soft newlines there were, so the caller can
    /// make sure the invariant was not satisfied vacuously.
    private func assertNoSoftNewlineTouchesABlock(in src: String, name: String,
                                                  file: StaticString = #filePath,
                                                  line: UInt = #line) -> Int {
        let blocks = BlockExtractor.extract(from: src)
        let protectedRanges = CheckboxOverlayManager.protectedRanges(in: src)
        let s = ReflowClassifier.softNewlineOffsets(in: src, blocks: blocks,
                                                    protectedRanges: protectedRanges)
        let ns = src as NSString
        for offset in s {
            XCTAssertEqual(ns.substring(with: NSRange(location: offset, length: 1)), "\n",
                           "\(name): offset \(offset) is not a newline", file: file, line: line)
            for block in blocks {
                let start = block.range.location
                let end = block.range.location + block.range.length
                XCTAssertFalse(offset >= start - 1 && offset <= end,
                               "\(name): soft newline at \(offset) touches a \(block.kind) block "
                               + "[\(start),\(end)] — this moves and resizes its overlay",
                               file: file, line: line)
            }
            for r in protectedRanges {
                XCTAssertFalse(offset >= r.location - 1 && offset <= r.location + r.length,
                               "\(name): soft newline at \(offset) falls in a protected range",
                               file: file, line: line)
            }
        }
        return s.count
    }

    /// Repository root, from this file's location. The fixtures are read from
    /// the checkout rather than the test bundle so the test needs no resource
    /// build phase and runs the same in Xcode, on the command line and in CI.
    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // PicaMDTests
            .deletingLastPathComponent()   // repo root
    }

    /// The invariant on a committed, hard-wrapped document that mixes every
    /// block kind with wrapped prose — and ends in a checklist, the shape
    /// that once switched reflow off for the whole document.
    func testNoSoftNewlineTouchesABlockInTheHardWrappedFixture() throws {
        let url = repositoryRoot.appendingPathComponent("PicaMDTests/Fixtures/reflow-hard-wrapped.md")
        let src = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(BlockExtractor.extract(from: src).isEmpty,
                       "precondition: the fixture must contain overlay blocks")
        let count = assertNoSoftNewlineTouchesABlock(in: src, name: url.lastPathComponent)
        // The fixture has 17 interior newlines in plain paragraphs and one
        // in a blockquote. Well below that means the classifier silently
        // stopped reflowing and the assertions above proved nothing.
        XCTAssertGreaterThanOrEqual(count, 15,
                                    "the classifier found almost nothing to reflow in the fixture")
    }

    /// The same invariant on the documents shipped in `samples/`.
    func testNoSoftNewlineTouchesABlockInTheSampleDocuments() throws {
        let dir = repositoryRoot.appendingPathComponent("samples")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
            .filter { $0.hasSuffix(".md") }
        XCTAssertFalse(files.isEmpty, "samples/ must contain markdown documents")
        for name in files {
            let src = try String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8)
            _ = assertNoSoftNewlineTouchesABlock(in: src, name: name)
        }
    }

    /// Opt-in: the invariant on a local corpus of real documents. Set
    /// `PICAMD_REFLOW_CORPUS` to a directory of `.md` files (for
    /// `xcodebuild`, as `TEST_RUNNER_PICAMD_REFLOW_CORPUS`); without it the
    /// test is skipped, never failed.
    func testNoSoftNewlineTouchesABlockInALocalCorpus() throws {
        let dir = ProcessInfo.processInfo.environment["PICAMD_REFLOW_CORPUS"] ?? ""
        try XCTSkipIf(dir.isEmpty, "PICAMD_REFLOW_CORPUS not set")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir)
            .filter { $0.hasSuffix(".md") }
        try XCTSkipIf(files.isEmpty, "no .md files in \(dir)")

        var totalSoft = 0
        for name in files {
            guard let src = try? String(contentsOfFile: dir + "/" + name, encoding: .utf8) else { continue }
            totalSoft += assertNoSoftNewlineTouchesABlock(in: src, name: name)
        }
        XCTAssertGreaterThan(totalSoft, 0,
                             "the classifier found nothing to reflow in the corpus — that would "
                             + "make the safety assertions above meaningless")
    }

    // MARK: - CRLF

    func testCRLFDocumentOffsetsStayAligned() {
        let doc = "Erste Zeile eines Absatzes\r\nzweite Zeile davon\r\n\r\nZweiter Absatz.\r\n"
        let ns = doc as NSString
        let s = soft(doc)
        for offset in s {
            XCTAssertEqual(ns.substring(with: NSRange(location: offset, length: 1)), "\n",
                           "every reported offset must point at an actual newline")
        }
    }

    // MARK: - End-to-end: does it actually change the typesetting?

    /// The classifier tests above only prove which newlines are *labelled*
    /// soft. This one drives a real TextKit 1 stack with the delegate
    /// installed and checks that the label actually reaches the typesetter.
    @MainActor
    func testReflowActuallyMergesLineFragments() {
        let doc = """
        Erste Zeile eines hart umgebrochenen Absatzes
        zweite Zeile desselben Absatzes
        dritte Zeile desselben Absatzes

        Zweiter Absatz nach einer Leerzeile.
        """

        func fragmentCount(reflow: Bool) -> (fragments: Int, characters: Int) {
            let storage = NSTextStorage(string: doc)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                                 range: NSRange(location: 0, length: (doc as NSString).length))
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 1200,
                                                          height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)

            let delegate = ReflowLayoutDelegate()
            delegate.textStorage = storage
            delegate.isEnabled = reflow
            delegate.publish(softNewlines: soft(doc))
            layoutManager.delegate = delegate
            layoutManager.ensureLayout(for: container)

            var fragments = 0
            var idx = 0
            while idx < layoutManager.numberOfGlyphs {
                var effective = NSRange()
                _ = layoutManager.lineFragmentRect(forGlyphAt: idx, effectiveRange: &effective)
                fragments += 1
                idx = NSMaxRange(effective)
                if effective.length == 0 { break }
            }
            return (fragments, storage.length)
        }

        let off = fragmentCount(reflow: false)
        let on = fragmentCount(reflow: true)

        XCTAssertEqual(off.fragments, 5, "precondition: 5 source lines lay out as 5 fragments")
        XCTAssertEqual(on.fragments, 3,
                       "the three-line paragraph must collapse to one fragment, "
                       + "leaving paragraph + blank + paragraph")
        XCTAssertEqual(off.characters, on.characters,
                       "reflow must not change the text storage by a single character")
    }

    /// In a CRLF document the classifier reports the `\n`, and the `\r` in
    /// front of it is a paragraph break of its own. The pair must be typeset
    /// as one space, or Reflow does nothing in CRLF files.
    @MainActor
    func testReflowMergesCRLFLinesWithASingleSpace() {
        func layout(_ doc: String) -> (fragments: Int, secondLineX: CGFloat) {
            let storage = NSTextStorage(string: doc)
            storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                                 range: NSRange(location: 0, length: (doc as NSString).length))
            let layoutManager = NSLayoutManager()
            let container = NSTextContainer(size: NSSize(width: 1200,
                                                          height: CGFloat.greatestFiniteMagnitude))
            storage.addLayoutManager(layoutManager)
            layoutManager.addTextContainer(container)
            let delegate = ReflowLayoutDelegate()
            delegate.textStorage = storage
            delegate.isEnabled = true
            delegate.publish(softNewlines: soft(doc))
            layoutManager.delegate = delegate
            layoutManager.ensureLayout(for: container)

            var fragments = 0
            var idx = 0
            while idx < layoutManager.numberOfGlyphs {
                var effective = NSRange()
                _ = layoutManager.lineFragmentRect(forGlyphAt: idx, effectiveRange: &effective)
                fragments += 1
                idx = NSMaxRange(effective)
                if effective.length == 0 { break }
            }
            let ccc = (doc as NSString).range(of: "ccc")
            let glyph = layoutManager.glyphIndexForCharacter(at: ccc.location)
            return (fragments, layoutManager.location(forGlyphAt: glyph).x)
        }

        let lf = layout("aaa bbb\nccc ddd")
        let crlf = layout("aaa bbb\r\nccc ddd")
        XCTAssertEqual(lf.fragments, 1, "precondition: the LF paragraph merges")
        XCTAssertEqual(crlf.fragments, 1, "the CRLF paragraph must merge as well")
        XCTAssertEqual(crlf.secondLineX, lf.secondLineX, accuracy: 0.01,
                       "the CRLF pair must take the room of ONE space, not two")
    }

    // MARK: - Offsets follow edits until the next classification

    func testShiftMovesOffsetsBehindAnEditAndDropsReplacedOnes() {
        let offsets: Set<Int> = [5, 10, 20]
        // Insert 3 characters at 8 (post-edit range 8..<11).
        XCTAssertEqual(ReflowLayoutDelegate.shift(offsets, editedRange: NSRange(location: 8, length: 3),
                                                  changeInLength: 3), [5, 13, 23])
        // Delete the character at 10 — the newline itself.
        XCTAssertEqual(ReflowLayoutDelegate.shift(offsets, editedRange: NSRange(location: 10, length: 0),
                                                  changeInLength: -1), [5, 19])
        // Replace 9..<12 with one character.
        XCTAssertEqual(ReflowLayoutDelegate.shift(offsets, editedRange: NSRange(location: 9, length: 1),
                                                  changeInLength: -2), [5, 18])
        // Typing directly after a soft newline leaves it where it is.
        XCTAssertEqual(ReflowLayoutDelegate.shift(offsets, editedRange: NSRange(location: 11, length: 1),
                                                  changeInLength: 1), [5, 10, 21])
    }

    /// Typing before a soft newline moves it. Between the edit and the next
    /// (debounced) classification the delegate must still find it, or the
    /// paragraph breaks at its old source lines for a frame.
    @MainActor
    func testSoftNewlinesFollowAnEditBeforeTheNextClassification() {
        let doc = """
        Erste Zeile eines hart umgebrochenen Absatzes
        zweite Zeile desselben Absatzes
        dritte Zeile desselben Absatzes

        Zweiter Absatz nach einer Leerzeile.
        """
        let storage = NSTextStorage(string: doc)
        storage.addAttribute(.font, value: NSFont.systemFont(ofSize: 15),
                             range: NSRange(location: 0, length: (doc as NSString).length))
        let layoutManager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: 1200,
                                                      height: CGFloat.greatestFiniteMagnitude))
        storage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(container)

        let delegate = ReflowLayoutDelegate()
        delegate.textStorage = storage
        delegate.isEnabled = true
        delegate.publish(softNewlines: soft(doc))
        layoutManager.delegate = delegate
        storage.delegate = delegate

        func fragments() -> Int {
            layoutManager.ensureLayout(for: container)
            var count = 0
            var idx = 0
            while idx < layoutManager.numberOfGlyphs {
                var effective = NSRange()
                _ = layoutManager.lineFragmentRect(forGlyphAt: idx, effectiveRange: &effective)
                count += 1
                idx = NSMaxRange(effective)
                if effective.length == 0 { break }
            }
            return count
        }
        XCTAssertEqual(fragments(), 3, "precondition: the paragraph is reflowed")

        storage.replaceCharacters(in: NSRange(location: 0, length: 0), with: "X")

        XCTAssertEqual(delegate.softNewlines, soft(storage.string),
                       "the shifted set must equal a fresh classification of the edited text")
        XCTAssertEqual(fragments(), 3,
                       "no republish yet, and the paragraph must still be one fragment")
    }

    func testExactShiftUsesEachSpanOfAMultiRangeEdit() {
        typealias Edit = ReflowLayoutDelegate.Edit
        let offsets: Set<Int> = [5, 10, 20, 30]
        // Replace 2 chars at 7 with 4, insert 1 at 20 (in front of the
        // newline), delete the newline at 30.
        let edits = [Edit(range: NSRange(location: 7, length: 2), replacementLength: 4),
                     Edit(range: NSRange(location: 20, length: 0), replacementLength: 1),
                     Edit(range: NSRange(location: 30, length: 1), replacementLength: 0)]
        XCTAssertEqual(ReflowLayoutDelegate.shift(offsets, by: edits), [5, 12, 23])
    }

    func testAnAnnouncementThatDoesNotMatchTheEditIsIgnored() {
        typealias Edit = ReflowLayoutDelegate.Edit
        let typed = [Edit(range: NSRange(location: 16, length: 0), replacementLength: 1)]
        // What NSTextView reports for that keystroke: widened to the line end.
        XCTAssertTrue(ReflowLayoutDelegate.edits(typed, explain: NSRange(location: 16, length: 7),
                                                 changeInLength: 1))
        // A different net length change (an undo after an abandoned change).
        XCTAssertFalse(ReflowLayoutDelegate.edits(typed, explain: NSRange(location: 16, length: 0),
                                                  changeInLength: -1))
        // Same delta, but the span is not inside the processed range.
        XCTAssertFalse(ReflowLayoutDelegate.edits(typed, explain: NSRange(location: 40, length: 1),
                                                  changeInLength: 1))
    }

    /// Wires a real editor text view the way `MarkdownTextView` does.
    @MainActor
    private func reflowingTextView(_ doc: String) -> (PicaMDTextView, ReflowLayoutDelegate, NSScrollView) {
        let (scrollView, textView) = PicaMDTextView.makeScrollable()
        textView.string = doc
        let delegate = ReflowLayoutDelegate()
        delegate.textStorage = textView.textStorage
        delegate.isEnabled = true
        textView.layoutManager?.delegate = delegate
        textView.textStorage?.delegate = delegate
        textView.reflowDelegate = delegate
        delegate.publish(softNewlines: soft(doc))
        return (textView, delegate, scrollView)
    }

    /// NSTextView widens the processed range of a keystroke to the end of
    /// its paragraph, so a shift by that range alone dropped the soft newline
    /// of the very line being typed in.
    @MainActor
    func testSoftNewlinesFollowTypingInARealTextView() {
        let doc = """
        Erste Zeile eines hart umgebrochenen Absatzes
        zweite Zeile desselben Absatzes
        dritte Zeile desselben Absatzes

        Zweiter Absatz nach einer Leerzeile.
        """
        let (textView, delegate, scrollView) = reflowingTextView(doc)
        XCTAssertFalse(delegate.softNewlines.isEmpty, "precondition")

        textView.setSelectedRange(NSRange(location: 5, length: 0))
        textView.insertText("X", replacementRange: textView.selectedRange())
        textView.insertText("Y", replacementRange: textView.selectedRange())
        XCTAssertEqual(delegate.softNewlines, soft(textView.string),
                       "typing in the first line must keep that line's soft newline")

        textView.deleteBackward(nil)
        XCTAssertEqual(delegate.softNewlines, soft(textView.string))
        withExtendedLifetime(scrollView) {}
    }

    /// Replace All announces every span; the newlines between the
    /// replacements stay soft instead of waiting for the next pass.
    @MainActor
    func testReplaceAllKeepsTheSoftNewlinesBetweenTheReplacements() {
        let doc = """
        Eine Zeile eines hart umgebrochenen Absatzes
        noch eine Zeile desselben Absatzes
        und eine letzte Zeile desselben Absatzes
        """
        let (textView, delegate, scrollView) = reflowingTextView(doc)
        guard let storage = textView.textStorage else { XCTFail(); return }
        let ns = doc as NSString
        var ranges: [NSRange] = []
        var from = 0
        while case let r = ns.range(of: "Zeile", range: NSRange(location: from, length: ns.length - from)),
              r.location != NSNotFound {
            ranges.append(r)
            from = NSMaxRange(r)
        }
        XCTAssertEqual(ranges.count, 3, "precondition")

        // The same sequence as the coordinator's replaceAllMatches().
        XCTAssertTrue(textView.shouldChangeText(inRanges: ranges.map { NSValue(range: $0) },
                                                replacementStrings: ranges.map { _ in "Reihe!" }))
        storage.beginEditing()
        for range in ranges.reversed() { storage.replaceCharacters(in: range, with: "Reihe!") }
        storage.endEditing()
        textView.didChangeText()

        XCTAssertEqual(delegate.softNewlines.count, 2)
        XCTAssertEqual(delegate.softNewlines, soft(textView.string))
        withExtendedLifetime(scrollView) {}
    }

    /// Undo bypasses `shouldChangeText` and arrives coalesced: one
    /// `editedRange` that is the union of all spans. Offsets inside it are
    /// dropped, offsets behind it still land on their own newline.
    @MainActor
    func testUnannouncedCoalescedEditsOnlyDropOffsets() {
        let doc = """
        Erster Absatz erste Zeile
        Erster Absatz zweite Zeile

        Zweiter Absatz erste Zeile
        Zweiter Absatz zweite Zeile

        Dritter Absatz erste Zeile
        Dritter Absatz zweite Zeile
        Dritter Absatz dritte Zeile
        """
        let storage = NSTextStorage(string: doc)
        let delegate = ReflowLayoutDelegate()
        delegate.textStorage = storage
        storage.delegate = delegate
        delegate.publish(softNewlines: soft(doc))
        XCTAssertEqual(soft(doc).count, 4, "precondition")

        storage.beginEditing()
        storage.replaceCharacters(in: NSRange(location: 2, length: 0), with: "ab")
        let second = (storage.string as NSString).range(of: "Zweiter").location
        storage.replaceCharacters(in: NSRange(location: second, length: 3), with: "z")
        storage.endEditing()

        let fresh = soft(storage.string)
        XCTAssertTrue(delegate.softNewlines.isSubset(of: fresh),
                      "a shifted offset that is not a soft newline would join two blocks")
        // The first paragraph's newline sits between the two edits; the
        // other three are behind the second one.
        XCTAssertEqual(delegate.softNewlines, fresh.filter { $0 > second + 1 })
        XCTAssertEqual(delegate.softNewlines.count, 3)
    }

    func testEveryReportedOffsetPointsAtANewline() {
        let doc = """
        # Titel

        Ein Absatz der über
        mehrere Zeilen geht.

        | a | b |
        |---|---|
        | 1 | 2 |

        - Liste
        - Punkte

        > Zitat hier
        > und weiter

        Schluss.
        """
        let ns = doc as NSString
        for offset in soft(doc) {
            XCTAssertTrue(offset >= 0 && offset < ns.length, "offset \(offset) out of bounds")
            XCTAssertEqual(ns.substring(with: NSRange(location: offset, length: 1)), "\n",
                           "offset \(offset) does not point at a newline")
        }
    }
}
