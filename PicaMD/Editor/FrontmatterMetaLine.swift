import Foundation

/// When the editor collapses the YAML block, and the one grey line it
/// shows instead ("October 3, 2026 · travel, portugal").
///
/// Pure functions only; `SyntaxHighlighter` reserves the line's height
/// (in the block's place, or under an H1 that follows the block) and
/// `PicaMDTextView` draws the text.
enum FrontmatterFold {
    /// The block is collapsed unless the selection starts inside it, the
    /// same way the caret line reveals its raw Markdown. A caret right
    /// after the closing fence's line break is outside. A caret at the
    /// very end of a document that ends on the closing fence itself (no
    /// line break) counts as inside: collapsing there would leave it
    /// typing onto an invisible `---`.
    /// `NSNotFound` (a table cell editor owns the caret) collapses.
    static func isFolded(selection: NSRange, block: NSRange, in source: NSString) -> Bool {
        guard selection.location != NSNotFound else { return true }
        let end = NSMaxRange(block)
        if selection.location < end { return false }
        if selection.location == end, end == source.length, !endsWithLineBreak(block, in: source) {
            return false
        }
        return true
    }

    /// The caret a freshly opened document starts with: moved behind the
    /// block when it would otherwise open the YAML, onto the first line
    /// that isn't blank. A blank line usually separates the block from
    /// the H1; a caret left on it sits above the title (the folded block
    /// takes no height), and the outline, which marks the heading at or
    /// above the caret, would mark nothing.
    static func initialSelection(_ selection: NSRange, block: NSRange?, in source: NSString) -> NSRange {
        guard let block, !isFolded(selection: selection, block: block, in: source) else {
            return selection
        }
        var location = NSMaxRange(block)
        while location < source.length {
            let line = source.lineRange(for: NSRange(location: location, length: 0))
            if !source.substring(with: line).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return NSRange(location: location, length: 0)
            }
            location = NSMaxRange(line)
        }
        // Nothing but blank lines behind the block: stay right behind it.
        return NSRange(location: NSMaxRange(block), length: 0)
    }

    /// Delete commands that remove text in front of an empty selection.
    static let backwardDeleteCommands: Set<String> = [
        "deleteBackward:", "deleteBackwardByDecomposingPreviousCharacter:",
        "deleteWordBackward:", "deleteToBeginningOfLine:", "deleteToBeginningOfParagraph:",
    ]

    /// Where to put the caret instead of running a backward delete, or
    /// nil to let it run. Right behind a folded block the character in
    /// front of the caret is the closing fence's hidden line break;
    /// deleting it would glue the first body line onto `---` and destroy
    /// the front matter without anything visible changing. The caret
    /// moves onto the fence instead, which opens the block, so the next
    /// delete happens in plain sight.
    static func caretInsteadOfDeleting(command: String, selection: NSRange,
                                       foldedBlock: NSRange?, in source: NSString) -> NSRange? {
        guard backwardDeleteCommands.contains(command), selection.length == 0,
              let block = foldedBlock, block.length > 0,
              selection.location == NSMaxRange(block), NSMaxRange(block) <= source.length,
              endsWithLineBreak(block, in: source) else { return nil }
        let lastLine = source.lineRange(for: NSRange(location: NSMaxRange(block) - 1, length: 0))
        var contentsEnd = 0
        source.getLineStart(nil, end: nil, contentsEnd: &contentsEnd, for: lastLine)
        return NSRange(location: contentsEnd, length: 0)
    }

    private static func endsWithLineBreak(_ block: NSRange, in source: NSString) -> Bool {
        guard block.length > 0, NSMaxRange(block) <= source.length else { return false }
        return source.character(at: NSMaxRange(block) - 1) == 0x0A
    }
}

enum FrontmatterMetaLine {
    /// Shown when the block has none of the three fields.
    static let placeholder = "Front matter"

