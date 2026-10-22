import Foundation

/// Decides, for every `\n` in a markdown source, whether it is a **hard wrap
/// inside a paragraph** (soft — may be typeset as a space so the paragraph
/// reflows to the window width) or **structural** (must keep breaking the
/// line).
///
/// Why this exists: markdown written by most tools — including every document
/// this editor was built for — wraps prose at a fixed column with real 0x0A
/// bytes. The text container already tracks the full window width, so a table
/// row (one 400-character source line) spans the window while a paragraph
/// stays pinned at ~88 characters. Reflow removes that asymmetry *visually*,
/// without touching a single byte of the file.
///
/// ## The safety invariant is asymmetric
/// Marking a structural newline as soft **corrupts** layout: block overlays are
/// positioned from glyph rects, so welding a table's boundary newline into the
/// prose above it moves and resizes the overlay. Marking a soft newline as
/// structural merely forfeits reflow on that line. Therefore, when in doubt,
/// return structural — and the veto pass below is applied **last**, so a
/// violation is impossible by construction rather than merely asserted.
///
/// ## Frame
/// Lines are classified, then each newline is decided from the (line, next
/// line) pair. That formulation is boundary-inclusive for free: a block-shaped
/// line makes *both* the newline above it and its own terminating newline
/// structural. `ExtractedBlock.range` cannot express this — a table range
/// starts at the first row and has its trailing newline stripped, so neither
/// boundary newline is inside it.
enum ReflowClassifier {

    struct Options {
        /// Join wrapped lines inside list items. Off by default: the list pass
        /// sets no paragraph style, so a joined item reflows with no hanging
        /// indent and the continuation runs back under the bullet.
        var joinInsideListItems: Bool = false
        /// Conservative lazy continuation: a continuation line joins its
        /// container only when indented to at least the container's content
        /// column. Strict CommonMark would also join unindented lines, which
        /// welds e.g. "3. Step three" and a following "Footnote" into one
        /// visual line — read by a user as the editor eating a line.
        var strictLazyContinuation: Bool = false

        init() {}
    }

    /// UTF-16 offsets of every newline that may be typeset as a space.
    static func softNewlineOffsets(in source: String,
                                   blocks: [ExtractedBlock],
                                   protectedRanges: [NSRange],
                                   options: Options = Options()) -> Set<Int> {
        let ns = source as NSString
        guard ns.length > 0 else { return [] }

        // ---- Line table ------------------------------------------------
        // UTF-16 offsets, never String.split: the latter treats "\r\n" as one
        // Character and would desynchronise every offset in a CRLF document.
        var lineStarts: [Int] = []
        var lineEnds: [Int] = []          // content end (before the newline)
        var newlineAt: [Int] = []         // offset of the terminating \n, or -1
        var i = 0
        while i < ns.length {
            var start = 0, end = 0, contentsEnd = 0
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                            for: NSRange(location: i, length: 0))
            lineStarts.append(start)
            lineEnds.append(contentsEnd)
            newlineAt.append(contentsEnd < end ? end - 1 : -1)
            i = end
            if end == start { break }     // defensive: no forward progress
        }
        guard !lineStarts.isEmpty else { return [] }

        let lines: [String] = (0..<lineStarts.count).map {
            ns.substring(with: NSRange(location: lineStarts[$0],
                                        length: lineEnds[$0] - lineStarts[$0]))
        }

        // ---- Stateful forward walk: classify each LINE -----------------
        var shape = [LineShape](repeating: .paragraph, count: lines.count)
        var contentColumn = [Int](repeating: 0, count: lines.count)
        var quoteDepth = [Int](repeating: 0, count: lines.count)
        // Content column of the innermost open list item at each paragraph
        // line, 0 outside lists. Recorded per line because the stack itself
        // is only valid at the moment of the walk: read after the loop it
        // holds whatever the document ENDS in, and a trailing checklist then
        // made every top-level paragraph fail rule 13.
        var listBase = [Int](repeating: 0, count: lines.count)

        var fenceMarker: String? = nil          // indent-tolerant, see below
        var inMath = false
        // Front matter by the one shared fence rule, so reflow agrees with
        // the highlighter, the fold and the inspector. A loose rule of its
        // own ("first line `---`, until the next `---`") kept a note that
        // opens with a thematic break structural down to the next `---`, or
        // to the end of the document.
        let frontmatterEnd = Frontmatter.fenceRegex
            .firstMatch(in: source, options: [], range: NSRange(location: 0, length: ns.length))
            .map { NSMaxRange($0.range) } ?? 0
        var listColumns: [Int] = []
        var paragraphOpen = false

