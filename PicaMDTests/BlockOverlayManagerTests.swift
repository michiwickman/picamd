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

    func testViewRecreatedWhenContentChanges() {
        let doc1 = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        let (tv, mgr) = makeFixture(doc1)
        guard let block1 = firstTable(in: doc1) else { XCTFail(); return }
        mgr.update(blocks: BlockExtractor.extract(from: doc1), cursorActiveRanges: [])
        let view1 = mgr.pooledViewForTesting(matching: block1)
        XCTAssertNotNil(view1)

        // Change a cell value: payload differs → new identity → new view.
        let doc2 = "| A | B |\n|---|---|\n| 9 | 9 |\n"
        tv.string = doc2
        mgr.update(blocks: BlockExtractor.extract(from: doc2), cursorActiveRanges: [])
        guard let block2 = firstTable(in: doc2) else { XCTFail(); return }
        let view2 = mgr.pooledViewForTesting(matching: block2)

        XCTAssertNotNil(view2)
        XCTAssertFalse(view1 === view2, "changed content must create a NEW overlay view")
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
