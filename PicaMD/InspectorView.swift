import SwiftUI

/// Strings shown by the inspector and the word count, kept free of UI so
/// they can be tested with a fixed locale and clock.
enum InspectorFormat {
    /// Shown for a value that does not exist yet (untitled document, no
    /// front matter key).
    static let missing = "—"

    /// Words per minute behind "Reading time". The board's example (412
    /// words → "2 min") fits rounding at 200.
    static let readingWordsPerMinute = 200.0

    /// "2,318" in en_US, "2.318" in de_DE.
    static func number(_ value: Int, locale: Locale = .current) -> String {
        value.formatted(.number.locale(locale))
    }

    /// The quiet label in the editor's corner: "412 words", "1 word".
    static func wordCount(_ words: Int, locale: Locale = .current) -> String {
        "\(number(words, locale: locale)) \(words == 1 ? "word" : "words")"
    }

    /// max(1, round(words / 200)) minutes; an empty document has none.
    static func readingTime(words: Int, locale: Locale = .current) -> String {
        guard words > 0 else { return missing }
        let minutes = max(1, Int((Double(words) / readingWordsPerMinute).rounded()))
        return "\(number(minutes, locale: locale)) min"
    }

    /// The last two folders above the file, "Documents ▸ Travel".
    static func location(of fileURL: URL?) -> String {
        guard let fileURL else { return missing }
        let folders = fileURL.deletingLastPathComponent().pathComponents.filter { $0 != "/" }
        guard !folders.isEmpty else { return "/" }
        return folders.suffix(2).joined(separator: " ▸ ")
    }

    /// "Today, 14:20", "Yesterday, 09:05", otherwise the date and time in
    /// the locale's short styles.
    static func modified(_ date: Date?, now: Date = Date(),
                         calendar: Calendar = .current,
                         locale: Locale = .current) -> String {
        guard let date else { return missing }
        var calendar = calendar
        calendar.locale = locale
        let timeStyle = Date.FormatStyle(date: .omitted, time: .shortened,
                                         locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone)
        let time = date.formatted(timeStyle)
        if calendar.isDate(date, inSameDayAs: now) { return "Today, \(time)" }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return "Yesterday, \(time)"
        }
        let dateStyle = Date.FormatStyle(date: .abbreviated, time: .omitted,
                                         locale: locale, calendar: calendar,
                                         timeZone: calendar.timeZone)
        return "\(date.formatted(dateStyle)), \(time)"
    }

    /// A front matter date as the Date field shows it while not being
    /// edited: "October 3, 2026", or the raw text when it isn't a date.
    static func frontmatterDate(_ raw: String, locale: Locale = .current) -> String {
        FrontmatterMetaLine.formattedDate(raw, locale: locale)
    }

    /// "Markdown" or "Plain Text" from the file extension.
    static func format(of fileURL: URL?) -> String {
        guard let fileURL else { return missing }
        switch fileURL.pathExtension.lowercased() {
        case "txt", "text": return "Plain Text"
        default: return "Markdown"
        }
    }
}

extension Palette {
    /// The word count's colour: the palette's text blended toward the
    /// background as far as legibility allows. `fgMuted` is decoration
    /// strength (about 3:1 on White, 2.7:1 on Off-White); the count is
    /// information at 11 pt and needs 4.5:1 (WCAG AA), so the blend starts
    /// at the muted strength and stops at the first step that reaches it.
    var wordCountColor: NSColor {
        let start = fgMuted.alphaComponent
        for step in 0...20 {
            let alpha = min(1, start + CGFloat(step) * 0.025)
            let color = bg.blended(withFraction: alpha, of: fg.withAlphaComponent(1)) ?? fg
            if Self.contrast(color, bg) >= 4.5 { return color }
        }
        return fg
    }