        for (idx, raw) in lines.enumerated() {
            let indent = leadingIndent(raw)
            let trimmed = raw.trimmingCharacters(in: .whitespaces)

            // RULE 1a — frontmatter, only when the document opens with it.
            if lineStarts[idx] < frontmatterEnd {
                shape[idx] = .block
                continue
            }

            // RULE 1b — fenced code, INDENT-TOLERANT.
            // `MarkdownRegexes.fencedCode` is anchored at column 0 and misses
            // every indented fence — including ones in this project's own
            // README. Trusting it alone would weld an indented code block into
            // one wrapped line, so the walk tracks fences itself.
            if let marker = fenceMarker {
                shape[idx] = .block
                if trimmed.hasPrefix(marker),
                   trimmed.dropFirst(marker.count).allSatisfy({ $0 == " " || $0 == "\t" }) {
                    fenceMarker = nil
                }
                continue
            }
            if let marker = openingFence(trimmed) {
                fenceMarker = marker
                shape[idx] = .block
                paragraphOpen = false
                continue
            }

            // RULE 1c — $$ math blocks.
            if inMath {
                shape[idx] = .block
                if trimmed.hasSuffix("$$") { inMath = false }
                continue
            }
            if trimmed.hasPrefix("$$") {
                shape[idx] = .block
                // A single-line `$$…$$` opens and closes at once.
                inMath = !(trimmed.count > 2 && trimmed.hasSuffix("$$"))
                paragraphOpen = false
                continue
            }

            // RULE 3 — blank. Closes the paragraph but does NOT pop the list
            // stack: a blank line does not close a list, and popping here
            // misreads a second paragraph inside a list item as top-level
            // prose (and then an indented fence under it as prose too).
            if trimmed.isEmpty {
                shape[idx] = .blank
                paragraphOpen = false
                continue
            }

            // Pop list containers only on a non-blank line that out-dents.
            while let top = listColumns.last, indent < top { listColumns.removeLast() }

            // RULE 9 — list item start pushes a content column.
            if let contentCol = listItemContentColumn(raw) {
                listColumns.append(contentCol)
                shape[idx] = .listItem
                contentColumn[idx] = contentCol
                paragraphOpen = true
                continue
            }

            // Indented code: measured from the enclosing list content column,
            // never from column 0, and it may not interrupt an open paragraph.
            let base = listColumns.last ?? 0
            if !paragraphOpen, indent >= base + 4 {
                shape[idx] = .block
                continue
            }

            // RULES 5-8 — line-shaped constructs. These predicates only have
            // to be CONSERVATIVE: a false positive costs reflow, never
            // correctness.
            if isThematicBreak(trimmed) || isHeading(trimmed) || isTableRow(trimmed)
                || isBlockImage(trimmed) || isFootnoteDefinition(trimmed)
                || isLinkReferenceDefinition(trimmed) || isHTMLBlockStart(trimmed) {
                shape[idx] = .block
                paragraphOpen = false
                continue
            }

            // RULE 12 — blockquotes join when the prefix depth matches.
            let depth = blockquoteDepth(trimmed)
            if depth > 0 {
                shape[idx] = .quote
                quoteDepth[idx] = depth
                paragraphOpen = true
                continue
            }

            shape[idx] = .paragraph
            contentColumn[idx] = indent
            listBase[idx] = base
            paragraphOpen = true
        }

        // ---- Decide each newline from the (line, next line) pair --------
        var soft = Set<Int>()
        for idx in 0..<(lines.count - 1) {
            let nl = newlineAt[idx]
            guard nl >= 0 else { continue }
            let next = idx + 1

            // RULE 2 — markdown hard break: two trailing spaces, or a
            // trailing backslash. Must always break.
            let raw = lines[idx]
            if raw.hasSuffix("  ") || raw.hasSuffix("\\") { continue }

            // RULE 4 — setext underline must be tested BEFORE thematic break:
            // `---` matches both, and testing the break first silently
            // misclassifies every Setext H2.
            if shape[idx] == .paragraph, isSetextUnderline(lines[next]) { continue }

            switch (shape[idx], shape[next]) {
            case (.paragraph, .paragraph):
                // RULE 13 — conservative lazy continuation. The container is
                // the one the CURRENT line sits in: a next line indented less
                // than that content column would be lazily pulled into it.
                if listBase[idx] > 0,
                   !options.strictLazyContinuation,
                   contentColumn[next] < listBase[idx] {
                    continue
                }
                soft.insert(nl)

            case (.quote, .quote):
                // RULE 12 — same prefix depth reflows cleanly, because the
                // blockquote pass sets firstLineHeadIndent == headIndent.
                if quoteDepth[idx] == quoteDepth[next] { soft.insert(nl) }

            case (.listItem, .paragraph), (.listItem, .listItem):
                // RULE 10 / 11 — off in v1: a joined list item has no hanging
                // indent, so the continuation would run back under the bullet,
                // and a wrapped task item would strike through only its first
                // source line.
                if options.joinInsideListItems { soft.insert(nl) }

            default:
                continue   // blank, block, or a shape change — structural
            }
        }

