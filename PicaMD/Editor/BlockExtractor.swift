import Foundation

enum BlockKind: Hashable, Sendable {
    case table
    case image
    case mathBlock
    case mermaid
}

struct ExtractedBlock: Hashable, Sendable {
    let range: NSRange         // in markdown source
    let kind: BlockKind
    let payload: String        // raw markdown content (used to render)

    func hash(into hasher: inout Hasher) {
        hasher.combine(range.location)
        hasher.combine(range.length)
        hasher.combine(kind)
        hasher.combine(payload)
    }

    static func == (lhs: ExtractedBlock, rhs: ExtractedBlock) -> Bool {
        lhs.range == rhs.range && lhs.kind == rhs.kind && lhs.payload == rhs.payload
    }
}

enum BlockExtractor {
    // Patterns are now centralised in MarkdownRegexes for one source of
    // truth across BlockExtractor + SyntaxHighlighter.
    private static var mathBlockRegex: NSRegularExpression { MarkdownRegexes.mathBlock }
    private static var fencedCodeRegex: NSRegularExpression { MarkdownRegexes.fencedCode }
    private static var mermaidFenceRegex: NSRegularExpression { MarkdownRegexes.mermaidFence }
    private static var imageRegex: NSRegularExpression { MarkdownRegexes.blockImage }
    private static var resizeAttributeRegex: NSRegularExpression { MarkdownRegexes.imageResizeAttribute }

    static func extract(from source: String) -> [ExtractedBlock] {
        var blocks: [ExtractedBlock] = []
        let nsString = source as NSString
        let fullRange = NSRange(location: 0, length: nsString.length)

        // First, find every fenced code-block range. Tables / math /
        // mermaid / image patterns inside code fences must NOT be
        // extracted as overlay blocks — otherwise the user types a
        // literal example inside ```markdown … ``` and the editor
        // turns the example itself into a rendered overlay (F4).
        var codeFenceRanges: [NSRange] = []
        fencedCodeRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            if let m = match { codeFenceRanges.append(m.range) }
        }
        func insideCodeFence(_ r: NSRange) -> Bool {
            for fence in codeFenceRanges {
                if NSLocationInRange(r.location, fence) { return true }
            }
            return false
        }

        // Tables: contiguous lines starting with `|`, with at least one being a separator
        for table in extractTables(in: nsString, range: fullRange) where !insideCodeFence(table.range) {
            blocks.append(table)
        }

        // Math blocks
        mathBlockRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            guard let m = match, !insideCodeFence(m.range) else { return }
            let payload = nsString.substring(with: m.range)
            blocks.append(ExtractedBlock(range: m.range, kind: .mathBlock, payload: payload))
        }

        // Mermaid blocks (these are fenced code blocks themselves; no exclusion needed)
        mermaidFenceRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            guard let m = match else { return }
            let payload = nsString.substring(with: m.range)
            blocks.append(ExtractedBlock(range: m.range, kind: .mermaid, payload: payload))
        }

        // Block-level images: line consisting of only `![alt](url)`
        imageRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
            guard let m = match, !insideCodeFence(m.range) else { return }
            let payload = nsString.substring(with: m.range)
            blocks.append(ExtractedBlock(range: m.range, kind: .image, payload: payload))
        }

        // Sort blocks by location for stable ordering
        blocks.sort { $0.range.location < $1.range.location }
        return blocks
    }

    private static func extractTables(in nsString: NSString, range: NSRange) -> [ExtractedBlock] {
        // Fast path: skip the entire line-walk when there is no `|` in range.
        if nsString.range(of: "|", options: [.literal], range: range).location == NSNotFound {
            return []
        }
        var results: [ExtractedBlock] = []
        let source = nsString as String
        var lineRanges: [NSRange] = []
        var idx = 0
        while idx < nsString.length {
            let lineRange = nsString.lineRange(for: NSRange(location: idx, length: 0))
            lineRanges.append(lineRange)
            idx = NSMaxRange(lineRange)
        }

        var i = 0
        while i < lineRanges.count {
            let line = nsString.substring(with: lineRanges[i])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("|") && line.hasSuffix("|") && line.count > 1, i + 1 < lineRanges.count {
                let nextLine = nsString.substring(with: lineRanges[i + 1])
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if isSeparatorLine(nextLine) {
                    // Found a table starting at i
                    var j = i + 2
                    while j < lineRanges.count {
                        let l = nsString.substring(with: lineRanges[j])
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                        if !(l.hasPrefix("|") && l.hasSuffix("|")) {
                            break
                        }
                        j += 1
                    }
                    let startLoc = lineRanges[i].location
                    let endLoc = NSMaxRange(lineRanges[j - 1])
                    // Drop trailing newline so the block doesn't include the next paragraph break
                    var length = endLoc - startLoc
                    let lastChar = nsString.substring(with: NSRange(location: endLoc - 1, length: 1))
                    if lastChar == "\n" {
                        length -= 1
                    }
                    let blockRange = NSRange(location: startLoc, length: length)
                    let payload = nsString.substring(with: blockRange)
                    results.append(ExtractedBlock(range: blockRange, kind: .table, payload: payload))
                    i = j
                    continue
                }
            }
            i += 1
        }
        _ = source  // silence unused warning
        return results
    }

    private static func isSeparatorLine(_ line: String) -> Bool {
        // Line of the form `|:---|:--:|---:|` or similar
        let cleaned = line.trimmingCharacters(in: CharacterSet(charactersIn: "| \t"))
        guard !cleaned.isEmpty else { return false }
        let parts = line
            .split(separator: "|", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard !parts.isEmpty else { return false }
        for p in parts {
            // Must be `:?-{2,}:?`
            let s = String(p)
            guard !s.isEmpty else { return false }
            var i = s.startIndex
            if s[i] == ":" { i = s.index(after: i) }
            guard i < s.endIndex, s[i] == "-" else { return false }
            while i < s.endIndex, s[i] == "-" { i = s.index(after: i) }
            if i < s.endIndex, s[i] == ":" { i = s.index(after: i) }
            if i != s.endIndex { return false }
        }
        return true
    }
}

