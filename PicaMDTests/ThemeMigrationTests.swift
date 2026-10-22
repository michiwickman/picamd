import XCTest
import AppKit
@testable import PicaMD

/// The 0.10 theme model must read every theme an older build stored and
/// render it exactly as before; new fields get their old-look defaults.
@MainActor
final class ThemeMigrationTests: XCTestCase {

    /// A 0.9 theme with non-default accent, palette and size (pink, OLED, 17 pt).
    static let customizedJSON = #"{"bodyFont":"mono","preset":"stock-plus","headingScale":"default","headingFont":"sans","codeStyle":"card","headingRule":false,"showStatusBar":true,"accent":"pink","fontBaseSize":17,"paletteName":"oled"}"#
    /// `EditorTheme.default` as 0.9 encoded it.
    static let oldDefaultJSON = #"{"accent":"system","bodyFont":"mono","codeStyle":"card","fontBaseSize":14.5,"headingFont":"sans","headingRule":false,"headingScale":"default","paletteName":"white","preset":"stock-plus","showStatusBar":true}"#
    static let tahoeJSON = #"{"accent":"orange","bodyFont":"mono","codeStyle":"tinted","fontBaseSize":15,"headingFont":"sans","headingRule":false,"headingScale":"tight","paletteName":"darkgrey","preset":"tahoe","showStatusBar":false}"#
    static let offwhiteJSON = #"{"accent":"system","bodyFont":"sans","codeStyle":"stripe","fontBaseSize":13.5,"headingFont":"sans","headingRule":true,"headingScale":"airy","paletteName":"offwhite","preset":"editorial","showStatusBar":true}"#

    private func decode(_ json: String) throws -> EditorTheme {
        try JSONDecoder().decode(EditorTheme.self, from: Data(json.utf8))
    }

