import AppKit

/// Native overlay view for a parsed pipe-table block. Draws header
/// background, alternating body rows, vertical column separators, and
/// inline-bold/italic/code in cells. No webview involved.
final class TableBlockView: BlockAttachmentView {
    /// Minimum row height; rows grow beyond this to fit wrapped cell text.
    private let rowHeight: CGFloat = 26
    private let cellHPadding: CGFloat = 12
    /// Vertical breathing room above+below the wrapped text within a row.
    private let cellVPadding: CGFloat = 5
    private let headerColor = NSColor.labelColor
    private let headerFont = NSFont.systemFont(ofSize: 13, weight: .semibold)
    private let bodyFont = NSFont.systemFont(ofSize: 13, weight: .regular)

    override func setupContent() {
        layer?.cornerRadius = 6
        layer?.borderWidth = 1
        applyColors()
    }

    private func applyColors() {
        if isDark {
            layer?.backgroundColor = NSColor(white: 0.13, alpha: 1).cgColor
            layer?.borderColor = NSColor(white: 0.25, alpha: 1).cgColor
        } else {
            layer?.backgroundColor = NSColor(white: 0.99, alpha: 1).cgColor
            layer?.borderColor = NSColor(white: 0.85, alpha: 1).cgColor
        }
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
        let columnWidth: CGFloat
        let headerHeight: CGFloat
        let rowHeights: [CGFloat]
        let total: CGFloat
    }

    private func computeLayout(parsed: ParsedTable, width: CGFloat) -> TableLayout {
        let columnCount = max(parsed.headers.count, parsed.rows.first?.count ?? 0)
        guard columnCount > 0, width > 0 else {
            return TableLayout(columnCount: max(columnCount, 1),
                               columnWidth: max(width, 1),
                               headerHeight: rowHeight, rowHeights: [], total: rowHeight)
        }
        let columnWidth = width / CGFloat(columnCount)
        let cellTextWidth = max(1, columnWidth - 2 * cellHPadding)

        let headerHeight = rowHeightFor(cells: parsed.headers, font: headerFont,
                                        cellTextWidth: cellTextWidth)
        let rowHeights = parsed.rows.map {
            rowHeightFor(cells: $0, font: bodyFont, cellTextWidth: cellTextWidth)
        }
        let total = headerHeight + rowHeights.reduce(0, +) + 8
        return TableLayout(columnCount: columnCount, columnWidth: columnWidth,
                           headerHeight: headerHeight, rowHeights: rowHeights, total: total)
    }

    private func rowHeightFor(cells: [String], font: NSFont, cellTextWidth: CGFloat) -> CGFloat {
        var maxTextHeight: CGFloat = 0
        for text in cells {
            let attr = wrappedCellString(text, font: font, color: .labelColor, alignment: .left)
            let rect = attr.boundingRect(
                with: NSSize(width: cellTextWidth, height: .greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            )
            maxTextHeight = max(maxTextHeight, ceil(rect.height))
        }
        return max(rowHeight, maxTextHeight + 2 * cellVPadding)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard let parsed = block.parseTable() else { return }
        let layout = computeLayout(parsed: parsed, width: bounds.width)
        let columnCount = layout.columnCount
        guard columnCount > 0 else { return }

        let columnWidth = layout.columnWidth
        let dark = isDark
        let headerH = layout.headerHeight

        // Header background (top band).
        let headerRect = NSRect(x: 0, y: bounds.height - headerH, width: bounds.width, height: headerH)
        (dark ? NSColor(white: 0.20, alpha: 1) : NSColor(white: 0.94, alpha: 1)).setFill()
        headerRect.fill()

        // Body rows alternating — walk top-down accumulating variable heights.
        var y = bounds.height - headerH
        for (i, rowH) in layout.rowHeights.enumerated() {
            y -= rowH
            if i % 2 == 1 {
                let row = NSRect(x: 0, y: y, width: bounds.width, height: rowH)
                (dark ? NSColor(white: 0.16, alpha: 1) : NSColor(white: 0.97, alpha: 1)).setFill()
                row.fill()
            }
        }

        // Vertical column separators (full height).
        let sepColor = dark ? NSColor(white: 0.25, alpha: 1) : NSColor(white: 0.88, alpha: 1)
        sepColor.setStroke()
        for c in 1..<columnCount {
            let x = CGFloat(c) * columnWidth
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
        p.line(to: NSPoint(x: bounds.width, y: underHeaderY))
        p.lineWidth = 0.5
        p.stroke()

        let textColor = dark ? NSColor(white: 0.92, alpha: 1) : NSColor(white: 0.10, alpha: 1)

        // Header cells.
        for (col, text) in parsed.headers.enumerated() {
            let rect = cellTextRect(col: col, columnWidth: columnWidth,
                                    bandTop: bounds.height, bandHeight: headerH)
            drawText(wrappedCellString(text, font: headerFont, color: textColor,
                                       alignment: alignmentFor(parsed.alignments, col: col)),
                     in: rect)
        }

        // Body cells.
        y = bounds.height - headerH
        for (rowIdx, row) in parsed.rows.enumerated() {
            let rowH = layout.rowHeights[rowIdx]
            for (col, text) in row.enumerated() {
                let rect = cellTextRect(col: col, columnWidth: columnWidth,
                                        bandTop: y, bandHeight: rowH)
                drawText(wrappedCellString(text, font: bodyFont, color: textColor,
                                           alignment: alignmentFor(parsed.alignments, col: col)),
                         in: rect)
            }
            y -= rowH
        }
    }

    /// The text rect for a cell: horizontally inset by `cellHPadding`,
    /// vertically inset by `cellVPadding`, top-aligned within the band.
    private func cellTextRect(col: Int, columnWidth: CGFloat,
                              bandTop: CGFloat, bandHeight: CGFloat) -> NSRect {
        NSRect(x: CGFloat(col) * columnWidth + cellHPadding,
               y: bandTop - bandHeight + cellVPadding,
               width: max(1, columnWidth - 2 * cellHPadding),
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
                    .backgroundColor: NSColor(white: 0.5, alpha: 0.15),
                ]
            )
            result.replaceCharacters(in: m.range, with: attr)
        }
        return result
    }
}
