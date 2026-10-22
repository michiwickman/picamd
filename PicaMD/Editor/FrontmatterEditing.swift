import Foundation

/// Writing the inspector's three fields back into the YAML front matter.
///
/// Every write is a line-level `TextEdit`: only the lines of the edited
/// key change. Unknown keys, comments, key order, blank lines,
/// indentation and the line-break style stay byte-identical, and the
/// value keeps the quoting / list style it was written in. CRLF files
/// are written with CRLF (each replaced line keeps its own line break),
/// so they stay editable instead of being locked.
extension Frontmatter {

    enum Field: Equatable, Sendable, CaseIterable {
        case title, date, tags

        /// The Edit menu's "Undo Edit Title".
        var undoActionName: String {
            switch self {
            case .title: return "Edit Title"
            case .date: return "Edit Date"
            case .tags: return "Edit Tags"
            }
        }

        /// Keys the field is read from, in priority order.
        var keys: [String] {
            switch self {
            case .title: return Frontmatter.titleKeys
            case .date: return Frontmatter.dateKeys
            case .tags: return ["tags"]
            }
        }

        /// A value YAML would read as a number, boolean or null is quoted
        /// for titles and tags. Dates stay plain: `2026-10-03` is meant as
        /// a date.
        fileprivate var quotesTypedValues: Bool { self != .date }
    }

    // MARK: - Locks

    /// Why `field` can't be written in `source`, or nil when it can.
    static func lockReason(for field: Field, in source: String) -> String? {
        lockReason(for: field, in: source, frontmatter: build(from: source))
    }

    /// As above, with the source's already parsed front matter.
    static func lockReason(for field: Field, in source: String, frontmatter fm: Frontmatter) -> String? {
        if fm.range == nil {
            // A first line of `---` that opens no front matter: a block
            // being typed (no closing fence yet, or a line YAML can't
            // hold), or a horizontal rule above prose. A new block on top
            // would leave the half-typed one below it, so don't guess.
            let firstLine = (source as NSString).lineRange(for: NSRange(location: 0, length: 0))
            let text = (source as NSString).substring(with: firstLine)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            return text == "---"
                ? "The first line is --- but no front matter block follows; edit it in the text."
                : nil
        }
        if let entry = fm.entries[fm.writeKey(for: field)], entry.isNestedMap {
            return "“\(entry.key)” holds nested values; edit it in the text."
        }
        return nil
    }

    // MARK: - Write

    /// Set `field` to `newValue` (for `.tags` a comma-separated list).
    /// An empty value removes the key line; the block stays. Without a
    /// front matter block, a non-empty value inserts one at the top.
    /// - Returns: nil when nothing would change or the field is locked.
    static func edit(source: String, field: Field, newValue: String) -> TextEdit? {
        if field == .tags {
            return edit(source: source, tags: newValue.split(separator: ",").map(String.init))
        }
        guard lockReason(for: field, in: source) == nil else { return nil }
        let value = singleLine(newValue)
        let fm = build(from: source)
        let current = field == .title ? fm.title : fm.date
        guard value != (current ?? "") else { return nil }

        let key = fm.writeKey(for: field)
        let reads: (Frontmatter) -> String? = { field == .title ? $0.title : $0.date }
        guard let entry = fm.entries[key] else {
            return firstRoundTrip([render(value, style: .plain, field: field), doubleQuoted(value)].map {
                insert(line: "\(key): \($0)", into: fm, source: source)
            }, source: source) { reads($0) == value }
        }
        if value.isEmpty { return remove(entry, source: source) }
        return firstRoundTrip([render(value, style: entry.style, field: field), doubleQuoted(value)].map {
            replace(entry, with: entry.keyPrefix + entry.valueSeparator + $0
                    + entry.trailingText + entry.lineBreak, source: source)
        }, source: source) { reads($0) == value }
    }

    /// Replace the tag list. Empty strings and repeats are dropped; an
    /// empty list removes the key.
    static func edit(source: String, tags newTags: [String]) -> TextEdit? {
        guard lockReason(for: .tags, in: source) == nil else { return nil }
        let tags = normalizedTags(newTags)
        let fm = build(from: source)
        guard tags != fm.tags else { return nil }

        // The inline array fallbacks: plain items where YAML allows it,
        // then every item double-quoted, which always reads back.
        let fallbacks = [inlineArray(tags, quote: nil), inlineArray(tags, quote: "\"")]
        guard let entry = fm.entries["tags"] else {
            return firstRoundTrip(fallbacks.map { insert(line: "tags: " + $0, into: fm, source: source) },
                                  source: source) { $0.tags == tags }
        }
        if tags.isEmpty { return remove(entry, source: source) }

        func valueLine(_ value: String) -> String {
            entry.keyPrefix + entry.valueSeparator + value + entry.trailingText + entry.lineBreak
        }
        var candidates: [String]
        switch entry.style {
        case .inlineArray(let quote):
            candidates = [valueLine(inlineArray(tags, quote: quote))]
        case .blockList(let indent, let gap, let quote):
            let lineBreak = entry.lineBreak.isEmpty ? "\n" : entry.lineBreak
            candidates = [quote, "\""].map { quote in
                entry.keyLine + lineBreak + tags.map {
                    indent + "-" + (gap.isEmpty ? " " : gap) + item($0, quote: quote) + lineBreak
                }.joined()
            }
        case .plain, .singleQuoted, .doubleQuoted, .blockScalar:
            // `tags: a, b` — a comma list in one scalar. A tag with a
            // comma, or a bracket or quote where the list reader takes it
            // for syntax, fails the read-back and becomes an inline array.
            candidates = [valueLine(render(tags.joined(separator: ", "), style: entry.style, field: .tags))]
        case .empty:
            candidates = []
        }
        candidates += fallbacks.map(valueLine)
        return firstRoundTrip(candidates.map { replace(entry, with: $0, source: source) },
                              source: source) { $0.tags == tags }
    }

