import AppKit

/// Inline 14×14 checkbox view that paints itself in the editor's accent
/// colour. Used by `CheckboxOverlayManager` as the visual stand-in for
/// the raw `[ ]` / `[x]` characters in the underlying markdown source.
///
/// Click semantics: a single mouse-down toggles the state. We swallow
/// the event so the underlying NSTextView doesn't move its caret onto
/// the line as a side-effect — the caret should land there only when
/// the user clicks somewhere else on the line.
@MainActor
final class CheckboxView: NSView {
    /// Whether to render the filled-with-checkmark state. Source-of-
    /// truth lives in the markdown text; this view just mirrors it.
    var isChecked: Bool = false {
        didSet {
            if oldValue != isChecked {
                needsDisplay = true
                setAccessibilityValue(isChecked)
            }
        }
    }

    /// Accent colour driving the box stroke (unchecked) and fill (checked).
    var accentColor: NSColor = .controlAccentColor {
        didSet { needsDisplay = true }
    }

    /// Editor background colour. Painted as the box's interior fill so
    /// the concealed `[ ]` characters underneath don't bleed through.
    var backgroundFillColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
    }

    /// The task's own text ("Buy milk"), the checkbox's VoiceOver name.
    /// Every checkbox used to be "Task checkbox", so a list of them could
    /// not be told apart.
    var taskText: String = "" {
        didSet {
            guard oldValue != taskText else { return }
            setAccessibilityLabel(Self.accessibilityLabel(for: taskText))
        }
    }

    static func accessibilityLabel(for taskText: String) -> String {
        let text = taskText.trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? "Task" : text
    }

    /// The tick on the accent fill: black or white, whichever stands out
    /// more. The palette background used to be drawn there, about 2:1 on
    /// Green or Warm Orange over a white palette.
    static func tickColor(on accent: NSColor) -> NSColor {
        let l = PaletteSelectionStyle.relativeLuminance(accent)
        let onWhite = 1.05 / (l + 0.05)
        let onBlack = (l + 0.05) / 0.05
        return onBlack > onWhite ? .black : .white
    }

    /// Toggle handler — the overlay manager wires this to a
    /// `NSTextStorage.replaceCharacters` edit that flips the source
    /// `[ ]` ↔ `[x]`. Undo-tracked because storage edits go through
    /// the standard NSTextView edit path.
    var onToggle: (() -> Void)?

    private var isHovering: Bool = false {
        didSet {
            if oldValue != isHovering { needsDisplay = true }
        }
    }

    private var trackingArea: NSTrackingArea?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // VoiceOver: expose as a checkbox the user can navigate to and
        // toggle with the keyboard. Without this the overlay is invisible
        // to assistive tech and the only way to toggle a task is a mouse
        // click on a 14×14 target.
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilityLabel(Self.accessibilityLabel(for: taskText))
        setAccessibilityValue(isChecked)
    }

    // Keyboard focus is drawn: the view takes first responder for Full
    // Keyboard Access, and a custom view gets a ring only through a mask.
    override var focusRingMaskBounds: NSRect { bounds }

    override func drawFocusRingMask() {
        let rect = bounds.insetBy(dx: 1.5, dy: 1.5)
        NSBezierPath(roundedRect: rect, xRadius: 3, yRadius: 3).fill()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var isFlipped: Bool { true }

    // Focusable so VoiceOver / full-keyboard-access can land on it and
    // Space-toggle via `performKeyEquivalent`.
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// VoiceOver "press" (VO-Space) and the accessibility activation path.
    override func accessibilityPerformPress() -> Bool {
        onToggle?()
        return true
    }

    /// Space-bar toggles when the view has keyboard focus.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Key equivalents are offered to every view in the window, so
        // without these checks ⌃Space (the AI picker) toggled the first
        // checkbox in the document.
        let mods = event.modifierFlags.intersection(KeyCombo.relevantModifiers)
        if window?.firstResponder === self, mods.isEmpty,
           event.charactersIgnoringModifiers == " " {
            onToggle?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let existing = trackingArea {
            removeTrackingArea(existing)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
    }

    override func mouseDown(with event: NSEvent) {
        // Swallow the click — don't forward to the NSTextView. We
        // explicitly do NOT call super.mouseDown(_:) because that would
        // let the textview's hit-test re-target and move the caret
        // onto the line, which feels wrong (clicking a checkbox should
        // toggle, not navigate).
        onToggle?()
        // Accepting first responder (for keyboard access) means the click
        // just took focus from the editor — hand it back so typing
        // continues where the caret was.
        if let editor = superview as? NSTextView {
            window?.makeFirstResponder(editor)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let inset: CGFloat = 1.5
        let rect = bounds.insetBy(dx: inset, dy: inset)
        let cornerRadius: CGFloat = 3

        let path = NSBezierPath(roundedRect: rect,
                                 xRadius: cornerRadius,
                                 yRadius: cornerRadius)
        path.lineWidth = 1.5

        if isChecked {
            // Filled with accent, checkmark in black or white by contrast
            // with the accent.
            accentColor.setFill()
            path.fill()
            drawCheckmark(in: rect, color: Self.tickColor(on: accentColor))
        } else {
            // Border only. Stroke colour deepens slightly on hover so
            // the user knows the box is interactive.
            backgroundFillColor.setFill()
            path.fill()
            let strokeAlpha: CGFloat = isHovering ? 0.95 : 0.55
            accentColor.withAlphaComponent(strokeAlpha).setStroke()
            path.stroke()
        }
    }

    private func drawCheckmark(in rect: NSRect, color: NSColor) {
        let path = NSBezierPath()
        path.lineWidth = 1.7
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        // We're in flipped coords (y grows downward).
        // Checkmark: lower-left → middle-bottom → upper-right.
        let p1 = NSPoint(x: rect.minX + rect.width * 0.22,
                          y: rect.minY + rect.height * 0.52)
        let p2 = NSPoint(x: rect.minX + rect.width * 0.43,
                          y: rect.minY + rect.height * 0.72)
        let p3 = NSPoint(x: rect.minX + rect.width * 0.78,
                          y: rect.minY + rect.height * 0.32)
        path.move(to: p1)
        path.line(to: p2)
        path.line(to: p3)
        color.setStroke()
        path.stroke()
    }
}