    /// "Title · October 3, 2026 · travel, portugal". The title is left
    /// out when it repeats the document's first H1 (an H1 right after the
    /// block has the line drawn directly under it).
    static func text(for frontmatter: Frontmatter, firstHeading: String?,
                     locale: Locale = .current) -> String {
        var parts: [String] = []
        if let title = frontmatter.title?.trimmingCharacters(in: .whitespaces), !title.isEmpty,
           !sameText(title, firstHeading) {
            parts.append(title)
        }
        if let date = frontmatter.date?.trimmingCharacters(in: .whitespaces), !date.isEmpty {
            parts.append(formattedDate(date, locale: locale))
        }
        if !frontmatter.tags.isEmpty {
            parts.append(frontmatter.tags.joined(separator: ", "))
        }
        return parts.isEmpty ? placeholder : parts.joined(separator: " · ")
    }

    private static func sameText(_ a: String, _ b: String?) -> Bool {
        guard let b else { return false }
        let collapse = { (s: String) in
            s.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        return collapse(a).compare(collapse(b), options: [.caseInsensitive]) == .orderedSame
    }

    // MARK: - Dates

    /// `2026-10-03` → "October 3, 2026" in `locale`; with a time
    /// (`2026-10-03 14:20`, `2026-10-03T14:20:00+02:00`) the time follows,
    /// as written (no conversion to the Mac's time zone). Anything else
    /// comes back unchanged.
    static func formattedDate(_ raw: String, locale: Locale = .current) -> String {
        guard let parsed = parseDate(raw) else { return raw }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = parsed.timeZone
        calendar.locale = locale
        let style = Date.FormatStyle(date: .long, time: parsed.hasTime ? .shortened : .omitted,
                                     locale: locale, calendar: calendar, timeZone: parsed.timeZone)
        return parsed.date.formatted(style)
    }

    private static let dateRegex = try! NSRegularExpression(
        pattern: #"^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?[ ]*(Z|[+-]\d{2}:?\d{2})?)?$"#
    )

    static func parseDate(_ raw: String) -> (date: Date, hasTime: Bool, timeZone: TimeZone)? {
        let text = raw.trimmingCharacters(in: .whitespaces)
        let ns = text as NSString
        guard let m = dateRegex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length))
        else { return nil }
        func int(_ i: Int) -> Int? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : Int(ns.substring(with: r))
        }
        var timeZone = TimeZone(identifier: "UTC")!
        let zoneRange = m.range(at: 7)
        if zoneRange.location != NSNotFound {
            let zone = ns.substring(with: zoneRange)
            if zone != "Z" {
                let digits = zone.dropFirst().filter(\.isNumber)
                let hours = Int(digits.prefix(2)) ?? 0
                let minutes = Int(digits.suffix(2)) ?? 0
                let seconds = (hours * 3600 + minutes * 60) * (zone.hasPrefix("-") ? -1 : 1)
                guard let tz = TimeZone(secondsFromGMT: seconds) else { return nil }
                timeZone = tz
            }
        }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let components = DateComponents(year: int(1), month: int(2), day: int(3),
                                        hour: int(4) ?? 0, minute: int(5) ?? 0, second: int(6) ?? 0)
        guard let date = calendar.date(from: components) else { return nil }
        // Reject dates the calendar rolled over (2026-02-30 → March 2).
        let back = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        guard back.year == components.year, back.month == components.month,
              back.day == components.day, back.hour == components.hour,
              back.minute == components.minute else { return nil }
        return (date, int(4) != nil, timeZone)
    }

    // MARK: - First heading

    /// Text of the first `# ` heading at or after `location`, outside the
    /// `protected` ranges (code, math), as the outline shows it.
    static func firstH1(in source: String, from location: Int,
                        skipping protected: [NSRange]) -> String? {
        let ns = source as NSString
        guard location < ns.length else { return nil }
        var result: String?
        MarkdownRegexes.heading.enumerateMatches(
            in: source, range: NSRange(location: location, length: ns.length - location)
        ) { match, _, stop in
            guard let match, match.range(at: 1).length == 1 else { return }
            if protected.contains(where: { NSLocationInRange(match.range.location, $0) }) { return }
            result = HeadingExtractor.plainText(from: ns.substring(with: match.range(at: 3)))
            stop.pointee = true
        }
        return result
    }
}
