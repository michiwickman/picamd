import Foundation

/// The inline styles of Format ▸ Bold, Italic, Strikethrough and Inline Code.
enum InlineStyle: CaseIterable, Sendable {
    case bold, italic, strikethrough, code

    /// The marker a toggle writes. Bold and italic also recognise the
    /// underscore spellings (`__x__`, `_x_`) when toggling off.
    var marker: String {
        switch self {
        case .bold: return "**"
        case .italic: return "*"
        case .strikethrough: return "~~"
        case .code: return "`"
        }
    }

    /// The characters a span of this style can be written with.
    fileprivate var markerCharacters: [unichar] {
        switch self {
        case .bold, .italic: return [Self.asterisk, Self.underscore]
        case .strikethrough: return [Self.tilde]
        case .code: return [Self.backtick]
        }
    }

    /// How many marker characters to remove on each side when a span is
    /// wrapped in runs of `left` and `right` marker characters, or nil
    /// when the runs don't make this style. `***x***` is bold and italic:
    /// italic takes one asterisk away, bold two.
    fileprivate func removalCount(left: Int, right: Int) -> Int? {
        let n = min(left, right)
        switch self {
        case .bold, .strikethrough: return n >= 2 ? 2 : nil
        case .italic: return n % 2 == 1 ? 1 : nil
        case .code: return n >= 1 ? n : nil
        }
    }

    /// Opening and closing markers for `content`. Code that itself holds
    /// backticks gets a longer fence, padded with a space where the
    /// content starts or ends with a backtick (CommonMark code spans).
    fileprivate func markers(around content: String) -> (open: String, close: String) {
        guard self == .code else { return (marker, marker) }
        var longest = 0, current = 0
        for ch in content {
            if ch == "`" { current += 1; longest = max(longest, current) } else { current = 0 }
        }
        let fence = String(repeating: "`", count: longest + 1)
        let pad = content.hasPrefix("`") || content.hasSuffix("`") ? " " : ""
        return (fence + pad, pad + fence)
    }

    /// The editor's own span patterns: group 1 is the opening marker,
    /// group 2 the content, and the closing marker repeats group 1.
    fileprivate var spanPatterns: [NSRegularExpression] {
        switch self {
        case .bold: return [MarkdownRegexes.bold]
        case .italic: return [MarkdownRegexes.italic]
        case .strikethrough: return [MarkdownRegexes.strikethrough]
        case .code: return [MarkdownRegexes.inlineCode]
        }
    }

    fileprivate static let asterisk = unichar(UInt8(ascii: "*"))
    fileprivate static let underscore = unichar(UInt8(ascii: "_"))
    fileprivate static let tilde = unichar(UInt8(ascii: "~"))
    fileprivate static let backtick = unichar(UInt8(ascii: "`"))
}

/// Format ▸ Bold … Table as pure text transforms, in the style of the
/// heading and move-line edits above: `(text, selection)` in, the new
/// state out. Line handling uses `getLineStart`, so CRLF documents keep
/// their line breaks.
extension MarkdownEdits {

    // MARK: - Inline styles