    private var repositoryRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    }

    private func recordedSnapshot(_ name: String) throws -> String {
        let url = repositoryRoot.appendingPathComponent("PicaMDTests/Fixtures/theme-snapshots/\(name).txt")
        return try String(contentsOf: url, encoding: .utf8)
    }

    private var suiteCount = 0

    private func makeIsolatedDefaults() -> UserDefaults {
        suiteCount += 1
        return makeTestDefaults("ThemeMigration.\(suiteCount)")
    }

    // MARK: Identical look

    /// Every attribute run of a sample document — fonts, sizes, colours,
    /// paragraph metrics — compared with what the 0.9 code produced for
    /// the same stored JSON (fixtures recorded before the model change).
    func testStoredThemesRenderExactlyAsBefore() throws {
        let cases = [("customized", Self.customizedJSON), ("olddefault", Self.oldDefaultJSON),
                     ("tahoe", Self.tahoeJSON), ("offwhite", Self.offwhiteJSON)]
        for (name, json) in cases {
            let theme = try decode(json)
            XCTAssertEqual(ThemeSnapshot.digest(theme), try recordedSnapshot(name),
                           "\(name): rendering changed")
        }
    }

    func testCustomizedThemeDecodesToTheSameValues() throws {
        let theme = try decode(Self.customizedJSON)
        XCTAssertEqual(theme.preset, .stockPlus)
        XCTAssertEqual(theme.paletteName, .oled)
        XCTAssertEqual(theme.accent, .pink)
        XCTAssertEqual(theme.bodyFont, .mono)
        XCTAssertEqual(theme.headingFont, .sans)
        XCTAssertEqual(theme.headingScale, .defaultScale)
        XCTAssertEqual(theme.codeStyle, .card)
        XCTAssertFalse(theme.headingRule)
        XCTAssertTrue(theme.showStatusBar)
        XCTAssertEqual(theme.fontBaseSize, 17)
        XCTAssertEqual(theme.palette.bg.toHex(), "#000000")
        XCTAssertEqual(theme.palette.fg.toHex(), "#e9e9ea")
        XCTAssertEqual(theme.effectiveAccent.toHex(), "#ff375f")
        let font = theme.resolvedBodyFont(size: theme.fontBaseSize)
        XCTAssertEqual(font.fontName, NSFont.monospacedSystemFont(ofSize: 17, weight: .regular).fontName)
        XCTAssertEqual(font.pointSize, 17)
        // New fields: the look before 0.10.
        XCTAssertEqual(theme.appearance, .automatic)
        XCTAssertEqual(theme.lineWidth, .full)
        XCTAssertFalse(theme.cardLayout)
        XCTAssertFalse(theme.useCustomColors)
        XCTAssertNil(theme.bodyFontName)
        XCTAssertEqual(theme.bodyFontSelection, .sfMono)
        XCTAssertTrue(PresetVariant.stockPlus.matches(theme), "the Stock+ card must show as selected")
    }

    func testFullLineWidthKeepsTheOldFixedMargin() throws {
        let theme = try decode(Self.customizedJSON)
        let column = theme.lineWidth.columnWidth(for: theme.resolvedBodyFont(size: theme.fontBaseSize))
        for width: CGFloat in [400, 940, 2560] {
            XCTAssertEqual(EditorLayout.horizontalInset(containerWidth: width, columnWidth: column,
                                                        lineFragmentPadding: 5),
                           EditorLayout.textContainerInsetWidth)
        }
    }

    func testLegacyTahoeKeepsItsCardLook() throws {
        XCTAssertTrue(try decode(Self.tahoeJSON).cardLayout)
        XCTAssertFalse(try decode(Self.offwhiteJSON).cardLayout)
        XCTAssertFalse(try decode(Self.tahoeJSON).showStatusBar, "stored word-count choice kept")
    }

    func testLegacyBlobLoadsWithoutCorruptFallbackAndIsNotRewritten() throws {
        let defaults = makeIsolatedDefaults()
        let blob = Data(Self.customizedJSON.utf8)
        defaults.set(blob, forKey: "PicaMD.editorTheme.v1")
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme.paletteName, .oled)
        XCTAssertNil(defaults.data(forKey: "PicaMD.editorTheme.v1.corrupt-backup"))
        XCTAssertEqual(defaults.data(forKey: "PicaMD.editorTheme.v1"), blob,
                       "loading must not rewrite the stored theme (rollback stays lossless)")
    }

    // MARK: Defaults

    func testFreshInstallDefaultsDifferFromLegacyDecodeDefaults() throws {
        XCTAssertEqual(EditorTheme.default.lineWidth, .readable)
        XCTAssertEqual(EditorTheme.default.bodyFont, .sans)
        XCTAssertEqual(EditorTheme.default.bodyFontSelection, .sfPro)
        XCTAssertEqual(EditorTheme.default.appearance, .automatic)
        XCTAssertFalse(EditorTheme.default.cardLayout)
        let legacy = try decode(Self.oldDefaultJSON)
        XCTAssertEqual(legacy.lineWidth, .full)
        XCTAssertEqual(legacy.bodyFont, .mono)
    }

    /// 0.9 saved the theme only once a setting changed. An upgrader who
    /// never touched Settings has no stored theme, but recents and other
    /// keys from using the app: that install keeps SF Mono at full width.
    func testUpgradeWithoutAStoredThemeKeepsTheOldLook() {
        let defaults = makeIsolatedDefaults()
        defaults.set(["/Users/m/a.md"], forKey: RecentDocumentsList.defaultsKey)
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme.bodyFont, .mono)
        XCTAssertEqual(store.theme.lineWidth, .full)
        XCTAssertNotNil(defaults.data(forKey: "PicaMD.editorTheme.v1"), "decided once and stored")
    }

    func testNewInstallGetsTheNewDefaultsAndKeepsThem() {
        let defaults = makeIsolatedDefaults()
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, EditorTheme.default)
        // Using the app afterwards must not turn it into an "upgrade".
        defaults.set(["/Users/m/a.md"], forKey: RecentDocumentsList.defaultsKey)
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, EditorTheme.default)
    }

    func testFreshInstallResolvesToSFPro() {
        let font = EditorTheme.default.resolvedBodyFont(size: 14.5)
        XCTAssertEqual(font.fontName, NSFont.systemFont(ofSize: 14.5).fontName)
        XCTAssertFalse(font.isFixedPitch)
    }

    // MARK: Codable

    func testRoundTripKeepsEveryField() throws {
        var theme = EditorTheme.default
        theme.preset = .tahoe
        theme.paletteName = .darkgrey
        theme.accent = .purple
        theme.bodyFont = .mono
        theme.headingFont = .serif
        theme.headingScale = .airy
        theme.codeStyle = .stripe
        theme.headingRule = true
        theme.showStatusBar = false
        theme.fontBaseSize = 16.5
        theme.appearance = .dark
        theme.lineWidth = .wide
        theme.cardLayout = true
        theme.useCustomColors = true
        theme.customTextColor = "#112233"
        theme.customBackgroundColor = "#fafafa"
        theme.bodyFontName = "Menlo"
        let data = try JSONEncoder().encode(theme)
        XCTAssertEqual(try JSONDecoder().decode(EditorTheme.self, from: data), theme)

        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        store.update { $0 = theme }
        XCTAssertEqual(ThemeStore(defaults: defaults).theme, theme)
    }

    /// An older build decodes with the synthesized 0.9 decoder: it needs
    /// the ten original keys with values it knows, and ignores the rest.
    func testEncodingKeepsTheKeysOlderBuildsRead() throws {
        var theme = try decode(Self.customizedJSON)
        theme.setBodyFontSelection(.newYork)
        theme.useCustomColors = true
        theme.customTextColor = "#eeeeee"
        theme.customBackgroundColor = "#101820"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
        for key in ["preset", "paletteName", "accent", "bodyFont", "headingFont", "headingScale",
                    "codeStyle", "headingRule", "showStatusBar", "fontBaseSize"] {
            XCTAssertNotNil(object[key], key)
        }
        XCTAssertEqual(object["bodyFont"] as? String, "sans", "New York is stored as sans for old builds")
        XCTAssertEqual(object["paletteName"] as? String, "oled", "custom colours keep the last built-in palette")
    }

    func testMissingOriginalFieldStillCountsAsCorrupt() {
        let json = #"{"accent":"pink","bodyFont":"mono","codeStyle":"card","fontBaseSize":17,"headingFont":"sans","headingRule":false,"headingScale":"default","paletteName":"oled","preset":"stock-plus"}"#
        XCTAssertThrowsError(try decode(json))
    }

    func testUnknownValueInANewFieldResetsOnlyThatField() throws {
        let json = #"{"accent":"pink","bodyFont":"mono","codeStyle":"card","fontBaseSize":17,"headingFont":"sans","headingRule":false,"headingScale":"default","paletteName":"oled","preset":"stock-plus","showStatusBar":true,"appearance":"sepia","lineWidth":"wide","cardLayout":"yes"}"#
        let theme = try decode(json)
        XCTAssertEqual(theme.appearance, .automatic)
        XCTAssertEqual(theme.lineWidth, .wide)
        XCTAssertFalse(theme.cardLayout)
        XCTAssertEqual(theme.accent, .pink)
    }

    // MARK: Presets

    func testPresetSwitchKeepsWordCountChoice() {
        var theme = EditorTheme.default
        theme.showStatusBar = false
        for preset in PresetVariant.allCases {
            preset.applyDefaults(to: &theme)
            XCTAssertFalse(theme.showStatusBar, "\(preset) turned the word count back on")
        }
    }

    func testPresetSwitchKeepsPersonalChoices() {
        var theme = EditorTheme.default
        theme.lineWidth = .wide
        theme.appearance = .dark
        theme.fontBaseSize = 16
        PresetVariant.editorial.applyDefaults(to: &theme)
        XCTAssertEqual(theme.lineWidth, .wide)
        XCTAssertEqual(theme.appearance, .dark)
        XCTAssertEqual(theme.fontBaseSize, 16)
    }

    func testOnlyTahoeTurnsOnTheCardLayout() {
        var theme = EditorTheme.default
        PresetVariant.tahoe.applyDefaults(to: &theme)
        XCTAssertTrue(theme.cardLayout)
        PresetVariant.editorial.applyDefaults(to: &theme)
        XCTAssertFalse(theme.cardLayout)
    }

    func testPresetCardSelectedOnlyOnExactMatch() {
        var theme = EditorTheme.default
        PresetVariant.editorial.applyDefaults(to: &theme)
        XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(theme) }, [.editorial])
        theme.codeStyle = .flat
        XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(theme) }, [],
                       "a changed field must clear the card selection")
        theme.codeStyle = .card
        // The body font is its own control under the cards, so a picked
        // family keeps the card; clicking a different preset still sets
        // that preset's body font.
        theme.setBodyFontSelection(.newYork)
        XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(theme) }, [.editorial])
        theme.setBodyFontSelection(.sfMono)
        XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(theme) }, [.editorial])
        theme.setBodyFontSelection(.newYork)
        PresetVariant.stockPlus.applyDefaults(to: &theme)
        XCTAssertNil(theme.bodyFontName, "a preset sets the body font, so a picked family is cleared")
        XCTAssertEqual(theme.bodyFont, .mono)
    }

    func testFreshInstallShowsTheStockPlusCardSelected() {
        XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(.default) }, [.stockPlus])
    }

    func testEveryPresetMatchesOnlyItself() {
        for preset in PresetVariant.allCases {
            for body: BodyFontSelection in [.sfPro, .sfMono, .newYork] {
                var theme = EditorTheme.default
                preset.applyDefaults(to: &theme)
                theme.setBodyFontSelection(body)
                XCTAssertEqual(PresetVariant.allCases.filter { $0.matches(theme) }, [preset],
                               "\(preset) with \(body)")
            }
        }
    }

    func testClickingTheSelectedCardKeepsTheBodyFont() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        XCTAssertEqual(store.theme, .default)
        store.selectPreset(.stockPlus)
        XCTAssertEqual(store.theme, .default, "a fresh install must keep SF Pro")
        store.selectPreset(.tahoe)
        XCTAssertEqual(store.theme.bodyFont, .mono, "a different card still applies its look")
        XCTAssertEqual(store.theme.preset, .tahoe)
        store.setBodyFontSelection(.newYork)
        store.selectPreset(.tahoe)
        XCTAssertEqual(store.theme.bodyFontSelection, .newYork)
    }

    func testResetAppearanceShowsTheStockPlusCardSelected() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        store.selectPreset(.editorial)
        store.resetToDefault()
        XCTAssertTrue(PresetVariant.stockPlus.matches(store.theme))
    }

    // MARK: Fonts

    func testSerifHeadingsAreNewYork() {
        let font = HeadingFontFamily.serif.font(size: 28, bold: true)
        XCTAssertTrue(font.fontName.contains("NewYork"), font.fontName)
        XCTAssertFalse(font.fontName.contains("Georgia"), font.fontName)
        XCTAssertTrue(font.fontDescriptor.symbolicTraits.contains(.bold), font.fontName)
        XCTAssertEqual(font.pointSize, 28)
    }

    func testBodyFontSelections() throws {
        var theme = try decode(Self.customizedJSON)
        theme.setBodyFontSelection(.newYork)
        XCTAssertTrue(theme.resolvedBodyFont(size: 17).fontName.contains("NewYork"))
        XCTAssertEqual(theme.bodyFontSelection, .newYork)

        theme.setBodyFontSelection(.family("Menlo"))
        XCTAssertEqual(theme.resolvedBodyFont(size: 17).familyName, "Menlo")
        XCTAssertEqual(theme.bodyFont, .mono, "fixed-pitch family keeps mono for old builds")
        XCTAssertEqual(theme.bodyFontSelection, .family("Menlo"))

        theme.setBodyFontSelection(.family("Helvetica"))
        XCTAssertEqual(theme.bodyFont, .sans)

        theme.bodyFontName = "No Such Family 4711"
        XCTAssertEqual(theme.resolvedBodyFont(size: 17).fontName,
                       BodyFontFamily.sans.font(size: 17).fontName,
                       "a family that is gone falls back to bodyFont")

        theme.setBodyFontSelection(.sfMono)
        XCTAssertNil(theme.bodyFontName)
        XCTAssertEqual(theme.bodyFont, .mono)
    }

    func testSizeLabel() {
        XCTAssertEqual(EditorTheme.formattedSize(14.5), "14.5 pt")
        XCTAssertEqual(EditorTheme.formattedSize(17), "17 pt")
        XCTAssertEqual(EditorTheme.formattedSize(12), "12 pt")
        XCTAssertEqual(EditorTheme.formattedSize(18), "18 pt")
    }

    // MARK: Custom colours

    private func luminance(_ color: NSColor) -> CGFloat {
        let c = color.usingColorSpace(.sRGB)!
        func linear(_ v: CGFloat) -> CGFloat { v <= 0.03928 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(c.redComponent) + 0.7152 * linear(c.greenComponent) + 0.0722 * linear(c.blueComponent)
    }

    private func contrast(_ a: NSColor, _ b: NSColor) -> CGFloat {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }

    func testCustomPaletteDerivation() throws {
        let pairs: [(bg: String, fg: String, dark: Bool)] = [
            ("#fdf6e3", "#333333", false),   // light, warm
            ("#102030", "#d8dee9", true),    // dark, blue
            ("#ffffff", "#000000", false),
            ("#000000", "#ffffff", true),
        ]
        for pair in pairs {
            let bg = try XCTUnwrap(NSColor(validHex: pair.bg))
            let fg = try XCTUnwrap(NSColor(validHex: pair.fg))
            let p = Palette.custom(background: bg, text: fg)
            XCTAssertEqual(p.bg.toHex(), pair.bg)
            XCTAssertEqual(p.fg.toHex(), pair.fg)
            XCTAssertEqual(p.isDark, pair.dark, pair.bg)
            XCTAssertEqual(p.synKw, (pair.dark ? Palette.darkgrey : Palette.white).synKw)
            for surface in [p.bgTint, p.codeBg, p.codeInlineBg] {
                XCTAssertNotEqual(surface.toHex(), p.bg.toHex(), "surface must be visible against bg")
                XCTAssertGreaterThan(contrast(p.fg, surface), contrast(p.fg, p.bg) * 0.75,
                                     "text must stay readable on derived surfaces (\(pair.bg))")
            }
            XCTAssertLessThan(p.fgMuted.alphaComponent, 1)
            XCTAssertLessThan(p.rule.alphaComponent, p.ruleStrong.alphaComponent)
        }
        // Deterministic.
        let a = Palette.custom(background: NSColor(hex: "#203040"), text: NSColor(hex: "#eeeeee"))
        let b = Palette.custom(background: NSColor(hex: "#203040"), text: NSColor(hex: "#eeeeee"))
        XCTAssertEqual(a, b)
    }

    func testThemeUsesCustomColorsOnlyWhenOnAndValid() {
        var theme = EditorTheme.default
        theme.paletteName = .offwhite
        theme.customTextColor = "#222222"
        theme.customBackgroundColor = "#eeffee"
        XCTAssertEqual(theme.palette.bg.toHex(), "#fbf9f4", "stored but off: built-in palette")
        theme.useCustomColors = true
        XCTAssertEqual(theme.palette.bg.toHex(), "#eeffee")
        XCTAssertEqual(theme.palette.fg.toHex(), "#222222")
        theme.customBackgroundColor = "not a colour"
        XCTAssertEqual(theme.palette.bg.toHex(), "#fbf9f4", "damaged value falls back")
    }

    func testStoreCustomColorFlow() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())
        store.setPalette(.darkgrey)
        store.selectCustomColors()
        XCTAssertTrue(store.theme.useCustomColors)
        XCTAssertEqual(store.theme.palette.bg.toHex(), "#1c1c1e", "switching to Custom changes nothing yet")
        XCTAssertEqual(store.theme.palette.fg.toHex(), "#ececec")
        store.setCustomBackgroundColor(NSColor(srgbRed: 0.1, green: 0.2, blue: 0.3, alpha: 0.5))
        XCTAssertEqual(store.theme.customBackgroundColor, "#1a334d", "alpha dropped")
        XCTAssertEqual(ThemeStore.currentPalette.bg.toHex(), "#1a334d")
        store.setPalette(.white)
        XCTAssertFalse(store.theme.useCustomColors)
        XCTAssertEqual(store.theme.customBackgroundColor, "#1a334d", "kept for the next Custom pick")
    }

    /// The first switch to Custom copies the palette's text and background.
    /// It must not change anything else either: on Off-White the accent
    /// (headings, links), keyword and highlight colours turned into White's.
    func testSwitchingToCustomOnOffWhiteKeepsItsColours() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())
        store.setPalette(.offwhite)
        let before = store.theme.palette
        let accentBefore = store.theme.effectiveAccent.toHex()
        store.selectCustomColors()
        XCTAssertTrue(store.theme.useCustomColors)
        XCTAssertEqual(store.theme.palette, before, "nothing visible changes")
        XCTAssertEqual(store.theme.effectiveAccent.toHex(), accentBefore)

        // A changed text colour derives the surfaces, but keeps the colours
        // that come from the palette the user started on.
        store.setCustomTextColor(NSColor(hex: "#111111"))
        XCTAssertEqual(store.theme.palette.accent.toHex(), Palette.offwhite.accent.toHex())
        XCTAssertEqual(store.theme.palette.synKw.toHex(), Palette.offwhite.synKw.toHex())
        // A background the base palette can't match falls back by luminance.
        store.setCustomBackgroundColor(NSColor(hex: "#101010"))
        store.setCustomTextColor(NSColor(hex: "#eeeeee"))
        XCTAssertEqual(store.theme.palette.synKw.toHex(), Palette.darkgrey.synKw.toHex())
    }

    // MARK: Appearance

    func testAppearanceModeMapsToNSAppearance() {
        XCTAssertNil(AppearanceMode.automatic.nsAppearance)
        XCTAssertEqual(AppearanceMode.light.nsAppearance?.name, .aqua)
        XCTAssertEqual(AppearanceMode.dark.nsAppearance?.name, .darkAqua)
    }

    func testStoreSendsAppearanceAtLaunchAndOnChange() {
        var received: [NSAppearance.Name?] = []
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults, appearanceSink: { received.append($0?.name) })
        XCTAssertEqual(received, [nil])
        store.setAppearance(.dark)
        store.setAccent(.green)          // unrelated change: no new appearance
        store.setAppearance(.light)
        XCTAssertEqual(received, [nil, .darkAqua, .aqua])
    }

    // MARK: Re-colouring

    func testChromeOnlyChangesDoNotRestyleTheText() {
        let base = EditorTheme.default
        var changed = base
        changed.appearance = .dark
        changed.lineWidth = .full
        changed.showStatusBar = false
        changed.cardLayout = true
        changed.preset = .tahoe
        XCTAssertFalse(changed.restyles(comparedTo: base))
        for mutate: (inout EditorTheme) -> Void in [
            { $0.accent = .pink }, { $0.fontBaseSize = 16 }, { $0.paletteName = .oled },
            { $0.bodyFontName = "Menlo" }, { $0.headingFont = .serif }, { $0.useCustomColors = true },
        ] {
            var t = base
            mutate(&t)
            XCTAssertTrue(t.restyles(comparedTo: base))
        }
    }
}
