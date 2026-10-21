import XCTest
import AppKit
@testable import PicaMD

/// Coverage for editing a single table cell in place — the feature that lets
/// the table stay rendered while one cell is changed, instead of collapsing
/// the whole thing back to raw markdown.
///
/// The load-bearing part is `parseTableCells()`: `parseTable()` throws cell
/// offsets away, and you cannot replace text you cannot locate. Every range it
/// reports must point at exactly the text the cell displays.
@MainActor
final class TableCellEditingTests: XCTestCase {

    private func firstTable(in source: String) -> ExtractedBlock? {
        BlockExtractor.extract(from: source).first { $0.kind == .table }
    }

    /// Every reported cell range must select exactly the cell's own text out
    /// of the ORIGINAL document — that is what the commit path writes into.
    private func assertRangesResolve(_ source: String,
                                     file: StaticString = #filePath, line: UInt = #line) {
        guard let block = firstTable(in: source),
              let parsed = block.parseTableCells() else {
            XCTFail("no parsable table", file: file, line: line); return
        }
        let ns = source as NSString
        for cell in parsed.header + parsed.rows.flatMap({ $0 }) {
            XCTAssertLessThanOrEqual(cell.contentRange.location + cell.contentRange.length,
                                     ns.length, "range out of bounds", file: file, line: line)
            XCTAssertEqual(ns.substring(with: cell.contentRange), cell.text,
                           "range does not select the cell's own text",
                           file: file, line: line)
        }
    }

    // MARK: - Range fidelity

    func testCellRangesResolveToTheirOwnText() {
        assertRangesResolve("| Nr. | Parameter | Wert |\n|---|---|---|\n| M1 | Wirkprinzip | induktiv |\n")
    }

    func testCellRangesSurviveLeadingProse() {
        // The block's range starts partway into the document — offsets must be
        // absolute, not payload-relative.
        assertRangesResolve("# Titel\n\nEin Absatz.\n\n| A | B |\n|---|---|\n| 1 | 2 |\n")
    }

    func testCellRangesSurviveIrregularPadding() {
        assertRangesResolve("|A|   B   |\n|---|---|\n|    1|2    |\n")
    }

    func testCellRangesSurviveCRLF() {
        assertRangesResolve("| A | B |\r\n|---|---|\r\n| 1 | 2 |\r\n")
    }

    func testEmptyCellYieldsAValidInsertionPoint() {
        let doc = "| A | B |\n|---|---|\n| 1 |  |\n"
        guard let block = firstTable(in: doc), let parsed = block.parseTableCells() else {
            XCTFail(); return
        }
        let empty = parsed.rows[0][1]
        XCTAssertEqual(empty.text, "")
        XCTAssertEqual(empty.contentRange.length, 0)
        // Must still be a usable location inside the document.
        XCTAssertLessThanOrEqual(empty.contentRange.location, (doc as NSString).length)
    }

    // MARK: - The scanner

    func testEscapedPipeDoesNotStartANewColumn() {
        let doc = "| A | B |\n|---|---|\n| ja \\| nein | 2 |\n"
        guard let block = firstTable(in: doc), let parsed = block.parseTableCells() else {
            XCTFail(); return
        }
        XCTAssertEqual(parsed.rows[0].count, 2, "an escaped pipe is content, not a separator")
        XCTAssertEqual(parsed.rows[0][0].text, "ja \\| nein")
        assertRangesResolve(doc)
    }

    func testPipeInsideACodeSpanDoesNotStartANewColumn() {
        let doc = "| A | B |\n|---|---|\n| `a|b` | 2 |\n"
        guard let block = firstTable(in: doc), let parsed = block.parseTableCells() else {
            XCTFail(); return
        }
        XCTAssertEqual(parsed.rows[0].count, 2, "a pipe inside a code span is content")
        XCTAssertEqual(parsed.rows[0][0].text, "`a|b`")
    }

    func testPhantomColumnDoesNotWidenTheWholeGrid() {
        // Column count is the max over all rows, so one stray pipe used to
        // widen every row of the table.
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n| `x|y` | 4 |\n"
        guard let block = firstTable(in: doc), let parsed = block.parseTable() else {
            XCTFail(); return
        }
        XCTAssertTrue(parsed.rows.allSatisfy { $0.count == 2 },
                      "no row may gain a phantom column")
    }

    // MARK: - parseTable and parseTableCells must not disagree

    func testTextMatchesBetweenTheTwoParsers() {
        let doc = "| Nr. | **Parameter** | `code|pipe` |\n|:---|:--:|---:|\n| M1 | *kursiv* | ja \\| nein |\n"
        guard let block = firstTable(in: doc),
              let plain = block.parseTable(),
              let cells = block.parseTableCells() else {
            XCTFail(); return
        }
        // Same cells; the drawn text only resolves `\|` (GFM table escape).
        XCTAssertEqual(plain.headers, cells.header.map { TableRowScanner.displayText($0.text) },
                       "drawing and editing must agree on the header cells")
        XCTAssertEqual(plain.rows.map { $0 }, cells.rows.map { $0.map { TableRowScanner.displayText($0.text) } },
                       "drawing and editing must agree on the body cells")
        XCTAssertEqual(plain.rows.first?.last, "ja | nein")
        XCTAssertEqual(cells.rows.first?.last?.text, "ja \\| nein")
        XCTAssertEqual(plain.alignments.count, cells.alignments.count)
    }