extension ExtractedBlock {
    /// Parse a table block into rows of cells with optional column alignments.
    func parseTable() -> (alignments: [TableAlignment?], headers: [String], rows: [[String]])? {
        guard kind == .table else { return nil }
        // `components(separatedBy: .newlines)`, not `split(separator: "\n")`:
        // in Swift "\r\n" is a SINGLE Character, so splitting on "\n" never
        // fires for a CRLF document — the whole table collapsed into one
        // line, the `lines.count >= 2` guard below failed, and every table in
        // a CRLF file rendered as an empty box. Splitting by scalar yields an
        // empty element between \r and \n, which the filter removes.
        let lines = payload
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let headers = parseRow(lines[0])
        let aligns = parseAlignmentRow(lines[1])
        let rows = lines.dropFirst(2).map { parseRow($0) }
        return (aligns, headers, rows)
    }

    /// The cells as they are drawn — see `TableRowScanner.displayText`.
    private func parseRow(_ line: String) -> [String] {
        let ns = line as NSString
        return TableRowScanner.cellRanges(in: ns).map {
            TableRowScanner.displayText(ns.substring(with: $0))
        }
    }

    private func parseAlignmentRow(_ line: String) -> [TableAlignment?] {
        let ns = line as NSString
        return TableRowScanner.cellRanges(in: ns).map { r -> TableAlignment? in
            let trimmed = ns.substring(with: r)
            let starts = trimmed.hasPrefix(":")
            let ends = trimmed.hasSuffix(":")
            switch (starts, ends) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return nil
            }
        }
    }
}

enum TableAlignment {
    case left, center, right
}

/// One table cell together with where its text lives in the document.
///
/// `parseTable()` throws the offsets away, which is fine for drawing but makes
/// editing a single cell impossible — you cannot replace text you cannot
/// locate. `contentRange` is the trimmed content span, so an empty cell has
/// length 0 and still yields a valid insertion point.
struct TableCell {
    let text: String
    /// Absolute range in the document's text storage.
    let contentRange: NSRange
}

/// Splits a pipe-table row into cell content ranges.
///
/// Deliberately one implementation shared by measuring, drawing, hit-testing
/// and editing: a second, subtly different splitter would let the rendered
/// grid and the edited source disagree about which cell is which.
///
/// Handles what a naive `split(separator: "|")` does not: `\|` is a literal
/// pipe, and a pipe inside a `` `code span` `` does not start a new cell.
/// Either would otherwise manufacture a phantom column — and since the column
/// count is now the max over all rows, one stray pipe widens the whole grid.
enum TableRowScanner {

