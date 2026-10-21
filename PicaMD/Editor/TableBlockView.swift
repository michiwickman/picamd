import AppKit

/// Table and cell-editor colours, derived from the editor palette instead of
/// fixed greys: with a free background colour (or OLED black) fixed values
/// put a light-grey table and a white input field on a black page.
/// Fills are the page colour mixed towards the text colour, so they stay
/// opaque and keep the same contrast direction on any palette.
struct TableColors {
    let background: NSColor
    let border: NSColor
    let headerFill: NSColor
    let alternateRowFill: NSColor
    let separator: NSColor
    let text: NSColor
    let inlineCodeFill: NSColor
    let editorBackground: NSColor

    /// Separate because cell strings are built for every measuring pass,
    /// where the full set of blends is not needed.
    static func inlineCodeFill(_ palette: Palette) -> NSColor {
        palette.fg.withAlphaComponent(0.10)
    }

    init(palette: Palette) {
        let bg = palette.bg.usingColorSpace(.sRGB) ?? palette.bg
        let fg = palette.fg.usingColorSpace(.sRGB) ?? palette.fg
        func mix(_ fraction: CGFloat) -> NSColor {
            bg.blended(withFraction: fraction, of: fg) ?? bg
        }
        background = bg
        border = mix(0.18)
        headerFill = mix(0.07)
        alternateRowFill = mix(0.035)
        separator = mix(0.14)
        text = fg
        inlineCodeFill = Self.inlineCodeFill(palette)
        editorBackground = mix(0.12)
    }
}

