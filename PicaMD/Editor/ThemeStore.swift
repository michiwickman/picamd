import SwiftUI
import Combine

/// Single source of truth for the editor's theme. Persists every
/// mutation to `UserDefaults` so the app reopens with the user's
/// chosen look. A single `@Published` `theme` value lets SwiftUI views
/// re-render and the NSTextView coordinator re-highlight on change.
@MainActor
final class ThemeStore: ObservableObject {
    @Published private(set) var theme: EditorTheme

    private let defaultsKey = "PicaMD.editorTheme.v1"

    /// Palette mirror for non-SwiftUI consumers (NSTextView block
    /// overlays — `BlockAttachmentView`, `MathBlockView`,
    /// `MermaidBlockView`). Updated on every theme mutation. Read on
    /// the main thread; writes also happen on main (we're @MainActor),
    /// so the `nonisolated(unsafe)` is a documented pinky-promise to
    /// the compiler, not actual unsafety.
    nonisolated(unsafe) static var currentPalette: Palette = EditorTheme.default.palette

    /// The user's *effective* accent colour (palette default unless the
    /// user picked an explicit AccentChoice). Mirrored here so AppKit-
    /// hosted chrome outside the SwiftUI scene — e.g. the welcome window —
    /// can tint itself with the user's accent. Updated in lockstep with
    /// `currentPalette`.
    nonisolated(unsafe) static var currentAccent: NSColor = EditorTheme.default.effectiveAccent

    /// Posted whenever `theme` changes. AppKit block views subscribe
    /// here and call `appearanceChanged()` so their WKWebView HTML
    /// reloads with the new palette colours.
    static let themeChangedNotification = Notification.Name("PicaMD.themeChanged")

    /// - Parameter appearanceSink: receives the chrome appearance at launch
    ///   and whenever it changes. The app passes `NSApp.appearance = $0`;
    ///   tests leave it `nil` so they don't restyle the test host.
    init(defaults: UserDefaults = .standard,
         appearanceSink: (@MainActor (NSAppearance?) -> Void)? = nil) {
        self.defaults = defaults
        self.appearanceSink = appearanceSink
        let stored = defaults.data(forKey: defaultsKey) != nil
        self.theme = Self.load(defaults: defaults, key: defaultsKey)
            ?? (stored ? EditorTheme.default : Self.firstTheme(defaults: defaults))
        // The choice between the two looks is made once: the next launch
        // must not take this install's own recents for an upgrade.
        if !stored { save() }
        Self.currentPalette = self.theme.palette
        Self.currentAccent = self.theme.effectiveAccent
        appearanceSink?(theme.appearance.nsAppearance)
    }

    private let defaults: UserDefaults
    private let appearanceSink: (@MainActor (NSAppearance?) -> Void)?

    /// Mutate the current theme via a closure. Persists immediately.
    func update(_ block: (inout EditorTheme) -> Void) {
        var next = theme
        block(&next)
        guard next != theme else { return }
        let appearanceChanged = next.appearance != theme.appearance
        theme = next
        if appearanceChanged {
            appearanceSink?(next.appearance.nsAppearance)
        }
        Self.currentPalette = next.palette
        Self.currentAccent = next.effectiveAccent
        NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
        save()
    }

    /// Switch to a built-in preset. Palette/accent are preserved.
    /// A click on the card that is already selected only records the
    /// label, like any selection control. Without this, a fresh install
    /// (Stock+ shown selected, SF Pro body) would switch to SF Mono on that
    /// click, because `matches` ignores the body font but `applyDefaults`
    /// sets it.
    func selectPreset(_ p: PresetVariant) {
        if p.matches(theme) {
            update { $0.preset = p }
        } else {
            update { p.applyDefaults(to: &$0) }
        }
    }