    static func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let la = PaletteSelectionStyle.relativeLuminance(a)
        let lb = PaletteSelectionStyle.relativeLuminance(b)
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

/// The inspector column (⌥⌘I): Document, Statistics, File.
///
/// The Document fields write the front matter through `bridge` (one undo
/// step per committed field, see `EditorBridge`); they never assign the
/// document's text. Every other input is a plain value, so a caret move
/// in the editor (which re-renders `ContentView`) only rebuilds this view
/// when one of them actually changed.
struct InspectorView: View, Equatable {
    let title: String?
    let tags: [String]
    let date: String?
    /// Why a field can't be written (see `Frontmatter.lockReason`).
    let locks: [Frontmatter.Field: String]
    let stats: TextStats
    let headingCount: Int
    let fileURL: URL?
    let modified: Date?
    let bridge: EditorBridge

    nonisolated static func == (lhs: InspectorView, rhs: InspectorView) -> Bool {
        lhs.title == rhs.title && lhs.tags == rhs.tags && lhs.date == rhs.date
            && lhs.locks == rhs.locks && lhs.stats == rhs.stats
            && lhs.headingCount == rhs.headingCount && lhs.fileURL == rhs.fileURL
            && lhs.modified == rhs.modified && lhs.bridge === rhs.bridge
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                section("Document") {
                    fieldLabel("Title", first: true)
                    FrontmatterField(value: title, prompt: "Add Title", lock: locks[.title],
                                     accessibilityName: "Title",
                                     refocusEditor: { bridge.focusEditor() }) {
                        bridge.setFrontmatter(.title, to: $0)
                    }
                    fieldLabel("Tags")
                    TagEditor(tags: tags, lock: locks[.tags],
                              remove: { bridge.removeTag($0, at: $1) },
                              add: { bridge.addTags($0) },
                              refocusEditor: { bridge.focusEditor() })
                    fieldLabel("Date")
                    FrontmatterField(value: date, prompt: "YYYY-MM-DD", lock: locks[.date],
                                     accessibilityName: "Date",
                                     display: { InspectorFormat.frontmatterDate($0) },
                                     refocusEditor: { bridge.focusEditor() }) {
                        bridge.setFrontmatter(.date, to: $0)
                    }
                }
                section("Statistics") {
                    row("Words", InspectorFormat.number(stats.words))
                    row("Characters", InspectorFormat.number(stats.characters))
                    row("Lines", InspectorFormat.number(stats.lines))
                    row("Reading time", InspectorFormat.readingTime(words: stats.words))
                    row("Headings", InspectorFormat.number(headingCount))
                }
                section("File") {
                    row("Where", InspectorFormat.location(of: fileURL))
                    row("Modified", InspectorFormat.modified(modified))
                    row("Format", InspectorFormat.format(of: fileURL))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Pieces (sizes from the Inspector board)

    private func section<Content: View>(_ title: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 10)
                .accessibilityAddTraits(.isHeader)
            content()
        }
        .padding(EdgeInsets(top: 16, leading: 18, bottom: 6, trailing: 18))
    }

    private func fieldLabel(_ text: String, first: Bool = false) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
            .padding(.top, first ? 0 : 12)
            .padding(.bottom, 4)
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer(minLength: 12)
            Text(value)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .font(.system(size: 13))
        .frame(minHeight: 26)
        .accessibilityElement(children: .combine)
    }
}

/// A Title or Date field. While focused it edits a local draft of the raw
/// value; Return or leaving the field commits it (Escape reverts). While
/// not focused it follows the document and shows `display(value)` —
/// the Date field's "October 3, 2026".
private struct FrontmatterField: View {
    let value: String?
    let prompt: String
    let lock: String?
    let accessibilityName: String
    var display: (String) -> String = { $0 }
    /// Hands keyboard focus back to the editor after Escape, as the find
    /// bar and the palette do; without it no view had focus.
    let refocusEditor: () -> Void
    let commit: (String) -> Void

