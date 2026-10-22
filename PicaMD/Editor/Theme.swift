import AppKit

// MARK: - Palette

/// Colour tokens for one editor surface. Hex values are 1:1 from the
/// design package's `themes.js`, so the four palettes match the
/// Claude-Design prototype exactly.
struct Palette: Equatable, Codable {
    var bg: NSColor              // canvas background
    var bgTint: NSColor          // chrome / tinted card surface (Tahoe variant)
    var fg: NSColor
    var fgMuted: NSColor
    var rule: NSColor            // hairlines, separators
    var ruleStrong: NSColor      // blockquote bar, stronger separators
    var chrome: NSColor          // titlebar / status-bar fill
    var codeBg: NSColor          // fenced code block background
    var codeInlineBg: NSColor    // inline `code`
    var codeFg: NSColor
    var synKw: NSColor           // syntax keyword colour
    var accent: NSColor          // default accent — overridden by AccentChoice
    var highlight: NSColor       // ==highlight== background
    var math: NSColor

    // MARK: Built-in palettes (1:1 mit themes.js)

    static let white = Palette(
        bg:           NSColor(hex: "#ffffff"),
        bgTint:       NSColor(hex: "#f5f5f7"),
        fg:           NSColor(hex: "#1d1d1f"),
        fgMuted:      NSColor(white: 60.0/255, alpha: 0.55),
        rule:         NSColor(white: 60.0/255, alpha: 0.12),
        ruleStrong:   NSColor(white: 60.0/255, alpha: 0.28),
        chrome:       NSColor(red: 246/255, green: 246/255, blue: 247/255, alpha: 0.78),
        codeBg:       NSColor(hex: "#f7f7f8"),
        codeInlineBg: NSColor(hex: "#f3f3f5"),
        codeFg:       NSColor(hex: "#2a2a2e"),
        synKw:        NSColor(hex: "#a431a0"),
        accent:       NSColor(hex: "#0a84ff"),
        highlight:    NSColor(red: 1.0, green: 0.95, blue: 0.30, alpha: 0.50),
        math:         NSColor(red: 0.40, green: 0.20, blue: 0.65, alpha: 1.0)
    )

    static let offwhite = Palette(
        bg:           NSColor(hex: "#fbf9f4"),
        bgTint:       NSColor(hex: "#f4f1ea"),
        fg:           NSColor(hex: "#272620"),
        fgMuted:      NSColor(red: 60/255, green: 55/255, blue: 40/255, alpha: 0.50),
        rule:         NSColor(red: 60/255, green: 55/255, blue: 40/255, alpha: 0.14),
        ruleStrong:   NSColor(red: 60/255, green: 55/255, blue: 40/255, alpha: 0.28),
        chrome:       NSColor(red: 248/255, green: 244/255, blue: 236/255, alpha: 0.85),
        codeBg:       NSColor(hex: "#f3efe6"),
        codeInlineBg: NSColor(hex: "#efebe0"),
        codeFg:       NSColor(hex: "#2c2a22"),
        synKw:        NSColor(hex: "#a85c1f"),
        accent:       NSColor(hex: "#b66a2a"),
        highlight:    NSColor(red: 0.95, green: 0.85, blue: 0.20, alpha: 0.45),
        math:         NSColor(red: 0.45, green: 0.30, blue: 0.10, alpha: 1.0)
    )

