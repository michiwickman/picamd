import Foundation

/// How a literal (or regex) query has to sit relative to word
/// boundaries. The three entries of the find bar's options menu that
/// form one radio group: Contains, Starts With, Whole Word.
enum MatchStyle: String, CaseIterable, Equatable, Sendable {
    case contains, startsWith, wholeWord
}

/// Search options surfaced in the find bar's options menu.
struct SearchOptions: Equatable, Sendable {
    var caseSensitive = false
    var matchStyle: MatchStyle = .contains
    var regex = false
    /// Ignore Markdown formatting: search the rendered/visible text so
    /// "bold" matches `**bold**` and matches can span marker boundaries.
    var ignoreFormatting = false
    /// Find Next past the last match continues at the first (and Find
    /// Previous before the first at the last). Off, the search stops at
    /// either end with a beep. Only navigation reads it; the match set
    /// is the same either way.
    var wrapAround = true

    /// The old Whole Word toggle, kept as a view onto `matchStyle`.
    var wholeWord: Bool {
        get { matchStyle == .wholeWord }
        set { matchStyle = newValue ? .wholeWord : .contains }
    }
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
        /// The Markdown source `text` was projected from: a match that
        /// runs across a line break is checked against its block structure.
        let source: String
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
        let ranges = regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            .map(\.range)
            .filter { $0.length > 0 }
        return keepingSoftBreaksOnly(ranges, in: source, query: query, options: options)
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
        return keepingSoftBreaksOnly(out, in: visible.source, query: query, options: options)
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
    /// or end in punctuation (`#tag`, `C++`) still match as whole words;
    /// Starts With keeps only the leading lookbehind. Regex mode lets
    /// `^`/`$` anchor at line boundaries, as editors do.
    private static func makeRegex(query: String, options: SearchOptions) -> NSRegularExpression? {
        var pattern = options.regex ? query : literalPattern(for: query)
        let notWordBefore = #"(?<![\p{L}\p{N}_])"#
        let notWordAfter = #"(?![\p{L}\p{N}_])"#
        switch options.matchStyle {
        case .contains: break
        case .startsWith: pattern = notWordBefore + "(?:" + pattern + ")"
        case .wholeWord: pattern = notWordBefore + "(?:" + pattern + ")" + notWordAfter
        }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        if options.regex { opts.insert(.anchorsMatchLines) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    /// Whitespace between two words of a literal query. A hard-wrapped
    /// paragraph shows its line breaks as spaces in Reflow mode (and
    /// renders them as spaces anywhere else), so "tram out" has to find
    /// `tram⏎out`. One line break at most: a blank line is a paragraph
    /// break, and a phrase does not run across paragraphs. A match whose
    /// break is structural (a heading, code) is dropped afterwards, see
    /// `keepingSoftBreaksOnly`.
    static let interWordSpacePattern = #"(?:[ \t]+(?:\r?\n[ \t]*)?|\r?\n[ \t]*)"#

    /// An escaped literal query whose runs of spaces and tabs match
    /// `interWordSpacePattern`. Leading and trailing spaces stay literal
    /// — they would otherwise turn "foo " into "foo at the end of a line".
    static func literalPattern(for query: String) -> String {
        let chars = Array(query)
        guard let first = chars.firstIndex(where: { $0 != " " && $0 != "\t" }),
              let last = chars.lastIndex(where: { $0 != " " && $0 != "\t" }) else {
            return NSRegularExpression.escapedPattern(for: query)
        }
        var pattern = NSRegularExpression.escapedPattern(for: String(chars[..<first]))
        var i = first
        while i <= last {
            if chars[i] == " " || chars[i] == "\t" {
                while chars[i] == " " || chars[i] == "\t" { i += 1 }
                pattern += interWordSpacePattern
            } else {
                var j = i
                while j <= last, chars[j] != " ", chars[j] != "\t" { j += 1 }
                pattern += NSRegularExpression.escapedPattern(for: String(chars[i..<j]))
                i = j
            }
        }
        pattern += NSRegularExpression.escapedPattern(for: String(chars[(last + 1)...]))
        return pattern
    }

    /// A space in a literal query stands for a line break only where the
    /// break is shown as a space: a hard wrap inside a paragraph, as
    /// `ReflowClassifier` decides it for Reflow mode. The line break
    /// after a heading, inside a code fence, inside a list item or
    /// between table rows is structural, so "Title body" must not find
    /// `# Title⏎body` — Replace would merge the heading into the
    /// paragraph. Regex queries say what they mean and are left alone,
    /// and so is a literal query that itself contains a line break (a
    /// multi-line selection taken with ⌘E).
    private static func keepingSoftBreaksOnly(_ ranges: [NSRange], in source: String,
                                              query: String, options: SearchOptions) -> [NSRange] {
        let keep = softBreakFilter(in: source, query: query, options: options)
        return ranges.filter { keep($0) }
    }

    /// The predicate behind `keepingSoftBreaksOnly`. The document is
    /// classified once, and only when a match actually crosses a line.
    private static func softBreakFilter(in source: String, query: String,
                                        options: SearchOptions) -> (NSRange) -> Bool {
        guard !options.regex, !query.contains(where: \.isNewline) else { return { _ in true } }
        let ns = source as NSString
        var soft: Set<Int>?
        return { range in
            guard ns.rangeOfCharacter(from: .newlines, options: [], range: range).location != NSNotFound else {
                return true
            }
            let breaks = soft ?? ReflowClassifier.softNewlineOffsets(
                in: source, blocks: BlockExtractor.extract(from: source),
                protectedRanges: CheckboxOverlayManager.protectedRanges(in: source))
            soft = breaks
            for i in range.location..<NSMaxRange(range) where ns.character(at: i) == 0x0A /* \n */ {
                if !breaks.contains(i) { return false }
            }
            return true
        }
    }

    // MARK: - Navigation

    /// The match Find Next (`delta` 1) or Find Previous (`delta` -1) lands
    /// on, as a 1-based index into `matches`, or nil when there is none
    /// to go to (the caller beeps and stays).
    ///
    /// `current` is the 1-based current match, 0 for none: the bar was
    /// closed, or Wrap Around is off and nothing follows the caret. Then
    /// the step starts at the selection — the first match at or after its
    /// end, or the last one before its start — so ⌘G with the bar closed
    /// continues from the match it selected last time.
    static func navigationTarget(current: Int, delta: Int, matches: [NSRange],
                                 selection: NSRange, wrapAround: Bool) -> Int? {
        let count = matches.count
        guard count > 0, delta != 0 else { return nil }
        if current < 1 || current > count {
            if delta > 0 {
                if let i = matches.firstIndex(where: { $0.location >= NSMaxRange(selection) }) { return i + 1 }
                return wrapAround ? 1 : nil
            }
            if let i = matches.lastIndex(where: { $0.location < selection.location }) { return i + 1 }
            return wrapAround ? count : nil
        }
        let target = current + delta
        if (1...count).contains(target) { return target }
        guard wrapAround else { return nil }
        return ((target - 1) % count + count) % count + 1
    }

    /// The match the bar starts on after the query or options change:
    /// the first one at or after `location` (1-based). Past the last
    /// match it wraps to the first, or — Wrap Around off — reports none
    /// (0), so the bar shows "N matches" and ⌘G beeps instead of
    /// jumping back to the top.
    static func nearestMatchIndex(in matches: [NSRange], to location: Int, wrapAround: Bool) -> Int {
        guard !matches.isEmpty else { return 0 }
        if let i = matches.firstIndex(where: { $0.location >= location }) { return i + 1 }
        return wrapAround ? 1 : 0
    }

    /// After a live edit, the current match stays the same occurrence:
    /// the first match that still ends after `previous` started. The same
    /// wrap rule as `nearestMatchIndex`.
    static func sameOccurrenceIndex(in matches: [NSRange], previous: NSRange, wrapAround: Bool) -> Int {
        guard !matches.isEmpty else { return 0 }
        if let i = matches.firstIndex(where: { NSMaxRange($0) > previous.location }) { return i + 1 }
        return wrapAround ? 1 : 0
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
        guard n > 0 else { return VisibleText(text: "", map: [], source: source) }
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
        return VisibleText(text: String(utf16CodeUnits: plain, count: plain.count), map: map, source: source)
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
        // The same match set the bar counts and highlights.
        let isShownMatch = softBreakFilter(in: source, query: query, options: options)
        return regex.matches(in: source, range: NSRange(location: 0, length: (source as NSString).length))
            .filter { $0.range.length > 0 && isShownMatch($0.range) }
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