        // ---- RULE 0 — VETO, applied last so violation is impossible ------
        // Anything the authoritative extractors consider a block wins, and
        // BOTH boundary newlines of such a range are removed, not just the
        // interior ones. Interior newlines are in fact the safe ones (eight
        // concealed 0.01 pt rows collapsing into one fragment preserves
        // roughly the same height); it is the boundaries that destroy the
        // reserved min-line-height band and move the overlay.
        var vetoed = protectedRanges
        vetoed.append(contentsOf: blocks.map { $0.range })
        guard !vetoed.isEmpty else { return soft }
        return soft.filter { nl in
            for r in vetoed {
                // nl or nl+1 inside the range, plus the newline immediately
                // preceding the range's first line.
                let start = r.location
                let end = r.location + r.length
                if nl >= start - 1 && nl <= end { return false }
            }
            return true
        }
    }

    // MARK: - Line shapes

    private enum LineShape {
        case paragraph, blank, block, listItem, quote
    }

    // MARK: - Conservative line predicates

    private static func leadingIndent(_ line: String) -> Int {
        var n = 0
        for ch in line {
            if ch == " " { n += 1 }
            else if ch == "\t" { n += 4 }
            else { break }
        }
        return n
    }

    /// ``` or ~~~ (3 or more), already whitespace-trimmed by the caller.
    private static func openingFence(_ trimmed: String) -> String? {
        for marker in ["`", "~"] {
            let ch = Character(marker)
            let run = trimmed.prefix { $0 == ch }
            if run.count >= 3 { return String(run) }
        }
        return nil
    }

    private static func isHeading(_ t: String) -> Bool {
        guard t.hasPrefix("#") else { return false }
        let hashes = t.prefix { $0 == "#" }
        return hashes.count <= 6 && (t.count == hashes.count || t.dropFirst(hashes.count).hasPrefix(" "))
    }

    private static func isThematicBreak(_ t: String) -> Bool {
        guard t.count >= 3 else { return false }
        for ch in ["-", "*", "_"] where t.allSatisfy({ $0 == Character(ch) || $0 == " " }) {
            if t.filter({ $0 == Character(ch) }).count >= 3 { return true }
        }
        return false
    }

    private static func isSetextUnderline(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return false }
        return t.allSatisfy { $0 == "=" } || t.allSatisfy { $0 == "-" }
    }

    /// Strictly wider than `BlockExtractor`, deliberately: a `| a | b |` line
    /// without a separator row underneath is NOT an extracted table block, but
    /// the highlighter still paints it with a mono font and a row background,
    /// so it must keep its own line.
    private static func isTableRow(_ t: String) -> Bool {
        t.hasPrefix("|") && t.hasSuffix("|") && t.count > 1
    }

    private static func isBlockImage(_ t: String) -> Bool {
        t.hasPrefix("![") && t.hasSuffix(")")
    }

    private static func isFootnoteDefinition(_ t: String) -> Bool {
        t.hasPrefix("[^") && t.contains("]:")
    }

    private static func isLinkReferenceDefinition(_ t: String) -> Bool {
        guard t.hasPrefix("["), let close = t.firstIndex(of: "]") else { return false }
        let after = t[t.index(after: close)...]
        return after.hasPrefix(":") && after.dropFirst().trimmingCharacters(in: .whitespaces).isEmpty == false
    }

    /// Covers `<details>` / `<summary>`, which carry their own indents and
    /// whole-range concealment.
    private static func isHTMLBlockStart(_ t: String) -> Bool {
        guard t.hasPrefix("<") else { return false }
        let rest = t.dropFirst().drop { $0 == "/" }
        return rest.first?.isLetter == true
    }

    private static func blockquoteDepth(_ t: String) -> Int {
        var depth = 0
        var rest = Substring(t)
        while rest.hasPrefix(">") {
            depth += 1
            rest = rest.dropFirst()
            while rest.hasPrefix(" ") { rest = rest.dropFirst() }
        }
        return depth
    }

    /// Content column of a list item (`- `, `* `, `+ `, `1. `, `1) `), i.e.
    /// the column its continuation text must reach to count as belonging to it.
    private static func listItemContentColumn(_ line: String) -> Int? {
        let indent = leadingIndent(line)
        var rest = Substring(line.drop { $0 == " " || $0 == "\t" })
        guard let first = rest.first else { return nil }

        var markerLength = 0
        if first == "-" || first == "*" || first == "+" {
            markerLength = 1
            rest = rest.dropFirst()
        } else if first.isNumber {
            let digits = rest.prefix { $0.isNumber }
            rest = rest.dropFirst(digits.count)
            guard let delim = rest.first, delim == "." || delim == ")" else { return nil }
            markerLength = digits.count + 1
            rest = rest.dropFirst()
        } else {
            return nil
        }
        let spaces = rest.prefix { $0 == " " || $0 == "\t" }
        guard !spaces.isEmpty || rest.isEmpty else { return nil }
        return indent + markerLength + spaces.count
    }
}