    static let darkgrey = Palette(
        bg:           NSColor(hex: "#1c1c1e"),
        bgTint:       NSColor(hex: "#2a2a2c"),
        fg:           NSColor(hex: "#ececec"),
        fgMuted:      NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.55),
        rule:         NSColor(white: 1.0, alpha: 0.10),
        ruleStrong:   NSColor(white: 1.0, alpha: 0.22),
        chrome:       NSColor(red: 28/255, green: 28/255, blue: 30/255, alpha: 0.78),
        codeBg:       NSColor(hex: "#252527"),
        codeInlineBg: NSColor(hex: "#2c2c2e"),
        codeFg:       NSColor(hex: "#e7e7ea"),
        synKw:        NSColor(hex: "#ff7ab2"),
        accent:       NSColor(hex: "#0a84ff"),
        highlight:    NSColor(red: 0.65, green: 0.55, blue: 0.10, alpha: 0.40),
        math:         NSColor(red: 0.80, green: 0.70, blue: 1.00, alpha: 1.0)
    )

    static let oled = Palette(
        bg:           NSColor(hex: "#000000"),
        bgTint:       NSColor(hex: "#0a0a0a"),
        fg:           NSColor(hex: "#e9e9ea"),
        fgMuted:      NSColor(red: 235/255, green: 235/255, blue: 245/255, alpha: 0.42),
        rule:         NSColor(white: 1.0, alpha: 0.07),
        ruleStrong:   NSColor(white: 1.0, alpha: 0.18),
        chrome:       NSColor(white: 0.0, alpha: 0.78),
        codeBg:       NSColor(hex: "#0c0c0c"),
        codeInlineBg: NSColor(hex: "#101010"),
        codeFg:       NSColor(hex: "#dededf"),
        synKw:        NSColor(hex: "#ff7ab2"),
        accent:       NSColor(hex: "#0a84ff"),
        highlight:    NSColor(red: 0.55, green: 0.45, blue: 0.05, alpha: 0.40),
        math:         NSColor(red: 0.80, green: 0.70, blue: 1.00, alpha: 1.0)
    )

    var isDark: Bool {
        // Decide by checking the bg lightness — works for any custom palette
        // a plugin might add later.
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        bg.usingColorSpace(.sRGB)?.getRed(&r, green: &g, blue: &b, alpha: &a)
        let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
        return luma < 0.5
    }

    /// The "Custom" palette: the user picks only text and background, and
    /// every other token is derived here so code blocks, rules and muted
    /// text stay legible on any pair. The mix ratios are read off the
    /// built-in palettes (e.g. white's `bgTint` is the background moved
    /// ~4 % toward the text colour, dark grey's ~6 %). Colours with no
    /// sensible derivation from two inputs — syntax keyword, highlight,
    /// math, the palette accent — come from `base`, the built-in palette
    /// the user came from, when it is as light or dark as the custom
    /// background; otherwise from the built-in light or dark palette,
    /// picked by the background's luminance like `isDark`. Custom colours
    /// still equal to the base's own text and background give the base
    /// palette unchanged, so the first switch to Custom changes nothing
    /// visible (on Off-White, headings and links used to turn from amber
    /// to blue).
    static func custom(background: NSColor, text: NSColor, base: Palette? = nil) -> Palette {
        let bg = background.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? background
        let fg = text.usingColorSpace(.sRGB)?.withAlphaComponent(1) ?? text
        if let base, base.bg.toHex() == bg.toHex(), base.fg.toHex() == fg.toHex() {
            return base
        }
        let probe = Palette.white.with(bg: bg, fg: fg)
        let dark = probe.isDark
        let base = base.flatMap { $0.isDark == dark ? $0 : nil }
            ?? (dark ? Palette.darkgrey : Palette.white)
        func mix(_ fraction: CGFloat) -> NSColor {
            bg.blended(withFraction: fraction, of: fg) ?? bg
        }
        return Palette(
            bg:           bg,
            bgTint:       mix(dark ? 0.06 : 0.04),
            fg:           fg,
            fgMuted:      fg.withAlphaComponent(dark ? 0.50 : 0.55),
            rule:         fg.withAlphaComponent(dark ? 0.10 : 0.12),
            ruleStrong:   fg.withAlphaComponent(dark ? 0.22 : 0.28),
            chrome:       bg.withAlphaComponent(0.78),
            codeBg:       mix(dark ? 0.045 : 0.03),
            codeInlineBg: mix(dark ? 0.07 : 0.05),
            codeFg:       fg,
            synKw:        base.synKw,
            accent:       base.accent,
            highlight:    base.highlight,
            math:         base.math
        )
    }

    private func with(bg: NSColor, fg: NSColor) -> Palette {
        var copy = self
        copy.bg = bg
        copy.fg = fg
        return copy
    }
}

// MARK: - PaletteName

enum PaletteName: String, CaseIterable, Identifiable, Codable {
    case white, offwhite, darkgrey, oled

    var id: String { rawValue }

    var palette: Palette {
        switch self {
        case .white: return .white
        case .offwhite: return .offwhite
        case .darkgrey: return .darkgrey
        case .oled: return .oled
        }
    }

