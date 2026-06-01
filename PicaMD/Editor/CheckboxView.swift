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
    /// Also used as the checkmark colour when `isChecked` is true so
    /// the tick stays legible against the accent fill.
    var backgroundFillColor: NSColor = .textBackgroundColor {
        didSet { needsDisplay = true }
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
        setAccessibilityLabel("Task checkbox")
        setAccessibilityValue(isChecked)
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
        if event.charactersIgnoringModifiers == " " {
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
            // Filled with accent, checkmark drawn in editor-bg colour
            // so it stays legible across light & dark palettes.
            accentColor.setFill()
            path.fill()
            drawCheckmark(in: rect, color: backgroundFillColor)
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
