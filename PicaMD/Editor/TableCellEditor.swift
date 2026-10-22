import AppKit

/// A borderless single-line text field placed directly over a rendered table
/// cell, so editing one cell does not collapse the whole table back to raw
/// markdown.
///
/// Single-line is a deliberate constraint, not a shortcut: a pipe-table cell
/// *is* single-line by definition (a newline would end the row), so an
/// `NSTextField` is the honest control for it — and it brings IME, undo within
/// the field, spell-checking and Services along for free, with no auto-grow
/// overhang to manage.
///
/// The field is parented to the `TableBlockView` itself, which is why the view
/// pool must key tables by document position rather than by payload: a
/// payload-keyed pool would destroy this view — and the open editor with it —
/// on the first committed keystroke.
@MainActor
final class TableCellEditor: NSObject, NSTextFieldDelegate {

    /// Replace `range` with `newText`, but only if the document still holds
    /// `expectedOld` there. Returns false if the guard failed.
    var onCommit: ((_ range: NSRange, _ newText: String, _ expectedOld: String) -> Bool)?
    /// Move to a neighbouring cell after committing.
    var onMove: ((_ rowDelta: Int, _ colDelta: Int) -> Void)?
    /// The editor closed and the caller should restore normal editing.
    var onClose: (() -> Void)?
    /// Hand keyboard focus back to the editor after Return or Esc. Without
    /// it no view kept focus: typing went nowhere and the Format menu, which
    /// targets the first-responder text view, did nothing.
    var restoreFocus: (() -> Void)?

    private let field: NSTextField = {
        let f = NSTextField()
        f.isBordered = false
        f.drawsBackground = true
        f.focusRingType = .none
        f.lineBreakMode = .byClipping
        f.cell?.usesSingleLineMode = true
        f.cell?.wraps = false
        f.cell?.isScrollable = true
        return f
    }()

    private weak var host: TableBlockView?
    private(set) var openCell: (row: Int, col: Int)?
    /// The exact source text the editor was opened with. The commit refuses to
    /// write if the document no longer holds this at the target range —
    /// highlighting is debounced, so the range can go stale under us.
    private var expectedOld: String = ""
    /// What the field held when it was opened or last committed. A commit
    /// compares the user's INPUT against this, never `sanitise(input)`
    /// against the source: `sanitise` rewrites unchanged cells (a pipe in a
    /// code span gets escaped, a tab becomes a space), so Return on an
    /// untouched cell would otherwise write it and add an undo step.
    private var committedInput: String = ""
    private var targetRange = NSRange(location: 0, length: 0)
    private var isCommitting = false

    var isOpen: Bool { field.superview != nil }

    // MARK: - Opening

    func open(in view: TableBlockView,
              cell: TableCell,
              row: Int, col: Int,
              rect: NSRect,
              font: NSFont) {
        // A different cell was open — commit it first.
        if isOpen, openCell.map({ $0.row != row || $0.col != col }) ?? false {
            commit()
        }
        host = view
        openCell = (row, col)
        expectedOld = cell.text
        targetRange = cell.contentRange

        let colors = TableColors(palette: view.palette)
        field.font = font
        field.textColor = colors.text
        field.backgroundColor = colors.editorBackground
        // A 12 % tint alone barely sets the open cell apart from its
        // neighbours (focus ring is off: it would overhang the grid).
        field.wantsLayer = true
        field.layer?.borderWidth = 1.5
        field.layer?.borderColor = ThemeStore.currentAccent.cgColor
        field.layer?.cornerRadius = 2
        field.setAccessibilityLabel(Self.accessibilityLabel(row: row, col: col))
        field.stringValue = cell.text
        committedInput = cell.text
        field.delegate = self
        field.frame = rect.insetBy(dx: 2, dy: 2)

        if field.superview !== view {
            field.removeFromSuperview()
            view.addSubview(field)
        }
        view.window?.makeFirstResponder(field)
        // The field editor's caret defaults to the control text colour of the
        // window's appearance, which need not match the editor palette.
        (field.currentEditor() as? NSTextView)?.insertionPointColor = colors.text
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
    }

