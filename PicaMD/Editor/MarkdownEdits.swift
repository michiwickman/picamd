import Foundation

/// Pure text-transformation primitives for the editor's keyboard
/// shortcuts. They take an immutable `(text, selection)` input and
/// return the new state, so they're trivially unit-testable without
/// any AppKit dependency.
enum MarkdownEdits {

    /// Result of an edit operation applied to a text+selection state.
    struct Result: Equatable {
        let text: String
        let selection: NSRange
    }

    // MARK: - Heading level

    /// Apply heading level `level` (0 = paragraph, 1...6 = H1...H6) to
    /// the line(s) covered by `selection`. If a line already has that
    /// level it is toggled off (becomes paragraph). Mixed selections
    /// uniformly take the new level.
    static func setHeading(level: Int, in text: String, selection: NSRange) -> Result {
        precondition((0...6).contains(level), "Heading level must be 0...6")
        let nsString = text as NSString
        let lines = lineRanges(covering: selection, in: nsString)
        guard !lines.isEmpty else { return Result(text: text, selection: selection) }

        // Uniform toggle: if every covered line is already at `level`,
        // toggle them all to paragraph.
        let allAtLevel = lines.allSatisfy { detectedHeadingLevel(of: nsString.substring(with: $0)) == level }
        let targetLevel = allAtLevel ? 0 : level

        var result = nsString as String
        // Iterate in reverse so earlier ranges aren't invalidated.
        for r in lines.reversed() {
            let lineText = (result as NSString).substring(with: r)
            let stripped = stripHeadingMarker(from: lineText)
            let newLine: String
            if targetLevel == 0 {
                newLine = stripped
            } else {
                newLine = String(repeating: "#", count: targetLevel) + " " + stripped.trimmingNewline()
                // re-attach the trailing newline if the original had one
                let suffix = lineText.hasSuffix("\n") ? "\n" : ""
                _ = suffix
            }
            // Preserve trailing newline of the line if present.
            let preservedNewline = lineText.hasSuffix("\n") && !newLine.hasSuffix("\n") ? "\n" : ""
            let nsResult = result as NSString
            let mutable = NSMutableString(string: nsResult)
            mutable.replaceCharacters(in: r, with: newLine + preservedNewline)
            result = mutable as String
        }
        // Compute new selection — keep it on the same logical lines.
        // Simplest approximation: collapse to the start of the first
        // affected line, length 0. `lines` is non-empty by the guard
        // above, but we use a safe fallback so this can't crash on a
        // pathological input.
        let firstLineLoc = lines.first?.location ?? selection.location
        let newSel = NSRange(location: firstLineLoc, length: 0)
        return Result(text: result, selection: clamp(newSel, in: result))
    }

    /// Detect the existing heading level of a single line of source.
    /// Returns 0 if the line is a paragraph.
    static func detectedHeadingLevel(of line: String) -> Int {
        let trimmed = line.trimmingNewline()
        var hashes = 0
        for ch in trimmed {
            if ch == "#" { hashes += 1; if hashes > 6 { return 0 } } else { break }
        }
        guard hashes >= 1 && hashes <= 6 else { return 0 }
        // Must be followed by a space
        let idx = trimmed.index(trimmed.startIndex, offsetBy: hashes)
        guard idx < trimmed.endIndex, trimmed[idx] == " " else { return 0 }
        return hashes
    }

    /// Strip leading `#`s and the single space after them.
    static func stripHeadingMarker(from line: String) -> String {
        let level = detectedHeadingLevel(of: line)
        guard level > 0 else { return line }
        let trimmed = line.trimmingNewline()
        let startIdx = trimmed.index(trimmed.startIndex, offsetBy: level + 1)
        let stripped = String(trimmed[startIdx...])
        return stripped + (line.hasSuffix("\n") ? "\n" : "")
    }

    // MARK: - Move line

