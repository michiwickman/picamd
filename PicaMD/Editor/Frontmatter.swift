import Foundation

/// Lightweight parser for the `---\n…\n---\n` YAML frontmatter block
/// at the top of a markdown document. Supports the small subset
/// PicaMD's inspector needs: scalar key/value pairs (plain, `'…'` and
/// `"…"`), inline `[a, b, c]` arrays, `- item` block lists, and block
/// scalars (`|`, `>`). Anything fancier (nested maps, anchors) stays
/// untouched in the source: the inspector rewrites single key lines
/// (see `Frontmatter.edit`), never the whole block.
///
/// Besides the values, the parser records where each top-level key lives
/// (`entries`) and how its value is written, so a write can replace
/// exactly those lines and keep the user's style.
///
/// Pulling in Yams or another full YAML parser would mean dragging a
/// package dependency into the lean bundle (and into the Quick Look
/// extension, which compiles this file too) for three fields.
struct Frontmatter: Equatable {
    /// Range of the entire frontmatter block (incl. the fences and the
    /// closing fence's line break) in the source document. `nil` if no
    /// frontmatter is present.
    let range: NSRange?
    /// Single-line scalar values keyed by their YAML key.
    let scalars: [String: String]
    /// Array values keyed by their YAML key. Order preserved.
    let arrays: [String: [String]]
    /// Original lines between the fences, preserved verbatim (without
    /// their line breaks).
    let rawLines: [String]
    /// The opening fence ends in CRLF. Lines the inspector adds use the
    /// same line break, so a Windows file stays a Windows file.
    let usesCRLF: Bool
    /// Range of the closing fence line, including its line break.
    let closingFenceRange: NSRange?
    /// Where each top-level key is written. Like `scalars`, a repeated key
    /// resolves to its last occurrence (the one a reader sees).
    let entries: [String: Entry]

    static let empty = Frontmatter(range: nil, scalars: [:], arrays: [:], rawLines: [],
                                   usesCRLF: false, closingFenceRange: nil, entries: [:])

    /// One top-level key and the lines that belong to it.
    struct Entry: Equatable {
        let key: String
        /// The key line plus its list items or indented continuation
        /// lines, each with its line break. Replacing this range never
        /// touches another key.
        let range: NSRange
        /// The key line without its line break.
        let keyLine: String
        /// `title:` exactly as written (key quoting and case kept).
        let keyPrefix: String
        /// Whitespace between the colon and the value (`" "` usually).
        let separator: String
        /// Whatever follows the value on the key line: spaces and a
        /// `# comment`. Kept when the value is rewritten.
        let trailing: String
        /// `"\n"` or `"\r\n"`: the key line's own line break.
        let lineBreak: String
        let style: ValueStyle
    }

    /// How a value is written in the source.
    enum ValueStyle: Equatable {
        case plain
        case singleQuoted
        case doubleQuoted
        /// `[a, b]`. `quote` is set when every item was quoted with it.
        case inlineArray(quote: Character?)
        /// `key:` followed by `- item` lines. `indent` is the text before
        /// the dash, `gap` the text between the dash and the item.
        case blockList(indent: String, gap: String, quote: Character?)
        /// `key: |` or `key: >` with indented lines below.
        case blockScalar
        /// `key:` with nothing (or only indented, non-list lines) below.
        case empty
    }

    // MARK: - Convenience accessors used by the inspector

    /// Keys a title is read from, in priority order.
    static let titleKeys = ["title", "name"]
    /// Keys a date is read from, in priority order.
    static let dateKeys = ["date", "created", "updated"]

    /// `title:` — falls back to `name:` (some users prefer it).
    var title: String? {
        titleKey.flatMap { scalars[$0] }
    }
    /// `date:` — falls back to `created:` / `updated:`.
    var date: String? {
        dateKey.flatMap { scalars[$0] }
    }
    /// Tags from either an inline `[a, b]` array or a `-` list.
    var tags: [String] {
        if let arr = arrays["tags"] { return arr }
        if let inline = scalars["tags"] {
            return Self.parseInlineArray(inline)
        }
        return []
    }

    /// The key the title is read from, if any.
    var titleKey: String? { Self.titleKeys.first { scalars[$0] != nil } }
    /// The key the date is read from, if any.
    var dateKey: String? { Self.dateKeys.first { scalars[$0] != nil } }

