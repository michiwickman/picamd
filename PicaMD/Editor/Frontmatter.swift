import Foundation

/// Lightweight parser for the `---\n…\n---\n` YAML frontmatter block
/// at the top of a markdown document. Supports the small subset
/// PicaMD's frontmatter bar needs: scalar key/value pairs, inline
/// `[a, b, c]` arrays, and tag-style YAML lists rendered as
/// `tags:\n  - foo\n  - bar`. Anything fancier (nested maps, anchors)
/// stays untouched in `rawLines` so the user's source isn't lossy.
///
/// Pulling in Yams or another full YAML parser would mean dragging a
/// CocoaPods/SPM dependency into the lean bundle for a feature that
/// only needs to show three fields. The minimal parser below is ~80
/// LOC and passes the realistic frontmatter formats PicaMD users
/// actually write.
struct Frontmatter: Equatable {
    /// Range of the entire frontmatter block (incl. the fences) in
    /// the source document. `nil` if no frontmatter is present.
    let range: NSRange?
    /// Single-line scalar values keyed by their YAML key.
    let scalars: [String: String]
    /// Array values keyed by their YAML key. Order preserved.
    let arrays: [String: [String]]
    /// Original lines between the fences, preserved verbatim — used
    /// by the edit sheet so unsupported keys round-trip.
    let rawLines: [String]

    static let empty = Frontmatter(range: nil, scalars: [:], arrays: [:], rawLines: [])

    // MARK: - Convenience accessors used by the bar

    /// `title:` — falls back to `name:` (some users prefer it).
    var title: String? {
        scalars["title"] ?? scalars["name"]
    }
    /// `date:` — falls back to `created:` / `updated:`.
    var date: String? {
        scalars["date"] ?? scalars["created"] ?? scalars["updated"]
    }
    /// Tags from either an inline `[a, b]` array or a `-` list.
    var tags: [String] {
        if let arr = arrays["tags"] { return arr }
        if let inline = scalars["tags"] {
            return Self.parseInlineArray(inline)
        }
        return []
    }

    // MARK: - Build

    // Compiled once at type-load time. Using `try!` here is intentional:
    // a regex syntax error is a programmer error caught at startup, not a
    // recoverable runtime condition. This follows the SyntaxHighlighter
    // convention for static regex constants.
    private static let fenceRegex: NSRegularExpression = {
        // Match the fenced block. The highlighter's regex demands a
        // trailing `\n` after the closing `---`, but we want to also
        // accept end-of-document (so a doc that's *just* frontmatter,
        // and Swift multi-line string literals which strip the final
        // newline, still parse). Capture group 1 is the body lines
        // between the fences.
        // `\n?` between the body and the closing fence handles the
        // empty-block case (`---\n---\n`) where there is no body — the
        // separator newline collapses too.
        try! NSRegularExpression(pattern: #"\A---\n([\s\S]*?)\n?---(?:\n|$)"#)
    }()

    /// Parse the leading frontmatter, if any. Order of operations:
    /// 1. Detect the fenced block via the same regex the highlighter
    ///    uses (`\A---\n[\s\S]*?\n---\n`).
    /// 2. Walk lines between the fences, classifying each as scalar,
    ///    inline-array, or list-item-belonging-to-previous-key.
    static func build(from source: String) -> Frontmatter {
        let nsSource = source as NSString
        guard let match = Self.fenceRegex.firstMatch(in: source,
                                                     options: [],
                                                     range: NSRange(location: 0, length: nsSource.length))
        else {
            return .empty
        }
        let bodyRange = match.range(at: 1)
        let body = bodyRange.location == NSNotFound
            ? ""
            : nsSource.substring(with: bodyRange)
        let lines: [String] = body.components(separatedBy: "\n")

        var scalars: [String: String] = [:]
        var arrays: [String: [String]] = [:]
        var currentArrayKey: String?

        for raw in lines {
            // Continuation of a YAML list under a previous key:
            //   tags:
            //     - foo
            //     - bar
            if let key = currentArrayKey,
               let item = parseListItem(raw) {
                arrays[key, default: []].append(item)
                continue
            }
            currentArrayKey = nil   // list ended

            // `key: value` or `key: [a, b, c]` or `key:` (start of a list)
            guard let (key, valueRaw) = splitKeyValue(raw) else { continue }
            let value = valueRaw.trimmingCharacters(in: CharacterSet.whitespaces)
            if value.isEmpty {
                // Empty value → expect a `- item` list to follow on the next lines.
                currentArrayKey = key
            } else if value.hasPrefix("[") && value.hasSuffix("]") {
                arrays[key] = parseInlineArray(value)
            } else {
                scalars[key] = unquote(value)
            }
        }

        return Frontmatter(range: match.range,
                           scalars: scalars,
                           arrays: arrays,
                           rawLines: lines)
    }

    // MARK: - Helpers

    private static func splitKeyValue(_ line: String) -> (key: String, value: String)? {
        // Don't split on `:` that's inside quotes — but for the small
        // subset we support this is fine: first `:` wins.
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let keyRaw = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
        guard !keyRaw.isEmpty,
              !keyRaw.hasPrefix("#"),     // comment
              !keyRaw.hasPrefix("-")       // looks like a list item, not a key
        else { return nil }
        let valueRaw = String(line[line.index(after: colon)...])
        return (keyRaw, valueRaw)
    }

    private static func parseListItem(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- ") else { return nil }
        let body = String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
        return unquote(body)
    }

    static func parseInlineArray(_ raw: String) -> [String] {
        var s = raw.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("[") { s.removeFirst() }
        if s.hasSuffix("]") { s.removeLast() }
        return s.split(separator: ",").map {
            unquote($0.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func unquote(_ raw: String) -> String {
        if (raw.hasPrefix("\"") && raw.hasSuffix("\"")) ||
           (raw.hasPrefix("'")  && raw.hasSuffix("'")) {
            return String(raw.dropFirst().dropLast())
        }
        return raw
    }
}