    /// Toggle `style` on the selection, or on the word at the caret.
    ///
    /// - Already styled (markers just outside the selection, or selected
    ///   with it): the markers go. A caret anywhere inside a styled span
    ///   removes that span's markers. A selection that touches several
    ///   spans (`**Note:** text **important**`) or only part of one loses
    ///   the markers of each span it touches; a second toggle then styles
    ///   it as a whole.
    /// - Otherwise the selection (or word) is wrapped. A caret outside
    ///   any word gets an empty pair with the caret in between.
    /// - A selection over several lines is styled line by line, skipping
    ///   list bullets, quote markers, heading hashes and outer spaces;
    ///   markers can't span a line break. When every line already has the
    ///   style it is removed from all of them.
    static func toggleInline(_ style: InlineStyle, in text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        if sel.length == 0 {
            return toggleInlineAtCaret(style, in: ns, caret: sel.location)
        }
        let segments = inlineSegments(of: sel, in: ns)
        guard !segments.isEmpty else { return Result(text: text, selection: sel) }
        // Per segment, the marker pairs that style it: the one span it is
        // wrapped in, else every span it touches, else none.
        let existing: [[(open: NSRange, close: NSRange)]] = segments.map { segment in
            if let wrap = wrapping(of: style, around: segment.range, in: ns, line: segment.line) {
                return [wrap]
            }
            return spans(of: style, touching: segment.range, in: ns, line: segment.line)
        }
        let removing = existing.allSatisfy { !$0.isEmpty }

        var edits: [(range: NSRange, replacement: String)] = []
        var contents: [NSRange] = []
        var delta = 0
        for (segment, pairs) in zip(segments, existing) {
            let seg = segment.range
            if removing {
                let markers = pairs.flatMap { [$0.open, $0.close] }
                // Marker characters removed in front of `position`; a
                // selection edge inside a marker moves to its start.
                func removed(before position: Int) -> Int {
                    markers.reduce(0) { $0 + max(0, min(NSMaxRange($1), position) - $1.location) }
                }
                let start = seg.location - removed(before: seg.location)
                let end = NSMaxRange(seg) - removed(before: NSMaxRange(seg))
                for marker in markers { edits.append((marker, "")) }
                contents.append(NSRange(location: start + delta, length: end - start))
                delta -= markers.reduce(0) { $0 + $1.length }
            } else if pairs.isEmpty {
                let markers = style.markers(around: ns.substring(with: seg))
                let openLength = (markers.open as NSString).length
                edits.append((NSRange(location: seg.location, length: 0), markers.open))
                edits.append((NSRange(location: NSMaxRange(seg), length: 0), markers.close))
                contents.append(NSRange(location: seg.location + delta + openLength, length: seg.length))
                delta += openLength + (markers.close as NSString).length
            } else {
                // Styled already, in a selection where other lines aren't:
                // only those get the markers.
                contents.append(NSRange(location: seg.location + delta, length: seg.length))
            }
        }
        let newText = applying(edits, to: ns)
        let first = contents[0], last = contents[contents.count - 1]
        let newSelection = NSRange(location: first.location, length: NSMaxRange(last) - first.location)
        return Result(text: newText, selection: clamp(newSelection, in: newText))
    }

    private static func toggleInlineAtCaret(_ style: InlineStyle, in ns: NSString, caret: Int) -> Result {
        let line = lineContent(at: caret, in: ns)

        // 1. Inside a span of this style: unwrap it.
        if let span = enclosingSpan(of: style, at: caret, in: ns, line: line) {
            let newText = applying([(span.open, ""), (span.close, "")], to: ns)
            let newCaret: Int
            if caret <= NSMaxRange(span.open) {
                newCaret = span.open.location
            } else if caret <= span.close.location {
                newCaret = caret - span.open.length
            } else {
                newCaret = span.close.location - span.open.length
            }
            return Result(text: newText, selection: NSRange(location: newCaret, length: 0))
        }

        let markers = style.markers(around: "")
        let open = markers.open as NSString, close = markers.close as NSString

        // 2. Between an empty pair (`**|**`): take it out again.
        if caret - open.length >= line.location, caret + close.length <= NSMaxRange(line),
           ns.substring(with: NSRange(location: caret - open.length, length: open.length)) == markers.open,
           ns.substring(with: NSRange(location: caret, length: close.length)) == markers.close,
           !isMarker(ns, at: caret - open.length - 1, of: style, within: line),
           !isMarker(ns, at: caret + close.length, of: style, within: line) {
            let pair = NSRange(location: caret - open.length, length: open.length + close.length)
            let newText = applying([(pair, "")], to: ns)
            return Result(text: newText, selection: NSRange(location: pair.location, length: 0))
        }

        // 3. The word at the caret.
        if let word = wordRange(at: caret, in: ns, line: line) {
            if let wrap = wrapping(of: style, around: word, in: ns, line: line) {
                let newText = applying([(wrap.open, ""), (wrap.close, "")], to: ns)
                return Result(text: newText,
                              selection: NSRange(location: caret - wrap.open.length, length: 0))
            }
            let wordMarkers = style.markers(around: ns.substring(with: word))
            let openLength = (wordMarkers.open as NSString).length
            let newText = applying([(NSRange(location: word.location, length: 0), wordMarkers.open),
                                    (NSRange(location: NSMaxRange(word), length: 0), wordMarkers.close)],
                                   to: ns)
            return Result(text: newText, selection: NSRange(location: caret + openLength, length: 0))
        }

        // 4. Nothing to style: an empty pair to type into.
        let newText = applying([(NSRange(location: caret, length: 0), markers.open + markers.close)], to: ns)
        return Result(text: newText, selection: NSRange(location: caret + open.length, length: 0))
    }