    /// Re-point an already-open editor at a new cell (Tab navigation) without
    /// tearing the field down.
    func reopen(in view: TableBlockView, cell: TableCell, row: Int, col: Int, rect: NSRect) {
        host = view
        openCell = (row, col)
        expectedOld = cell.text
        targetRange = cell.contentRange
        field.stringValue = cell.text
        committedInput = cell.text
        field.setAccessibilityLabel(Self.accessibilityLabel(row: row, col: col))
        field.frame = rect.insetBy(dx: 2, dy: 2)
        if field.superview !== view {
            field.removeFromSuperview()
            view.addSubview(field)
        }
        view.window?.makeFirstResponder(field)
        field.currentEditor()?.selectedRange = NSRange(location: 0, length: field.stringValue.count)
    }

    /// What VoiceOver calls the field: which cell it edits. `row` is -1
    /// for the header; both are 0-based here and 1-based when spoken.
    static func accessibilityLabel(row: Int, col: Int) -> String {
        row < 0 ? "Header, column \(col + 1)" : "Row \(row + 1), column \(col + 1)"
    }

    var accessibilityLabelForTesting: String? { field.accessibilityLabel() }

    // MARK: - Closing

    @discardableResult
    func commit() -> Bool {
        guard isOpen, !isCommitting else { return false }
        isCommitting = true
        defer { isCommitting = false }

        let input = field.stringValue
        guard input != committedInput else { return true }
        let edited = Self.sanitise(input)
        guard edited != expectedOld else { return true }
        let ok = onCommit?(targetRange, edited, expectedOld) ?? false
        if ok {
            expectedOld = edited
            committedInput = input
        }
        return ok
    }

    /// `refocus` is false when focus is already moving elsewhere (the user
    /// clicked another control); the editor must not pull it back then.
    func close(commitFirst: Bool = true, refocus: Bool = true) {
        guard isOpen else { return }
        if commitFirst { commit() }
        let window = field.window
        // Read before the removal: taking the field out of the window can
        // already reset the first responder to the window itself. Only the
        // field or ITS field editor counts — the document's own text view
        // is an NSText too, and it may legitimately hold focus here.
        let fieldEditor = field.currentEditor()
        let hadFocus = window.map {
            $0.firstResponder === field || (fieldEditor != nil && $0.firstResponder === fieldEditor)
        } ?? false
        field.removeFromSuperview()
        openCell = nil
        host = nil
        if let window, hadFocus {
            if refocus, let restoreFocus {
                restoreFocus()
            } else if window.firstResponder === field
                        || (fieldEditor != nil && window.firstResponder === fieldEditor) {
                window.makeFirstResponder(window.contentView)
            }
        }
        onClose?()
    }

    func cancel() {
        guard isOpen else { return }
        field.stringValue = expectedOld
        close(commitFirst: false)
    }

    /// A pipe would manufacture a new column and a newline would end the row,
    /// so both are neutralised rather than written through.
    static func sanitise(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\\|", with: "|")   // normalise first…
            .replacingOccurrences(of: "|", with: "\\|")   // …then escape once
            .trimmingCharacters(in: .whitespaces)
    }

    /// Test-only: stands in for the user typing into the open field.
    var inputForTesting: String {
        get { field.stringValue }
        set { field.stringValue = newValue }
    }

    var fieldColorsForTesting: (background: NSColor?, text: NSColor?) {
        (field.backgroundColor, field.textColor)
    }

    // MARK: - NSTextFieldDelegate

    func control(_ control: NSControl, textView: NSTextView,
                 doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        case #selector(NSResponder.insertNewline(_:)):
            close(commitFirst: true)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            cancel()
            return true
        case #selector(NSResponder.insertTab(_:)):
            if commit() { onMove?(0, 1) } else { close(commitFirst: false) }
            return true
        case #selector(NSResponder.insertBacktab(_:)):
            if commit() { onMove?(0, -1) } else { close(commitFirst: false) }
            return true
        case #selector(NSResponder.moveUp(_:)):
            if commit() { onMove?(-1, 0) } else { close(commitFirst: false) }
            return true
        case #selector(NSResponder.moveDown(_:)):
            if commit() { onMove?(1, 0) } else { close(commitFirst: false) }
            return true
        default:
            return false
        }
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        // Clicking elsewhere: commit and get out of the way. Guarded against
        // the re-entrant call the commit itself provokes.
        guard !isCommitting, isOpen else { return }
        close(commitFirst: true, refocus: false)
    }
}
