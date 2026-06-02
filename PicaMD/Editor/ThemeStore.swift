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

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.theme = Self.load(defaults: defaults, key: defaultsKey)
            ?? EditorTheme.default
        Self.currentPalette = self.theme.palette
        Self.currentAccent = self.theme.effectiveAccent
    }

    private let defaults: UserDefaults

    /// Mutate the current theme via a closure. Persists immediately.
    func update(_ block: (inout EditorTheme) -> Void) {
        var next = theme
        block(&next)
        guard next != theme else { return }
        theme = next
        Self.currentPalette = next.palette
        Self.currentAccent = next.effectiveAccent
        NotificationCenter.default.post(name: Self.themeChangedNotification, object: nil)
        save()
    }

    /// Switch to a built-in preset. Palette/accent are preserved.
    func selectPreset(_ p: PresetVariant) {
        update { p.applyDefaults(to: &$0) }
    }

    /// Convenience setters for the SwiftUI Settings view.
    func setPalette(_ p: PaletteName) { update { $0.paletteName = p } }
    func setAccent(_ a: AccentChoice) { update { $0.accent = a } }
    func setBodyFont(_ f: BodyFontFamily) { update { $0.bodyFont = f } }
    func setHeadingFont(_ f: HeadingFontFamily) { update { $0.headingFont = f } }
    func setHeadingScale(_ s: HeadingScale) { update { $0.headingScale = s } }
    func setCodeStyle(_ c: CodeBlockStyle) { update { $0.codeStyle = c } }
    func setHeadingRule(_ on: Bool) { update { $0.headingRule = on } }
    func setShowStatusBar(_ on: Bool) { update { $0.showStatusBar = on } }
    func setBaseFontSize(_ size: CGFloat) { update { $0.fontBaseSize = size } }

    /// Reset everything back to the canonical default theme.
    func resetToDefault() {
        theme = .default
        save()
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
