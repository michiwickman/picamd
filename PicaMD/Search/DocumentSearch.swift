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
/// `ignoreFormatting`, the source is reduced to a "plain text" string
/// (markers stripped, links collapsed to their text) with a per-character
/// map back to source UTF-16 offsets, so a match in the plain text maps to
/// the enclosing source range.
enum DocumentSearch {

    // MARK: - Matching

    /// All non-overlapping matches of `query` in `source`, in document order.
    /// Returns `[]` for an empty query or an invalid regex pattern.
    static func matches(in source: String, query: String, options: SearchOptions) -> [NSRange] {
        guard !query.isEmpty else { return [] }
        if options.ignoreFormatting {
            return ignoreFormattingMatches(in: source, query: query, options: options)
        }
        guard let regex = makeRegex(query: query, options: options) else { return [] }
        let ns = source as NSString
        return regex.matches(in: source, range: NSRange(location: 0, length: ns.length))
            .map(\.range)
            .filter { $0.length > 0 }
    }

    /// Whether `query` compiles to a usable pattern under `options`. The bar
    /// uses this to show an "invalid pattern" state for bad regex input.
    static func isValid(query: String, options: SearchOptions) -> Bool {
        if query.isEmpty { return true }
        if options.ignoreFormatting { return true }   // literal/regex over plain text
        return makeRegex(query: query, options: options) != nil
    }

    /// Build the regex used for a (non-ignoreFormatting) search. Literal
    /// queries are escaped; `wholeWord` wraps with `\b…\b`; case folds via
    /// `.caseInsensitive`.
    private static func makeRegex(query: String, options: SearchOptions) -> NSRegularExpression? {
        var pattern = options.regex ? query : NSRegularExpression.escapedPattern(for: query)
        if options.wholeWord {
            pattern = "\\b(?:\(pattern))\\b"
        }
        var opts: NSRegularExpression.Options = []
        if !options.caseSensitive { opts.insert(.caseInsensitive) }
        return try? NSRegularExpression(pattern: pattern, options: opts)
    }

    // MARK: - Ignore-formatting (Markdown-aware) matching

    private static func ignoreFormattingMatches(in source: String,
                                                query: String,
                                                options: SearchOptions) -> [NSRange] {
        let (plain, map) = plainText(from: source)
        guard !plain.isEmpty else { return [] }
        // Reuse the regex builder over the plain string (no ignoreFormatting
        // recursion). Whole-word / case / regex all still apply.
        var literalOpts = options
        literalOpts.ignoreFormatting = false
        guard let regex = makeRegex(query: query, options: literalOpts) else { return [] }

        let plainNS = plain as NSString
        let plainMatches = regex.matches(in: plain, range: NSRange(location: 0, length: plainNS.length))
            .map(\.range)
            .filter { $0.length > 0 }

        // Map each plain-text match back to the enclosing source range using
        // the per-character offset map (map[i] = source offset of plain char i).
        var out: [NSRange] = []
        for m in plainMatches {
            guard m.location < map.count else { continue }
            let lastPlain = m.location + m.length - 1
            guard lastPlain < map.count else { continue }
            let srcStart = map[m.location]
            // End = one past the source offset of the last matched plain char.
            // A plain char maps to a single source char, so +1 is exact even
            // when the run is interrupted by stripped markers in between.
            let srcEnd = map[lastPlain] + 1
            if srcEnd > srcStart {
                out.append(NSRange(location: srcStart, length: srcEnd - srcStart))
            }
        }
        return out
    }