    /// Blanks behind the closing pipe: the editing parser must see the same
    /// columns as the drawn table, or Tab steps into a column that does not
    /// exist and the editor closes instead of wrapping.
    func testTrailingBlanksAfterTheLastPipeAddNoColumn() {
        let doc = "| a | b |  \n|---|---|\t\n| 1 | 2 | \n"
        guard let block = firstTable(in: doc),
              let plain = block.parseTable(),
              let cells = block.parseTableCells() else {
            XCTFail(); return
        }
        XCTAssertEqual(cells.header.count, plain.headers.count)
        XCTAssertEqual(cells.header.count, 2)
        XCTAssertEqual(cells.alignments.count, 2)
        XCTAssertEqual(cells.rows.first?.count, 2)
        assertRangesResolve(doc)
    }

    // MARK: - Hit testing

    func testHitTestMapsPointsBackToTheCellTheyWereTakenFrom() {
        let doc = "| Nr. | Parameter | Ausprägungen |\n|---|---|---|\n"
            + "| M1 | Wirkprinzip | ein ziemlich langer Text der umbrechen kann |\n"
            + "| M2 | Ort | kurz |\n"
        guard let block = firstTable(in: doc) else { XCTFail(); return }
        let view = TableBlockView(block: block, documentURL: nil)
        view.frame = NSRect(x: 0, y: 0, width: 900,
                            height: view.desiredHeight(for: 900))

        for row in -1...1 {
            for col in 0...2 {
                guard let rect = view.cellRect(row: row, col: col) else {
                    XCTFail("no rect for (\(row),\(col))"); continue
                }
                let probe = NSPoint(x: rect.midX, y: rect.midY)
                guard let hit = view.cellAt(probe) else {
                    XCTFail("no hit at the centre of (\(row),\(col))"); continue
                }
                XCTAssertEqual(hit.row, row, "row mismatch at (\(row),\(col))")
                XCTAssertEqual(hit.col, col, "column mismatch at (\(row),\(col))")
            }
        }
    }

