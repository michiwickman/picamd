import Foundation

/// Search options surfaced in the find bar.
struct SearchOptions: Equatable {
    var caseSensitive = false
    var wholeWord = false
    var regex = false
    /// Ignore Markdown formatting: search the rendered/visible text so
    /// "bold" matches `**bold**` and matches can span marker boundaries.
    var ignoreFormatting = false
}

/// Pure, UI-free document search used by the editor's find bar.
///
/// All matching is computed over the raw Markdown source. For
/// `ignoreFormatting`, the source is first projected to the text the
/// editor actually shows (concealed markers removed) with a per-character
/// map back to source UTF-16 offsets, so a match in the visible text maps
/// to the enclosing source range.
enum DocumentSearch {

    /// The editor-visible projection of a Markdown source: `text` is what's
    /// left once concealed markers are dropped, `map[i]` is the source
    /// UTF-16 offset of `text`'s UTF-16 unit `i`. Cacheable per source.
    struct VisibleText {
        let text: String
        let map: [Int]
    }

    // MARK: - Matching

    /// All non-overlapping matches of `query` in `source`, in document order.
    /// Returns `[]` for an empty query or an invalid regex pattern.
    static func matches(in source: String, query: String, options: SearchOptions) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if options.ignoreFormatting {
            return matches(in: visibleText(from: source), query: query, options: options)
        }
        guard let regex = makeRegex(query: query, options: options) else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            .map(\.range)
            .filter { $0.length > 0 }
    }

    /// Ignore-formatting matches against a precomputed visible-text
    /// projection, mapped back to source ranges.
    static func matches(in visible: VisibleText, query: String, options: SearchOptions) -> [NSRange] {
        guard !query.isEmpty, !visible.text.isEmpty,
              let regex = makeRegex(query: query, options: options) else { return [] }
        let plainMatches = regex.matches(in: visible.text,
                                         range: NSRange(location: 0, length: (visible.text as NSString).length))
        let map = visible.map
        var out: [NSRange] = []
        out.reserveCapacity(plainMatches.count)
        for m in plainMatches.map(\.range) where m.length > 0 {
            let lastPlain = m.location + m.length - 1
            guard lastPlain < map.count else { continue }
            // Start at the first visible char, end one past the last one.
            // Concealed markers between them fall inside the range, which
            // is what the highlight should cover.
            let srcStart = map[m.location]
            let srcEnd = map[lastPlain] + 1
            if srcEnd > srcStart {
                out.append(NSRange(location: srcStart, length: srcEnd - srcStart))
            }
        }
        return out
    }

    /// Whether `query` compiles to a usable pattern under `options`. The bar
    /// uses this to show an "invalid pattern" state for bad regex input —
    /// in ignore-formatting mode too, where the same regex runs over the
    /// visible text.
    static func isValid(query: String, options: SearchOptions) -> Bool {
        if query.isEmpty { return true }
        return makeRegex(query: query, options: options) != nil
    }

    /// Build the regex for a search. Literal queries are escaped. Whole-word
    /// uses letter/digit lookarounds instead of `\b`, so queries that start
    /// or end in punctuation (`#tag`, `C++`) still match as whole words.
    /// Regex mode lets `^`/`$` anchor at line boundaries, as editors do.
    private static func makeRegex(query: String, options: SearchOptions) -> NSRegularExpression? {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = #"(?<![\p{L}\p{N}_])(?:"# + pattern + #")(?![\p{L}\p{N}_])"#
        }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        if options.regex { opts.insert(.anchorsMatchLines) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    // MARK: - Visible-text projection (ignore formatting)

    /// Reduce Markdown `source` to the text the editor shows when the caret
    /// is elsewhere, plus a map from each visible UTF-16 index back to its
    /// source index.
    ///
    /// Mirrors `SyntaxHighlighter`'s concealment using the same shared
    /// patterns (`MarkdownRegexes`): heading hashes, blockquote markers,
    /// bold / italic / strikethrough / highlight / inline-code / inline-math
    /// delimiters, and link/image brackets + URLs. Fenced code, math blocks
    /// and frontmatter are left verbatim — the highlighter doesn't conceal
    /// anything inside them either. Prose like `snake_case` or `a = b`
    /// therefore stays searchable as typed.
    static func plainText(from source: String) -> (text: String, map: [Int]) {
        let visible = visibleText(from: source)
        return (visible.text, visible.map)
    }

    static func visibleText(from source: String) -> VisibleText {
        let ns = source as NSString
        let n = ns.length
        guard n > 0 else { return VisibleText(text: "", map: []) }
        let full = NSRange(location: 0, length: n)

        // Regions shown verbatim — nothing inside them is concealed.
        var verbatim = [Bool](repeating: false, count: n)
        for regex in [MarkdownRegexes.fencedCode, MarkdownRegexes.mathBlock, MarkdownRegexes.frontmatter] {
            for m in regex.matches(in: source, range: full) {
                for i in m.range.location..<min(NSMaxRange(m.range), n) { verbatim[i] = true }
            }
        }

        var hidden = [Bool](repeating: false, count: n)
        func hide(_ r: NSRange) {
            guard r.location != NSNotFound, r.length > 0 else { return }
            for i in r.location..<min(NSMaxRange(r), n) { hidden[i] = true }
        }
        func each(_ regex: NSRegularExpression, _ body: (NSTextCheckingResult) -> Void) {
            for m in regex.matches(in: source, range: full)
            where m.range.location < n && !verbatim[m.range.location] {
                body(m)
            }
        }
        /// Hide a symmetric delimiter pair: group 1 opens, the same number
        /// of characters closes at the end of the match.
        func hideDelimiters(_ m: NSTextCheckingResult) {
            let open = m.range(at: 1)
            hide(open)
            hide(NSRange(location: NSMaxRange(m.range) - open.length, length: open.length))
        }

        each(MarkdownRegexes.heading) { m in hide(m.range(at: 1)); hide(m.range(at: 2)) }
        each(MarkdownRegexes.blockquote) { m in hide(m.range(at: 1)) }
        for regex in [MarkdownRegexes.bold, MarkdownRegexes.italic, MarkdownRegexes.strikethrough,
                      MarkdownRegexes.highlight, MarkdownRegexes.inlineCode, MarkdownRegexes.mathInline] {
            each(regex, hideDelimiters)
        }
        // `***x***`: the bold pass hides the outer `**`; the inner single
        // markers are concealed by the highlighter's bold-italic branch.
        each(MarkdownRegexes.bold) { m in
            let inner = m.range(at: 2)
            guard inner.length >= 2 else { return }
            let first = ns.character(at: inner.location)
            let last = ns.character(at: NSMaxRange(inner) - 1)
            if first == last, first == 0x2A /* * */ || first == 0x5F /* _ */ {
                hide(NSRange(location: inner.location, length: 1))
                hide(NSRange(location: NSMaxRange(inner) - 1, length: 1))
            }
        }
        // Links / images: keep only the label.
        each(MarkdownRegexes.link) { m in
            let label = m.range(at: 2)
            hide(NSRange(location: m.range.location, length: label.location - m.range.location))
            hide(NSRange(location: NSMaxRange(label), length: NSMaxRange(m.range) - NSMaxRange(label)))
        }

        var plain = [unichar]()
        var map = [Int]()
        plain.reserveCapacity(n)
        map.reserveCapacity(n)
        for i in 0..<n where !hidden[i] {
            plain.append(ns.character(at: i))
            map.append(i)
        }
        return VisibleText(text: String(utf16CodeUnits: plain, count: plain.count), map: map)
    }

    // MARK: - Replace

    /// Every raw-source match paired with its replacement, from a single
    /// matching pass so `$1`-style captures (and any lookarounds) are
    /// evaluated in full-document context. Literal mode substitutes the
    /// template verbatim. Replace is never offered in ignore-formatting
    /// mode (a visible-text match has no single source span to swap).
    static func replacements(in source: String,
                             query: String,
                             template: String,
                             options: SearchOptions) -> [(range: NSRange, text: String)] {
        guard !query.isEmpty, !options.ignoreFormatting,
              let regex = makeRegex(query: query, options: options) else { return [] }
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            .filter { $0.range.length > 0 }
            .map { result in
                let text = options.regex
                    ? regex.replacementString(for: result, in: source, offset: 0, template: template)
                    : template
                return (result.range, text)
            }
    }

    /// The replacement string for a single match. Literal mode returns the
    /// template verbatim; regex mode expands `$1`-style capture references.
    /// The match is re-run with transparent, non-anchoring bounds so
    /// lookbehinds and `^`/`$` see the surrounding document exactly as the
    /// original search did.
    static func replacementText(forMatch match: NSRange,
                                in source: String,
                                query: String,
                                template: String,
                                options: SearchOptions) -> String {
        guard options.regex, !options.ignoreFormatting,
              NSMaxRange(match) <= (source as NSString).length,
              let regex = makeRegex(query: query, options: options),
              let result = regex.firstMatch(in: source,
                                            options: [.withTransparentBounds, .withoutAnchoringBounds],
                                            range: match),
              result.range.location == match.location else {
            return template
        }
        return regex.replacementString(for: result, in: source, offset: 0, template: template)
    }
}
