import AppKit

/// One inline task-list item discovered in the markdown source. The
/// fields cover everything the highlighter and overlay manager need
/// without making either re-parse the line.
struct TaskListMatch: Hashable, Sendable {
    /// Range of the entire line — used for `cursor.touches(...)` so we
    /// can hide the overlay while the caret is on the line and let the
    /// user edit the raw `[ ]` markup.
    let lineRange: NSRange
    /// Range of the literal `[ ]` or `[x]` (always 3 characters).
    let boxRange: NSRange
    /// Range from after the checkbox+space to end-of-line. Used for
    /// strike-through + dimmed colour when the item is checked.
    let textRange: NSRange
    /// Current state derived from the source: `[x]` (any case) → true.
    let checked: Bool
}

/// Manages a pool of `CheckboxView` instances overlayed on the
/// `NSTextView`'s glyph rects. Mirrors the architecture of
/// `BlockOverlayManager` but for inline single-glyph attachments
/// instead of full-paragraph blocks.
///
/// The textview's text storage retains the original `[ ]`/`[x]`
/// markdown chars; the highlighter conceals them with `.clear`
/// foreground colour while the cursor is off the line, and the views
/// in this manager paint a real checkbox at the corresponding glyph
/// rect. When the cursor enters the line, the highlighter restores
/// the accent foreground and this manager hides its overlay so the
/// user edits raw markup just like every other syntax token in PicaMD.
@MainActor
final class CheckboxOverlayManager {
    weak var textView: NSTextView?
    var theme: EditorTheme = .default

    /// Closure called when a checkbox is toggled. Receives the box-range
    /// in the *current* source coordinate system and the new desired
    /// state. Wired by the coordinator to a `NSTextStorage.replaceCharacters`
    /// edit so the change goes through the standard undo path.
    var onToggle: ((NSRange, Bool) -> Void)?

    /// Index-stable pool of reusable `CheckboxView` instances. Sized
    /// to exactly `liveMatches.count` each pass: grow by appending new
    /// views (addSubview), shrink by popping from the tail
    /// (removeFromSuperview + removeLast). This avoids the O(N) view
    /// churn that the old `[NSRange: CheckboxView]` dict caused — any
    /// edit above the first checkbox shifted every boxRange key so every
    /// view was torn down and recreated every keystroke.
    private var pool: [CheckboxView] = []

    /// Inputs that determined the current pool state. Used for an
    /// early-return fast-path: if matches, cursor ranges, and protected
    /// ranges are all unchanged we skip the full rebind loop.
    private var lastMatches: [TaskListMatch] = []
    private var lastCursorRanges: [NSRange] = []
    private var lastProtectedRanges: [NSRange] = []

    /// Cached size of one checkbox in points. Tuned so the box visually
    /// matches the cap-height of the editor's body font at the default
    /// size. If a user picks a much larger base size the box will look
    /// proportionally small but remain functional.
    private let boxSize: CGFloat = 14

    // MARK: - Public API

    /// Sync overlay views with the current set of matches. Adds/removes
    /// views as needed and repositions all visible ones.
    ///
    /// `protectedRanges` are code-fence / math-block / frontmatter spans:
    /// a `- [ ]` line inside ``` … ``` is NOT a real task item, so we must
    /// not paint a clickable checkbox over it (a click would rewrite the
    /// user's documented code). The highlighter skips these same ranges,
    /// so the two stay in lock-step.
    func update(matches: [TaskListMatch],
                cursorActiveRanges: [NSRange],
                protectedRanges: [NSRange] = []) {
        guard let textView = textView else { return }

        // Effective matches = those not inside a protected (code/math) span.
        let liveMatches = protectedRanges.isEmpty
            ? matches
            : matches.filter { match in
                !protectedRanges.contains { NSLocationInRange(match.lineRange.location, $0) }
            }

        // Fast-path: if nothing that affects layout/visibility changed,
        // skip the full rebind loop. We must compute liveMatches first
        // (above) since it derives from protectedRanges.
        if liveMatches == lastMatches,
           cursorActiveRanges == lastCursorRanges,
           protectedRanges == lastProtectedRanges {
            return
        }

        let storageLength = textView.textStorage?.length ?? 0
        let accent = theme.effectiveAccent
        let bgFill = theme.palette.bg

        // Grow pool if we need more views.
        while pool.count < liveMatches.count {
            let v = CheckboxView(frame: .zero)
            textView.addSubview(v)
            pool.append(v)
        }

        // Shrink pool by removing trailing views that are no longer needed.
        while pool.count > liveMatches.count {
            pool.last?.removeFromSuperview()
            pool.removeLast()
        }

        // Rebind each pooled view to the corresponding match by index.
        for (i, match) in liveMatches.enumerated() {
            let view = pool[i]

            // Range out of bounds (shouldn't happen, but guards against
            // stale calls during rapid edits).
            guard match.boxRange.location + match.boxRange.length <= storageLength else {
                view.isHidden = true
                continue
            }

            // Re-bind the toggle closure each pass so it captures the
            // freshest match state — important because the source may
            // have shifted between passes (other lines added/removed)
            // and `match.boxRange` reflects the current source.
            let capturedRange = match.boxRange
            let capturedChecked = match.checked
            view.onToggle = { [weak self] in
                self?.onToggle?(capturedRange, !capturedChecked)
            }
            view.isChecked = match.checked
            view.accentColor = accent
            view.backgroundFillColor = bgFill

            // Hide while the cursor is on the line so the user edits
            // raw markup, matching the existing concealment pattern
            // used by every other inline syntax token.
            let active = cursorActiveRanges.contains { intersects($0, match.lineRange) }
            view.isHidden = active

            if !active {
                view.frame = computeFrame(for: match.boxRange) ?? .zero
            }
        }

        // Persist the inputs that produced this pool state for the
        // fast-path check on the next call.
        lastMatches = liveMatches
        lastCursorRanges = cursorActiveRanges
        lastProtectedRanges = protectedRanges
    }