    /// The marker ranges that make `segment` styled. Markers selected
    /// along with the text (`**bold**`, or `bold**` after a toggle over
    /// several lines) are first trimmed off the segment; the runs of
    /// marker characters right around the trimmed text then decide.
    private static func wrapping(of style: InlineStyle, around segment: NSRange,
                                 in ns: NSString, line: NSRange) -> (open: NSRange, close: NSRange)? {
        if style == .code, let padded = paddedCodeSpan(around: segment, in: ns, line: line) {
            return padded
        }
        for c in style.markerCharacters {
            var start = segment.location, end = NSMaxRange(segment)
            while start < end, ns.character(at: start) == c { start += 1 }
            while end > start, ns.character(at: end - 1) == c { end -= 1 }
            guard start < end else { continue }
            let left = run(of: c, in: ns, from: start, forward: false, limit: line.location)
            let right = run(of: c, in: ns, from: end, forward: true, limit: NSMaxRange(line))
            guard let k = style.removalCount(left: left, right: right) else { continue }
            // `snake_case_name`: underscores inside a word aren't emphasis.
            if c == InlineStyle.underscore,
               isWordCharacter(ns, at: start - left - 1) || isWordCharacter(ns, at: end + right) {
                continue
            }
            // `**a** and **b**`: the markers around the text open one span
            // and close another, so stripping them would leave `a** and **b`.
            if containsClosingRun(of: c, style: style, fence: k, in: ns,
                                  from: start, to: end) {
                continue
            }
            var open = NSRange(location: start - k, length: k)
            var close = NSRange(location: end, length: k)
            if style == .code { padCodeSpan(&open, &close, in: ns) }
            return (open, close)
        }
        return nil
    }

    /// Code whose text starts or ends with a backtick, selected without
    /// its fence and padding: `` `` |`x| `` ``. Trimming backticks off the
    /// segment would cut into the code itself, so the fence is looked for
    /// right outside the segment, past one space on each side.
    private static func paddedCodeSpan(around segment: NSRange, in ns: NSString,
                                       line: NSRange) -> (open: NSRange, close: NSRange)? {
        let start = segment.location, end = NSMaxRange(segment)
        guard start - 1 >= line.location, end < NSMaxRange(line),
              ns.character(at: start - 1) == 0x20, ns.character(at: end) == 0x20 else { return nil }
        let tick = InlineStyle.backtick
        let left = run(of: tick, in: ns, from: start - 1, forward: false, limit: line.location)
        let right = run(of: tick, in: ns, from: end + 1, forward: true, limit: NSMaxRange(line))
        let k = min(left, right)
        guard k >= 1 else { return nil }
        return (NSRange(location: start - 1 - k, length: k + 1), NSRange(location: end, length: k + 1))
    }

