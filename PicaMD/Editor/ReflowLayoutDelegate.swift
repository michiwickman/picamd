import AppKit

/// Makes hard-wrapped paragraphs reflow to the window width by typesetting
/// their interior newlines as spaces — without changing a single byte of the
/// text storage.
///
/// The hook is `NSLayoutManagerDelegate`, deliberately, not an
/// `NSATSTypesetter` subclass: `actionForControlCharacterAtIndex:` is
/// documented as deprecated in favour of this delegate method, which does the
/// same job with no subclass and no change to how the text view is built.
///
/// The two methods are a **mandatory pair**. `.whitespace` with no bounding
/// box behaves as `.zeroAdvancement`, which fuses the last word of one line
/// into the first word of the next.
///
/// Character indices are untouched: nothing is inserted or removed, so the
/// glyph↔character mapping is exactly what it is with the mode off. Every
/// existing `NSRange` in the editor — overlay positioning, search highlight
/// rects, checkbox frames, footnote hit-testing, viewport ranges — stays valid
/// by construction. What changes is geometry: fragments merge, so those rects
/// move. That is the feature.
/// `@preconcurrency` on the conformance: `NSLayoutManagerDelegate` is not
/// annotated for Swift 6 isolation, but both callbacks below are only ever
/// invoked from `NSLayoutManager`'s layout pass, which for an `NSTextView`
/// runs on the main thread — the same actor that publishes the classification.
///
/// It is also the text storage's delegate, for one reason: the classification
/// is absolute character offsets, published by the debounced highlight pass.
/// Between an edit and that pass every soft newline after the edit point
/// would be looked up at its old offset, so the lines under the caret broke
/// in the wrong places for one frame. `didProcessEditing` runs before the
/// storage notifies its layout managers, so shifting the set there keeps it
/// valid for the relayout the edit triggers.
///
/// The shift needs the exact replaced span, which `didProcessEditing` does
/// not report: a typed character arrives with `editedRange` widened to the end
/// of its paragraph (the typing attributes are fixed paragraph-wide), so the
/// line's own soft newline would look replaced. The text view therefore hands
/// over the spans from `shouldChangeText` (`noteUpcomingEdit`). Edits that
/// bypass it — undo and redo — fall back to `editedRange`, which only ever
/// drops offsets it cannot place.
@MainActor
final class ReflowLayoutDelegate: NSObject, @preconcurrency NSLayoutManagerDelegate,
                                  @preconcurrency NSTextStorageDelegate {

    /// Whether reflow is active at all. Toggled from the View menu.
    var isEnabled: Bool = false

    /// UTF-16 offsets of the newlines that may be typeset as a space.
    /// Published by the highlight pass and shifted on every character edit,
    /// never computed lazily inside a layout callback (that would re-enter
    /// layout).
    private(set) var softNewlines: Set<Int> = []

    weak var textStorage: NSTextStorage?
    var fallbackFont: NSFont = .systemFont(ofSize: EditorFont.defaultBaseSize)

    /// Space advance per font, so a long document doesn't re-measure per glyph.
    private var spaceWidthCache: [ObjectIdentifier: CGFloat] = [:]

    /// One replaced span of a text change, in pre-edit coordinates.
    struct Edit: Equatable, Sendable {
        let range: NSRange
        let replacementLength: Int
        var delta: Int { replacementLength - range.length }
    }

    /// The spans announced by the text view for the change in flight;
    /// consumed by the next character edit.
    private var pendingEdits: [Edit]?

    func publish(softNewlines: Set<Int>) {
        self.softNewlines = softNewlines
    }

    /// Called from `shouldChangeText` once the change is allowed, with the
    /// ranges and replacement lengths the text view is about to apply.
    func noteUpcomingEdit(_ edits: [Edit]) {
        pendingEdits = edits.sorted { $0.range.location < $1.range.location }
    }

    /// The change announced last was not applied (or is complete).
    func discardPendingEdit() {
        pendingEdits = nil
    }

    func invalidateFontCache() {
        spaceWidthCache.removeAll()
    }

    /// How a control character is typeset in reflow.
    private enum SoftKind { case structural, space, zeroWidth }

    /// The classifier reports the `\n` of each soft line break. In a CRLF
    /// document the `\r` in front of it is a paragraph break of its own,
    /// so marking the `\n` alone merged nothing and Reflow did nothing in
    /// CRLF files. The pair is typeset as ONE space: the `\r` gets the
    /// space advance, the `\n` behind it none.
    private func softKind(_ charIndex: Int) -> SoftKind {
        guard isEnabled, !softNewlines.isEmpty else { return .structural }
        let chars = textStorage?.mutableString
        let length = chars?.length ?? 0
        if softNewlines.contains(charIndex) {
            if let chars, charIndex > 0, charIndex - 1 < length,
               chars.character(at: charIndex - 1) == 0x0D {
                return .zeroWidth
            }
            return .space
        }
        if let chars, charIndex + 1 < length,
           chars.character(at: charIndex) == 0x0D,
           chars.character(at: charIndex + 1) == 0x0A,
           softNewlines.contains(charIndex + 1) {
            return .space
        }
        return .structural
    }

    // MARK: - NSTextStorageDelegate

    func textStorage(_ textStorage: NSTextStorage,
                     didProcessEditing editedMask: NSTextStorageEditActions,
                     range editedRange: NSRange,
                     changeInLength delta: Int) {
        guard editedMask.contains(.editedCharacters) else { return }
        let announced = pendingEdits
        pendingEdits = nil
        guard !softNewlines.isEmpty else { return }
        if let announced, Self.edits(announced, explain: editedRange, changeInLength: delta) {
            softNewlines = Self.shift(softNewlines, by: announced)
        } else {
            softNewlines = Self.shift(softNewlines, editedRange: editedRange, changeInLength: delta)
        }
    }

    /// Whether the announced spans are the edit the storage just processed.
    /// A stale announcement (a change that was allowed but never applied)
    /// must not be used for an unrelated undo: it is accepted only if its
    /// net length change matches and every span lies inside `editedRange`.
    nonisolated static func edits(_ edits: [Edit], explain editedRange: NSRange,
                                  changeInLength delta: Int) -> Bool {
        guard !edits.isEmpty, edits.reduce(0, { $0 + $1.delta }) == delta else { return false }
        let oldEnd = editedRange.location + editedRange.length - delta
        var previousEnd = editedRange.location
        for edit in edits {
            guard edit.range.location >= previousEnd else { return false }
            previousEnd = NSMaxRange(edit.range)
        }
        return previousEnd <= oldEnd
    }

    /// Exact form of `shift(_:editedRange:changeInLength:)`: drops the
    /// offsets inside a replaced span and moves every other one by the length
    /// change of the spans in front of it. `edits` are sorted and disjoint.
    nonisolated static func shift(_ offsets: Set<Int>, by edits: [Edit]) -> Set<Int> {
        var shifted = Set<Int>()
        shifted.reserveCapacity(offsets.count)
        var next = 0
        var moved = 0
        for offset in offsets.sorted() {
            // An insertion at the offset itself goes in front of the newline.
            while next < edits.count, NSMaxRange(edits[next].range) <= offset {
                moved += edits[next].delta
                next += 1
            }
            if next < edits.count, edits[next].range.location <= offset { continue }
            shifted.insert(offset + moved)
        }
        return shifted
    }

    /// Moves offsets behind the edit by `delta` and drops the ones whose
    /// character was replaced. Dropping is the safe direction: a newline
    /// wrongly treated as structural only loses reflow until the next pass
    /// reclassifies the text. Also exact for edits coalesced inside
    /// `beginEditing`/`endEditing`: `editedRange` is then their union in
    /// post-edit coordinates, everything behind it lies behind every edit,
    /// and offsets between the edits are dropped.
    nonisolated static func shift(_ offsets: Set<Int>, editedRange: NSRange, changeInLength delta: Int) -> Set<Int> {
        // `editedRange` is in post-edit coordinates; the replaced span in the
        // old text started at the same location and was `delta` shorter.
        let start = editedRange.location
        let oldEnd = editedRange.location + editedRange.length - delta
        var shifted = Set<Int>()
        shifted.reserveCapacity(offsets.count)
        for offset in offsets {
            if offset < start {
                shifted.insert(offset)
            } else if offset >= oldEnd {
                shifted.insert(offset + delta)
            }
        }
        return shifted
    }

    // MARK: - NSLayoutManagerDelegate

    /// Reclassify the newline. Returning the incoming `action` unchanged for
    /// everything else matters: the framework proposes an option-set union,
    /// and hardcoding `.paragraphBreak` would narrow it.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       shouldUse action: NSLayoutManager.ControlCharacterAction,
                       forControlCharacterAt charIndex: Int)
        -> NSLayoutManager.ControlCharacterAction {
        switch softKind(charIndex) {
        case .structural: return action
        case .space: return .whitespace
        case .zeroWidth: return .zeroAdvancement
        }
    }

    /// Give the reclassified newline the advance of a real space.
    func layoutManager(_ layoutManager: NSLayoutManager,
                       boundingBoxForControlGlyphAt glyphIndex: Int,
                       for textContainer: NSTextContainer,
                       proposedLineFragment proposedRect: NSRect,
                       glyphPosition: NSPoint,
                       characterIndex charIndex: Int) -> NSRect {
        guard softKind(charIndex) == .space else { return .zero }
        return NSRect(x: glyphPosition.x, y: 0,
                      width: spaceAdvance(at: charIndex),
                      height: proposedRect.height)
    }

    // MARK: - Metrics

    /// The width must come from the real font run, not a constant: this editor
    /// mixes body, heading and monospace fonts, and conceals markup with a
    /// 0.01 pt font. Probing the character *before* the newline gets the last
    /// real glyph of the line rather than whatever run the newline inherited.
    private func spaceAdvance(at charIndex: Int) -> CGFloat {
        guard let storage = textStorage, storage.length > 0 else {
            return measuredSpace(fallbackFont)
        }
        let probe = max(0, min(charIndex - 1, storage.length - 1))
        var font = (storage.attribute(.font, at: probe, effectiveRange: nil) as? NSFont)
            ?? fallbackFont
        if font.pointSize < 1.0 { font = fallbackFont }   // concealment font
        return measuredSpace(font)
    }

    private func measuredSpace(_ font: NSFont) -> CGFloat {
        let key = ObjectIdentifier(font)
        if let cached = spaceWidthCache[key] { return cached }
        let w = (" " as NSString).size(withAttributes: [.font: font]).width
        spaceWidthCache[key] = w
        return w
    }
}
