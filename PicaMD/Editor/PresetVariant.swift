import Foundation

/// One of the built-in editor "looks". Picking a preset sets *typography
/// + structure* defaults (body/heading font, scale, code style, etc.)
/// but leaves palette and accent untouched — the user can freely combine
/// "Editorial preset + OLED palette + pink accent".
enum PresetVariant: String, CaseIterable, Identifiable, Codable {
    /// The current refined-as-is PicaMD look. Mono body, calm palette.
    case stockPlus = "stock-plus"

    /// New York serif H1 with a hairline rule, sans body. For long-form
    /// essays and prose-heavy notes.
    case editorial = "editorial"

    /// SF Pro headings, SF Mono body, tinted code blocks, editor drawn as
    /// a floating card. The native macOS Tahoe look — calm,
    /// system-default-feeling.
    case tahoe = "tahoe"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .stockPlus: return "Stock+"
        case .editorial: return "Editorial"
        case .tahoe:     return "Tahoe"
        }
    }

    /// One line under the preset card in Settings ▸ Appearance.
    var subtitle: String {
        switch self {
        case .stockPlus: return "SF Pro headings, card code"
        case .editorial: return "New York headings"
        case .tahoe:     return "Card layout, tinted code"
        }
    }

    /// Apply this preset's typography/structure defaults to `theme`.
    /// Palette, accent, size, column width, chrome appearance and the
    /// word-count switch are preserved: they are personal choices, not
    /// part of a look. (The word-count switch used to be forced back on
    /// by every preset click.)
    func applyDefaults(to theme: inout EditorTheme) {
        theme.preset = self
        // A preset names its body font; a family picked in the font panel
        // would otherwise keep winning over it.
        theme.bodyFontName = nil
        switch self {
        case .stockPlus:
            theme.bodyFont      = .mono
            theme.headingFont   = .sans
            theme.headingScale  = .defaultScale
            theme.headingRule   = false
            theme.codeStyle     = .card
            theme.cardLayout    = false

        case .editorial:
            theme.bodyFont      = .sans
            theme.headingFont   = .serif
            theme.headingScale  = .airy
            theme.headingRule   = true
            theme.codeStyle     = .card
            theme.cardLayout    = false

        case .tahoe:
            theme.bodyFont      = .mono
            theme.headingFont   = .sans
            theme.headingScale  = .defaultScale
            theme.headingRule   = false
            theme.codeStyle     = .tinted
            theme.cardLayout    = true
        }
    }

    /// Whether the theme still has this preset's look: every field the
    /// preset sets has the preset's value, except the body font. The
    /// stored `preset` label is ignored: it stays behind after the user
    /// changes a single field, so it can't tell whether the look still
    /// is the preset's (Settings used to tick a card that no longer
    /// matched).
    ///
    /// The body font is left out because it is its own control (the Font
    /// popup under the cards) and a personal choice like size: a fresh
    /// install pairs Stock+ with SF Pro while Stock+ itself picks SF Mono,
    /// and comparing the font would leave every card unselected there.
    /// The three presets still differ in their heading and block fields,
    /// so at most one card matches.
    func matches(_ theme: EditorTheme) -> Bool {
        var applied = theme
        applyDefaults(to: &applied)
        applied.preset = theme.preset
        applied.bodyFont = theme.bodyFont
        applied.bodyFontName = theme.bodyFontName
        return applied == theme
    }
}
