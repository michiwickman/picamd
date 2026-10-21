import XCTest
import AppKit
@testable import PicaMD

/// Regression coverage for the table-overlay geometry bugs:
///
///   * the reserved band height and the drawn table height were computed at
///     two different widths (2 pt apart), which flipped a wrapped line in
///     dense cells and shifted the overlay against the text underneath;
///   * the height cache ignored width, so a window resize kept reserving the
///     height measured at the previous width until the payload changed;
///   * every column was `available / columnCount` wide regardless of content,
///     so the trailing column was grossly over-wide while a prose column
///     wrapped needlessly.
@MainActor
final class TableLayoutTests: XCTestCase {

    /// A table whose columns want wildly different widths — the shape that
    /// exposed the uniform-width model in real documents.
    private let lopsided = """
    | Nr. | Parameter | Ausprägungen |
    |---|---|---|
    | M1 | Physikalisches Wirkprinzip | mechanischer Kontakt, induktiv Tauchanker, Wirbelstrom am bewegten Metall, LVDT differenziell, magnetostriktive Laufzeit, magnetisch Reed, akustisch Ultraschall-Laufzeit, faseroptisch Mikrobiegung |
    | M2 | Ort des Elements | im Wasser passiv, ausserhalb durch die Wand |
    """

    private func makeFixture(_ text: String, width: CGFloat = 900) -> (NSTextView, BlockOverlayManager) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 600))
        tv.string = text
        let mgr = BlockOverlayManager()
        mgr.textView = tv
        return (tv, mgr)
    }

    private func firstTable(in source: String) -> ExtractedBlock? {
        BlockExtractor.extract(from: source).first { $0.kind == .table }
    }

    // MARK: - Measure width == draw width

    func testReservedHeightMatchesHeightAtTheDrawnWidth() {
        let (_, mgr) = makeFixture(lopsided)
        let blocks = BlockExtractor.extract(from: lopsided)
        guard let block = blocks.first(where: { $0.kind == .table }) else {
            XCTFail("table not extracted"); return
        }
        mgr.update(blocks: blocks, cursorActiveRanges: [])

        let reserved = mgr.desiredHeights(for: blocks)[block]
        XCTAssertNotNil(reserved)

        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail("expected a TableBlockView"); return
        }
        // The height the view actually draws at its own frame width must be
        // exactly the height that was reserved for it. This is the invariant
        // the whole fix exists to guarantee.
        let drawn = view.desiredHeight(for: mgr.contentWidthForTesting)
        XCTAssertEqual(reserved!, drawn, accuracy: 0.001,
                       "reserved band height and drawn table height must agree exactly")
    }

    func testOverlayFrameWidthEqualsTheMeasuringWidth() {
        let (_, mgr) = makeFixture(lopsided)
        let blocks = BlockExtractor.extract(from: lopsided)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) else { XCTFail(); return }

        XCTAssertEqual(view.frame.width, mgr.contentWidthForTesting, accuracy: 0.001,
                       "the overlay must be drawn at exactly the width it was measured at")
    }

    // MARK: - Width-aware height cache

    func testHeightCacheIsInvalidatedWhenTheWidthChanges() {
        let (tv, mgr) = makeFixture(lopsided, width: 1400)
        let blocks = BlockExtractor.extract(from: lopsided)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])

        let wide = mgr.desiredHeights(for: blocks)[block]
        let wideWidth = mgr.contentWidthForTesting

        // Shrink the window; the payload is untouched. Before the fix the
        // cache key ignored width and happily returned the old height.
        tv.setFrameSize(NSSize(width: 420, height: 600))
        let narrowWidth = mgr.contentWidthForTesting
        XCTAssertLessThan(narrowWidth, wideWidth, "precondition: the usable width must shrink")

        let narrow = mgr.desiredHeights(for: blocks)[block]
        XCTAssertNotNil(wide)
        XCTAssertNotNil(narrow)
        XCTAssertGreaterThan(narrow!, wide!,
                             "a narrower table wraps more and must reserve MORE height")
    }

    func testStaleWidthEntriesAreDroppedFromTheCache() {
        let (tv, mgr) = makeFixture(lopsided, width: 1400)
        let blocks = BlockExtractor.extract(from: lopsided)
        _ = mgr.desiredHeights(for: blocks)
        let afterFirst = mgr.probeCacheCountForTesting
        XCTAssertGreaterThan(afterFirst, 0)

        // Walk several widths, as a live resize does.
        for w in stride(from: CGFloat(1300), through: 900, by: -100) {
            tv.setFrameSize(NSSize(width: w, height: 600))
            _ = mgr.desiredHeights(for: blocks)
        }
        XCTAssertEqual(mgr.probeCacheCountForTesting, afterFirst,
                       "only the current width may be cached — a resize must not accumulate entries")
    }

    // MARK: - Content-proportional columns

    func testColumnsAreProportionalToContentNotUniform() {
        let (_, mgr) = makeFixture(lopsided)
        let blocks = BlockExtractor.extract(from: lopsided)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }

        let available = mgr.contentWidthForTesting
        let widths = view.columnWidthsForTesting(width: available)
        XCTAssertEqual(widths.count, 3)

        // "Nr." holds two characters; "Ausprägungen" holds a long list.
        XCTAssertLessThan(widths[0], widths[1], "the number column must be the narrowest")
        XCTAssertLessThan(widths[1], widths[2], "the prose column must be the widest")

        let uniform = available / 3
        XCTAssertLessThan(widths[0], uniform * 0.6,
                          "the number column must be well below its old uniform share")

        // The table must still fill exactly the width it was given.
        XCTAssertEqual(widths.reduce(0, +), available, accuracy: 0.5)
    }

    func testEveryColumnKeepsAUsableMinimumWidth() {
        // Many columns, one of them enormously greedy.
        let squeezed = """
        | A | B | C | D | E |
        |---|---|---|---|---|
        | 1 | 2 | 3 | 4 | \(String(repeating: "sehr langer Text ", count: 40)) |
        """
        let (_, mgr) = makeFixture(squeezed, width: 700)
        let blocks = BlockExtractor.extract(from: squeezed)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }
        let widths = view.columnWidthsForTesting(width: mgr.contentWidthForTesting)
        for (i, w) in widths.enumerated() {
            XCTAssertGreaterThan(w, 1, "column \(i) collapsed to nothing")
        }
    }

    func testColumnWidthsNeverOverflowTheAvailableWidth() {
        // Many modest columns plus one very greedy one: the naive
        // clamp-to-floor implementation raised the modest columns to the
        // floor without taking that space from anyone, so the widths summed
        // to more than the table was given and the trailing column was
        // clipped away by masksToBounds.
        let greedy = String(repeating: "unteilbarerlangertext ", count: 60)
        for columns in 2...9 {
            let header = "|" + (1...columns).map { " H\($0) " }.joined(separator: "|") + "|"
            let sep = "|" + (1...columns).map { _ in "---" }.joined(separator: "|") + "|"
            var cells = (1..<columns).map { " \($0) " }
            cells.append(" \(greedy) ")
            let row = "|" + cells.joined(separator: "|") + "|"
            let doc = "\(header)\n\(sep)\n\(row)\n"

            for windowWidth in [CGFloat(400), 700, 1400] {
                let (_, mgr) = makeFixture(doc, width: windowWidth)
                let blocks = BlockExtractor.extract(from: doc)
                guard let block = blocks.first(where: { $0.kind == .table }) else {
                    XCTFail("no table for \(columns) columns"); continue
                }
                mgr.update(blocks: blocks, cursorActiveRanges: [])
                guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
                    XCTFail(); continue
                }
                let available = mgr.contentWidthForTesting
                let widths = view.columnWidthsForTesting(width: available)
                let total = widths.reduce(0, +)
                // A table that fits fills exactly the available width. One
                // whose longest words don't fit gets wider and scrolls
                // sideways — never narrower, and never with a column
                // whose trailing part is unreachable.
                XCTAssertGreaterThanOrEqual(total, available - 0.5,
                                            "\(columns) columns at \(windowWidth)pt must fill the available width")
                if total > available + 0.5 {
                    view.frame = NSRect(x: 0, y: 0, width: available, height: 200)
                    XCTAssertEqual(view.horizontalOverflow, total - available, accuracy: 0.5,
                                   "\(columns) columns at \(windowWidth)pt: the overflow must be scrollable")
                    let greedyWord = longestWordWidth("unteilbarerlangertext", font: bodyFont)
                    XCTAssertGreaterThanOrEqual(widths.last ?? 0, greedyWord,
                                                "an overflowing table must not break words")
                }
                for w in widths {
                    XCTAssertGreaterThan(w, 0, "\(columns) columns at \(windowWidth)pt produced a non-positive column")
                }
            }
        }
    }

    func testColumnsAreNeverSqueezedBelowTheirLongestWord() {
        // Found by looking at the real app: at a narrow window the middle
        // column of "Nr. | Parameter | Ausprägungen" was squeezed to the flat
        // 56 pt minimum next to a very greedy neighbour, so "Parameter"
        // rendered as "Para / mete / r". A column must not go below the width
        // of the longest word it has to show.
        let (_, mgr) = makeFixture(lopsided, width: 520)
        let blocks = BlockExtractor.extract(from: lopsided)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }
        let available = mgr.contentWidthForTesting
        let widths = view.columnWidthsForTesting(width: available)

        // "Physikalisches" is the longest word in the middle column.
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let longest = ceil(NSAttributedString(string: "Physikalisches",
                                              attributes: [.font: font]).size().width)
        XCTAssertGreaterThanOrEqual(widths[1], longest,
                                    "the middle column must fit its longest word without breaking it")
        XCTAssertEqual(widths.reduce(0, +), available, accuracy: 0.5)
    }

    // MARK: - Too narrow for the longest words

    private let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)
    private let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)

    private func longestWordWidth(_ word: String, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: word, attributes: [.font: font]).size().width)
    }

    /// The morphological box from the visual check: at a 940 pt window the
    /// readable column is ~620 pt, and the floors of its columns add up to
    /// more than that. They used to be scaled down together, which broke
    /// every column inside a word ("Nr|.", "Ausprägun|g A", "Fügeverfahr|en",
    /// "pulverbeschicht|et").
    private let morphologicalBox = """
    | Nr. | Parameter | Ausprägung A | Ausprägung B | Ausprägung C | Ausprägung D |
    |---|---|---|---|---|---|
    | P1 | Fügeverfahren | geschraubt | geklebt | geschweißt | genietet |
    | P2 | Oberfläche | pulverbeschichtet | eloxiert | lackiert | verzinkt |
    | P3 | Gewinde | `M8\\|M10` | `M12` | Feingewinde | selbstschneidend |
    """

    func testNoColumnBreaksInsideAWordWhenTheTableIsTooNarrow() {
        for width in [CGFloat(500), 620] {
            let (_, mgr) = makeFixture(morphologicalBox, width: width)
            let blocks = BlockExtractor.extract(from: morphologicalBox)
            guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
            mgr.update(blocks: blocks, cursorActiveRanges: [])
            guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView,
                  let parsed = block.parseTable() else { XCTFail(); return }
            let widths = view.columnWidthsForTesting(width: mgr.contentWidthForTesting)

            // Every word of every cell, measured independently in the font it
            // is drawn in, must fit its column's text width (12 pt padding).
            func check(_ cells: [String], font: NSFont) {
                for (col, cell) in cells.enumerated() {
                    for word in cell.split(separator: " ") where !word.contains("`") {
                        XCTAssertGreaterThanOrEqual(widths[col] - 24, longestWordWidth(String(word), font: font),
                                                    "at \(width) pt column \(col) breaks \"\(word)\"")
                    }
                }
            }
            check(parsed.headers, font: headerFont)
            for row in parsed.rows { check(row, font: bodyFont) }
            // The code span is measured in the code font, without backticks.
            let code = ceil(NSAttributedString(string: "M8|M10", attributes:
                [.font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)]).size().width)
            XCTAssertGreaterThanOrEqual(widths[2] - 24, code, "at \(width) pt the code span breaks")
        }
    }

    /// The line breaker keeps a hyphen with a following digit and a
    /// leading hyphen with its word, so those may not end a run when the
    /// column floor is measured; a hyphen inside a word still does.
    func testHyphenatedNumbersAreMeasuredWhole() {
        func floor(_ text: String) -> CGFloat {
            TableBlockView.longestUnbreakableWidth(in: NSAttributedString(string: text, attributes: [.font: bodyFont]))
        }
        for number in ["-1234567", "170-1234567", "+49-170-1234567", "6-12"] {
            XCTAssertEqual(floor(number), longestWordWidth(number, font: bodyFont), "\(number) breaks inside")
        }
        XCTAssertEqual(floor("Ausprägungs-Wert"),
                       max(longestWordWidth("Ausprägungs-", font: bodyFont), longestWordWidth("Wert", font: bodyFont)))
    }

    /// The overlay manager sets every table's frame on each scroll tick.
    /// With the size unchanged, and for a table that is not scrolled
    /// sideways, that may not run a layout pass; neither may a vertical
    /// wheel event over a table.
    func testScrollingTheDocumentRunsNoTableLayout() throws {
        let (_, mgr) = makeFixture(morphologicalBox, width: 500)
        let blocks = BlockExtractor.extract(from: morphologicalBox)
        let block = try XCTUnwrap(blocks.first(where: { $0.kind == .table }))
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        let view = try XCTUnwrap(mgr.pooledViewForTesting(matching: block) as? TableBlockView)
        let available = mgr.contentWidthForTesting
        view.frame = NSRect(x: 0, y: 0, width: available, height: 300)

        let before = TableBlockView.layoutPassCountForTesting
        for y in stride(from: CGFloat(0), to: 200, by: 10) {
            view.frame = NSRect(x: 0, y: y, width: available, height: 300)
        }
        let vertical = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                             wheelCount: 2, wheel1: -12, wheel2: 0, wheel3: 0))
        view.scrollWheel(with: try XCTUnwrap(NSEvent(cgEvent: vertical)))
        XCTAssertEqual(TableBlockView.layoutPassCountForTesting, before)

        // A scrolled table is still re-clamped when its width shrinks.
        view.horizontalScrollOffset = 10_000
        let scrolled = view.horizontalScrollOffset
        XCTAssertGreaterThan(scrolled, 0)
        view.frame = NSRect(x: 0, y: 0, width: available + 40, height: 300)
        XCTAssertEqual(view.horizontalScrollOffset, view.horizontalOverflow, accuracy: 0.5)
        XCTAssertLessThan(view.horizontalScrollOffset, scrolled)
    }

    func testOverflowingTableScrollsSidewaysAndRevealsColumns() {
        let (_, mgr) = makeFixture(morphologicalBox, width: 500)
        let blocks = BlockExtractor.extract(from: morphologicalBox)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }
        let available = mgr.contentWidthForTesting
        view.frame = NSRect(x: 0, y: 0, width: available, height: view.desiredHeight(for: available))
        let widths = view.columnWidthsForTesting(width: available)
        let total = widths.reduce(0, +)
        XCTAssertGreaterThan(total, available, "fixture must overflow at 500 pt")
        XCTAssertEqual(view.horizontalOverflow, total - available, accuracy: 0.5)

        // Clamped to the table's extent.
        view.horizontalScrollOffset = 10_000
        XCTAssertEqual(view.horizontalScrollOffset, total - available, accuracy: 0.5)
        view.horizontalScrollOffset = -50
        XCTAssertEqual(view.horizontalScrollOffset, 0)

        // Bringing the last column into view puts its right edge at the
        // view's right edge, and a click there hits that column.
        let last = widths.count - 1
        view.scrollColumnToVisible(last)
        XCTAssertEqual(view.horizontalScrollOffset, total - available, accuracy: 0.5)
        let rightEdge = view.horizontalScrollOffset + available - 2
        let hit = view.cellAt(NSPoint(x: rightEdge, y: view.bounds.height - 4))
        XCTAssertEqual(hit?.col, last)
        view.scrollColumnToVisible(0)
        XCTAssertEqual(view.horizontalScrollOffset, 0)

        // A table that fits does not scroll.
        let (_, wide) = makeFixture(morphologicalBox, width: 2000)
        wide.update(blocks: blocks, cursorActiveRanges: [])
        guard let fitting = wide.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }
        fitting.frame = NSRect(x: 0, y: 0, width: wide.contentWidthForTesting, height: 200)
        XCTAssertEqual(fitting.horizontalOverflow, 0)
        fitting.horizontalScrollOffset = 40
        XCTAssertEqual(fitting.horizontalScrollOffset, 0)
    }

    // MARK: - CRLF documents

    func testTableInACRLFDocumentStillParses() {
        // "\r\n" is a single Swift Character, so the old
        // `split(separator: "\n")` never fired and every table in a CRLF
        // file rendered as an empty box.
        let crlf = "| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n"
        guard let block = BlockExtractor.extract(from: crlf).first(where: { $0.kind == .table }) else {
            XCTFail("CRLF table not extracted"); return
        }
        guard let parsed = block.parseTable() else {
            XCTFail("CRLF table extracted but not parsed — renders as an empty box"); return
        }
        XCTAssertEqual(parsed.headers, ["A", "B"])
        XCTAssertEqual(parsed.rows.count, 1)
        XCTAssertEqual(parsed.rows.first ?? [], ["1", "2"])
    }

    // MARK: - Pre-layout guard

    func testNoHeightsAreReportedBeforeTheContainerHasAWidth() {
        // makeNSView highlights before SwiftUI lays the scroll view out.
        // Reserving at the clamped minimum there baked an ~8x too-tall band
        // into every table in the document.
        let tv = NSTextView(frame: .zero)
        tv.string = lopsided
        tv.textContainer?.size = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        let mgr = BlockOverlayManager()
        mgr.textView = tv

        let blocks = BlockExtractor.extract(from: lopsided)
        XCTAssertTrue(mgr.desiredHeights(for: blocks).isEmpty,
                      "with no resolved width there must be NO reservation at all")
    }

    // MARK: - Shared collapse predicate

    func testCaretOnTheLineBelowTheTableDoesNotRevealTheSource() {
        // The highlighter used ±1 fuzz, the overlay manager none. At exactly
        // this caret position the source was un-concealed while the opaque
        // overlay stayed drawn on top of it.
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\nText darunter\n"
        guard let block = BlockExtractor.extract(from: doc).first(where: { $0.kind == .table }) else {
            XCTFail(); return
        }
        let firstCharBelow = block.range.location + block.range.length + 1
        let caret = NSRange(location: firstCharBelow, length: 0)

        // Both sides must now answer identically — this is the invariant.
        XCTAssertFalse(caret.touchesBlock(block.range),
                       "a caret on the line below must not count as editing the table")
    }

    func testCaretInsideTheTableIsTreatedAsEditingByBothSides() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\nText darunter\n"
        guard let block = BlockExtractor.extract(from: doc).first(where: { $0.kind == .table }) else {
            XCTFail(); return
        }
        let caret = NSRange(location: block.range.location + 3, length: 0)
        XCTAssertTrue(caret.touchesBlock(block.range))
    }

    func testColumnCountFollowsTheWidestRowNotTheFirst() {
        // The header and first body row have 2 cells; a later row has 3.
        // The old code sized from the first row and drew the extra cell
        // past the right edge with no separator.
        let ragged = """
        | A | B |
        |---|---|
        | 1 | 2 |
        | 3 | 4 | 5 |
        """
        let (_, mgr) = makeFixture(ragged)
        let blocks = BlockExtractor.extract(from: ragged)
        guard let block = blocks.first(where: { $0.kind == .table }) else { XCTFail(); return }
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        guard let view = mgr.pooledViewForTesting(matching: block) as? TableBlockView else {
            XCTFail(); return
        }
        XCTAssertEqual(view.columnCountForTesting(width: mgr.contentWidthForTesting), 3,
                       "the widest row determines the column count")
    }
}