    // MARK: - Fence

    /// The one fence rule, shared with the highlighter, search and word
    /// count through `MarkdownRegexes.frontmatter`:
    ///
    /// - the opening `---` is alone on the first line,
    /// - the closing `---` is alone on a later line,
    /// - both may carry trailing spaces or tabs,
    /// - lines end in LF or CRLF,
    /// - the block may be empty and may end the document.
    ///
    /// - every line between them looks like YAML: blank, indented, a
    ///   `# comment`, a `- item`, or a `key:` line (colon followed by a
    ///   space or the line end).
    ///
    /// So `title: foo---` and `----` are not fences, and a note that opens
    /// with a horizontal rule and has prose before the next `---` (or a
    /// Setext underline) is not front matter: the editor would otherwise
    /// fold that prose away and the inspector would write keys into it.
    /// Group 1 is the body without its last line break (absent for an
    /// empty block), group 2 the closing fence line with its line break.
    /// The optional body is lazy (`??`) so `---\n---\n` is an empty block
    /// rather than the start of a block that ends at the next `---`.
    /// Each body line is an atomic group with one way to match, so a long
    /// unclosed block fails in linear time instead of backtracking.
    static let fencePattern =
        #"\A---[ \t]*\r?\n(?:((?:"# + yamlLine + #"\r?\n)*?"# + yamlLine + #")\r?\n)??(---[ \t]*(?:\r?\n|\z))"#

    /// One body line (without its line break) that YAML could hold.
    private static let yamlLine =
        #"(?>[ \t#-][^\r\n]*|[^\r\n]*?:(?:[ \t][^\r\n]*)?(?=\r?\n|\z)|)"#