    var displayName: String {
        switch self {
        case .white: return "Pure White"
        case .offwhite: return "Off-White"
        case .darkgrey: return "Dark Grey"
        case .oled: return "OLED True Black"
        }
    }
}

// MARK: - HeadingScale

enum HeadingScale: String, CaseIterable, Identifiable, Codable {
    case tight, defaultScale = "default", airy

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .tight: return "Tight"
        case .defaultScale: return "Default"
        case .airy: return "Airy"
        }
    }

    /// Sizes for H1...H6, in order. Mirrors the prototype's
    /// `.scale-airy / .scale-default / .scale-tight` rules.
    var sizes: [CGFloat] {
        switch self {
        case .tight:        return [22, 18, 16, 15, 14, 14]
        case .defaultScale: return [28, 21, 17, 15.5, 14, 14]
        case .airy:         return [36, 24, 18, 16, 15, 15]
        }
    }
}

// MARK: - CodeBlockStyle

enum CodeBlockStyle: String, CaseIterable, Identifiable, Codable {
    case card, tinted, stripe, flat

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .card:   return "Card with border"
        case .tinted: return "Tinted, no border"
        case .stripe: return "Left stripe only"
        case .flat:   return "Flat / muted"
        }
    }
}

// MARK: - Body / Heading font family

enum BodyFontFamily: String, CaseIterable, Identifiable, Codable {
    case mono, sans

    var id: String { rawValue }
    var displayName: String { self == .mono ? "Mono" : "Sans" }

    func font(size: CGFloat, bold: Bool = false) -> NSFont {
        switch self {
        case .mono: return .monospacedSystemFont(ofSize: size, weight: bold ? .semibold : .regular)
        case .sans: return .systemFont(ofSize: size, weight: bold ? .semibold : .regular)
        }
    }
}

enum HeadingFontFamily: String, CaseIterable, Identifiable, Codable {
    case sans, serif

    var id: String { rawValue }
    var displayName: String { self == .sans ? "Sans" : "Serif" }

    func font(size: CGFloat, bold: Bool = true) -> NSFont {
        let weight: NSFont.Weight = bold ? .bold : .regular
        switch self {
        case .sans:
            return .systemFont(ofSize: size, weight: weight)
        case .serif:
            return SystemSerif.font(size: size, weight: weight)
        }
    }
}

/// New York, the system serif. It is a hidden system font (PostScript
/// names start with a dot), so looking it up by the family name "New
/// York" fails and the old code silently fell back to Georgia. The
/// supported route is the system font's `.serif` design.
enum SystemSerif {
    static let familyDisplayName = "New York"

    static func font(size: CGFloat, weight: NSFont.Weight = .regular) -> NSFont {
        let system = NSFont.systemFont(ofSize: size, weight: weight)
        if let descriptor = system.fontDescriptor.withDesign(.serif),
           let font = NSFont(descriptor: descriptor, size: size) {
            return font
        }
        return NSFont(name: weight >= .semibold ? "Georgia-Bold" : "Georgia", size: size) ?? system
    }
}

/// What the Font popup in Settings ▸ Appearance shows. Stored as the
/// pair `bodyFont` (mono | sans, understood by every build) plus the
/// optional `bodyFontName` (a family name, newer builds only).
enum BodyFontSelection: Hashable {
    case sfPro
    case sfMono
    case newYork
    /// Any installed family picked through the font panel.
    case family(String)

    var displayName: String {
        switch self {
        case .sfPro: return "SF Pro"
        case .sfMono: return "SF Mono"
        case .newYork: return SystemSerif.familyDisplayName
        case .family(let name): return name
        }
    }
}

// MARK: - AccentChoice

enum AccentChoice: String, CaseIterable, Identifiable, Codable {
    case system, blue, orange, pink, green, purple, mono

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .system: return "System (palette default)"
        case .blue:   return "Blue"
        case .orange: return "Warm Orange"
        case .pink:   return "Pink"
        case .green:  return "Green"
        case .purple: return "Purple"
        case .mono:   return "Monochrome"
        }
    }

    /// Colour from the prototype's ACCENTS dictionary.
    var color: NSColor {
        switch self {
        case .system, .blue: return NSColor(hex: "#0a84ff")
        case .orange:        return NSColor(hex: "#ff8c42")
        case .pink:          return NSColor(hex: "#ff375f")
        case .green:         return NSColor(hex: "#30d158")
        case .purple:        return NSColor(hex: "#bf5af2")
        case .mono:          return NSColor(hex: "#7d7d82")
        }
    }
}