    func testHitTestReturnsNilBelowTheLastRow() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        guard let block = firstTable(in: doc) else { XCTFail(); return }
        let view = TableBlockView(block: block, documentURL: nil)
        // Deliberately taller than the content, as the reserved band can be.
        view.frame = NSRect(x: 0, y: 0, width: 600,
                            height: view.desiredHeight(for: 600) + 40)
        XCTAssertNil(view.cellAt(NSPoint(x: 300, y: 4)),
                     "the gap under the last row is chrome — it must collapse to source")
    }

    // MARK: - Sanitising what gets written back

    func testCommittedTextCannotManufactureAColumnOrEndTheRow() {
        XCTAssertEqual(TableCellEditor.sanitise("a|b"), "a\\|b",
                       "a raw pipe must be escaped, or it would split the cell")
        XCTAssertEqual(TableCellEditor.sanitise("a\\|b"), "a\\|b",
                       "an already-escaped pipe must not be double-escaped")
        XCTAssertEqual(TableCellEditor.sanitise("a\nb"), "a b",
                       "a newline would end the table row")
        XCTAssertEqual(TableCellEditor.sanitise("a\r\nb"), "a b")
        XCTAssertEqual(TableCellEditor.sanitise("  padded  "), "padded")
    }

    /// Round-trip: sanitised text written into a cell must parse back as one
    /// cell holding that text.
    func testSanitisedTextRoundTripsThroughTheParser() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        guard let block = firstTable(in: doc), let parsed = block.parseTableCells() else {
            XCTFail(); return
        }
        let target = parsed.rows[0][0]
        let edited = TableCellEditor.sanitise("neu | mit Pipe")
        let ns = doc as NSString
        let mutated = ns.replacingCharacters(in: target.contentRange, with: edited)

        guard let newBlock = firstTable(in: mutated), let newParsed = newBlock.parseTableCells() else {
            XCTFail("the edited document no longer parses as a table"); return
        }
        XCTAssertEqual(newParsed.rows[0].count, 2, "the edit must not add a column")
        XCTAssertEqual(newParsed.rows[0][0].text, edited)
    }

    // MARK: - Committing only what the user changed

    /// Opens the editor on body cell (row 0, col 0) and records every write
    /// the commit path attempts.
    private func openEditor(on doc: String) -> (TableCellEditor, TableBlockView, () -> [String])? {
        guard let block = firstTable(in: doc), let parsed = block.parseTableCells() else { return nil }
        let view = TableBlockView(block: block, documentURL: nil)
        view.frame = NSRect(x: 0, y: 0, width: 600, height: view.desiredHeight(for: 600))
        let editor = TableCellEditor()
        var writes: [String] = []
        editor.onCommit = { _, newText, _ in writes.append(newText); return true }
        editor.open(in: view, cell: parsed.rows[0][0], row: 0, col: 0,
                    rect: view.cellRect(row: 0, col: 0) ?? .zero,
                    font: .systemFont(ofSize: 13))
        return (editor, view, { writes })
    }

    func testCommittingAnUntouchedCellWritesNothing() {
        // `sanitise` escapes the pipe inside the code span, so comparing the
        // sanitised text with the source called this a change.
        let doc = "| Code | B |\n|---|---|\n| `a|b` | 2 |\n"
        guard let (editor, view, writes) = openEditor(on: doc) else { XCTFail(); return }
        XCTAssertTrue(editor.isOpen)

        XCTAssertTrue(editor.commit())
        editor.close(commitFirst: true)

        XCTAssertEqual(writes(), [], "Return on an unchanged cell must not rewrite it or add an undo step")
        withExtendedLifetime(view) {}
    }

    func testCommittingAnEditedCellWritesItOnce() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        guard let (editor, view, writes) = openEditor(on: doc) else { XCTFail(); return }

        editor.inputForTesting = "neu"
        XCTAssertTrue(editor.commit())
        // Closing commits again; nothing new was typed in between.
        editor.close(commitFirst: true)

        XCTAssertEqual(writes(), ["neu"])
        withExtendedLifetime(view) {}
    }

    /// VoiceOver says which cell the field edits.
    func testCellEditorIsNamedAfterItsCell() {
        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n"
        guard let (editor, view, _) = openEditor(on: doc) else { XCTFail(); return }
        XCTAssertEqual(editor.accessibilityLabelForTesting, "Row 1, column 1")
        XCTAssertEqual(TableCellEditor.accessibilityLabel(row: -1, col: 1), "Header, column 2")
        withExtendedLifetime(view) {}
    }

    // MARK: - Colours follow the palette

    private func luminance(_ color: NSColor) -> CGFloat {
        guard let c = color.usingColorSpace(.sRGB) else { return -1 }
        return 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
    }

    /// The defect was wiring, not arithmetic: the view and the field painted
    /// fixed greys whatever `TableColors` said. Checks what they actually use.
    func testTableViewAndCellEditorPaintWithTheActivePalette() throws {
        let saved = ThemeStore.currentPalette
        defer { ThemeStore.currentPalette = saved }
        ThemeStore.currentPalette = .oled

        let doc = "| A | B |\n|---|---|\n| 1 | 2 |\n| 3 | 4 |\n"
        let (editor, view, _) = try XCTUnwrap(openEditor(on: doc))
        defer { editor.close(commitFirst: false) }

        let field = editor.fieldColorsForTesting
        XCTAssertLessThan(luminance(try XCTUnwrap(field.background)), 0.2,
                          "a white input field on an OLED-black page")
        XCTAssertGreaterThan(luminance(try XCTUnwrap(field.text)), 0.8)

        let layerBackground = try XCTUnwrap(view.layer?.backgroundColor.flatMap(NSColor.init(cgColor:)))
        XCTAssertLessThan(luminance(layerBackground), 0.01)

        // The header band from draw(_:); the fixed dark grey was 0.20.
        let rep = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: rep)
        let header = try XCTUnwrap(rep.colorAt(x: 10, y: 4))
        XCTAssertLessThan(luminance(header), 0.12, "header fill must come from the palette")
    }

    func testTableAndEditorColoursComeFromThePalette() {
        let oled = TableColors(palette: .oled)
        XCTAssertLessThan(luminance(oled.background), 0.01, "an OLED page keeps a black table")
        XCTAssertLessThan(luminance(oled.editorBackground), 0.2,
                          "the cell editor must not put a light field on a black page")
        XCTAssertGreaterThan(luminance(oled.text), 0.8)

        let white = TableColors(palette: .white)
        XCTAssertGreaterThan(luminance(white.editorBackground), 0.8)
        XCTAssertLessThan(luminance(white.text), 0.2)

        // A free page colour: the fills sit between page and text colour.
        var custom = Palette.offwhite
        custom.bg = NSColor(srgbRed: 0.10, green: 0.20, blue: 0.40, alpha: 1)
        custom.fg = NSColor(srgbRed: 0.95, green: 0.90, blue: 0.80, alpha: 1)
        let colors = TableColors(palette: custom)
        for fill in [colors.headerFill, colors.alternateRowFill, colors.editorBackground, colors.border] {
            XCTAssertGreaterThan(luminance(fill), luminance(custom.bg))
            XCTAssertLessThan(luminance(fill), luminance(custom.fg))
        }
        XCTAssertEqual(colors.text, custom.fg.usingColorSpace(.sRGB))
    }
}