    /// `` `` `x` `` ``: the single spaces inside a padded code span belong
    /// to the fence and go with it.
    private static func padCodeSpan(_ open: inout NSRange, _ close: inout NSRange, in ns: NSString) {
        let innerStart = NSMaxRange(open), innerEnd = close.location
        guard innerEnd - innerStart >= 3,
              ns.character(at: innerStart) == 0x20, ns.character(at: innerEnd - 1) == 0x20,
              ns.substring(with: NSRange(location: innerStart, length: innerEnd - innerStart)).contains("`")
        else { return }
        open.length += 1
        close.location -= 1
        close.length += 1
    }

    /// Whether `start..<end` holds a run of `c` that would end a span of
    /// `style` opened right before it: two or more for bold and
    /// strikethrough, an odd count for italic (an even one is bold inside
    /// the italic), the fence length for code. Underscores between two
    /// word characters (`snake_case`) don't count.
    private static func containsClosingRun(of c: unichar, style: InlineStyle, fence: Int,
                                           in ns: NSString, from start: Int, to end: Int) -> Bool {
        var i = start
        while i < end {
            guard ns.character(at: i) == c else { i += 1; continue }
            var j = i
            while j < end, ns.character(at: j) == c { j += 1 }
            let length = j - i
            let intraword = c == InlineStyle.underscore
                && isWordCharacter(ns, at: i - 1) && isWordCharacter(ns, at: j)
            if !intraword {
                switch style {
                case .bold, .strikethrough: if length >= 2 { return true }
                case .italic: if length % 2 == 1 { return true }
                case .code: if length == fence { return true }
                }
            }
            i = j
        }
        return false
    }

    /// The spans of `style` on `line` that overlap `segment`, in order.
    private static func spans(of style: InlineStyle, touching segment: NSRange, in ns: NSString,
                              line: NSRange) -> [(open: NSRange, close: NSRange)] {
        var pairs: [(open: NSRange, close: NSRange)] = []
        for regex in style.spanPatterns {
            for match in regex.matches(in: ns as String, range: line)
            where NSIntersectionRange(match.range, segment).length > 0 {
                let open = match.range(at: 1)
                let content = match.range(at: 2)
                pairs.append((open, NSRange(location: NSMaxRange(content), length: open.length)))
            }
        }
        return pairs.sorted { $0.open.location < $1.open.location }
    }

    /// A span of `style` on `line` with the caret strictly inside it.
    private static func enclosingSpan(of style: InlineStyle, at caret: Int, in ns: NSString,
                                      line: NSRange) -> (open: NSRange, close: NSRange)? {
        for regex in style.spanPatterns {
            for match in regex.matches(in: ns as String, range: line) {
                guard caret > match.range.location, caret < NSMaxRange(match.range) else { continue }
                let open = match.range(at: 1)
                let content = match.range(at: 2)
                return (open, NSRange(location: NSMaxRange(content), length: open.length))
            }
        }
        return nil
    }

    private static func isMarker(_ ns: NSString, at index: Int, of style: InlineStyle, within line: NSRange) -> Bool {
        guard index >= line.location, index < NSMaxRange(line) else { return false }
        return style.markerCharacters.contains(ns.character(at: index))
    }

    /// The parts of a selection that get markers: one per line, without
    /// the line's block prefix (indent, `>`, bullet, checkbox, `#`) and
    /// without outer spaces. Empty parts are dropped.
    private static func inlineSegments(of selection: NSRange, in ns: NSString) -> [(range: NSRange, line: NSRange)] {
        var segments: [(range: NSRange, line: NSRange)] = []
        for line in lineContents(covering: selection, in: ns) {
            var start = max(line.location, selection.location)
            var end = min(NSMaxRange(line), NSMaxRange(selection))
            let prefixEnd = line.location + blockPrefixLength(of: line, in: ns)
            if start < prefixEnd { start = prefixEnd }
            while start < end, isSpace(ns.character(at: start)) { start += 1 }
            while end > start, isSpace(ns.character(at: end - 1)) { end -= 1 }
            if start < end {
                segments.append((NSRange(location: start, length: end - start), line))
            }
        }
        return segments
    }

