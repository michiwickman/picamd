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
        let lines = payload
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count >= 2 else { return nil }

        let headers = parseRow(lines[0])
        let aligns = parseAlignmentRow(lines[1])
        let rows = lines.dropFirst(2).map { parseRow($0) }
        return (aligns, headers, rows)
    }

    private func parseRow(_ line: String) -> [String] {
        var l = line
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.split(separator: "|", omittingEmptySubsequences: false).map {
            $0.trimmingCharacters(in: .whitespaces)
        }
    }

    private func parseAlignmentRow(_ line: String) -> [TableAlignment?] {
        var l = line
        if l.hasPrefix("|") { l.removeFirst() }
        if l.hasSuffix("|") { l.removeLast() }
        return l.split(separator: "|", omittingEmptySubsequences: false).map { cell -> TableAlignment? in
            let trimmed = cell.trimmingCharacters(in: .whitespaces)
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