    /// Reduce Markdown `source` to visible text + a map from each plain-text
    /// UTF-16 index to its originating source UTF-16 index.
    ///
    /// Handled: inline emphasis/strong (`*`,`_`), strikethrough (`~~`),
    /// highlight (`==`), inline code (`` ` ``), links `[text](url)` → `text`,
    /// leading ATX heading hashes (`#`+space) and blockquote markers (`>`+space).
    /// Fenced-code bodies are left verbatim. The map lets a plain match be
    /// projected back to the exact enclosing source span.
    static func plainText(from source: String) -> (text: String, map: [Int]) {
        let ns = source as NSString
        let n = ns.length
        var plain = [unichar]()
        var map = [Int]()
        plain.reserveCapacity(n)
        map.reserveCapacity(n)

        var i = 0
        var atLineStart = true
        var inFence = false

        func isMarkerRun(_ ch: unichar, at idx: Int) -> Int {
            // Count a run of the same marker char starting at idx.
            var k = idx
            while k < n && ns.character(at: k) == ch { k += 1 }
            return k - idx
        }

        while i < n {
            let c = ns.character(at: i)
            let nl: unichar = 0x0A

            // Fenced code toggle on lines starting with ``` or ~~~.
            if atLineStart {
                if matchesFence(ns, at: i) {
                    inFence.toggle()
                    // Keep the fence line verbatim (incl. its text) up to newline.
                    while i < n && ns.character(at: i) != nl {
                        plain.append(ns.character(at: i)); map.append(i); i += 1
                    }
                    continue
                }
                if !inFence {
                    // Strip leading ATX hashes "#{1,6} " and blockquote "> ".
                    if c == 0x23 /* # */ {
                        var k = i
                        while k < n && ns.character(at: k) == 0x23 { k += 1 }
                        let hashes = k - i
                        if hashes >= 1 && hashes <= 6 && k < n && ns.character(at: k) == 0x20 {
                            i = k + 1            // skip hashes + the single space
                            atLineStart = false
                            continue
                        }
                    }
                    if c == 0x3E /* > */ {
                        var k = i
                        // one level of "> " (optionally repeated) at line start
                        while k < n && ns.character(at: k) == 0x3E {
                            k += 1
                            if k < n && ns.character(at: k) == 0x20 { k += 1 }
                        }
                        i = k
                        atLineStart = false
                        continue
                    }
                }
            }

            if inFence {
                plain.append(c); map.append(i)
                atLineStart = (c == nl)
                i += 1
                continue
            }

            // Links / images: [text](url) → text ; ![alt](url) → alt
            if c == 0x5B /* [ */ {
                if let link = parseLink(ns, at: i, n: n) {
                    var t = link.textStart
                    while t < link.textEnd {
                        plain.append(ns.character(at: t)); map.append(t); t += 1
                    }
                    i = link.end
                    atLineStart = false
                    continue
                }
            }

            // Inline marker runs to drop: * _ ` ~ =
            if c == 0x2A || c == 0x5F || c == 0x60 || c == 0x7E || c == 0x3D {
                let run = isMarkerRun(c, at: i)
                // Drop emphasis/code/strike/highlight markers. (We don't try to
                // balance — dropping marker chars is enough for visible-text
                // search; unmatched markers in prose are rare.)
                i += run
                atLineStart = false
                continue
            }

            plain.append(c); map.append(i)
            atLineStart = (c == nl)
            i += 1
        }

        return (String(utf16CodeUnits: plain, count: plain.count), map)
    }

    private static func matchesFence(_ ns: NSString, at i: Int) -> Bool {
        let n = ns.length
        guard i + 2 < n else { return false }
        let c = ns.character(at: i)
        guard c == 0x60 /* ` */ || c == 0x7E /* ~ */ else { return false }
        return ns.character(at: i + 1) == c && ns.character(at: i + 2) == c
    }

    /// Parse `[text](url)` (or `![text](url)`) starting at `[`. Returns the
    /// text span and the index one past the closing `)`.
    private static func parseLink(_ ns: NSString, at open: Int, n: Int)
        -> (textStart: Int, textEnd: Int, end: Int)? {
        var i = open + 1
        let textStart = i
        while i < n {
            let c = ns.character(at: i)
            if c == 0x5D /* ] */ { break }
            if c == 0x0A { return nil }
            i += 1
        }
        guard i < n, ns.character(at: i) == 0x5D else { return nil }
        let textEnd = i
        guard i + 1 < n, ns.character(at: i + 1) == 0x28 /* ( */ else { return nil }
        i += 2
        while i < n {
            let c = ns.character(at: i)
            if c == 0x29 /* ) */ { return (textStart, textEnd, i + 1) }
            if c == 0x0A { return nil }
            i += 1
        }
        return nil
    }

    // MARK: - Replace

    /// The replacement string for a single match. Literal mode returns the
    /// template verbatim; regex mode expands `$1`-style capture references
    /// against the groups captured by `query` at `match`.
    ///
    /// Replace is never offered while `ignoreFormatting` is on (there's no
    /// safe single source span to substitute), so this only handles the
    /// raw-source literal and regex cases.
    static func replacementText(forMatch match: NSRange,
                                in source: String,
                                query: String,
                                template: String,
                                options: SearchOptions) -> String {
        guard options.regex, !options.ignoreFormatting,
              let regex = makeRegex(query: query, options: options),
              let result = regex.firstMatch(in: source, range: match) else {
            return template
        }
        return regex.replacementString(for: result, in: source, offset: 0, template: template)
    }
}