    /// Indent, quote markers, a list bullet with its checkbox, or heading
    /// hashes at the start of a line.
    private static let blockPrefix = try! NSRegularExpression(
        pattern: #"^[ \t]*(?:>[ \t]?)*[ \t]*(?:(?:[-*+]|\d{1,9}[.)])[ \t]+(?:\[[ xX]\][ \t]+)?|#{1,6}[ \t]+)?"#)

    private static func blockPrefixLength(of line: NSRange, in ns: NSString) -> Int {
        blockPrefix.firstMatch(in: ns as String, range: line)?.range.length ?? 0
    }

    /// The word around the caret: letters and digits, joined by `'`, `’`
    /// or `-` (`don't`, `well-known`). Markup characters end a word.
    private static func wordRange(at caret: Int, in ns: NSString, line: NSRange) -> NSRange? {
        func isPart(_ range: NSRange) -> Bool {
            guard let ch = ns.substring(with: range).first else { return false }
            return ch.isLetter || ch.isNumber || ch == "'" || ch == "’" || ch == "-"
        }
        func isCore(_ range: NSRange) -> Bool {
            guard let ch = ns.substring(with: range).first else { return false }
            return ch.isLetter || ch.isNumber
        }
        var start = caret, end = caret
        while start > line.location {
            let r = ns.rangeOfComposedCharacterSequence(at: start - 1)
            guard isPart(r) else { break }
            start = r.location
        }
        while end < NSMaxRange(line) {
            let r = ns.rangeOfComposedCharacterSequence(at: end)
            guard isPart(r) else { break }
            end = NSMaxRange(r)
        }
        // Joiners only count between letters: `-word-` is `word`.
        while start < end, !isCore(ns.rangeOfComposedCharacterSequence(at: start)) {
            start = NSMaxRange(ns.rangeOfComposedCharacterSequence(at: start))
        }
        while end > start, !isCore(ns.rangeOfComposedCharacterSequence(at: end - 1)) {
            end = ns.rangeOfComposedCharacterSequence(at: end - 1).location
        }
        return start < end ? NSRange(location: start, length: end - start) : nil
    }

    // MARK: - Link

    /// An inline link `[text](url)` (not an image) on one line.
    struct LinkSpan: Equatable {
        let range: NSRange
        let text: NSRange
        let url: NSRange
    }

    /// The link the selection sits in, if the whole selection is inside
    /// one link on one line. A caret counts only strictly inside, so a
    /// caret right after a link starts a new one.
    static func link(enclosing selection: NSRange, in text: String) -> LinkSpan? {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        let line = lineContent(at: sel.location, in: ns)
        guard NSMaxRange(sel) <= NSMaxRange(line) else { return nil }
        for match in MarkdownRegexes.link.matches(in: text, range: line) {
            let inside = sel.length == 0
                ? sel.location > match.range.location && sel.location < NSMaxRange(match.range)
                : sel.location >= match.range.location && NSMaxRange(sel) <= NSMaxRange(match.range)
            guard match.range(at: 1).length == 0,  // `![…](…)` is an image
                  inside else { continue }
            return LinkSpan(range: match.range, text: match.range(at: 2), url: match.range(at: 3))
        }
        return nil
    }

    /// What Link… writes for `url` (trimmed).
    ///
    /// - Inside an existing link: its URL is replaced, or the link is
    ///   taken apart (text kept) when `url` is empty.
    /// - Otherwise the selection becomes `[selection](url)`. The caret goes
    ///   where typing continues: into `[]` when there's no text, into `()`
    ///   when there's text but no URL, after the link when both are there.
    static func setLink(url rawURL: String, in text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        let url = formattedLinkDestination(rawURL)

        if let link = link(enclosing: sel, in: text) {
            if url.isEmpty {
                let label = ns.substring(with: link.text)
                let newText = applying([(link.range, label)], to: ns)
                return Result(text: newText,
                              selection: NSRange(location: link.range.location, length: (label as NSString).length))
            }
            let newText = applying([(link.url, url)], to: ns)
            return Result(text: newText,
                          selection: NSRange(location: link.text.location, length: link.text.length))
        }

        var start = sel.location, end = NSMaxRange(sel)
        while start < end, isWhitespaceOrNewline(ns.character(at: start)) { start += 1 }
        while end > start, isWhitespaceOrNewline(ns.character(at: end - 1)) { end -= 1 }
        let label = ns.substring(with: NSRange(location: start, length: end - start))
        let target = start < end ? NSRange(location: start, length: end - start)
                                 : NSRange(location: sel.location, length: 0)
        let replaced = sel.length > 0 && start == end ? sel : target
        let link = "[" + label + "](" + url + ")"
        let newText = applying([(replaced, link)], to: ns)
        let labelLength = (label as NSString).length
        let caret: Int
        if label.isEmpty {
            caret = replaced.location + 1
        } else if url.isEmpty {
            caret = replaced.location + 1 + labelLength + 2
        } else {
            caret = replaced.location + (link as NSString).length
        }
        return Result(text: newText, selection: NSRange(location: caret, length: 0))
    }

    /// A URL in angle brackets when it has spaces, which a bare link
    /// destination can't hold.
    private static func formattedLinkDestination(_ raw: String) -> String {
        let url = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if url.contains(" "), !url.hasPrefix("<") { return "<" + url + ">" }
        return url
    }

    /// The pasteboard's text when it is one web, mail or file URL, for
    /// prefilling Link…; nil for anything else.
    static func linkCandidate(fromPasteboard string: String?) -> String? {
        guard let trimmed = string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace),
              let url = URL(string: trimmed), let scheme = url.scheme?.lowercased(),
              ["http", "https", "mailto", "ftp", "file"].contains(scheme)
        else { return nil }
        if scheme == "mailto" { return trimmed }
        return url.host?.isEmpty == false || scheme == "file" ? trimmed : nil
    }