// MARK: - Appearance / line width

/// Light or dark window chrome (sidebar, toolbar, settings). The editor
/// surface does not follow it: its colours come from the palette, so an
/// OLED editor stays black under a light system appearance.
enum AppearanceMode: String, CaseIterable, Identifiable, Codable {
    case automatic, light, dark

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .automatic: return "Automatic"
        case .light:     return "Light"
        case .dark:      return "Dark"
        }
    }

    /// Value for `NSApp.appearance`; `nil` follows the system.
    var nsAppearance: NSAppearance? {
        switch self {
        case .automatic: return nil
        case .light:     return NSAppearance(named: .aqua)
        case .dark:      return NSAppearance(named: .darkAqua)
        }
    }
}

/// Maximum width of the text column. Measured in characters of the body
/// font rather than points, so the column keeps its line length when the
/// user switches between a wide mono and a narrow proportional font.
enum LineWidth: String, CaseIterable, Identifiable, Codable {
    case readable, wide, full

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .readable: return "Readable"
        case .wide:     return "Wide"
        case .full:     return "Full"
        }
    }

    /// Characters per line; `nil` = no limit.
    var characters: CGFloat? {
        switch self {
        case .readable: return 66
        case .wide:     return 100
        case .full:     return nil
        }
    }

    /// Column width in points for `font`: `characters` times the advance
    /// of the digit "0" (the CSS `ch` unit). `.infinity` for `.full`.
    func columnWidth(for font: NSFont) -> CGFloat {
        guard let characters else { return .infinity }
        let zero = ("0" as NSString).size(withAttributes: [.font: font]).width
        return (characters * zero).rounded()
    }
}

// MARK: - EditorTheme

/// Aggregate of every tweakable. Equatable so view layers can diff and
/// re-render only when something actually changed.
///
/// Persisted as JSON (`ThemeStore`). The decoder is hand-written (see the
/// extension below): every field added after 0.9 is optional in the JSON
/// and falls back to the value that reproduces the old look, so a stored
/// theme from an older build never resets.
struct EditorTheme: Equatable, Codable {
    var preset: PresetVariant
    var paletteName: PaletteName
    var accent: AccentChoice
    var bodyFont: BodyFontFamily
    var headingFont: HeadingFontFamily
    var headingScale: HeadingScale
    var codeStyle: CodeBlockStyle
    var headingRule: Bool
    /// Persisted under its old name; the setting is "Show word count" now.
    var showStatusBar: Bool
    var fontBaseSize: CGFloat
    /// Window chrome only (see `AppearanceMode`).
    var appearance: AppearanceMode = .automatic
    var lineWidth: LineWidth = .readable
    /// The Tahoe "floating card" editor look, formerly implied by
    /// `preset == .tahoe`.
    var cardLayout: Bool = false
    /// When on, `palette` is derived from the two custom colours below.
    /// `paletteName` keeps the last built-in choice, so an older build
    /// reading this JSON still finds a palette it knows.
    var useCustomColors: Bool = false
    /// `#rrggbb`.
    var customTextColor: String? = nil
    /// `#rrggbb`.
    var customBackgroundColor: String? = nil
    /// Body font family chosen beyond SF Pro / SF Mono ("New York" or any
    /// installed family). Wins over `bodyFont` when it resolves.
    var bodyFontName: String? = nil

    var palette: Palette {
        if useCustomColors,
           let text = customTextColor.flatMap(NSColor.init(validHex:)),
           let background = customBackgroundColor.flatMap(NSColor.init(validHex:)) {
            return .custom(background: background, text: text, base: paletteName.palette)
        }
        return paletteName.palette
    }

    /// Effective accent colour: explicit accent if set, else palette's own
    /// accent (used for "system" → palette default).
    var effectiveAccent: NSColor {
        switch accent {
        case .system: return palette.accent
        default:      return accent.color
        }
    }

