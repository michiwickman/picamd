import XCTest
import AppKit
@testable import PicaMD

/// Coverage for the content-identity view pool (F6): a range shift from
/// editing *above* a block must REUSE its overlay view (so a WKWebView
/// isn't torn down + respawned on every keystroke), while an actual
/// content change must create a fresh view.
@MainActor
final class BlockOverlayManagerTests: XCTestCase {

    private func makeFixture(_ text: String) -> (NSTextView, BlockOverlayManager) {
        let tv = NSTextView(frame: NSRect(x: 0, y: 0, width: 600, height: 400))
        tv.string = text
        let mgr = BlockOverlayManager()
        mgr.textView = tv
        return (tv, mgr)
    }

    private func firstTable(in source: String) -> ExtractedBlock? {
        BlockExtractor.extract(from: source).first { $0.kind == .table }
    }

    func testViewReusedWhenRangeShiftsButContentUnchanged() {
        let doc1 = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (tv, mgr) = makeFixture(doc1)
        guard let block1 = firstTable(in: doc1) else {
            XCTFail("table not extracted"); return
        }
        mgr.update(blocks: BlockExtractor.extract(from: doc1), cursorActiveRanges: [])
        let view1 = mgr.pooledViewForTesting(matching: block1)
        XCTAssertNotNil(view1, "table should get an overlay view")

        // Insert a line ABOVE the table: same payload, shifted range.
        let doc2 = "inserted heading\n" + doc1
        tv.string = doc2
        guard let block2 = firstTable(in: doc2) else { XCTFail(); return }
        XCTAssertNotEqual(block1.range.location, block2.range.location,
                          "precondition: the table's range must have shifted")
        mgr.update(blocks: BlockExtractor.extract(from: doc2), cursorActiveRanges: [])
        let view2 = mgr.pooledViewForTesting(matching: block2)

        XCTAssertNotNil(view2)
        XCTAssertTrue(view1 === view2,
                      "same content at a shifted range MUST reuse the overlay view (no respawn)")
        XCTAssertEqual(mgr.pooledViewCountForTesting, 1)
    }

    /// Tables are pooled by document POSITION, not by payload — deliberately.
    /// A payload-keyed pool tore the view down on every committed keystroke,
    /// which would destroy an open in-place cell editor mid-edit and lose the
    /// target of Tab-chaining. The view must be reused and refreshed instead.
    func testTableViewIsReusedAndRefreshedWhenContentChanges() {
        let doc1 = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (tv, mgr) = makeFixture(doc1)
        guard let block1 = firstTable(in: doc1) else { XCTFail(); return }
        mgr.update(blocks: BlockExtractor.extract(from: doc1), cursorActiveRanges: [])
        let view1 = mgr.pooledViewForTesting(matching: block1)
        XCTAssertNotNil(view1)

        // Edit a cell, exactly as committing an in-place edit would.
        let doc2 = "| A | B |\n|---|---|\n| 9 | 2 |\n"
        tv.string = doc2
        mgr.update(blocks: BlockExtractor.extract(from: doc2), cursorActiveRanges: [])
        guard let block2 = firstTable(in: doc2) else { XCTFail(); return }
        let view2 = mgr.pooledViewForTesting(matching: block2)

        XCTAssertTrue(view1 === view2,
                      "a cell edit must REUSE the table's overlay view, not replace it")
        XCTAssertEqual(view2?.block.payload, block2.payload,
                       "the reused view must have adopted the new content")
        XCTAssertEqual(mgr.pooledViewCountForTesting, 1)
    }

    /// After an edit, the height must be measured for the NEW table. The
    /// pooled view still holds the old table until `update()` runs, and the
    /// highlighter asks for heights before that — measuring the pooled view
    /// cached the old height under the new payload's key.
    func testEditedTableIsMeasuredWithItsNewContent() {
        let doc1 = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (tv, mgr) = makeFixture(doc1)
        let blocks1 = BlockExtractor.extract(from: doc1)
        _ = mgr.desiredHeights(for: blocks1)
        mgr.update(blocks: blocks1, cursorActiveRanges: [])

        let doc2 = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n| 5 | 6 |\n| 7 | 8 |\n"
        tv.string = doc2
        let blocks2 = BlockExtractor.extract(from: doc2)
        guard let table2 = blocks2.first(where: { $0.kind == .table }) else { XCTFail(); return }
        let measured = mgr.desiredHeights(for: blocks2)[table2]

        let (_, fresh) = makeFixture(doc2)
        let expected = fresh.desiredHeights(for: blocks2)[table2]
        XCTAssertNotNil(expected)
        XCTAssertEqual(measured, expected,
                       "a table with four more rows must not reuse the old height")
    }