    // MARK: - Checklist

    /// `[ \t>]` lead, then an optional list bullet and checkbox.
    private static let listLine = try! NSRegularExpression(
        pattern: #"^([ \t]*(?:>[ \t]?)*[ \t]*)(?:([-*+]|\d{1,9}[.)])([ \t]+|$)(\[[ xX]\](?:[ \t]+|$))?)?"#)

    /// Turn the selected lines into a checklist, or back.
    ///
    /// When every non-blank line is a task (`- [ ] x`, `- [x] x`,
    /// `1. [ ] x`) the checkboxes go, and with them the bullet of an
    /// unordered item, so the line is plain text again (a numbered item
    /// keeps its number). Otherwise plain lines get `- [ ] ` after their
    /// indent and quote markers, and list items (`- x`, `1. x`) get
    /// `[ ] ` after their bullet. Blank lines are left alone.
    static func toggleChecklist(in text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        struct Parsed { let line: NSRange; let match: NSTextCheckingResult; let blank: Bool }
        let lines = lineContents(covering: sel, in: ns).compactMap { line -> Parsed? in
            guard let m = listLine.firstMatch(in: text, range: line) else { return nil }
            let lead = m.range(at: 1)
            let rest = ns.substring(with: NSRange(location: NSMaxRange(lead), length: NSMaxRange(line) - NSMaxRange(lead)))
            return Parsed(line: line, match: m, blank: rest.trimmingCharacters(in: .whitespaces).isEmpty
                          && m.range(at: 2).location == NSNotFound)
        }
        let content = lines.filter { !$0.blank }
        guard !content.isEmpty else {
            // Only blank lines: start a checklist at the caret's line.
            guard let first = lines.first else { return Result(text: text, selection: sel) }
            let at = NSMaxRange(first.match.range(at: 1))
            return applyingLineEdits([(NSRange(location: at, length: 0), "- [ ] ")], to: ns, selection: sel)
        }
        let allTasks = content.allSatisfy { $0.match.range(at: 4).location != NSNotFound }
        var edits: [(range: NSRange, replacement: String)] = []
        for p in content {
            let bullet = p.match.range(at: 2), space = p.match.range(at: 3), box = p.match.range(at: 4)
            if allTasks {
                let ordered = ns.character(at: bullet.location) >= 0x30 && ns.character(at: bullet.location) <= 0x39
                let from = ordered ? box.location : bullet.location
                edits.append((NSRange(location: from, length: NSMaxRange(box) - from), ""))
            } else if box.location != NSNotFound {
                continue
            } else if bullet.location != NSNotFound {
                // `-` at the very end of a line has no space yet.
                let insert = space.length == 0 ? " [ ] " : "[ ] "
                edits.append((NSRange(location: NSMaxRange(space), length: 0), insert))
            } else {
                edits.append((NSRange(location: NSMaxRange(p.match.range(at: 1)), length: 0), "- [ ] "))
            }
        }
        return applyingLineEdits(edits, to: ns, selection: sel)
    }

    // MARK: - Quote

    private static let quoteMarker = try! NSRegularExpression(pattern: #"^ {0,3}>[ \t]?"#)

    /// Toggle `> ` on the selected lines. When every non-blank line is
    /// quoted, one level of `>` comes off each line; otherwise unquoted
    /// lines get `> `. Blank lines between quoted lines get a bare `>`, so
    /// the paragraphs stay one quote.
    static func toggleQuote(in text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let sel = clamp(selection, in: text)
        let lines = lineContents(covering: sel, in: ns)
        func isBlank(_ line: NSRange) -> Bool {
            ns.substring(with: line).trimmingCharacters(in: .whitespaces).isEmpty
        }
        let markers = lines.map { quoteMarker.firstMatch(in: text, range: $0)?.range }
        let nonBlank = zip(lines, markers).filter { !isBlank($0.0) }
        let allQuoted = !nonBlank.isEmpty && nonBlank.allSatisfy { $0.1 != nil }

        var edits: [(range: NSRange, replacement: String)] = []
        for (line, marker) in zip(lines, markers) {
            if allQuoted {
                if let marker { edits.append((marker, "")) }
            } else if marker == nil {
                let blank = isBlank(line)
                if blank && lines.count > 1 {
                    edits.append((NSRange(location: line.location, length: line.length), ">"))
                } else {
                    edits.append((NSRange(location: line.location, length: 0), "> "))
                }
            }
        }
        return applyingLineEdits(edits, to: ns, selection: sel)
    }

    // MARK: - Table

    /// Three columns, a header and two empty rows.
    static let tableSkeleton = [
        "| Column 1 | Column 2 | Column 3 |",
        "| -------- | -------- | -------- |",
        "|          |          |          |",
        "|          |          |          |",
    ]

    /// Insert an empty table at the caret on lines of its own, with a
    /// blank line before and after it where there's text, and select the
    /// first header cell's placeholder so typing replaces it. A selection
    /// is kept and the table goes after it: Table is not a conversion, so
    /// it must not swallow the selected text. Uses the document's line
    /// break (CRLF stays CRLF).
    static func insertTable(in text: String, selection: NSRange) -> Result {
        let ns = text as NSString
        let selected = clamp(selection, in: text)
        let sel = NSRange(location: NSMaxRange(selected), length: 0)
        let nl = text.contains("\r\n") ? "\r\n" : "\n"
        let before = ns.substring(to: sel.location)
        let after = ns.substring(from: NSMaxRange(sel))
        let prefix: String
        if before.isEmpty || before.hasSuffix(nl + nl) {
            prefix = ""
        } else if before.hasSuffix(nl) {
            prefix = nl
        } else {
            prefix = nl + nl
        }
        let suffix: String
        if after.isEmpty {
            suffix = nl
        } else if after == nl || after.hasPrefix(nl + nl) {
            suffix = ""
        } else if after.hasPrefix(nl) {
            suffix = nl
        } else {
            suffix = nl + nl
        }
        let table = tableSkeleton.joined(separator: nl)
        let newText = applying([(sel, prefix + table + suffix)], to: ns)
        let cell = NSRange(location: sel.location + (prefix as NSString).length + 2,
                           length: ("Column 1" as NSString).length)
        return Result(text: newText, selection: cell)
    }

    // MARK: - Helpers

    /// Content ranges (without line breaks) of the lines a selection
    /// touches. A selection ending at the start of a line doesn't touch
    /// that line; a caret touches its own line.
    static func lineContents(covering selection: NSRange, in ns: NSString) -> [NSRange] {
        var start = 0, end = 0, contentsEnd = 0
        ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd,
                        for: NSRange(location: min(selection.location, ns.length), length: 0))
        var lines = [NSRange(location: start, length: contentsEnd - start)]
        while end < ns.length, end < NSMaxRange(selection) {
            let next = end
            ns.getLineStart(&start, end: &end, contentsEnd: &contentsEnd, for: NSRange(location: next, length: 0))
            lines.append(NSRange(location: start, length: contentsEnd - start))
        }
        return lines
    }

    private static func lineContent(at location: Int, in ns: NSString) -> NSRange {
        lineContents(covering: NSRange(location: location, length: 0), in: ns)[0]
    }

    /// Apply non-overlapping edits given in ascending order.
    static func applying(_ edits: [(range: NSRange, replacement: String)], to ns: NSString) -> String {
        let out = NSMutableString(string: ns)
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }).reversed() {
            out.replaceCharacters(in: edit.range, with: edit.replacement)
        }
        return out as String
    }

    /// Where `position` lands after `edits`: text inserted at or before
    /// it pushes it along; a position inside replaced text moves to the
    /// same offset in the replacement, at most its end.
    static func map(_ position: Int, through edits: [(range: NSRange, replacement: String)]) -> Int {
        var shift = 0
        for edit in edits.sorted(by: { $0.range.location < $1.range.location }) {
            if edit.range.location > position { break }
            let replacementLength = (edit.replacement as NSString).length
            if NSMaxRange(edit.range) <= position {
                shift += replacementLength - edit.range.length
            } else {
                return edit.range.location + shift + min(position - edit.range.location, replacementLength)
            }
        }
        return position + shift
    }

    /// Line-prefix edits keep the selection on the same text.
    private static func applyingLineEdits(_ edits: [(range: NSRange, replacement: String)],
                                          to ns: NSString, selection: NSRange) -> Result {
        let newText = applying(edits, to: ns)
        let start = map(selection.location, through: edits)
        let end = selection.length == 0 ? start : max(start, map(NSMaxRange(selection), through: edits))
        return Result(text: newText, selection: clamp(NSRange(location: start, length: end - start), in: newText))
    }

    private static func run(of c: unichar, in ns: NSString, from location: Int, forward: Bool, limit: Int) -> Int {
        var count = 0
        if forward {
            var i = location
            while i < limit, i < ns.length, ns.character(at: i) == c { count += 1; i += 1 }
        } else {
            var i = location - 1
            while i >= limit, i >= 0, ns.character(at: i) == c { count += 1; i -= 1 }
        }
        return count
    }

    private static func isWordCharacter(_ ns: NSString, at index: Int) -> Bool {
        guard index >= 0, index < ns.length else { return false }
        guard let ch = ns.substring(with: ns.rangeOfComposedCharacterSequence(at: index)).first else { return false }
        return ch.isLetter || ch.isNumber
    }

    private static func isSpace(_ c: unichar) -> Bool { c == 0x20 || c == 0x09 }

    private static func isWhitespaceOrNewline(_ c: unichar) -> Bool {
        c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D
    }
}