/// Native overlay view for a parsed pipe-table block. Draws header
/// background, alternating body rows, vertical column separators, and
/// inline-bold/italic/code in cells. No webview involved.
final class TableBlockView: BlockAttachmentView {
    /// Minimum row height; rows grow beyond this to fit wrapped cell text.
    private let rowHeight: CGFloat = 26
    private let cellHPadding: CGFloat = 12
    /// Vertical breathing room above+below the wrapped text within a row.
    private let cellVPadding: CGFloat = 5
    private let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    override func setupContent() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyColors()
    }

    private func applyColors() {
        let colors = TableColors(palette: palette)
        layer?.backgroundColor = colors.background.cgColor
        layer?.borderColor = colors.border.cgColor
    }

    override func appearanceChanged() {
        applyColors()
        needsDisplay = true
    }

    override func desiredHeight(for width: CGFloat) -> CGFloat {
        guard let parsed = block.parseTable() else { return rowHeight }
        let layout = computeLayout(parsed: parsed, width: width)
        return layout.total
    }

    /// Per-row heights for a given available width. Each row is as tall as
    /// its tallest word-wrapped cell (clamped to at least `rowHeight`), so
    /// long cell content wraps onto multiple lines instead of truncating.
    private typealias ParsedTable = (alignments: [TableAlignment?], headers: [String], rows: [[String]])

    private struct TableLayout {
        let columnCount: Int
        /// Actual width of each column — content-proportional, see `distribute`.
        let columnWidths: [CGFloat]
        /// Left edge of each column: the prefix sums of `columnWidths`.
        let columnXs: [CGFloat]
        let headerHeight: CGFloat
        let rowHeights: [CGFloat]
        let total: CGFloat
    }

    /// A column is never squeezed below this, however greedy its neighbours.
    private let minColumnWidth: CGFloat = 56

    /// Test-only: how many layout passes ran. A pass measures every cell
    /// several times, so the scroll path must not run one per tick.
    private(set) static var layoutPassCountForTesting = 0

    private func computeLayout(parsed: ParsedTable, width: CGFloat) -> TableLayout {
        Self.layoutPassCountForTesting += 1
        // Widest row wins, not just the first one: a later row with an extra
        // cell used to be drawn past the right edge with no separator.
        let columnCount = max(parsed.headers.count,
                              parsed.rows.map(\.count).max() ?? 0)
        guard columnCount > 0, width > 0 else {
            return TableLayout(columnCount: 1, columnWidths: [max(width, 1)],
                               columnXs: [0], headerHeight: rowHeight,
                               rowHeights: [], total: rowHeight)
        }
        let columnWidths = distribute(
            natural: naturalColumnWidths(parsed: parsed, columnCount: columnCount),
            floors: minimumColumnWidths(parsed: parsed, columnCount: columnCount),
            available: width
        )
        var columnXs: [CGFloat] = []
        var x: CGFloat = 0
        for w in columnWidths { columnXs.append(x); x += w }

        let headerHeight = rowHeightFor(cells: parsed.headers, font: headerFont,
                                        columnWidths: columnWidths)
        let rowHeights = parsed.rows.map {
            rowHeightFor(cells: $0, font: bodyFont, columnWidths: columnWidths)
        }
        // Pure content height. Vertical padding is owned solely by
        // `EditorLayout.blockOverlayHeightPadding` — see there. Adding a
        // second, private +8 here (which `draw()` never read back) left a
        // dead strip inside the table's own border box.
        let total = headerHeight + rowHeights.reduce(0, +)
        return TableLayout(columnCount: columnCount, columnWidths: columnWidths,
                           columnXs: columnXs, headerHeight: headerHeight,
                           rowHeights: rowHeights, total: total)
    }

    /// What each column would need to render on a single line, padding
    /// included. Measured from the same inline-parsed attributed string the
    /// cell is actually drawn with, so `**M1**` measures as a bold "M1"
    /// rather than as six literal characters.
    private func naturalColumnWidths(parsed: ParsedTable, columnCount: Int) -> [CGFloat] {
        var natural = [CGFloat](repeating: 0, count: columnCount)
        func note(_ cells: [String], _ font: NSFont) {
            for (col, text) in cells.enumerated() where col < columnCount {
                let s = wrappedCellString(text, font: font, color: .labelColor, alignment: .left)
                natural[col] = max(natural[col], ceil(s.size().width) + 2 * cellHPadding)
            }
        }
        note(parsed.headers, headerFont)
        for row in parsed.rows { note(row, bodyFont) }
        return natural
    }

    /// Turn per-column natural widths into the widths actually used.
    ///
    /// The previous model gave every column `available / columnCount`. On real
    /// documents that misallocates badly: in a "Nr. | Parameter | Ausprägungen"
    /// table the number column needs ~74 pt and was handed 552, while the prose
    /// column needed ~2150 pt and was handed the same 552 — so it wrapped to
    /// several lines while a third of the table sat empty. Across the author's
    /// documents the uniform model misallocated roughly 600 pt per table, and
    /// the trailing column was the most visibly over-wide.
    ///
    /// Instead: a column asking for no more than its fair share gets exactly
    /// what it asked for, and the freed space goes to the columns that wanted
    /// more, in proportion to how much more they wanted.
    /// The narrowest a column can get before it starts breaking words in the
    /// middle. Measured from the longest single word the column contains — a
    /// flat minimum is not enough: with one very greedy neighbour, a column
    /// holding "Physikalisches" was squeezed to 56 pt and rendered as
    /// "Phys / ikali / sche / s", which reads as a broken layout rather than
    /// a tight one. Capped at the natural width so a column never claims more
    /// than it could ever use.
    private func minimumColumnWidths(parsed: ParsedTable, columnCount: Int) -> [CGFloat] {
        var floors = [CGFloat](repeating: 0, count: columnCount)
        func note(_ cells: [String], _ font: NSFont) {
            for (col, text) in cells.enumerated() where col < columnCount {
                let s = wrappedCellString(text, font: font, color: .labelColor, alignment: .left)
                floors[col] = max(floors[col], Self.longestUnbreakableWidth(in: s))
            }
        }
        note(parsed.headers, headerFont)
        for row in parsed.rows { note(row, bodyFont) }
        return floors.map { $0 + 2 * cellHPadding }
    }

    /// Width of the widest run the line breaker can't split: text between
    /// spaces or tabs, where a hyphen inside a word also ends a run. The
    /// line breaker never breaks after a hyphen that starts the run or
    /// stands before a digit (UAX #14 keeps "-1234567", "170-1234567" and
    /// "6-12" whole), so neither ends a run here: measured apart, such a
    /// column's floor came out narrower than the number and the number
    /// broke inside. Measured on the
    /// cell's drawn string, after inline parsing, so `` `M8|M10` `` is
    /// measured in the code font without its backticks and `**x**` as bold
    /// without its asterisks. Splitting the raw source at spaces measured
    /// the markers and the wrong font, which under-estimates code spans.
    static func longestUnbreakableWidth(in s: NSAttributedString) -> CGFloat {
        let ns = s.string as NSString
        var longest: CGFloat = 0
        var start: Int?
        func close(at end: Int) {
            guard let st = start, end > st else { start = nil; return }
            let run = s.attributedSubstring(from: NSRange(location: st, length: end - st))
            longest = max(longest, ceil(run.size().width))
            start = nil
        }
        for i in 0..<ns.length {
            let c = ns.character(at: i)
            if c == 0x20 || c == 0x09 || c == 0x0A {
                close(at: i)
            } else {
                if start == nil { start = i }
                // Break opportunity after "-", unless it leads the run or
                // a digit follows.
                if c == 0x2D, let st = start, i > st,
                   !(i + 1 < ns.length && (0x30...0x39).contains(ns.character(at: i + 1))) {
                    close(at: i + 1)
                }
            }
        }
        close(at: ns.length)
        return longest
    }

    private func distribute(natural: [CGFloat], floors rawFloors: [CGFloat],
                            available: CGFloat) -> [CGFloat] {
        let count = natural.count
        guard count > 0 else { return [] }
        let demand = natural.reduce(0, +)
        let fairShare = available / CGFloat(count)
        guard demand > 0 else {
            return [CGFloat](repeating: fairShare, count: count)
        }

        // Per-column floor: the longest word, never more than the column's own
        // natural width.
        let floors = (0..<count).map { i -> CGFloat in
            min(max(rawFloors[i], min(minColumnWidth, fairShare)), natural[i])
        }
        // If even the floors do not fit, the table gets wider than the column
        // and scrolls sideways inside its overlay (see `scrollWheel`). These
        // floors used to be scaled down together to fit, which broke words in
        // the middle in every column at once ("Nr|.", "Ausprägun|g A",
        // "pulverbeschicht|et") — the very thing the floors exist to prevent.
        let floorSum = floors.reduce(0, +)
        if floorSum >= available {
            return floors
        }
        if demand <= available {
            // Everything fits unwrapped: give the slack to the columns with
            // the most content, not equally to all of them.
            let slack = available - demand
            return natural.map { $0 + slack * ($0 / demand) }
        }
        // Over-subscribed: shrink proportionally, but never below the floor.
        // A column that would fall under the floor is locked there and the
        // remaining budget is re-shared among the rest, repeating until
        // nothing else has to be locked. Terminates in at most `count`
        // rounds because each round locks at least one column.
        //
        // The naive version — clamp each column with `max(floor, share)` in
        // one pass — is wrong: raising a column to the floor takes that space
        // from nobody, so the widths can sum to MORE than `available`, the
        // column offsets run past the view's right edge, and the trailing
        // column is clipped by `masksToBounds`. That is the over-wide-last-
        // column bug reintroduced by the code meant to cure it.
        var widths = [CGFloat](repeating: 0, count: count)
        var locked = [Bool](repeating: false, count: count)
        while true {
            let lockedTotal = (0..<count).filter { locked[$0] }
                .reduce(CGFloat(0)) { $0 + widths[$1] }
            let free = (0..<count).filter { !locked[$0] }
            guard !free.isEmpty else { break }
            let budget = max(0, available - lockedTotal)
            let freeDemand = free.reduce(CGFloat(0)) { $0 + natural[$1] }
            guard freeDemand > 0 else {
                let each = budget / CGFloat(free.count)
                for i in free { widths[i] = each }
                break
            }
            var lockedAny = false
            for i in free {
                let w = budget * (natural[i] / freeDemand)
                if w < floors[i] {
                    widths[i] = floors[i]
                    locked[i] = true
                    lockedAny = true
                } else {
                    widths[i] = w
                }
            }
            if !lockedAny { break }
        }
        // Absorb accumulated float drift so the rightmost separator lands
        // exactly on the view's right edge.
        let sum = widths.reduce(0, +)
        if sum > 0, abs(sum - available) > 0.001 {
            let k = available / sum
            for i in 0..<count { widths[i] *= k }
        }
        return widths
    }

    /// Row height for a set of cells, each measured against ITS OWN column
    /// width. The row is as tall as its tallest wrapped cell.
    private func rowHeightFor(cells: [String], font: NSFont,
                              columnWidths: [CGFloat]) -> CGFloat {
        var maxTextHeight: CGFloat = 0
        for (col, text) in cells.enumerated() where col < columnWidths.count {
            let cellTextWidth = max(1, columnWidths[col] - 2 * cellHPadding)
            let attr = wrappedCellString(text, font: font, color: .labelColor, alignment: .left)
            let rect = attr.boundingRect(
                with: NSSize(width: cellTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            maxTextHeight = max(maxTextHeight, ceil(rect.height))
        }
        return max(rowHeight, maxTextHeight + 2 * cellVPadding)
    }

    // MARK: - Hit testing

    /// Which cell sits under `point` (view coordinates)? `row == -1` is the
    /// header band. Returns `nil` for table chrome — the border, the padding,
    /// the gap below the last row — which is the "collapse to source" zone.
    ///
    /// Derived from the same `computeLayout` the drawing uses, never from the
    /// text view's glyph positions: those point at the concealed 0.01 pt
    /// source glyphs and have nothing to do with where the cell is painted.
    func cellAt(_ point: NSPoint) -> (row: Int, col: Int, rect: NSRect)? {
        guard let parsed = block.parseTable() else { return nil }
        let layout = computeLayout(parsed: parsed, width: bounds.width)
        guard layout.columnCount > 0, !layout.columnWidths.isEmpty else { return nil }

        guard let col = (0..<layout.columnWidths.count).first(where: { c in
            point.x >= layout.columnXs[c] && point.x < layout.columnXs[c] + layout.columnWidths[c]
        }) else { return nil }

        let headerBottom = bounds.height - layout.headerHeight
        if point.y <= bounds.height, point.y > headerBottom {
            return (-1, col, NSRect(x: layout.columnXs[col], y: headerBottom,
                                    width: layout.columnWidths[col],
                                    height: layout.headerHeight))
        }
        var y = headerBottom
        for (idx, height) in layout.rowHeights.enumerated() {
            let top = y
            y -= height
            if point.y <= top, point.y > y {
                return (idx, col, NSRect(x: layout.columnXs[col], y: y,
                                         width: layout.columnWidths[col],
                                         height: height))
            }
        }
        return nil
    }

    /// Where a given cell is drawn, for placing the in-place editor. Uses the
    /// same layout as `draw()` and `cellAt(_:)`, so all three agree.
    func cellRect(row: Int, col: Int) -> NSRect? {
        guard let parsed = block.parseTable() else { return nil }
        let layout = computeLayout(parsed: parsed, width: bounds.width)
        guard col >= 0, col < layout.columnWidths.count else { return nil }
        let headerBottom = bounds.height - layout.headerHeight
        if row < 0 {
            return NSRect(x: layout.columnXs[col], y: headerBottom,
                          width: layout.columnWidths[col], height: layout.headerHeight)
        }
        guard row < layout.rowHeights.count else { return nil }
        var y = headerBottom
        for idx in 0...row {
            y -= layout.rowHeights[idx]
            if idx == row {
                return NSRect(x: layout.columnXs[col], y: y,
                              width: layout.columnWidths[col],
                              height: layout.rowHeights[idx])
            }
        }
        return nil
    }

    /// Fired on a single click inside a cell. The manager rebinds this on
    /// every pass with a freshly captured range.
    var onEditCell: ((_ row: Int, _ col: Int, _ rect: NSRect) -> Void)?
    /// Fired on a double-click on table chrome, or on a single click when the
    /// block no longer parses as a table — the explicit "edit the whole thing
    /// as markdown" gesture.
    var onCollapseToSource: (() -> Void)?

    /// Swallows the event deliberately — `super.mouseDown` would let the text
    /// view move the caret into the block, which is exactly what makes the
    /// highlighter reveal the raw pipes and collapse the table. Because the
    /// caret never moves, the table stays rendered by construction and no new
    /// state is needed anywhere else.
    ///
    /// Consuming the click also removes the only route into the source, so the
    /// chrome double-click below is not a nicety — it is the escape hatch.
    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hit = cellAt(point) else {
            onCollapseToSource?()
            return
        }
        if event.clickCount >= 2 {
            onCollapseToSource?()
            return
        }
        onEditCell?(hit.row, hit.col, hit.rect)
    }

    /// Second route to the raw markdown, next to the chrome double-click.
    /// Both exist because `mouseDown` is swallowed, which removes the caret
    /// as a way in.
    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let item = NSMenuItem(title: "Edit as Markdown",
                              action: #selector(editAsMarkdown),
                              keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func editAsMarkdown() {
        onCollapseToSource?()
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        addCursorRect(bounds, cursor: .iBeam)
    }

    // MARK: - Test seams

    /// Test-only: the column widths this table resolves to at `width`.
    func columnWidthsForTesting(width: CGFloat) -> [CGFloat] {
        guard let parsed = block.parseTable() else { return [] }
        return computeLayout(parsed: parsed, width: width).columnWidths
    }

    /// Test-only: the column count this table resolves to at `width`.
    func columnCountForTesting(width: CGFloat) -> Int {
        guard let parsed = block.parseTable() else { return 0 }
        return computeLayout(parsed: parsed, width: width).columnCount
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let parsed = block.parseTable() else { return }
        let layout = computeLayout(parsed: parsed, width: bounds.width)
        let columnCount = layout.columnCount
        guard columnCount > 0 else { return }

        let colors = TableColors(palette: palette)
        let headerH = layout.headerHeight
        // Bands span the whole table, which may be wider than the view and
        // scrolled (bounds.origin.x); everything is drawn in table coordinates.
        let tableWidth = max(bounds.width, layout.columnWidths.reduce(0, +))

        // Header background (top band).
        let headerRect = NSRect(x: 0, y: bounds.height - headerH, width: tableWidth, height: headerH)
        colors.headerFill.setFill()
        headerRect.fill()

        // Body rows alternating — walk top-down accumulating variable heights.
        var y = bounds.height - headerH
        for (i, rowH) in layout.rowHeights.enumerated() {
            y -= rowH
            if i % 2 == 1 {
                let row = NSRect(x: 0, y: y, width: tableWidth, height: rowH)
                colors.alternateRowFill.setFill()
                row.fill()
            }
        }

        // Vertical column separators (full height).
        colors.separator.setStroke()
        for c in 1..<columnCount where c < layout.columnXs.count {
            let x = layout.columnXs[c]
            let p = NSBezierPath()
            p.move(to: NSPoint(x: x, y: 0))
            p.line(to: NSPoint(x: x, y: bounds.height))
            p.lineWidth = 0.5
            p.stroke()
        }

        // Horizontal line under the header.
        let underHeaderY = bounds.height - headerH
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 0, y: underHeaderY))
        p.line(to: NSPoint(x: tableWidth, y: underHeaderY))
        p.lineWidth = 0.5
        p.stroke()

        let textColor = colors.text

        // Header cells.
        for (col, text) in parsed.headers.enumerated() where col < layout.columnCount {
            let rect = cellTextRect(col: col, layout: layout,
                                    bandTop: bounds.height, bandHeight: headerH)
            drawText(wrappedCellString(text, font: headerFont, color: textColor,
                                       alignment: alignmentFor(parsed.alignments, col: col)),
                     in: rect)
        }

        // Body cells.
        y = bounds.height - headerH
        for (rowIdx, row) in parsed.rows.enumerated() {
            let rowH = layout.rowHeights[rowIdx]
            for (col, text) in row.enumerated() where col < layout.columnCount {
                let rect = cellTextRect(col: col, layout: layout,
                                        bandTop: y, bandHeight: rowH)
                drawText(wrappedCellString(text, font: bodyFont, color: textColor,
                                           alignment: alignmentFor(parsed.alignments, col: col)),
                         in: rect)
            }
            y -= rowH
        }

        drawOverflowFades(tableWidth: tableWidth, colors: colors)
    }

    /// A soft fade on each side where more of the table is scrolled out of
    /// view, so a clipped column reads as "continues" rather than as cut off.
    private func drawOverflowFades(tableWidth: CGFloat, colors: TableColors) {
        let fadeWidth: CGFloat = 20
        let visible = bounds
        let edge = colors.background
        if visible.minX > 0.5 {
            NSGradient(starting: edge, ending: edge.withAlphaComponent(0))?
                .draw(in: NSRect(x: visible.minX, y: visible.minY, width: fadeWidth, height: visible.height),
                      angle: 0)
        }
        if visible.maxX < tableWidth - 0.5 {
            NSGradient(starting: edge.withAlphaComponent(0), ending: edge)?
                .draw(in: NSRect(x: visible.maxX - fadeWidth, y: visible.minY, width: fadeWidth, height: visible.height),
                      angle: 0)
        }
    }

    // MARK: - Horizontal overflow

    /// How far the table can scroll sideways: its columns' total width
    /// beyond the view, 0 when it fits.
    var horizontalOverflow: CGFloat {
        guard let parsed = block.parseTable() else { return 0 }
        let widths = computeLayout(parsed: parsed, width: bounds.width).columnWidths
        // A fitting table's widths sum to the width up to float drift.
        let overflow = widths.reduce(0, +) - bounds.width
        return overflow > 0.5 ? overflow : 0
    }

    /// The scroll position is the bounds origin, like a clip view's: drawing,
    /// `cellAt`, `cellRect` and the cell editor (a subview) all work in table
    /// coordinates and follow it without conversions of their own.
    var horizontalScrollOffset: CGFloat {
        get { bounds.origin.x }
        set {
            let clamped = min(max(0, newValue), horizontalOverflow)
            guard clamped != bounds.origin.x else { return }
            setBoundsOrigin(NSPoint(x: clamped, y: bounds.origin.y))
            needsDisplay = true
        }
    }

    /// Scroll so the column is in view, for the cell editor moving with Tab
    /// or opening on a partly hidden cell.
    func scrollColumnToVisible(_ col: Int) {
        guard let parsed = block.parseTable() else { return }
        let layout = computeLayout(parsed: parsed, width: bounds.width)
        guard col >= 0, col < layout.columnWidths.count else { return }
        let left = layout.columnXs[col]
        let right = left + layout.columnWidths[col]
        if left < horizontalScrollOffset || layout.columnWidths[col] > bounds.width {
            horizontalScrollOffset = left
        } else if right > horizontalScrollOffset + bounds.width {
            horizontalScrollOffset = right - bounds.width
        }
    }

    /// Sideways gestures scroll an overflowing table; everything else goes
    /// on to the editor, so scrolling the document over a table still works.
    override func scrollWheel(with event: NSEvent) {
        let dx = event.scrollingDeltaX
        // Direction first: it is free, and the overflow costs a layout
        // pass, which vertical scrolling over a table would pay per event.
        guard abs(dx) > abs(event.scrollingDeltaY), horizontalOverflow > 0 else {
            super.scrollWheel(with: event)
            return
        }
        horizontalScrollOffset -= event.hasPreciseScrollingDeltas ? dx : dx * 8
    }

    /// Re-clamp the scroll position to a new width. The overlay manager
    /// sets every table's frame on every scroll tick, mostly with the size
    /// unchanged, and clamping costs a layout pass; an unscrolled table
    /// (offset 0) is always in range, so only a scrolled one that changed
    /// width pays it.
    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged, bounds.origin.x != 0 {
            horizontalScrollOffset = bounds.origin.x
        }
    }

    override func contentDidChange() {
        super.contentDidChange()
        if bounds.origin.x != 0 { horizontalScrollOffset = bounds.origin.x }
    }

    /// The text rect for a cell: horizontally inset by `cellHPadding`,
    /// vertically inset by `cellVPadding`, top-aligned within the band.
    private func cellTextRect(col: Int, layout: TableLayout,
                              bandTop: CGFloat, bandHeight: CGFloat) -> NSRect {
        guard col < layout.columnXs.count, col < layout.columnWidths.count else { return .zero }
        return NSRect(x: layout.columnXs[col] + cellHPadding,
                      y: bandTop - bandHeight + cellVPadding,
                      width: max(1, layout.columnWidths[col] - 2 * cellHPadding),
                      height: max(0, bandHeight - 2 * cellVPadding))
    }

    private func alignmentFor(_ aligns: [TableAlignment?], col: Int) -> NSTextAlignment {
        guard col < aligns.count, let a = aligns[col] else { return .left }
        switch a {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    /// Build the render-ready, WORD-WRAPPING attributed string for a cell:
    /// inline markup parsed, paragraph set to wrap (not truncate), colour
    /// and a normalised font applied. Used for both measuring (height) and
    /// drawing, so the two always agree.
    private func wrappedCellString(_ text: String,
                                   font: NSFont,
                                   color: NSColor,
                                   alignment: NSTextAlignment) -> NSAttributedString {
        let para = NSMutableParagraphStyle()
        para.alignment = alignment
        para.lineBreakMode = .byWordWrapping   // wrap instead of truncate

        let mutable = NSMutableAttributedString(attributedString: parseInline(text))
        let full = NSRange(location: 0, length: mutable.length)
        mutable.addAttributes([.paragraphStyle: para, .foregroundColor: color], range: full)
        mutable.enumerateAttribute(.font, in: full, options: []) { val, r, _ in
            if val == nil {
                mutable.addAttribute(.font, value: font, range: r)
            } else if let f = val as? NSFont {
                mutable.addAttribute(.font, value: NSFontManager.shared.convert(f, toSize: font.pointSize), range: r)
            }
        }
        return mutable
    }

    /// Draw a (wrapped) cell string top-aligned within its text rect.
    private func drawText(_ attr: NSAttributedString, in rect: NSRect) {
        attr.draw(with: rect, options: [.usesLineFragmentOrigin, .usesFontLeading])
    }

    // Static patterns reused for every cell render — one compile per
    // process, not per cell render pass.
    private static let cellBoldRegex = try! NSRegularExpression(pattern: #"\*\*([^*]+)\*\*"#)
    private static let cellItalicRegex = try! NSRegularExpression(pattern: #"(?<!\*)\*([^*]+)\*(?!\*)"#)
    private static let cellCodeRegex = try! NSRegularExpression(pattern: #"`([^`]+)`"#)

    /// Lightweight inline parser — handles **bold**, *italic*, `code`. Enough
    /// to make `**bold**` render as bold inside table cells.
    private func parseInline(_ text: String) -> NSAttributedString {
        let result = NSMutableAttributedString(string: text)
        let nsString = text as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // Bold
        for m in Self.cellBoldRegex.matches(in: text, range: fullRange).reversed() {
            let inner = nsString.substring(with: m.range(at: 1))
            let attr = NSAttributedString(
                string: inner,
                attributes: [.font: NSFont.boldSystemFont(ofSize: 13)]
            )
            result.replaceCharacters(in: m.range, with: attr)
        }
        // Italic (only single-asterisk pairs not already eaten by bold above)
        let updated = result.string as NSString
        let updatedRange = NSRange(location: 0, length: updated.length)
        for m in Self.cellItalicRegex.matches(in: result.string, range: updatedRange).reversed() {
            let inner = updated.substring(with: m.range(at: 1))
            let italicFont = NSFontManager.shared.font(
                withFamily: NSFont.systemFont(ofSize: 13).familyName ?? "Helvetica",
                traits: [.italicFontMask],
                weight: 5,
                size: 13
            ) ?? NSFont.systemFont(ofSize: 13)
            let attr = NSAttributedString(string: inner, attributes: [.font: italicFont])
            result.replaceCharacters(in: m.range, with: attr)
        }
        // Inline code
        let afterItalic = result.string as NSString
        let r = NSRange(location: 0, length: afterItalic.length)
        for m in Self.cellCodeRegex.matches(in: result.string, range: r).reversed() {
            let inner = afterItalic.substring(with: m.range(at: 1))
            let attr = NSAttributedString(
                string: inner,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .regular),
                    .backgroundColor: TableColors.inlineCodeFill(palette),
                ]
            )
            result.replaceCharacters(in: m.range, with: attr)
        }
        return result
    }
}