    static func moveLine(direction: MoveDirection, in text: String, selection: NSRange) -> Result {
        let nsString = text as NSString
        let lines = lineRanges(covering: selection, in: nsString)
        guard let firstLine = lines.first, let lastLine = lines.last else {
            return Result(text: text, selection: selection)
        }
        let blockStart = firstLine.location
        let blockEnd = NSMaxRange(lastLine)
        let blockRange = NSRange(location: blockStart, length: blockEnd - blockStart)
        let blockText = nsString.substring(with: blockRange)

        switch direction {
        case .up:
            guard blockStart > 0 else { return Result(text: text, selection: selection) }
            let prevRange = nsString.lineRange(for: NSRange(location: blockStart - 1, length: 0))
            var newBlock = blockText
            var newPrev = nsString.substring(with: prevRange)
            // If the moving block has no trailing newline (last line of doc),
            // we'd lose the line break when swapping. Compensate.
            if !newBlock.hasSuffix("\n") {
                // Move the trailing newline from prev onto the block
                if newPrev.hasSuffix("\n") {
                    newPrev.removeLast()
                    newBlock = newBlock + "\n"
                }
            }
            let combinedRange = NSRange(location: prevRange.location,
                                        length: prevRange.length + blockRange.length)
            let combined = newBlock + newPrev
            let mutable = NSMutableString(string: nsString)
            mutable.replaceCharacters(in: combinedRange, with: combined)
            // Shift the selection up by prevRange.length
            let newSel = NSRange(location: max(0, selection.location - prevRange.length),
                                 length: selection.length)
            return Result(text: mutable as String, selection: clamp(newSel, in: mutable as String))

        case .down:
            let docLength = nsString.length
            guard blockEnd < docLength else { return Result(text: text, selection: selection) }
            let nextRange = nsString.lineRange(for: NSRange(location: blockEnd, length: 0))
            var newBlock = blockText
            var newNext = nsString.substring(with: nextRange)
            // If the next line has no trailing newline (it's the last line of
            // doc), the block needs one to keep its newline-ness when
            // appearing before it.
            if !newBlock.hasSuffix("\n") {
                newBlock = newBlock + "\n"
                if newNext.hasSuffix("\n") {
                    newNext.removeLast()
                }
            }
            let combinedRange = NSRange(location: blockRange.location,
                                        length: blockRange.length + nextRange.length)
            let combined = newNext + newBlock
            let mutable = NSMutableString(string: nsString)
            mutable.replaceCharacters(in: combinedRange, with: combined)
            // Shift the selection down by nextRange.length
            let newSel = NSRange(location: selection.location + nextRange.length,
                                 length: selection.length)
            return Result(text: mutable as String, selection: clamp(newSel, in: mutable as String))
        }
    }

    enum MoveDirection { case up, down }

    // MARK: - Duplicate line / selection

    static func duplicate(in text: String, selection: NSRange) -> Result {
        let nsString = text as NSString
        if selection.length == 0 {
            // Duplicate the current line
            let lineRange = nsString.lineRange(for: NSRange(location: selection.location, length: 0))
            let originalLine = nsString.substring(with: lineRange)
            let lineHasTrailingNewline = originalLine.hasSuffix("\n")
            // Duplicate sits AFTER the existing line. If the original ends
            // with `\n`, just repeat it. Otherwise (last line of doc) we
            // prepend a `\n` to the duplicate so the two stay distinct lines.
            let duplicate = lineHasTrailingNewline ? originalLine : ("\n" + originalLine)
            let mutable = NSMutableString(string: nsString)
            let insertLoc = NSMaxRange(lineRange)
            mutable.insert(duplicate, at: insertLoc)
            // Move the cursor to the same column on the duplicated line.
            let newCursor = NSRange(location: selection.location + duplicate.count, length: 0)
            return Result(text: mutable as String, selection: clamp(newCursor, in: mutable as String))
        } else {
            // Duplicate the selection inline (right after the existing one)
            let snippet = nsString.substring(with: selection)
            let mutable = NSMutableString(string: nsString)
            mutable.insert(snippet, at: NSMaxRange(selection))
            // Place cursor at the end of the duplicated copy, no selection
            let newCursor = NSRange(location: NSMaxRange(selection) + snippet.count, length: 0)
            return Result(text: mutable as String, selection: clamp(newCursor, in: mutable as String))
        }
    }

    // MARK: - Select line

    static func selectLine(in text: String, selection: NSRange) -> Result {
        let nsString = text as NSString
        let lines = lineRanges(covering: selection, in: nsString)
        guard let first = lines.first, let last = lines.last else {
            return Result(text: text, selection: selection)
        }
        let combined = NSRange(location: first.location,
                               length: NSMaxRange(last) - first.location)
        return Result(text: text, selection: combined)
    }

    // MARK: - Auto-pair

