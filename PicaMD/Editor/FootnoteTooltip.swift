import AppKit

/// Hover-popover for `[^id]` footnote references in the editor.
/// Backing data lives in `FootnoteIndex` (pure, in `FootnoteIndex.swift`)
/// so the same model powers both this AppKit tooltip and the HTML
/// exporter's footnote rendering.

// MARK: - Tooltip controller

@MainActor
final class FootnoteTooltipController {
    private weak var textView: NSTextView?
    private let popover = NSPopover()
    private(set) var index: FootnoteIndex = .empty
    private var trackingArea: NSTrackingArea?
    private var currentRef: FootnoteRef?

    init(textView: NSTextView) {
        self.textView = textView
        popover.behavior = .transient   // dismisses on click outside
        popover.animates = false        // snappier feel for a tooltip
    }

    /// Called by the highlighter after each pass so the lookup is
    /// always in sync with the source text.
    func updateIndex(from source: String) {
        let new = FootnoteIndex.build(from: source)
        if new != index {
            index = new
            // If the popover is showing a ref that no longer exists
            // (user just deleted the definition), close it.
            if let cur = currentRef, !index.refs.contains(where: { $0.id == cur.id }) {
                hide()
            }
        }
    }

    /// Refresh the tracking area to cover the current visible bounds.
    /// Call from `viewDidMoveToWindow` and on `viewDidEndLiveResize` —
    /// AppKit doesn't auto-resize tracking areas with the view.
    func refreshTrackingArea() {
        guard let textView = textView else { return }
        if let old = trackingArea {
            textView.removeTrackingArea(old)
        }
        let new = NSTrackingArea(
            rect: textView.bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeInKeyWindow, .inVisibleRect],
            owner: textView,
            userInfo: nil
        )
        textView.addTrackingArea(new)
        trackingArea = new
    }

    /// Call from `NSTextView.mouseMoved(with:)`.
    func mouseMoved(_ event: NSEvent) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            hide()
            return
        }
        // Convert window-coords → text-view-coords → text-container-coords.
        let viewPoint = textView.convert(event.locationInWindow, from: nil)
        let containerPoint = NSPoint(
            x: viewPoint.x - textView.textContainerOrigin.x,
            y: viewPoint.y - textView.textContainerOrigin.y
        )
        // Check that the point is actually inside a glyph (not out
        // past the end of line — `glyphIndex(for:in:)` snaps to the
        // closest glyph which gives false positives at the trailing
        // edge of a ref).
        var fraction: CGFloat = 0
        let glyphIndex = layoutManager.glyphIndex(for: containerPoint,
                                                    in: textContainer,
                                                    fractionOfDistanceThroughGlyph: &fraction)
        // If we're past the last glyph, fraction is 1 and the index is
        // the last glyph — which would falsely match the trailing `]`.
        // Filter that out by checking the actual glyph bounding box.
        let glyphRect = layoutManager.boundingRect(
            forGlyphRange: NSRange(location: glyphIndex, length: 1),
            in: textContainer
        ).offsetBy(dx: textView.textContainerOrigin.x,
                   dy: textView.textContainerOrigin.y)
        if !glyphRect.contains(viewPoint) {
            hide()
            return
        }

        let charIndex = layoutManager.characterIndexForGlyph(at: glyphIndex)
        guard let ref = index.ref(at: charIndex) else {
            hide()
            return
        }
        // Already showing for this ref? Don't flicker.
        if currentRef == ref { return }
        guard let definition = index.definitions[ref.id], !definition.isEmpty else {
            hide()
            return
        }
        show(ref: ref, definition: definition)
    }

    /// Call from `NSTextView.mouseExited(with:)` (or
    /// `viewWillMoveToWindow(nil)`).
    func hide() {
        popover.performClose(nil)
        currentRef = nil
    }

    private func show(ref: FootnoteRef, definition: String) {
        guard let textView = textView,
              let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else { return }

        // Anchor the popover to the glyph rect of the ref.
        let glyphRange = layoutManager.glyphRange(forCharacterRange: ref.range,
                                                    actualCharacterRange: nil)
        let bounding = layoutManager.boundingRect(forGlyphRange: glyphRange,
                                                    in: textContainer)
        let anchor = bounding.offsetBy(dx: textView.textContainerOrigin.x,
                                        dy: textView.textContainerOrigin.y)

        popover.contentViewController = FootnoteContentVC(definition: definition,
                                                          id: ref.id)
        popover.show(relativeTo: anchor, of: textView, preferredEdge: .maxY)
        currentRef = ref
    }
}

// MARK: - Popover content

private final class FootnoteContentVC: NSViewController {
    private let definition: String
    private let id: String

    init(definition: String, id: String) {
        self.definition = definition
        self.id = id
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let container = NSView()
        container.wantsLayer = true

        let idLabel = NSTextField(labelWithString: "[^\(id)]")
        idLabel.font = .monospacedSystemFont(ofSize: 10, weight: .semibold)
        idLabel.textColor = .tertiaryLabelColor

        let body = NSTextField(wrappingLabelWithString: definition)
        body.font = .systemFont(ofSize: 12)
        body.preferredMaxLayoutWidth = 320
        body.maximumNumberOfLines = 8
        body.lineBreakMode = .byWordWrapping

        let stack = NSStackView(views: [idLabel, body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -10),
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 12),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -12),
            container.widthAnchor.constraint(lessThanOrEqualToConstant: 360),
        ])
        view = container
    }
}