    /// The first edit whose result reads back as intended. The quoting
    /// rules cover the common cases; this check catches the rest (a tag
    /// like `]` in a comma list) instead of writing a value that silently
    /// changes on the next read.
    private static func firstRoundTrip(_ edits: [TextEdit], source: String,
                                       reads: (Frontmatter) -> Bool) -> TextEdit? {
        edits.first { edit in
            let result = (source as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
            return reads(build(from: result))
        }
    }

    // MARK: - Key resolution

    /// The key a write goes to: the one the value is read from, else an
    /// existing alias line (`title:` with no value), else the field's
    /// first key.
    func writeKey(for field: Field) -> String {
        switch field {
        case .title: if let key = titleKey { return key }
        case .date: if let key = dateKey { return key }
        case .tags: return "tags"
        }
        return field.keys.first { entries[$0] != nil } ?? field.keys[0]
    }

    // MARK: - Edits

    private static func replace(_ entry: Entry, with text: String, source: String) -> TextEdit {
        TextEdit(range: entry.range, replacement: text,
                 expected: (source as NSString).substring(with: entry.range))
    }

    private static func remove(_ entry: Entry, source: String) -> TextEdit {
        replace(entry, with: "", source: source)
    }

    /// A new key goes last in the block, in front of the closing fence
    /// (which the edit covers, so the stale-range guard has text to
    /// check). Without a block, a new one goes at the very top.
    private static func insert(line: String, into fm: Frontmatter, source: String) -> TextEdit {
        let ns = source as NSString
        if let closing = fm.closingFenceRange {
            let lineBreak = fm.usesCRLF ? "\r\n" : "\n"
            let fence = ns.substring(with: closing)
            return TextEdit(range: closing, replacement: line + lineBreak + fence, expected: fence)
        }
        let lineBreak = usesCRLF(source) ? "\r\n" : "\n"
        return TextEdit(range: NSRange(location: 0, length: 0),
                        replacement: "---" + lineBreak + line + lineBreak + "---" + lineBreak,
                        expected: "")
    }

    /// The document's first line break is CRLF.
    private static func usesCRLF(_ source: String) -> Bool {
        let ns = source as NSString
        let lf = ns.range(of: "\n")
        return lf.location != NSNotFound && lf.location > 0
            && ns.character(at: lf.location - 1) == 0x0D
    }

    // MARK: - Rendering values

    /// Inspector fields are single-line; a pasted line break becomes a
    /// space so a value can never spill into a second YAML line.
    private static func singleLine(_ value: String) -> String {
        value.components(separatedBy: .newlines).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    static func normalizedTags(_ tags: [String]) -> [String] {
        var seen = Set<String>()
        return tags.map(singleLine).filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// `value` in `style`; a plain value that YAML would misread gets
    /// double quotes.
    private static func render(_ value: String, style: ValueStyle, field: Field) -> String {
        switch style {
        case .singleQuoted:
            return singleQuoted(value)
        case .doubleQuoted:
            return doubleQuoted(value)
        default:
            return needsQuoting(value, quotesTypedValues: field.quotesTypedValues, inFlow: false)
                ? doubleQuoted(value) : value
        }
    }

    private static func inlineArray(_ tags: [String], quote: Character?) -> String {
        "[" + tags.map { item($0, quote: quote, inFlow: true) }.joined(separator: ", ") + "]"
    }

    /// A list item: quoted with the list's own quote when it had one.
    private static func item(_ tag: String, quote: Character?, inFlow: Bool = false) -> String {
        switch quote {
        case "'": return singleQuoted(tag)
        case "\"": return doubleQuoted(tag)
        default:
            return needsQuoting(tag, quotesTypedValues: true, inFlow: inFlow) ? doubleQuoted(tag) : tag
        }
    }

    static func doubleQuoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }

    static func singleQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }

    /// Whether a plain scalar would read back as something else.
    static func needsQuoting(_ value: String, quotesTypedValues: Bool, inFlow: Bool) -> Bool {
        guard let first = value.first, let last = value.last else { return true }
        if first.isWhitespace || last.isWhitespace { return true }
        if value.contains(": ") || value.hasSuffix(":") || value.contains(" #")
            || value.contains("\t") { return true }
        if "[]{}#&*!|>'\"%@`,".contains(first) { return true }
        if ["-", "?", ":"].contains(value) || value.hasPrefix("- ") || value.hasPrefix("? ")
            || value.hasPrefix(": ") { return true }
        if inFlow, value.contains(where: { ",[]{}".contains($0) }) { return true }
        if quotesTypedValues {
            let reserved: Set<String> = ["true", "false", "yes", "no", "on", "off",
                                         "y", "n", "null", "~"]
            if reserved.contains(value.lowercased()) || Double(value) != nil { return true }
        }
        return false
    }
}

private extension Frontmatter.Entry {
    /// The whitespace after the colon, or one space when there was none
    /// (`title:` with no value).
    var valueSeparator: String { separator.isEmpty ? " " : separator }

    /// The comment after the value, separated by a space.
    var trailingText: String {
        guard let first = trailing.first else { return "" }
        return first == " " || first == "\t" ? trailing : " " + trailing
    }

    /// `key:` with indented, non-list lines below: a nested map the
    /// inspector can't represent.
    var isNestedMap: Bool {
        style == .empty && range.length > (keyLine as NSString).length + (lineBreak as NSString).length
    }
}