    /// The one place the body font is resolved. Highlighter, text view and
    /// reflow all call this, so they can never disagree.
    func resolvedBodyFont(size: CGFloat) -> NSFont {
        if let name = bodyFontName {
            if name == SystemSerif.familyDisplayName {
                return SystemSerif.font(size: size)
            }
            if let font = NSFontManager.shared.font(withFamily: name, traits: [],
                                                    weight: 5, size: size) {
                return font
            }
        }
        return bodyFont.font(size: size)
    }

    var bodyFontSelection: BodyFontSelection {
        if let name = bodyFontName {
            return name == SystemSerif.familyDisplayName ? .newYork : .family(name)
        }
        return bodyFont == .mono ? .sfMono : .sfPro
    }

    /// Writes both fields so an older build (which only knows `bodyFont`)
    /// still gets the closest match: mono for fixed-pitch families, sans
    /// for everything else.
    mutating func setBodyFontSelection(_ selection: BodyFontSelection) {
        switch selection {
        case .sfPro:
            bodyFont = .sans
            bodyFontName = nil
        case .sfMono:
            bodyFont = .mono
            bodyFontName = nil
        case .newYork:
            bodyFont = .sans
            bodyFontName = SystemSerif.familyDisplayName
        case .family(let name):
            let probe = NSFontManager.shared.font(withFamily: name, traits: [], weight: 5, size: 13)
            bodyFont = probe?.isFixedPitch == true ? .mono : .sans
            bodyFontName = name
        }
    }

    /// `false` when two themes differ only in fields that never touch the
    /// text's attributes (chrome appearance, column width, word count,
    /// card look, preset label). The editor then skips the full-document
    /// re-colouring pass.
    func restyles(comparedTo other: EditorTheme) -> Bool {
        stylingFields != other.stylingFields
    }

    private var stylingFields: EditorTheme {
        var t = self
        t.preset = .stockPlus
        t.appearance = .automatic
        t.lineWidth = .full
        t.cardLayout = false
        t.showStatusBar = true
        return t
    }

    /// A fresh install. Differs from what an old JSON decodes to in
    /// `bodyFont` (SF Pro instead of SF Mono) and `lineWidth` (readable
    /// instead of full): existing users keep their look, new users get
    /// the 0.10 defaults.
    static let `default` = EditorTheme(
        preset: .stockPlus,
        paletteName: .white,
        accent: .system,
        bodyFont: .sans,
        headingFont: .sans,
        headingScale: .defaultScale,
        codeStyle: .card,
        headingRule: false,
        showStatusBar: true,
        fontBaseSize: 14.5,
        appearance: .automatic,
        lineWidth: .readable,
        cardLayout: false
    )

    /// Settings shows sizes as "17 pt" and "14.5 pt" (the old label
    /// truncated 14.5 to "14 pt"). `%g` always uses a period and drops a
    /// trailing ".0".
    static func formattedSize(_ size: CGFloat) -> String {
        String(format: "%g pt", Double(size))
    }
}

extension EditorTheme {
    private enum CodingKeys: String, CodingKey {
        case preset, paletteName, accent, bodyFont, headingFont, headingScale,
             codeStyle, headingRule, showStatusBar, fontBaseSize,
             appearance, lineWidth, cardLayout, useCustomColors,
             customTextColor, customBackgroundColor, bodyFontName
    }

    /// Fields that every build since 0.1 writes stay strictly required: a
    /// blob missing one is corrupt and `ThemeStore` falls back (and backs
    /// it up). Newer fields are optional, and an unknown value in one of
    /// them (written by a future build) resets only that field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        preset        = try c.decode(PresetVariant.self, forKey: .preset)
        paletteName   = try c.decode(PaletteName.self, forKey: .paletteName)
        accent        = try c.decode(AccentChoice.self, forKey: .accent)
        bodyFont      = try c.decode(BodyFontFamily.self, forKey: .bodyFont)
        headingFont   = try c.decode(HeadingFontFamily.self, forKey: .headingFont)
        headingScale  = try c.decode(HeadingScale.self, forKey: .headingScale)
        codeStyle     = try c.decode(CodeBlockStyle.self, forKey: .codeStyle)
        headingRule   = try c.decode(Bool.self, forKey: .headingRule)
        showStatusBar = try c.decode(Bool.self, forKey: .showStatusBar)
        fontBaseSize  = try c.decode(CGFloat.self, forKey: .fontBaseSize)

