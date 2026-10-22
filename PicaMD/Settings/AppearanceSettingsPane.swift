import SwiftUI
import AppKit

/// Settings ▸ Appearance: preset cards, chrome appearance, editor colours
/// and typography (design board "Settings").
///
/// Selection rings use the system accent colour on purpose: the user's
/// accent belongs to the editor (headings, links, checkboxes) and the
/// selection lists, Settings controls keep the system look.
struct AppearanceSettingsPane: View {
    @EnvironmentObject private var themeStore: ThemeStore

    private var theme: EditorTheme { themeStore.theme }

    var body: some View {
        Form {
            Section {
                HStack(alignment: .top, spacing: 0) {
                    ForEach(PresetVariant.allCases) { preset in
                        Spacer(minLength: 0)
                        PresetCard(preset: preset, isSelected: preset.matches(theme)) {
                            themeStore.selectPreset(preset)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .padding(.vertical, 6)
            }

            Section {
                Picker("Appearance", selection: Binding(
                    get: { theme.appearance },
                    set: { themeStore.setAppearance($0) }
                )) {
                    ForEach(AppearanceMode.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Background") {
                    HStack(spacing: 12) {
                        ForEach(PaletteName.allCases) { name in
                            PaletteSwatch(palette: name.palette, help: name.displayName,
                                          isSelected: !theme.useCustomColors && theme.paletteName == name) {
                                themeStore.setPalette(name)
                            }
                        }
                        CustomPaletteSwatch(isSelected: theme.useCustomColors) {
                            themeStore.selectCustomColors()
                        }
                    }
                }

                if theme.useCustomColors {
                    ColorPicker("Text color", selection: Binding(
                        get: { Color(nsColor: theme.palette.fg) },
                        set: { themeStore.setCustomTextColor(NSColor($0)) }
                    ), supportsOpacity: false)
                    ColorPicker("Background color", selection: Binding(
                        get: { Color(nsColor: theme.palette.bg) },
                        set: { themeStore.setCustomBackgroundColor(NSColor($0)) }
                    ), supportsOpacity: false)
                }

                LabeledContent("Accent color") {
                    HStack(spacing: 10) {
                        ForEach(AccentChoice.allCases) { accent in
                            AccentDot(accent: accent, palette: theme.palette,
                                      isSelected: theme.accent == accent) {
                                themeStore.setAccent(accent)
                            }
                        }
                    }
                }
            }

            Section {
                BodyFontPicker()

                Picker("Heading font", selection: Binding(
                    get: { theme.headingFont },
                    set: { themeStore.setHeadingFont($0) }
                )) {
                    ForEach(HeadingFontFamily.allCases) { Text($0.displayName).tag($0) }
                }
                .pickerStyle(.segmented)

                LabeledContent("Size") {
                    HStack(spacing: 4) {
                        Text(EditorTheme.formattedSize(theme.fontBaseSize))
                            .monospacedDigit()
                            .foregroundStyle(.primary)
                        Stepper("Size", value: Binding(
                            get: { theme.fontBaseSize },
                            set: { themeStore.setBaseFontSize($0) }
                        ), in: 12...18, step: 0.5)
                        .labelsHidden()
                    }
                }

                Picker("Line width", selection: Binding(
                    get: { theme.lineWidth },
                    set: { themeStore.setLineWidth($0) }
                )) {
                    ForEach(LineWidth.allCases) { Text($0.displayName).tag($0) }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { BodyFontPanel.shared.detach() }
    }
}

// MARK: - Preset card

extension PresetVariant {
    /// The card's VoiceOver name: "Editorial, <subtitle>", without the
    /// sample text drawn on the card.
    var cardAccessibilityLabel: String { "\(displayName), \(subtitle)" }
}

/// "Aa Heading" card drawn with the preset's own heading font, over four
/// grey text lines. Tahoe's card look and Editorial's hairline are drawn
/// too, so the three cards differ the way the presets do.
private struct PresetCard: View {
    let preset: PresetVariant
    let isSelected: Bool
    let action: () -> Void

    private var look: EditorTheme {
        var theme = EditorTheme.default
        preset.applyDefaults(to: &theme)
        return theme
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                card
                Text(preset.displayName)
                    .font(.system(size: 12, weight: .semibold))
                Text(preset.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .buttonStyle(.plain)
        // Named by the preset alone: built from the child texts, every
        // card started with the sample "Aa Heading".
        .accessibilityLabel(preset.cardAccessibilityLabel)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var card: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        return VStack(alignment: .leading, spacing: 5) {
            Text("Aa Heading")
                .font(Font(look.headingFont.font(size: 15, bold: true)))
                .foregroundStyle(.primary)
                .padding(.bottom, look.headingRule ? 1 : 3)
            if look.headingRule {
                Rectangle()
                    .fill(Color.primary.opacity(0.15))
                    .frame(height: 0.5)
                    .padding(.bottom, 2)
            }
            ForEach(Array([0.92, 0.86, 0.90, 0.60].enumerated()), id: \.offset) { _, fraction in
                GeometryReader { proxy in
                    Capsule()
                        .fill(Color.secondary.opacity(0.3))
                        .frame(width: proxy.size.width * fraction, height: 4)
                }
                .frame(height: 4)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            if look.cardLayout {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.primary.opacity(0.12), lineWidth: 0.5)
                    .padding(5)
            }
        }
        .frame(width: 150, height: 96, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: shape)
        .overlay {
            shape.strokeBorder(isSelected ? Color.accentColor : Color.primary.opacity(0.12),
                               lineWidth: isSelected ? 2.5 : 0.5)
        }
        .contentShape(shape)
    }
}

// MARK: - Swatches

/// A built-in editor palette, shown by its background colour (the real
/// palette value, not the design board's approximations).
private struct PaletteSwatch: View {
    let palette: Palette
    let help: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: palette.bg))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5) }
                .frame(width: 22, height: 22)
                .modifier(SelectionRing(isSelected: isSelected, gap: 2, width: 2))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// The fifth swatch: own text and background colours.
private struct CustomPaletteSwatch: View {
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(AngularGradient(colors: [.red, .yellow, .green, .cyan, .blue, .purple, .red],
                                      center: .center))
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5) }
                .frame(width: 22, height: 22)
                .modifier(SelectionRing(isSelected: isSelected, gap: 2, width: 2))
        }
        .buttonStyle(.plain)
        .help("Custom")
        .accessibilityLabel("Custom")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// One accent choice. "System" shows the colour it resolves to on the
/// current palette (the palette's own accent, e.g. amber on Off-White),
/// marked with an inner ring so it can't be mistaken for Blue.
private struct AccentDot: View {
    let accent: AccentChoice
    let palette: Palette
    let isSelected: Bool
    let action: () -> Void

    private var color: NSColor { accent == .system ? palette.accent : accent.color }

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(Color(nsColor: color))
                .overlay {
                    if accent == .system {
                        Circle().strokeBorder(Color.white.opacity(0.9), lineWidth: 1.5).padding(3.5)
                    }
                }
                .frame(width: 16, height: 16)
                .modifier(SelectionRing(isSelected: isSelected, gap: 2, width: 1.5,
                                        color: Color(nsColor: color)))
        }
        .buttonStyle(.plain)
        .help(accent.displayName)
        .accessibilityLabel(accent.displayName)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Board selection mark: a gap, then a ring. Drawn outside the swatch's
/// frame so a selected row is no taller than the others (a taller row
/// pulls the form's row label up to its top).
private struct SelectionRing: ViewModifier {
    let isSelected: Bool
    let gap: CGFloat
    let width: CGFloat
    var color: Color = .accentColor

    func body(content: Content) -> some View {
        content
            .overlay {
                if isSelected {
                    Circle()
                        .strokeBorder(color, lineWidth: width)
                        .padding(-(gap + width))
                }
            }
    }
}

// MARK: - Body font

/// Font popup: SF Pro, SF Mono, New York, the family picked in the font
/// panel (if any), and "Other…" to pick one.
private struct BodyFontPicker: View {
    @EnvironmentObject private var themeStore: ThemeStore

    private enum Item: Hashable {
        case choice(BodyFontSelection)
        case other
    }

    var body: some View {
        let current = themeStore.theme.bodyFontSelection
        Picker("Font", selection: Binding<Item>(
            get: { .choice(current) },
            set: { item in
                switch item {
                case .choice(let selection):
                    themeStore.setBodyFontSelection(selection)
                case .other:
                    showFontPanel()
                }
            }
        )) {
            Text(BodyFontSelection.sfPro.displayName).tag(Item.choice(.sfPro))
            Text(BodyFontSelection.sfMono.displayName).tag(Item.choice(.sfMono))
            Text(BodyFontSelection.newYork.displayName).tag(Item.choice(.newYork))
            Divider()
            if case .family(let name) = current {
                Text(name).tag(Item.choice(current))
            }
            Text("Other…").tag(Item.other)
        }
    }

    private func showFontPanel() {
        let theme = themeStore.theme
        BodyFontPanel.shared.show(current: theme.resolvedBodyFont(size: theme.fontBaseSize)) { family in
            themeStore.setBodyFontSelection(.family(family))
        }
    }
}

/// Drives the shared font panel for the body-font choice. Only the
/// family is used: size has its own control and weight/style come from
/// the Markdown.
@MainActor
final class BodyFontPanel: NSObject, NSFontChanging {
    static let shared = BodyFontPanel()

    private var onPick: ((String) -> Void)?

    func show(current: NSFont, onPick: @escaping (String) -> Void) {
        self.onPick = onPick
        let manager = NSFontManager.shared
        manager.target = self
        manager.setSelectedFont(current, isMultiple: false)
        manager.orderFrontFontPanel(self)
    }

    /// Stop receiving font-panel changes once the Appearance pane goes
    /// away (another Settings tab or the window closing), so the panel
    /// can't change the editor font from elsewhere later. The panel is
    /// closed too when it was opened from here: left open it would accept
    /// choices and silently drop them.
    func detach(closing panel: NSPanel? = NSFontManager.shared.fontPanel(false)) {
        let manager = NSFontManager.shared
        if manager.target === self {
            manager.target = nil
            panel?.orderOut(nil)
        }
        onPick = nil
    }

    func changeFont(_ sender: NSFontManager?) {
        guard let sender else { return }
        let picked = sender.convert(NSFont.systemFont(ofSize: NSFont.systemFontSize))
        guard let family = picked.familyName, !family.hasPrefix(".") else { return }
        onPick?(family)
    }

    func validModesForFontPanel(_ fontPanel: NSFontPanel) -> NSFontPanel.ModeMask {
        [.collection]
    }
}