    /// Pairs `(`/`{`/`[`/`"`/`'`/`*`/`_`/`` ` ``/`~`/`=`/`$` with the
    /// matching close char. Returns the result of the auto-pair if the
    /// input is a known opening character; otherwise nil so the caller
    /// can fall through to default insertion.
    static func autoPair(input: String, in text: String, selection: NSRange) -> Result? {
        guard input.count == 1, let ch = input.first else { return nil }
        if selection.length == 0, !shouldAutoPair(ch, in: text, at: selection.location) {
            return nil
        }
        let pair: Character?
        switch ch {
        case "(": pair = ")"
        case "[": pair = "]"
        case "{": pair = "}"
        case "\"": pair = "\""
        case "'": pair = "'"
        case "`": pair = "`"
        default: return nil
        }
        guard let close = pair else { return nil }

        let nsString = text as NSString
        if selection.length > 0 {
            // Wrap the selection
            let inner = nsString.substring(with: selection)
            let replaced = String(ch) + inner + String(close)
            let mutable = NSMutableString(string: nsString)
            mutable.replaceCharacters(in: selection, with: replaced)
            let newSel = NSRange(location: selection.location + 1, length: (inner as NSString).length)
            return Result(text: mutable as String, selection: newSel)
        } else {
            // Insert pair, place cursor between
            let insert = String(ch) + String(close)
            let mutable = NSMutableString(string: nsString)
            mutable.insert(insert, at: selection.location)
            let newSel = NSRange(location: selection.location + 1, length: 0)
            return Result(text: mutable as String, selection: newSel)
        }
    }

    /// Whether typing `ch` at `location` (no selection) should insert
    /// the closing half too. Pairing only makes sense where a new span
    /// starts:
    ///   - never right before a word (`(|word` stays `(word`);
    ///   - `'` / `"` / `` ` `` not right after a letter or digit — that's
    ///     an apostrophe (`don't`, `geht's`) or the end of a span;
    ///   - `` ` `` not after another backtick, so typing a ``` fence gives
    ///     exactly three backticks.
    static func shouldAutoPair(_ ch: Character, in text: String, at location: Int) -> Bool {
        let ns = text as NSString
        guard location >= 0, location <= ns.length else { return false }
        let next: Character? = location < ns.length
            ? ns.substring(with: NSRange(location: location, length: 1)).first : nil
        let prev: Character? = location > 0
            ? ns.substring(with: NSRange(location: location - 1, length: 1)).first : nil
        if let next, next.isLetter || next.isNumber || next == "_" { return false }
        switch ch {
        case "'", "\"":
            if let prev, prev.isLetter || prev.isNumber || prev == ch { return false }
        case "`":
            if let prev, prev.isLetter || prev.isNumber || prev == "`" { return false }
        default:
            break
        }
        return true
    }

    /// Whether smart punctuation may rewrite text at `location`. Markdown
    /// syntax is made of the very characters it replaces, so stay out of
    /// code, frontmatter and HTML, and away from lines that are only
    /// dashes / pipes / colons (`---` rules and frontmatter fences,
    /// `|---|` table separators) — the old behaviour turned those into
    /// em-dashes.
    static func smartPunctuationAllowed(in text: String, at location: Int) -> Bool {
        let ns = text as NSString
        guard location > 0, location <= ns.length else { return false }
        let lineRange = ns.lineRange(for: NSRange(location: location - 1, length: 0))
        let linePrefix = ns.substring(with: NSRange(location: lineRange.location,
                                                    length: location - lineRange.location))
        let trimmed = linePrefix.trimmingCharacters(in: .whitespaces)
        // Only-structural line so far: `---`, `|--`, `:--`, `- ` bullets.
        if trimmed.allSatisfy({ "-|:–—".contains($0) }) { return false }
        // Inside an inline code span: odd number of backticks before us.
        if linePrefix.filter({ $0 == "`" }).count % 2 == 1 { return false }
        // Inside an HTML tag / comment (`<a href="…">`, `<!-- … -->`).
        if let lt = linePrefix.lastIndex(of: "<"), !linePrefix[lt...].contains(">") { return false }
        // Inside a link destination `](…`.
        if let open = linePrefix.range(of: "](", options: .backwards),
           !linePrefix[open.upperBound...].contains(")") { return false }
        // Fenced code block or frontmatter: count fences above the line.
        let before = ns.substring(to: lineRange.location)
        var inFence = false
        var inFrontmatter = before.hasPrefix("---\n")
        var lineIndex = 0
        before.enumerateLines { line, _ in
            let t = line.trimmingCharacters(in: .whitespaces)
            if inFrontmatter && lineIndex > 0 && t == "---" { inFrontmatter = false }
            if t.hasPrefix("```") || t.hasPrefix("~~~") { inFence.toggle() }
            lineIndex += 1
        }
        return !inFence && !inFrontmatter
    }

    /// If the cursor is right before `close` (e.g. `)` typed when the
    /// next char is `)`), returns a result that just hops the cursor
    /// forward instead of inserting a duplicate close char.
    static func autoSkip(closing input: String, in text: String, selection: NSRange) -> Result? {
        guard input.count == 1, selection.length == 0 else { return nil }
        let nsString = text as NSString
        guard selection.location < nsString.length else { return nil }
        let nextChar = nsString.substring(with: NSRange(location: selection.location, length: 1))
        guard nextChar == input else { return nil }
        let isClose = ")]}\"'`".contains(input)
        guard isClose else { return nil }
        return Result(text: text, selection: NSRange(location: selection.location + 1, length: 0))
    }