    /// Content ranges of each cell, relative to `line`, with surrounding
    /// whitespace already trimmed off.
    static func cellRanges(in line: NSString) -> [NSRange] {
        let length = line.length
        guard length > 0 else { return [] }

        // Strip one leading and one trailing bare pipe, as the format allows.
        var start = 0
        var end = length
        if line.character(at: 0) == pipe { start = 1 }
        if end > start, line.character(at: end - 1) == pipe {
            // Only if it is not escaped: `\|` at the end is content.
            let precedingBackslashes = countBackslashes(before: end - 1, in: line, notBefore: start)
            if precedingBackslashes % 2 == 0 { end -= 1 }
        }
        guard start <= end else { return [] }

        var ranges: [NSRange] = []
        var cellStart = start
        var inCode = false
        var i = start
        while i < end {
            let ch = line.character(at: i)
            if ch == backslash {
                i += 2          // escaped character — consume both
                continue
            }
            if ch == backtick {
                inCode.toggle()
                i += 1
                continue
            }
            if ch == pipe, !inCode {
                ranges.append(trimmed(NSRange(location: cellStart, length: i - cellStart), in: line))
                cellStart = i + 1
            }
            i += 1
        }
        ranges.append(trimmed(NSRange(location: cellStart, length: max(0, end - cellStart)), in: line))
        return ranges
    }

    /// A cell's source as it is drawn. GFM resolves `\|` at table level,
    /// before any inline parsing and so inside code spans too: the cell
    /// `` `M8\|M10` `` shows the code `M8|M10`. Only the drawn text loses
    /// the backslash; `parseTableCells()` keeps the source for editing.
    static func displayText(_ cellSource: String) -> String {
        cellSource.replacingOccurrences(of: "\\|", with: "|")
    }

    // MARK: -

    private static let pipe: unichar = 0x7C          // |
    private static let backslash: unichar = 0x5C     // \
    private static let backtick: unichar = 0x60      // `
    private static let space: unichar = 0x20
    private static let tab: unichar = 0x09

    private static func countBackslashes(before index: Int, in line: NSString,
                                         notBefore lowerBound: Int) -> Int {
        var n = 0
        var i = index - 1
        while i >= lowerBound, line.character(at: i) == backslash {
            n += 1
            i -= 1
        }
        return n
    }

    private static func trimmed(_ range: NSRange, in line: NSString) -> NSRange {
        var start = range.location
        var end = range.location + range.length
        while start < end, isBlank(line.character(at: start)) { start += 1 }
        while end > start, isBlank(line.character(at: end - 1)) { end -= 1 }
        return NSRange(location: start, length: end - start)
    }

    private static func isBlank(_ c: unichar) -> Bool {
        c == space || c == tab
    }
}

extension ExtractedBlock {
    /// Like `parseTable()`, but every cell carries its absolute range in the
    /// document so a single cell can be replaced in place.
    ///
    /// Lines are walked with `NSString.lineRange` rather than by splitting the
    /// payload, because the offsets have to survive CRLF documents and any
    /// leading indentation.
    func parseTableCells() -> (alignments: [TableAlignment?],
                               header: [TableCell],
                               rows: [[TableCell]])? {
        guard kind == .table else { return nil }
        let ns = payload as NSString
        guard ns.length > 0 else { return nil }

        var lineRanges: [NSRange] = []
        var i = 0
        while i < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: i, length: 0))
            if contentsEnd > start { lineRanges.append(NSRange(location: start,
                                                                length: contentsEnd - start)) }
            if end == start { break }
            i = end
        }
        guard lineRanges.count >= 2 else { return nil }

        func cells(of lineRange: NSRange) -> [TableCell] {
            let lineText = ns.substring(with: lineRange) as NSString
            // The scanner works on a trimmed line, so record the shift.
            // Trailing blanks go too, as in `parseTable`: behind the closing
            // pipe they hid it from the scanner, which then reported an
            // extra empty column that the drawn table does not have.
            var lead = 0
            while lead < lineText.length,
                  lineText.character(at: lead) == 0x20 || lineText.character(at: lead) == 0x09 {
                lead += 1
            }
            var end = lineText.length
            while end > lead,
                  lineText.character(at: end - 1) == 0x20 || lineText.character(at: end - 1) == 0x09 {
                end -= 1
            }
            let body = lineText.substring(with: NSRange(location: lead, length: end - lead)) as NSString
            return TableRowScanner.cellRanges(in: body).map { r in
                TableCell(
                    text: body.substring(with: r),
                    contentRange: NSRange(location: range.location + lineRange.location + lead + r.location,
                                          length: r.length)
                )
            }
        }

        let header = cells(of: lineRanges[0])
        let alignments = cells(of: lineRanges[1]).map { cell -> TableAlignment? in
            let t = cell.text
            switch (t.hasPrefix(":"), t.hasSuffix(":")) {
            case (true, true): return .center
            case (true, false): return .left
            case (false, true): return .right
            case (false, false): return nil
            }
        }
        let rows = lineRanges.dropFirst(2).map { cells(of: $0) }
        return (alignments, header, rows)
    }
}
