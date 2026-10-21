import XCTest
import AppKit
@testable import PicaMD

/// The in-place cell editor inside a real document window: what happens to
/// the document's caret and to keyboard focus when a cell edit is committed
/// with Return. Both depend on the coordinator's wiring, which a bare
/// `TableCellEditor` cannot show.
@MainActor
final class TableCellCommitTests: XCTestCase {

    private var hosted: HostedDocument?

    override func tearDown() async throws {
        hosted?.close()
        hosted = nil
        try await super.tearDown()
    }

    private func tableView(in view: NSView) -> TableBlockView? {
        if let t = view as? TableBlockView { return t }
        for sub in view.subviews {
            if let t = tableView(in: sub) { return t }
        }
        return nil
    }

    private func textField(in view: NSView) -> NSTextField? {
        view.subviews.compactMap { $0 as? NSTextField }.first
    }

    /// Opens the cell editor on body cell (0, 0) of a document whose caret
    /// sits at the start of the line after the table, types `input` and
    /// presses Return.
    private func commitCell(_ input: String) throws -> (tv: PicaMDTextView, source: String) {
        let doc = try HostedDocument.untitled()
        hosted = doc
        let tv = doc.textView
        let source = "| A | B |\n|---|---|\n| 1 | 2 |\nafter\n"
        let full = NSRange(location: 0, length: (tv.string as NSString).length)
        XCTAssertTrue(tv.shouldChangeText(in: full, replacementString: source))
        tv.textStorage?.replaceCharacters(in: full, with: source)
        tv.didChangeText()
        tv.setSelectedRange(NSRange(location: (source as NSString).range(of: "after").location, length: 0))

        XCTAssertTrue(HostedDocument.spin(until: { self.tableView(in: tv) != nil }),
                      "the table must be rendered as an overlay")
        let table = try XCTUnwrap(tableView(in: tv))
        let rect = try XCTUnwrap(table.cellRect(row: 0, col: 0))
        table.onEditCell?(0, 0, rect)
        let field = try XCTUnwrap(textField(in: table), "the cell editor must open")

        field.stringValue = input
        let delegate = try XCTUnwrap(field.delegate)
        _ = delegate.control?(field, textView: NSTextView(),
                              doCommandBy: #selector(NSResponder.insertNewline(_:)))
        return (tv, tv.string)
    }

    /// Clicking a cell does not move the caret, so it usually sits below the
    /// table. The commit must shift it with the text after the edit; before,
    /// a cell that grew left the caret inside the table, and the table
    /// collapsed to raw pipes when the editor closed.
    func testCaretBelowTheTableFollowsAGrowingCell() throws {
        let (tv, source) = try commitCell("1234567")
        XCTAssertTrue(source.contains("| 1234567 | 2 |"))
        let expected = (source as NSString).range(of: "after").location
        XCTAssertEqual(tv.selectedRange(), NSRange(location: expected, length: 0))
    }

    func testCaretBelowTheTableFollowsAShrinkingCell() throws {
        let (tv, source) = try commitCell("")
        XCTAssertTrue(source.contains("|  | 2 |"))
        let expected = (source as NSString).range(of: "after").location
        XCTAssertEqual(tv.selectedRange(), NSRange(location: expected, length: 0))
    }

    /// Return closes the editor; the document's text view must get keyboard
    /// focus back, or typing goes nowhere and the Format menu does nothing.
    func testReturnHandsFocusBackToTheEditor() throws {
        let (tv, _) = try commitCell("x")
        XCTAssertTrue(tv.window?.firstResponder === tv,
                      "after Return the editor must be first responder, not \(String(describing: tv.window?.firstResponder))")
    }
}