    /// Convenience setters for the SwiftUI Settings view.
    func setAccent(_ a: AccentChoice) { update { $0.accent = a } }
    func setBodyFont(_ f: BodyFontFamily) { update { $0.bodyFont = f } }
    func setHeadingFont(_ f: HeadingFontFamily) { update { $0.headingFont = f } }
    func setHeadingScale(_ s: HeadingScale) { update { $0.headingScale = s } }
    func setCodeStyle(_ c: CodeBlockStyle) { update { $0.codeStyle = c } }
    func setHeadingRule(_ on: Bool) { update { $0.headingRule = on } }
    func setShowStatusBar(_ on: Bool) { update { $0.showStatusBar = on } }
    func setBaseFontSize(_ size: CGFloat) { update { $0.fontBaseSize = size } }
    func setAppearance(_ mode: AppearanceMode) { update { $0.appearance = mode } }
    func setLineWidth(_ width: LineWidth) { update { $0.lineWidth = width } }
    func setCardLayout(_ on: Bool) { update { $0.cardLayout = on } }
    func setBodyFontSelection(_ selection: BodyFontSelection) {
        update { $0.setBodyFontSelection(selection) }
    }

    /// Switch the editor surface to the custom colours. The first time,
    /// they start as the current palette's text and background, so the
    /// switch itself changes nothing visible.
    func selectCustomColors() {
        update { theme in
            let current = theme.palette
            if theme.customTextColor == nil { theme.customTextColor = current.fg.toHex() }
            if theme.customBackgroundColor == nil { theme.customBackgroundColor = current.bg.toHex() }
            theme.useCustomColors = true
        }
    }

    /// Picking a built-in swatch also leaves custom colours, but keeps
    /// them stored for the next time the user picks Custom.
    func setPalette(_ p: PaletteName) {
        update {
            $0.paletteName = p
            $0.useCustomColors = false
        }
    }

    func setCustomTextColor(_ color: NSColor) {
        update { $0.customTextColor = Self.opaqueHex(color) }
    }

    func setCustomBackgroundColor(_ color: NSColor) {
        update { $0.customBackgroundColor = Self.opaqueHex(color) }
    }

    /// `#rrggbb` in sRGB. Alpha is dropped: a translucent editor
    /// background or text colour has no meaning here.
    static func opaqueHex(_ color: NSColor) -> String {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        return srgb.withAlphaComponent(1).toHex()
    }

    /// Reset everything back to the canonical default theme.
    func resetToDefault() {
        // Through `update` so the palette/accent mirrors and block
        // overlays follow too (they kept the old palette before).
        update { $0 = .default }
    }

    // MARK: - Persistence

    private func save() {
        do {
            let data = try JSONEncoder().encode(theme)
            defaults.set(data, forKey: defaultsKey)
        } catch {
            NSLog("PicaMD: failed to persist theme: \(error)")
        }
    }

    /// Keys 0.9 and earlier wrote through use alone: a document opened,
    /// the AI settings or presets loaded, an update check run. This
    /// version writes none of them before the theme is first loaded (the
    /// App creates the theme store before any document or Settings
    /// window), so one of them means an install from before 0.10 whose
    /// theme was never changed. Keys with registered defaults can't tell
    /// anything and are left out.
    static let earlierUseKeys = [
        RecentDocumentsList.defaultsKey,
        AIConfig.storageKey,
        AIConfig.presetsStorageKey,
        "PicaMD.ai.enabled",            // the AI settings before v2
        "SULastCheckTime",              // Sparkle, after an update check
    ]

    /// The theme when none is stored. Versions before 0.10 saved the
    /// theme only once a setting changed, so an upgrader who never opened
    /// Settings has no stored theme either. Such an install keeps the look
    /// it had (SF Mono, full width), which is what an old stored theme
    /// decodes to; only a new install gets the 0.10 defaults.
    static func firstTheme(defaults: UserDefaults) -> EditorTheme {
        let upgraded = earlierUseKeys.contains { defaults.object(forKey: $0) != nil }
        guard upgraded else { return .default }
        var theme = EditorTheme.default
        theme.bodyFont = .mono
        theme.lineWidth = .full
        return theme
    }

    private static func load(defaults: UserDefaults, key: String) -> EditorTheme? {
        guard let data = defaults.data(forKey: key) else { return nil }
        do {
            return try JSONDecoder().decode(EditorTheme.self, from: data)
        } catch {
            NSLog("PicaMD: theme JSON corrupt, falling back to default: \(error)")
            // Preserve the first bad blob for forensics; never clobber a
            // previously saved backup so the original corrupt data survives.
            let backupKey = "\(key).corrupt-backup"
            if defaults.data(forKey: backupKey) == nil {
                defaults.set(data, forKey: backupKey)
            }
            return nil
        }
    }
}