    // MARK: - Smart punctuation

    /// Looks at the just-inserted character at `selection.location - 1`
    /// (assuming the input was already inserted into `text`) and rewrites
    /// it according to smart-punctuation rules. Returns nil if no rewrite
    /// applies.
    ///
    /// Rules:
    /// - `--` → `–` (en-dash)
    /// - `–-` → `—` (em-dash) — i.e. typing a third hyphen after en-dash
    /// - `...` → `…`
    /// - `"` → `"` or `"` based on context (open vs close)
    /// - `'` → `'` or `'` based on context
    static func smartPunctuation(after input: String, in text: String, selection: NSRange) -> Result? {
        guard input.count == 1 else { return nil }
        let nsString = text as NSString
        let cursor = selection.location
        guard cursor >= 1, cursor <= nsString.length else { return nil }

        let charBefore: Character = {
            let s = nsString.substring(with: NSRange(location: cursor - 1, length: 1))
            return s.first ?? " "
        }()
        guard String(charBefore) == input else { return nil }

        // Look back further
        let twoBack: Character? = cursor >= 2
            ? nsString.substring(with: NSRange(location: cursor - 2, length: 1)).first
            : nil
        let threeBack: Character? = cursor >= 3
            ? nsString.substring(with: NSRange(location: cursor - 3, length: 1)).first
            : nil

        let mutable = NSMutableString(string: nsString)

        // `--` → en-dash
        if input == "-" && twoBack == "-" {
            mutable.replaceCharacters(in: NSRange(location: cursor - 2, length: 2), with: "–")
            return Result(text: mutable as String,
                          selection: NSRange(location: cursor - 1, length: 0))
        }
        // `–-` → em-dash
        if input == "-" && twoBack == "–" {
            mutable.replaceCharacters(in: NSRange(location: cursor - 2, length: 2), with: "—")
            return Result(text: mutable as String,
                          selection: NSRange(location: cursor - 1, length: 0))
        }
        // `...` → ellipsis
        if input == "." && twoBack == "." && threeBack == "." {
            mutable.replaceCharacters(in: NSRange(location: cursor - 3, length: 3), with: "…")
            return Result(text: mutable as String,
                          selection: NSRange(location: cursor - 2, length: 0))
        }
        // smart double quote
        if input == "\"" {
            let isOpen = (twoBack == nil) || twoBack?.isWhitespace == true ||
                         (twoBack.map { "([{".contains($0) } ?? false)
            mutable.replaceCharacters(in: NSRange(location: cursor - 1, length: 1),
                                       with: isOpen ? "“" : "”")
            return Result(text: mutable as String, selection: selection)
        }
        // smart single quote / apostrophe
        if input == "'" {
            // Apostrophe (between letters): use right single quote
            if let prev = twoBack, prev.isLetter {
                mutable.replaceCharacters(in: NSRange(location: cursor - 1, length: 1),
                                           with: "’")
                return Result(text: mutable as String, selection: selection)
            }
            let isOpen = (twoBack == nil) || twoBack?.isWhitespace == true ||
                         (twoBack.map { "([{".contains($0) } ?? false)
            mutable.replaceCharacters(in: NSRange(location: cursor - 1, length: 1),
                                       with: isOpen ? "‘" : "’")
            return Result(text: mutable as String, selection: selection)
        }
        return nil
    }

    // MARK: - Helpers

    private static func lineRanges(covering selection: NSRange, in nsString: NSString) -> [NSRange] {
        guard nsString.length > 0 else { return [] }
        let startLine = nsString.lineRange(for: NSRange(location: min(selection.location, nsString.length), length: 0))
        let endLoc = max(selection.location, NSMaxRange(selection) - 1)
        let endLine = nsString.lineRange(for: NSRange(location: min(endLoc, nsString.length - 1), length: 0))
        if NSEqualRanges(startLine, endLine) {
            return [startLine]
        }
        var ranges: [NSRange] = []
        var loc = startLine.location
        while loc <= endLine.location {
            let line = nsString.lineRange(for: NSRange(location: loc, length: 0))
            ranges.append(line)
            loc = NSMaxRange(line)
            if loc >= nsString.length { break }
        }
        return ranges
    }

    private static func clamp(_ range: NSRange, in text: String) -> NSRange {
        let total = (text as NSString).length
        let location = max(0, min(range.location, total))
        let length = max(0, min(range.length, total - location))
        return NSRange(location: location, length: length)
    }
}

private extension String {
    func trimmingNewline() -> String {
        if hasSuffix("\r\n") { return String(dropLast(2)) }
        if hasSuffix("\n") { return String(dropLast()) }
        return self
    }
}
