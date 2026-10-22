import AppKit

/// One replacement in the editor's text, computed by pure code (the
/// inspector's front matter writer) and applied by the editor through
/// `EditorBridge`, so it lands on the text view's undo stack.
struct TextEdit: Equatable {
    /// UTF-16 range in the source the edit was computed from.
    let range: NSRange
    let replacement: String
    /// The text `range` held when the edit was computed. The editor
    /// refuses the edit when the range holds anything else by then.
    let expected: String

    /// Length difference the edit causes (UTF-16).
    var delta: Int { (replacement as NSString).length - range.length }

    /// Where a selection ends up after the edit. Each end is mapped on its
    /// own: a point before the edit stays, a point after it moves by
    /// `delta`, and a point inside the replaced text moves to the end of
    /// the changed text. Text that `expected` and `replacement` share at
    /// either end did not change, so a point in it keeps its place: a new
    /// key written in front of the closing fence (an edit that covers the
    /// fence) leaves a caret on that fence on the fence, inside the open
    /// block. An insertion at the caret pushes the caret along.
    func adjustedSelection(_ selection: NSRange) -> NSRange {
        let (prefix, suffix) = commonEnds
        let start = map(selection.location, prefix: prefix, suffix: suffix)
        let end = map(NSMaxRange(selection), prefix: prefix, suffix: suffix)
        return NSRange(location: start, length: max(0, end - start))
    }

    private func map(_ point: Int, prefix: Int, suffix: Int) -> Int {
        if point < range.location { return point }
        if point >= NSMaxRange(range) { return point + delta }
        let offset = point - range.location
        if offset >= range.length - suffix { return point + delta }
        if prefix > 0, offset <= prefix { return point }
        return range.location + (replacement as NSString).length - suffix
    }

    /// UTF-16 lengths of the unchanged text at the start and the end of
    /// the edit, counted in whole characters so neither splits a
    /// surrogate pair, and never overlapping.
    private var commonEnds: (prefix: Int, suffix: Int) {
        let old = Array(expected), new = Array(replacement)
        var p = 0
        while p < old.count, p < new.count, old[p] == new[p] { p += 1 }
        var s = 0
        while s < old.count - p, s < new.count - p, old[old.count - 1 - s] == new[new.count - 1 - s] { s += 1 }
        let utf16 = { (chars: ArraySlice<Character>) in chars.reduce(0) { $0 + $1.utf16.count } }
        return (utf16(old[..<p]), utf16(old[(old.count - s)...]))
    }
}

/// The channel from SwiftUI views (the inspector) into the window's text
/// view. Assigning `document.text` would replace the whole buffer and
/// wipe the undo history, so edits go through the coordinator instead.
@MainActor
protocol EditorEditing: AnyObject {
    /// The text view's current text.
    var editorText: String { get }
    /// Apply `edit` as one undoable step named `actionName`.
    /// - Returns: false when the edit no longer fits the text.
    @discardableResult
    func apply(_ edit: TextEdit, actionName: String) -> Bool
    /// The window's editor, for commands the command palette runs.
    var commandTarget: PicaMDTextView? { get }
}

/// One per window, owned by `ContentView`. The editor's coordinator
/// registers itself as `driver` (weakly, like `SearchModel.driver`).
@MainActor
final class EditorBridge {
    weak var driver: EditorEditing?

    /// Write a front matter field, computed against the live text so a
    /// pending (debounced) re-parse can't hand the writer stale ranges.
    @discardableResult
    func setFrontmatter(_ field: Frontmatter.Field, to value: String) -> Bool {
        guard let driver,
              let edit = Frontmatter.edit(source: driver.editorText, field: field, newValue: value)
        else { return false }
        return driver.apply(edit, actionName: field.undoActionName)
    }

    /// Replace the tag list (an empty list removes the key).
    @discardableResult
    func setTags(_ tags: [String]) -> Bool {
        guard let driver,
              let edit = Frontmatter.edit(source: driver.editorText, tags: tags)
        else { return false }
        return driver.apply(edit, actionName: Frontmatter.Field.tags.undoActionName)
    }

    /// Remove one tag, looked up in the LIVE text. The inspector's list is
    /// re-parsed after a 150 ms debounce, so a second chip click in that
    /// window, computed from the shown list, put back the tag the first
    /// click had removed. `index` picks among equal tags; when the live
    /// list has moved, the first tag with that name goes.
    @discardableResult
    func removeTag(_ tag: String, at index: Int) -> Bool {
        guard let driver else { return false }
        var live = Frontmatter.build(from: driver.editorText).tags
        if live.indices.contains(index), live[index] == tag {
            live.remove(at: index)
        } else if let first = live.firstIndex(of: tag) {
            live.remove(at: first)
        } else {
            return false
        }
        return setTags(live)
    }

    /// Append tags to the LIVE list (see `removeTag`).
    @discardableResult
    func addTags(_ added: [String]) -> Bool {
        guard let driver, !added.isEmpty else { return false }
        return setTags(Frontmatter.build(from: driver.editorText).tags + added)
    }

    /// Give the editor the keyboard focus back (the palette had it).
    func focusEditor() {
        guard let textView = driver?.commandTarget else { return }
        textView.window?.makeFirstResponder(textView)
    }

    /// Run a Format command from the command palette on the editor's
    /// selection. Called directly, not through the responder chain: the
    /// palette's search field may still be first responder.
    func perform(_ action: KeybindingAction) {
        focusEditor()
        driver?.commandTarget?.runCommand(action)
    }

    /// Run an AI preset from the command palette.
    func runAIPreset(_ preset: AIPreset) {
        focusEditor()
        driver?.commandTarget?.runAIPresetFromPalette(preset)
    }
}
