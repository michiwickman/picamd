import CoreGraphics

/// Where to scroll the editor's clip view for an outline jump and for
/// Typewriter Mode, with the scroll view's content insets taken into
/// account.
///
/// In the macOS 27 window the editor's scroll view starts below the
/// toolbar and its `contentInsets` are zero (probe, 27.0.1): then these
/// are the old formulas. Should the scroll view ever extend under the
/// toolbar (full-size content with `automaticallyAdjustsContentInsets`),
/// its top inset grows, the clip view's origin may go negative, and the
/// unobscured part of the viewport starts `insetTop` points lower. The
/// old formulas clamped at 0 and centred on the whole clip height, which
/// would hide the first line and a jumped-to heading under the toolbar.
///
/// All values are in the text view's (flipped) coordinates.
enum EditorScrollMath {
    /// Gap kept above a heading after an outline jump.
    static let jumpTopMargin: CGFloat = 24

    /// Allowed clip-view origins: from `-insetTop` (first line just below
    /// the obscured band) to the point where the document's end meets
    /// the bottom inset.
    static func originRange(documentHeight: CGFloat, viewportHeight: CGFloat,
                            insetTop: CGFloat, insetBottom: CGFloat) -> ClosedRange<CGFloat> {
        let lower = -insetTop
        let upper = max(lower, documentHeight - viewportHeight + insetBottom)
        return lower...upper
    }

    /// Clip origin that puts a line starting at `lineTop` `jumpTopMargin`
    /// below the top of the visible area.
    static func jumpOrigin(lineTop: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat,
                           insetTop: CGFloat = 0, insetBottom: CGFloat = 0) -> CGFloat {
        let range = originRange(documentHeight: documentHeight, viewportHeight: viewportHeight,
                                insetTop: insetTop, insetBottom: insetBottom)
        return clamp(lineTop - jumpTopMargin - insetTop, to: range)
    }

    /// Clip origin that puts `lineMidY` at the middle of the visible area.
    static func centeredOrigin(lineMidY: CGFloat, documentHeight: CGFloat, viewportHeight: CGFloat,
                               insetTop: CGFloat = 0, insetBottom: CGFloat = 0) -> CGFloat {
        let range = originRange(documentHeight: documentHeight, viewportHeight: viewportHeight,
                                insetTop: insetTop, insetBottom: insetBottom)
        let visibleHeight = max(0, viewportHeight - insetTop - insetBottom)
        return clamp(lineMidY - insetTop - visibleHeight / 2, to: range)
    }

    private static func clamp(_ value: CGFloat, to range: ClosedRange<CGFloat>) -> CGFloat {
        min(range.upperBound, max(range.lowerBound, value))
    }
}
