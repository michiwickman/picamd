import Foundation

/// Pure-logic footnote parser used by both the editor's hover-tooltip
/// (`FootnoteTooltipController`) and the HTML exporter
/// (`MarkdownToHTML`). No AppKit dependencies → safe to compile into
/// the Quick-Look extension too.
///
/// The model is a single immutable index built from raw Markdown:
///   - `refs`: every `[^id]` reference, in document order
///   - `definitions`: id → plain-text definition (multi-line bodies
///     joined into a single whitespace-collapsed string)

struct FootnoteRef: Equatable {
    let id: String
    let range: NSRange      // in the markdown source
}

struct FootnoteIndex: Equatable {
    let refs: [FootnoteRef]
    /// Plain-text definition keyed by id (without the leading `^`).
    /// Multi-line definitions are joined with a single space.
    let definitions: [String: String]

    static let empty = FootnoteIndex(refs: [], definitions: [:])

    // Compiled once — `build` runs on every edit.
    private static let defRegex = try! NSRegularExpression(pattern: #"^\[\^([^\]]+)\]:[ \t]*"#,
                                                           options: [.anchorsMatchLines])
    private static let refRegex = try! NSRegularExpression(pattern: #"\[\^([^\]]+)\]"#)
    private static let fencedCodeRegex = try! NSRegularExpression(
        pattern: #"(?m)^([`~]{3,})[^\n]*\n[\s\S]*?^\1[ \t]*$"#)
    private static let inlineCodeRegex = try! NSRegularExpression(pattern: #"(`+)([^`\n]+?)\1"#)

    /// Fenced blocks and inline code spans. `[^a-z]` in a regex inside a
    /// code block is code, not a footnote reference.
    static func codeRanges(in source: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (source as NSString).length)
        return (fencedCodeRegex.matches(in: source, range: full)
                + inlineCodeRegex.matches(in: source, range: full)).map(\.range)
    }

    /// Build the index from raw markdown.
    ///
    /// Ref grammar: `[^<id>]` where `<id>` matches `[^\]]+`.
    /// Def grammar: at start-of-line, `[^<id>]: ` followed by the
    /// definition text. The definition runs until the next blank line
    /// or the next footnote-definition line.
    static func build(from source: String) -> FootnoteIndex {
        let nsSource = source as NSString
        let fullRange = NSRange(location: 0, length: nsSource.length)
        let code = codeRanges(in: source)
        func inCode(_ location: Int) -> Bool {
            code.contains { NSLocationInRange(location, $0) }
        }

        // Definitions first — collect their start positions so we can
        // exclude them from the refs list (the same `[^id]` regex
        // would otherwise match the bracket portion of every def).
        struct DefStart { let id: String; let lineStart: Int; let bodyStart: Int }
        var defStarts: [DefStart] = []
        do {
            defRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2, !inCode(m.range.location) else { return }
                let idRange = m.range(at: 1)
                guard idRange.location != NSNotFound else { return }
                let id = nsSource.substring(with: idRange)
                let bodyStart = m.range.location + m.range.length
                defStarts.append(DefStart(id: id,
                                          lineStart: m.range.location,
                                          bodyStart: bodyStart))
            }
        }
        let defLineStarts = Set(defStarts.map(\.lineStart))

        // Refs — same regex as the syntax highlighter uses, but we
        // skip any `[^id]` whose location matches a definition's line
        // start (those are the bracket portion of the def itself, not
        // a reference to it).
        var refs: [FootnoteRef] = []
        do {
            refRegex.enumerateMatches(in: source, options: [], range: fullRange) { match, _, _ in
                guard let m = match, m.numberOfRanges >= 2, !inCode(m.range.location) else { return }
                if defLineStarts.contains(m.range.location) { return }
                let idRange = m.range(at: 1)
                guard idRange.location != NSNotFound else { return }
                let id = nsSource.substring(with: idRange)
                refs.append(FootnoteRef(id: id, range: m.range))
            }
        }

        var definitions: [String: String] = [:]
        // For each def, walk forward until: blank line / next def line / EOF
        for (i, start) in defStarts.enumerated() {
            let end: Int
            if i + 1 < defStarts.count {
                end = defStarts[i + 1].lineStart
            } else {
                end = nsSource.length
            }
            let bodyRange = NSRange(location: start.bodyStart,
                                    length: max(0, end - start.bodyStart))
            let bodySlice = nsSource.substring(with: bodyRange)
            // Cut at first blank line
            let trimmed: String
            if let blankRange = bodySlice.range(of: #"\r?\n[ \t]*\r?\n"#, options: .regularExpression) {
                trimmed = String(bodySlice[..<blankRange.lowerBound])
            } else {
                trimmed = bodySlice
            }
            // Collapse whitespace into single spaces for the tooltip
            let collapsed = trimmed
                .split(whereSeparator: { $0.isWhitespace })
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            definitions[start.id] = collapsed
        }

        return FootnoteIndex(refs: refs, definitions: definitions)
    }

    /// Find the ref at the given char index (or `nil` if none).
    func ref(at charIndex: Int) -> FootnoteRef? {
        for r in refs {
            if r.range.contains(charIndex) {
                return r
            }
        }
        return nil
    }
}
