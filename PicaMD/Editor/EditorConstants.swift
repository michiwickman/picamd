import Foundation
import CoreGraphics

/// Tuning knobs that used to live as magic numbers scattered through
/// the editor. Centralised so the team can tweak feel without hunt-
/// and-peck across files.
///
/// Group conventions:
///   `Timing`   — debounce / throttle delays (milliseconds)
///   `Layout`   — paddings, margins, line-spacings, container insets
///   `Buffer`   — viewport / scroll-buffer sizes
///   `Font`     — base sizes, conceal sizes
///   `Block`    — overlay defaults
enum EditorTiming {
    /// Highlighter pass after a text change. Fast-but-not-flicker.
    static let highlightDebounceMs: Int = 50
    /// Highlighter pass after a cursor move (concealment refresh).
    /// Snappier than text-change because users expect markup to
    /// appear/disappear immediately when stepping in/out of a span.
    static let cursorMoveHighlightDebounceMs: Int = 16
    /// Highlighter pass after a window/frame resize.
    static let frameChangeHighlightDebounceMs: Int = 30
    /// FileWatcher: vnode events within this window of our own save
    /// are treated as our own (not as external edits).
    static let selfWriteIgnoreInterval: TimeInterval = 1.5
    /// `BlockOverlayManager.refreshLiveSet()` debounce after the user
    /// stops scrolling. Long enough to coalesce a 60-Hz scroll burst
    /// into a single re-evaluation, short enough that promoted blocks
    /// pop in before the user notices the placeholder. 150 ms feels
    /// right in testing.
    static let lazyLiveSetDebounceMs: Int = 150
}

enum EditorLayout {
    /// Inset of the text container inside the NSTextView.
    static let textContainerInsetWidth: CGFloat = 24
    static let textContainerInsetHeight: CGFloat = 20
    /// Padding around the editor card in the Tahoe preset.
    static let tahoeCardPaddingTop: CGFloat = 14
    static let tahoeCardPaddingHorizontal: CGFloat = 16
    static let tahoeCardCornerRadius: CGFloat = 12
    /// Default minimum width per overlay block view.
    static let blockOverlayMinWidth: CGFloat = 120
    /// Reserved space around an overlay block.
    static let blockOverlayHeightPadding: CGFloat = 8
}

enum EditorBuffer {
    /// Characters of context kept on each side of the visible viewport
    /// when running an incremental highlight pass. Large enough to
    /// cover any inline-markup or block boundary that crosses the
    /// viewport edge in real-world docs.
    static let viewportContext: Int = 4000
    /// Target chunk size (characters) for the progressive full-document
    /// re-highlight that runs after a theme / dark-mode change. Small
    /// enough that each chunk's inline passes finish in well under a
    /// frame so the `Task.yield()` between chunks keeps typing and
    /// scrolling responsive; the actual chunk end snaps to the next
    /// newline so an inline construct is never split across a boundary.
    static let progressiveChunkChars: Int = 8000
}

enum EditorFont {
    /// Default body size when no theme has overridden it.
    static let defaultBaseSize: CGFloat = 15
    /// Tiny size used to "conceal" markup characters without removing
    /// them from the buffer.
    static let concealedSize: CGFloat = 0.01
}

enum EditorBlockDefaults {
    /// Heights reserved for overlay blocks before their real size is
    /// reported (web views measure async; tables / images measure sync).
    static let table: CGFloat = 100
    static let image: CGFloat = 220
    static let mathBlock: CGFloat = 100
    static let mermaid: CGFloat = 200
}