    // Compiled once at type-load time. Using `try!` here is intentional:
    // a regex syntax error is a programmer error caught at startup, not a
    // recoverable runtime condition. This follows the SyntaxHighlighter
    // convention for static regex constants.
    static let fenceRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: fencePattern)
    }()

    // MARK: - Build

    /// Parse the leading frontmatter, if any.
    static func build(from source: String) -> Frontmatter {
        let ns = source as NSString
        guard let match = fenceRegex.firstMatch(in: source, options: [],
                                                range: NSRange(location: 0, length: ns.length))
        else {
            return .empty
        }
        let closing = match.range(at: 2)
        let openingLine = ns.lineRange(for: NSRange(location: 0, length: 0))
        let usesCRLF = ns.substring(with: openingLine).hasSuffix("\r\n")

        // Every body line, each with its line break: from the end of the
        // opening fence to the start of the closing one.
        var lines: [Line] = []
        var location = NSMaxRange(openingLine)
        while location < closing.location {
            let lineRange = ns.lineRange(for: NSRange(location: location, length: 0))
            let full = ns.substring(with: lineRange)
            var text = full
            var lineBreak = ""
            if text.hasSuffix("\r\n") {
                text.removeLast(1)          // "\r\n" is one Character
                lineBreak = "\r\n"
            } else if text.hasSuffix("\n") {
                text.removeLast()
                lineBreak = "\n"
            }
            lines.append(Line(text: text, lineBreak: lineBreak, range: lineRange))
            location = NSMaxRange(lineRange)
        }

        var scalars: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var entries: [String: Entry] = [:]

        var index = 0
        while index < lines.count {
            let line = lines[index]
            index += 1
            guard let (keyPrefix, key, afterColon) = splitKey(line.text) else { continue }

            let separator = String(afterColon.prefix { $0 == " " || $0 == "\t" })
            let valueText = String(afterColon.dropFirst(separator.count))
            let (value, trailing) = scanValue(valueText)
            let style: ValueStyle

            // Lines that belong to this key: list items and indented
            // continuation lines. Anything else starts the next key.
            // Under `key: |` and a bare `key:` (list, nested map), blank
            // lines followed by more of the entry belong to it too: a
            // blank line that ended a `|` text left the rest of it behind
            // as stray lines when the key was rewritten. After a plain
            // value they stay outside, so odd lines below it keep their
            // bytes.
            let spansBlankLines: Bool
            switch value {
            case .blockScalarIndicator: spansBlankLines = true
            case .plain(let text): spansBlankLines = text.isEmpty
            default: spansBlankLines = false
            }
            var items: [Line] = []
            while index < lines.count {
                if belongsToPreviousKey(lines[index].text) {
                    items.append(lines[index])
                    index += 1
                    continue
                }
                guard spansBlankLines else { break }
                var next = index
                while next < lines.count, isBlank(lines[next].text) { next += 1 }
                guard next > index, next < lines.count, belongsToPreviousKey(lines[next].text)
                else { break }
                items.append(contentsOf: lines[index..<next])
                index = next
            }
            let content = items.filter { !isBlank($0.text) }

            switch value {
            case .inlineArray(let raw, let quote):
                arrays[key] = parseInlineArray(raw)
                style = .inlineArray(quote: quote)
            case .doubleQuoted(let text):
                scalars[key] = text
                style = .doubleQuoted
            case .singleQuoted(let text):
                scalars[key] = text
                style = .singleQuoted
            case .blockScalarIndicator(let folded):
                let body = items.map { $0.text.trimmingCharacters(in: .whitespaces) }
                scalars[key] = folded ? foldLines(body) : body.joined(separator: "\n")
                style = .blockScalar
            case .plain(let text) where !text.isEmpty:
                // A plain scalar may go on over indented lines; YAML folds
                // them into one value. Lines YAML can't continue a plain
                // scalar with (a comment, a list item, `key: value`) leave
                // the value as the first line reads it.
                let more = items.map { $0.text.trimmingCharacters(in: .whitespaces) }
                let continues = more.allSatisfy {
                    !$0.hasPrefix("#") && !$0.hasPrefix("-") && !$0.contains(": ") && !$0.contains(" #")
                }
                scalars[key] = more.isEmpty || !continues ? text : unquote(foldLines([text] + more))
                style = .plain
            case .plain:
                // `key:` alone: a `- item` list may follow.
                let listItems = content.compactMap { parseListItem($0.text) }
                if !listItems.isEmpty, listItems.count == content.count {
                    arrays[key] = listItems.map(\.value)
                    let first = listItems[0]
                    let quote = listItems.allSatisfy { $0.quote != nil && $0.quote == first.quote }
                        ? first.quote : nil
                    style = .blockList(indent: first.indent, gap: first.gap, quote: quote)
                } else {
                    style = .empty
                }
            }

            let entryRange = NSRange(location: line.range.location,
                                     length: NSMaxRange(items.last?.range ?? line.range) - line.range.location)
            entries[key] = Entry(key: key, range: entryRange, keyLine: line.text,
                                 keyPrefix: keyPrefix, separator: separator, trailing: trailing,
                                 lineBreak: line.lineBreak, style: style)
        }

        return Frontmatter(range: match.range,
                           scalars: scalars,
                           arrays: arrays,
                           rawLines: lines.map(\.text),
                           usesCRLF: usesCRLF,
                           closingFenceRange: closing,
                           entries: entries)
    }

    // MARK: - Helpers

    private struct Line {
        let text: String
        let lineBreak: String
        let range: NSRange
    }

    /// A top-level `key:` line → (`key:` as written, unquoted key, rest).
    /// Indented lines are continuations of the key above (a block
    /// scalar's `  note: x` is text, not a key), so they never start an
    /// entry. Comments and list items do not either.
    private static func splitKey(_ line: String) -> (prefix: String, key: String, rest: String)? {
        guard let first = line.first, first != " ", first != "\t",
              first != "#", first != "-" else { return nil }
        // First `:` wins (also inside a quoted key — fine for the
        // realistic subset).
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let keyRaw = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !keyRaw.isEmpty else { return nil }
        let key = unquote(keyRaw)
        let prefix = String(line[...colon])
        let rest = String(line[line.index(after: colon)...])
        return (prefix, key, rest)
    }

    private static func isBlank(_ line: String) -> Bool {
        line.allSatisfy { $0 == " " || $0 == "\t" }
    }

    /// YAML line folding: lines join with a space, a blank line becomes a
    /// line break.
    private static func foldLines(_ lines: [String]) -> String {
        var paragraphs: [[String]] = [[]]
        for line in lines {
            if line.isEmpty { paragraphs.append([]) } else { paragraphs[paragraphs.count - 1].append(line) }
        }
        return paragraphs.map { $0.joined(separator: " ") }.joined(separator: "\n")
    }

    /// List items and indented lines belong to the key above them.
    private static func belongsToPreviousKey(_ line: String) -> Bool {
        guard let first = line.first else { return false }    // blank line ends it
        if first == " " || first == "\t" {
            return !line.trimmingCharacters(in: .whitespaces).isEmpty
        }
        return line == "-" || line.hasPrefix("- ")
    }

    private struct ListItem {
        let value: String
        let indent: String
        let gap: String
        let quote: Character?
    }

    private static func parseListItem(_ line: String) -> ListItem? {
        let indent = String(line.prefix { $0 == " " || $0 == "\t" })
        let rest = line.dropFirst(indent.count)
        guard rest.hasPrefix("-") else { return nil }
        let afterDash = rest.dropFirst()
        let gap = String(afterDash.prefix { $0 == " " || $0 == "\t" })
        guard !gap.isEmpty || afterDash.isEmpty else { return nil }   // `-foo` is not an item
        let body = String(afterDash.dropFirst(gap.count))
        let (value, _) = scanValue(body)
        switch value {
        case .doubleQuoted(let text): return ListItem(value: text, indent: indent, gap: gap, quote: "\"")
        case .singleQuoted(let text): return ListItem(value: text, indent: indent, gap: gap, quote: "'")
        case .plain(let text): return ListItem(value: text, indent: indent, gap: gap, quote: nil)
        case .inlineArray(let raw, _): return ListItem(value: raw, indent: indent, gap: gap, quote: nil)
        case .blockScalarIndicator: return ListItem(value: body, indent: indent, gap: gap, quote: nil)
        }
    }

    private enum ScannedValue {
        case plain(String)
        case doubleQuoted(String)
        case singleQuoted(String)
        /// `raw` includes the brackets.
        case inlineArray(raw: String, quote: Character?)
        case blockScalarIndicator(folded: Bool)
    }

    /// Split the text after `key: ` into the value and what trails it
    /// (spaces and a comment).
    private static func scanValue(_ text: String) -> (ScannedValue, trailing: String) {
        let chars = Array(text)
        guard let first = chars.first else { return (.plain(""), "") }

        func rest(from i: Int) -> String { String(chars[i...]) }
        func isTrailing(_ s: String) -> Bool {
            let t = s.trimmingCharacters(in: .whitespaces)
            return t.isEmpty || t.hasPrefix("#")
        }

        switch first {
        case "\"":
            if let end = closingDoubleQuote(in: chars, from: 1), isTrailing(rest(from: end + 1)) {
                return (.doubleQuoted(unescapeDoubleQuoted(String(chars[1..<end]))), rest(from: end + 1))
            }
        case "'":
            if let end = closingSingleQuote(in: chars, from: 1), isTrailing(rest(from: end + 1)) {
                let inner = String(chars[1..<end]).replacingOccurrences(of: "''", with: "'")
                return (.singleQuoted(inner), rest(from: end + 1))
            }
        case "[":
            if let end = closingBracket(in: chars), isTrailing(rest(from: end + 1)) {
                let raw = String(chars[0...end])
                let items = splitInlineItems(String(chars[1..<end]))
                let firstQuote = items.first?.first
                let quote: Character? = (firstQuote == "\"" || firstQuote == "'")
                    && items.allSatisfy({ $0.first == firstQuote }) ? firstQuote : nil
                return (.inlineArray(raw: raw, quote: quote), rest(from: end + 1))
            }
        case "|", ">":
            // `|`, `|-`, `>+`, `|2` … followed by nothing but a comment.
            let indicator = chars.prefix { !$0.isWhitespace }
            if indicator.dropFirst().allSatisfy({ "+-0123456789".contains($0) }),
               isTrailing(rest(from: indicator.count)) {
                return (.blockScalarIndicator(folded: first == ">"), rest(from: indicator.count))
            }
        default:
            break
        }

        // Plain scalar: a comment starts at whitespace + `#`.
        var end = chars.count
        if first == "#" {
            end = 0
        } else {
            for i in 1..<chars.count where chars[i] == "#" && (chars[i - 1] == " " || chars[i - 1] == "\t") {
                end = i - 1
                break
            }
        }
        var valueEnd = end
        while valueEnd > 0, chars[valueEnd - 1] == " " || chars[valueEnd - 1] == "\t" { valueEnd -= 1 }
        return (.plain(String(chars[0..<valueEnd])), rest(from: valueEnd))
    }

    private static func closingDoubleQuote(in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "\\" { i += 2; continue }
            if chars[i] == "\"" { return i }
            i += 1
        }
        return nil
    }

    private static func closingSingleQuote(in chars: [Character], from start: Int) -> Int? {
        var i = start
        while i < chars.count {
            if chars[i] == "'" {
                if i + 1 < chars.count, chars[i + 1] == "'" { i += 2; continue }
                return i
            }
            i += 1
        }
        return nil
    }

    /// Index of the `]` closing the array that starts at 0, skipping
    /// brackets inside quoted items. A quote opens a quoted item only as
    /// the item's first character (YAML's rule): the `'` in `don't` is
    /// part of a plain item.
    private static func closingBracket(in chars: [Character]) -> Int? {
        var i = 1
        var atItemStart = true
        while i < chars.count {
            switch chars[i] {
            case " ", "\t":
                break
            case "\"" where atItemStart:
                guard let end = closingDoubleQuote(in: chars, from: i + 1) else { return nil }
                i = end
                atItemStart = false
            case "'" where atItemStart:
                guard let end = closingSingleQuote(in: chars, from: i + 1) else { return nil }
                i = end
                atItemStart = false
            case ",":
                atItemStart = true
            case "]":
                return i
            default:
                atItemStart = false
            }
            i += 1
        }
        return nil
    }

    /// Items of an inline array body, split on commas outside quoted
    /// items, still quoted and trimmed. Quotes count only at an item's
    /// start, as in `closingBracket`.
    private static func splitInlineItems(_ body: String) -> [String] {
        let chars = Array(body)
        var items: [String] = []
        var start = 0
        var i = 0
        var atItemStart = true
        while i < chars.count {
            switch chars[i] {
            case " ", "\t":
                break
            case "\"" where atItemStart:
                i = closingDoubleQuote(in: chars, from: i + 1) ?? chars.count
                atItemStart = false
            case "'" where atItemStart:
                i = closingSingleQuote(in: chars, from: i + 1) ?? chars.count
                atItemStart = false
            case ",":
                items.append(String(chars[start..<i]))
                start = i + 1
                atItemStart = true
            default:
                atItemStart = false
            }
            i += 1
        }
        items.append(String(chars[min(start, chars.count)...]))
        // `[]`, `[a,,b]` and a trailing comma yield no empty item.
        return items.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parseInlineArray(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return splitInlineItems(s).map(unquote)
    }

    /// Remove one pair of surrounding quotes and resolve the escapes of
    /// that quote style: `\"`, `\\`, `\n`, `\t`, `\uXXXX` in double
    /// quotes, `''` in single quotes.
    static func unquote(_ raw: String) -> String {
        guard raw.count >= 2 else { return raw }
        if raw.hasPrefix("\""), raw.hasSuffix("\"") {
            return unescapeDoubleQuoted(String(raw.dropFirst().dropLast()))
        }
        if raw.hasPrefix("'"), raw.hasSuffix("'") {
            return String(raw.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        return raw
    }

    private static func unescapeDoubleQuoted(_ inner: String) -> String {
        var out = ""
        var chars = inner.makeIterator()
        while let c = chars.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = chars.next() else { out.append("\\"); break }
            switch e {
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            case "0": out.append("\0")
            case "\"", "\\", "/": out.append(e)
            case "u", "x":
                let count = e == "u" ? 4 : 2
                var hex = ""
                for _ in 0..<count { if let h = chars.next() { hex.append(h) } }
                if hex.count == count, let value = UInt32(hex, radix: 16),
                   let scalar = Unicode.Scalar(value) {
                    out.unicodeScalars.append(scalar)
                } else {
                    out.append("\\"); out.append(e); out.append(contentsOf: hex)
                }
            default:
                out.append("\\"); out.append(e)
            }
        }
        return out
    }
}