    /// Re-position visible views in response to scroll / resize. Cheap
    /// — a single layout-rect lookup per view, no view churn.
    func reposition() {
        for (i, view) in pool.enumerated() where !view.isHidden {
            guard i < lastMatches.count else { continue }
            let range = lastMatches[i].boxRange
            view.frame = computeFrame(for: range) ?? view.frame
        }
    }

    /// Drop every overlay (e.g. when the document is replaced
    /// wholesale by an external-reload).
    func clear() {
        for view in pool { view.removeFromSuperview() }
        pool.removeAll()
        lastMatches.removeAll()
        lastCursorRanges.removeAll()
        lastProtectedRanges.removeAll()
    }

    // MARK: - Source extraction

    /// Extract every `- [ ]` / `- [x]` task-list item in the source.
    /// Static + nonisolated so unit tests can call it without an
    /// NSTextView. Used by both `SyntaxHighlighter` (for concealment +
    /// strike-through) and `CheckboxOverlayManager.update(...)` (for
    /// view placement) — single source of truth, regex parsed once.
    /// Compiled once, reused for every extraction. Re-compiling an
    /// NSRegularExpression on each call (twice per highlight pass, at the
    /// 16 ms cursor-move cadence) was pure waste on large docs.
    /// `nonisolated` so the nonisolated `extractMatches` can read it;
    /// NSRegularExpression is Sendable, so no `(unsafe)` is needed.
    nonisolated private static let taskListRegex = try! NSRegularExpression(
        pattern: #"^([ \t]*[-*+][ \t]+)(\[[ xX]\])([ \t]+)(.*)$"#,
        options: [.anchorsMatchLines]
    )

    /// Code-fence + math-block spans, so callers can exclude `- [ ]`
    /// lines that live inside ``` … ``` or `$$ … $$` from the overlay
    /// (and from concealment). Uses the same shared regexes the
    /// highlighter and BlockExtractor use, so the three never diverge.
    nonisolated static func protectedRanges(in source: String) -> [NSRange] {
        let full = NSRange(location: 0, length: (source as NSString).length)
        guard full.length > 0 else { return [] }
        var ranges: [NSRange] = []
        for re in [MarkdownRegexes.fencedCode, MarkdownRegexes.mathBlock] {
            re.enumerateMatches(in: source, options: [], range: full) { m, _, _ in
                if let m = m { ranges.append(m.range) }
            }
        }
        return ranges
    }

    nonisolated static func extractMatches(from source: String) -> [TaskListMatch] {
        let ns = source as NSString
        let full = NSRange(location: 0, length: ns.length)
        guard full.length > 0 else { return [] }

        var out: [TaskListMatch] = []
        taskListRegex.enumerateMatches(in: source, options: [], range: full) { match, _, _ in
            guard let match = match else { return }
            // Group 0: full line. Group 2: `[ ]` or `[x]`. Group 4: rest.
            let lineRange = match.range
            let boxRange = match.range(at: 2)
            let restRange = match.range(at: 4)
            guard boxRange.length == 3 else { return }
            let box = ns.substring(with: boxRange)
            // Inner char (between `[` and `]`).
            let inner = box.dropFirst().dropLast()
            let checked = inner.lowercased() == "x"
            out.append(TaskListMatch(
                lineRange: lineRange,
                boxRange: boxRange,
                textRange: restRange.location == NSNotFound ? NSRange(location: lineRange.location + lineRange.length, length: 0) : restRange,
                checked: checked
            ))
        }
        return out
    }

    // MARK: - Private

    private func computeFrame(for range: NSRange) -> NSRect? {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return nil }
        let storageLength = textView.textStorage?.length ?? 0
        guard range.location + range.length <= storageLength else { return nil }
        let glyphRange = layoutManager.glyphRange(forCharacterRange: range,
                                                    actualCharacterRange: nil)
        guard glyphRange.length > 0 else { return nil }
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                    in: textContainer)
        let inset = textView.textContainerInset
        return NSRect(
            x: bounding.minX + inset.width,
            y: bounding.minY + inset.height + max(0, (bounding.height - boxSize) / 2),
            width: boxSize,
            height: boxSize
        )
    }

    private func intersects(_ a: NSRange, _ b: NSRange) -> Bool {
        let aEnd = a.location + a.length
        let bEnd = b.location + b.length
        return a.location <= bEnd && b.location <= aEnd
    }
}