    @State private var draft = ""
    /// Set while the user owns the draft; `focused` alone flips before
    /// `onDisappear` can see it.
    @State private var editing = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextField(accessibilityName, text: $draft, prompt: Text(prompt))
                .labelsHidden()
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .focused($focused)
                .onSubmit(commitDraft)
                .onExitCommand {
                    draft = value ?? ""
                    focused = false
                    refocusEditor()
                }
                .padding(.horizontal, 8)
                .frame(maxWidth: .infinity, minHeight: 26, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(focused ? Color.accentColor : Color(nsColor: .separatorColor),
                                  lineWidth: focused ? 1 : 0.5))
                .disabled(lock != nil)
            if let lock { LockHint(text: lock) }
        }
        .onAppear { draft = shown }
        .onChange(of: value) { _, _ in
            if !editing { draft = shown }
        }
        .onChange(of: focused) { _, isFocused in
            if isFocused {
                editing = true
                draft = value ?? ""
            } else {
                commitDraft()
                editing = false
                draft = shown
            }
        }
        .onDisappear {
            if editing { commitDraft() }
        }
    }

    private var shown: String { value.map(display) ?? "" }

    private func commitDraft() {
        guard editing, draft != (value ?? "") else { return }
        commit(draft)
    }
}

/// Tag chips with a remove button (on hover or keyboard focus) and a
/// context menu, then an "Add…" field: Return adds (a comma-separated
/// entry adds several). Both write against the live text, not `tags`.
private struct TagEditor: View {
    let tags: [String]
    let lock: String?
    let remove: (_ tag: String, _ index: Int) -> Void
    let add: ([String]) -> Void
    let refocusEditor: () -> Void

    @State private var newTag = ""
    @FocusState private var addFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            FlowLayout(spacing: 6) {
                ForEach(Array(tags.enumerated()), id: \.offset) { index, tag in
                    TagChip(tag: tag, removable: lock == nil) {
                        remove(tag, index)
                    }
                }
                TextField("Add tag", text: $newTag, prompt: Text("Add…"))
                    .labelsHidden()
                    .textFieldStyle(.plain)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 2)
                    .frame(width: 84)
                    .focused($addFocused)
                    .onSubmit(addTags)
                    .onExitCommand {
                        newTag = ""
                        addFocused = false
                        refocusEditor()
                    }
                    .onChange(of: addFocused) { _, isFocused in
                        if !isFocused { addTags() }
                    }
                    .disabled(lock != nil)
            }
            if let lock { LockHint(text: lock) }
        }
    }

    private func addTags() {
        let added = newTag.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        newTag = ""
        guard !added.isEmpty else { return }
        add(added)
    }
}

private struct TagChip: View {
    let tag: String
    let removable: Bool
    let remove: () -> Void
    @State private var hovering = false
    /// Full Keyboard Access can Tab onto the remove button; it must then
    /// be visible, or Space deletes the tag through an invisible control.
    @FocusState private var removeFocused: Bool

    private var showsRemove: Bool { hovering || removeFocused }

    var body: some View {
        HStack(spacing: 3) {
            Text(tag)
            if removable {
                // Always laid out, shown on hover: a chip that grew on
                // hover could wrap to the next row, leave the pointer,
                // shrink back and flicker.
                Button(action: remove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .focused($removeFocused)
                .opacity(showsRemove ? 1 : 0)
                .allowsHitTesting(showsRemove)
                .help("Remove “\(tag)”")
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Capsule().fill(.quaternary))
        .onHover { hovering = $0 }
        .contextMenu {
            if removable {
                Button("Remove Tag", action: remove)
            }
        }
        // One element named after the tag. The button inside stays out of
        // it (`.combine` read "swift, Remove swift"); VoiceOver removes
        // through the named action instead.
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(tag)
        .accessibilityAction(named: "Remove") { if removable { remove() } }
    }
}

/// Why a field is read-only, under it.
private struct LockHint: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Left-aligned wrapping row for the tag chips.
private struct FlowLayout: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineHeight: CGFloat = 0, widest: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > 0, x + size.width > width {
                y += lineHeight + spacing
                x = 0
                lineHeight = 0
            }
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: proposal.width ?? widest, height: y + lineHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize,
                       subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += lineHeight + spacing
                x = bounds.minX
                lineHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            lineHeight = max(lineHeight, size.height)
        }
    }
}