        func optional<T: Decodable>(_ type: T.Type, _ key: CodingKeys) -> T? {
            (try? c.decodeIfPresent(type, forKey: key)) ?? nil
        }
        // Defaults for a JSON without the key: the look before 0.10.
        appearance            = optional(AppearanceMode.self, .appearance) ?? .automatic
        lineWidth             = optional(LineWidth.self, .lineWidth) ?? .full
        cardLayout            = optional(Bool.self, .cardLayout) ?? (preset == .tahoe)
        useCustomColors       = optional(Bool.self, .useCustomColors) ?? false
        customTextColor       = optional(String.self, .customTextColor)
        customBackgroundColor = optional(String.self, .customBackgroundColor)
        bodyFontName          = optional(String.self, .bodyFontName)
    }
}

// MARK: - NSColor hex helper

extension NSColor {
    /// Initialize from a `#RRGGBB` or `#RRGGBBAA` hex string in sRGB.
    convenience init(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        var value: UInt64 = 0
        Scanner(string: s).scanHexInt64(&value)
        let r, g, b, a: CGFloat
        if s.count == 8 {
            r = CGFloat((value >> 24) & 0xff) / 255
            g = CGFloat((value >> 16) & 0xff) / 255
            b = CGFloat((value >>  8) & 0xff) / 255
            a = CGFloat( value        & 0xff) / 255
        } else {
            r = CGFloat((value >> 16) & 0xff) / 255
            g = CGFloat((value >>  8) & 0xff) / 255
            b = CGFloat( value        & 0xff) / 255
            a = 1.0
        }
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

extension NSColor {
    /// Like `init(hex:)`, but `nil` unless the string is exactly six or
    /// eight hex digits (with or without "#"). Stored custom colours go
    /// through this so a damaged value falls back to the built-in palette
    /// instead of painting black.
    convenience init?(validHex: String) {
        var s = validHex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 6 || s.count == 8, s.allSatisfy(\.isHexDigit) else { return nil }
        self.init(hex: s)
    }
}

// MARK: - Codable for NSColor (sRGB hex)

extension Palette {
    private enum CodingKeys: String, CodingKey {
        case bg, bgTint, fg, fgMuted, rule, ruleStrong, chrome,
             codeBg, codeInlineBg, codeFg, synKw, accent, highlight, math
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func col(_ k: CodingKeys) throws -> NSColor {
            NSColor(hex: try c.decode(String.self, forKey: k))
        }
        bg           = try col(.bg)
        bgTint       = try col(.bgTint)
        fg           = try col(.fg)
        fgMuted      = try col(.fgMuted)
        rule         = try col(.rule)
        ruleStrong   = try col(.ruleStrong)
        chrome       = try col(.chrome)
        codeBg       = try col(.codeBg)
        codeInlineBg = try col(.codeInlineBg)
        codeFg       = try col(.codeFg)
        synKw        = try col(.synKw)
        accent       = try col(.accent)
        highlight    = try col(.highlight)
        math         = try col(.math)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        func put(_ k: CodingKeys, _ color: NSColor) throws {
            try c.encode(color.toHex(), forKey: k)
        }
        try put(.bg, bg)
        try put(.bgTint, bgTint)
        try put(.fg, fg)
        try put(.fgMuted, fgMuted)
        try put(.rule, rule)
        try put(.ruleStrong, ruleStrong)
        try put(.chrome, chrome)
        try put(.codeBg, codeBg)
        try put(.codeInlineBg, codeInlineBg)
        try put(.codeFg, codeFg)
        try put(.synKw, synKw)
        try put(.accent, accent)
        try put(.highlight, highlight)
        try put(.math, math)
    }
}

extension NSColor {
    func toHex() -> String {
        let s = usingColorSpace(.sRGB) ?? self
        let r = Int((s.redComponent   * 255).rounded())
        let g = Int((s.greenComponent * 255).rounded())
        let b = Int((s.blueComponent  * 255).rounded())
        let a = Int((s.alphaComponent * 255).rounded())
        if a == 255 {
            return String(format: "#%02x%02x%02x", r, g, b)
        } else {
            return String(format: "#%02x%02x%02x%02x", r, g, b, a)
        }
    }
}
