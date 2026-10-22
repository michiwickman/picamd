import XCTest
@testable import PicaMD

/// `` `M8\|M10` `` in a table cell was drawn
/// with the backslash. GFM takes `\|` apart at table level, before inline
/// parsing — even inside a code span — so the cell shows `M8|M10`. The
/// source keeps its backslash: only what is drawn changes.
final class TableCellTextTests: XCTestCase {

    private let source = "| Gewinde | Hinweis |\n|---|---|\n| `M8\\|M10` | M8\\|M10 |\n"

    private var table: ExtractedBlock? {
        BlockExtractor.extract(from: source).first { $0.kind == .table }
    }

    func testEscapedPipeIsDrawnWithoutItsBackslash() throws {
        let parsed = try XCTUnwrap(table?.parseTable())
        XCTAssertEqual(parsed.headers, ["Gewinde", "Hinweis"])
        XCTAssertEqual(parsed.rows.first ?? [], ["`M8|M10`", "M8|M10"],
                       "the escaped pipe must not split the cell, and its backslash is not drawn")
    }

    /// The cell editor and its write-back work on the source, which must
    /// keep the escape — otherwise committing the cell would split it.
    func testCellEditorStillSeesTheEscapedSource() throws {
        let cells = try XCTUnwrap(table?.parseTableCells())
        XCTAssertEqual(cells.rows.first?.map(\.text) ?? [], ["`M8\\|M10`", "M8\\|M10"])
    }
}