    /// Two tables in one document keep separate views, and editing the first
    /// must not make the second adopt its content.
    func testTwoTablesKeepDistinctViews() {
        let doc = "| A |\n|---|\n| 1 |\n\ntext\n\n| B |\n|---|\n| 2 |\n"
        let (_, mgr) = makeFixture(doc)
        let blocks = BlockExtractor.extract(from: doc)
        mgr.update(blocks: blocks, cursorActiveRanges: [])
        XCTAssertEqual(mgr.pooledViewCountForTesting, 2)

        let tables = blocks.filter { $0.kind == .table }
        XCTAssertEqual(tables.count, 2)
        let first = mgr.view(for: tables[0])
        let second = mgr.view(for: tables[1])
        XCTAssertNotNil(first)
        XCTAssertNotNil(second)
        XCTAssertFalse(first === second, "each table must have its own view")
        XCTAssertEqual(first?.block.payload, tables[0].payload)
        XCTAssertEqual(second?.block.payload, tables[1].payload)
    }

    /// Images are NOT pooled by position: `ImageBlockView` loads its file
    /// once, so a reused view would keep showing (and sizing for) the old
    /// image after the path changed.
    func testImagePathChangeCreatesAFreshView() {
        let doc1 = "![x](a.png)\n"
        let (tv, mgr) = makeFixture(doc1)
        guard let block1 = BlockExtractor.extract(from: doc1).first(where: { $0.kind == .image }) else {
            XCTFail("image not extracted"); return
        }
        mgr.update(blocks: BlockExtractor.extract(from: doc1), cursorActiveRanges: [])
        let view1 = mgr.pooledViewForTesting(matching: block1)
        XCTAssertNotNil(view1)

        let doc2 = "![x](b.png)\n"
        tv.string = doc2
        let blocks2 = BlockExtractor.extract(from: doc2)
        mgr.update(blocks: blocks2, cursorActiveRanges: [])
        guard let block2 = blocks2.first(where: { $0.kind == .image }) else { XCTFail(); return }
        let view2 = mgr.pooledViewForTesting(matching: block2)

        XCTAssertNotNil(view2)
        XCTAssertFalse(view1 === view2,
                       "a changed image path must get a new view, which loads the new file")
        XCTAssertEqual(mgr.pooledViewCountForTesting, 1)
    }

    /// Deleting the first of two images must leave the second image's own
    /// view in place, not hand the first image's view the second's payload.
    func testRemovingAnImageAboveKeepsTheOtherImagesView() {
        let doc1 = "![a](a.png)\n\ntext\n\n![b](b.png)\n"
        let (tv, mgr) = makeFixture(doc1)
        let blocks1 = BlockExtractor.extract(from: doc1).filter { $0.kind == .image }
        XCTAssertEqual(blocks1.count, 2)
        mgr.update(blocks: blocks1, cursorActiveRanges: [])
        let secondView = mgr.pooledViewForTesting(matching: blocks1[1])
        XCTAssertNotNil(secondView)

        let doc2 = "text\n\n![b](b.png)\n"
        tv.string = doc2
        let blocks2 = BlockExtractor.extract(from: doc2).filter { $0.kind == .image }
        mgr.update(blocks: blocks2, cursorActiveRanges: [])
        XCTAssertEqual(mgr.pooledViewCountForTesting, 1)
        XCTAssertTrue(mgr.pooledViewForTesting(matching: blocks2[0]) === secondView,
                      "the surviving image keeps the view that already rendered it")
    }

    func testClearRemovesAllViews() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (_, mgr) = makeFixture(doc)
        mgr.update(blocks: BlockExtractor.extract(from: doc), cursorActiveRanges: [])
        XCTAssertGreaterThan(mgr.pooledViewCountForTesting, 0)
        mgr.clear()
        XCTAssertEqual(mgr.pooledViewCountForTesting, 0)
    }

    func testVanishedBlockIsRemoved() {
        let doc1 = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (tv, mgr) = makeFixture(doc1)
        mgr.update(blocks: BlockExtractor.extract(from: doc1), cursorActiveRanges: [])
        XCTAssertEqual(mgr.pooledViewCountForTesting, 1)

        // Delete the table entirely.
        let doc2 = "just prose now\n"
        tv.string = doc2
        mgr.update(blocks: BlockExtractor.extract(from: doc2), cursorActiveRanges: [])
        XCTAssertEqual(mgr.pooledViewCountForTesting, 0,
                       "removing the block must drop its pooled view")
    }
}
