import XCTest
@testable import PicaMD

@MainActor
final class ThemeTests: XCTestCase {

    // MARK: Palette tokens (exact hex from themes.js)

    func testWhitePaletteHexValues() {
        XCTAssertEqual(Palette.white.bg.toHex(), "#ffffff")
        XCTAssertEqual(Palette.white.fg.toHex(), "#1d1d1f")
        XCTAssertEqual(Palette.white.codeBg.toHex(), "#f7f7f8")
    }

    func testOffwhitePaletteHexValues() {
        XCTAssertEqual(Palette.offwhite.bg.toHex(), "#fbf9f4")
        XCTAssertEqual(Palette.offwhite.fg.toHex(), "#272620")
        XCTAssertEqual(Palette.offwhite.synKw.toHex(), "#a85c1f")
    }

    func testDarkgreyPaletteHexValues() {
        XCTAssertEqual(Palette.darkgrey.bg.toHex(), "#1c1c1e")
        XCTAssertEqual(Palette.darkgrey.fg.toHex(), "#ececec")
    }

    func testOLEDPaletteHexValues() {
        XCTAssertEqual(Palette.oled.bg.toHex(), "#000000")
        XCTAssertEqual(Palette.oled.codeBg.toHex(), "#0c0c0c")
    }

    func testIsDarkLumaDetection() {
        XCTAssertFalse(Palette.white.isDark)
        XCTAssertFalse(Palette.offwhite.isDark)
        XCTAssertTrue(Palette.darkgrey.isDark)
        XCTAssertTrue(Palette.oled.isDark)
    }

    // MARK: HeadingScale

    func testHeadingScaleHasSixSizesEach() {
        for scale in HeadingScale.allCases {
            XCTAssertEqual(scale.sizes.count, 6, "Scale \(scale) must have 6 sizes")
        }
    }

    func testHeadingScaleAiryIsLargerThanTight() {
        XCTAssertGreaterThan(HeadingScale.airy.sizes[0], HeadingScale.tight.sizes[0])
        XCTAssertGreaterThan(HeadingScale.airy.sizes[2], HeadingScale.tight.sizes[2])
    }

    // MARK: PresetVariant.applyDefaults

    func testStockPlusDefaults() {
        var t = EditorTheme.default
        t.bodyFont = .sans
        t.headingFont = .serif
        t.headingScale = .airy
        t.headingRule = true
        t.codeStyle = .stripe

        PresetVariant.stockPlus.applyDefaults(to: &t)

        XCTAssertEqual(t.preset, .stockPlus)
        XCTAssertEqual(t.bodyFont, .mono)
        XCTAssertEqual(t.headingFont, .sans)
        XCTAssertEqual(t.headingScale, .defaultScale)
        XCTAssertEqual(t.codeStyle, .card)
        XCTAssertFalse(t.headingRule)
    }

    func testEditorialDefaults() {
        var t = EditorTheme.default
        PresetVariant.editorial.applyDefaults(to: &t)

        XCTAssertEqual(t.preset, .editorial)
        XCTAssertEqual(t.bodyFont, .sans)
        XCTAssertEqual(t.headingFont, .serif)
        XCTAssertEqual(t.headingScale, .airy)
        XCTAssertTrue(t.headingRule)
        XCTAssertEqual(t.codeStyle, .card)
    }

    func testTahoeDefaults() {
        var t = EditorTheme.default
        PresetVariant.tahoe.applyDefaults(to: &t)

        XCTAssertEqual(t.preset, .tahoe)
        XCTAssertEqual(t.bodyFont, .mono)
        XCTAssertEqual(t.headingFont, .sans)
        XCTAssertEqual(t.codeStyle, .tinted)
    }

    func testApplyDefaultsPreservesPaletteAndAccent() {
        var t = EditorTheme.default
        t.paletteName = .oled
        t.accent = .pink

        PresetVariant.editorial.applyDefaults(to: &t)

        XCTAssertEqual(t.paletteName, .oled, "Palette must be preserved across preset switch")
        XCTAssertEqual(t.accent, .pink, "Accent must be preserved across preset switch")
    }

    // MARK: AccentChoice

    func testAccentColorsMatchPrototype() {
        XCTAssertEqual(AccentChoice.blue.color.toHex(),   "#0a84ff")
        XCTAssertEqual(AccentChoice.orange.color.toHex(), "#ff8c42")
        XCTAssertEqual(AccentChoice.pink.color.toHex(),   "#ff375f")
        XCTAssertEqual(AccentChoice.green.color.toHex(),  "#30d158")
        XCTAssertEqual(AccentChoice.purple.color.toHex(), "#bf5af2")
        XCTAssertEqual(AccentChoice.mono.color.toHex(),   "#7d7d82")
    }

    func testEffectiveAccentFollowsSystemPaletteByDefault() {
        let t = EditorTheme.default
        XCTAssertEqual(t.accent, .system)
        XCTAssertEqual(t.effectiveAccent.toHex(), Palette.white.accent.toHex())
    }

    func testEffectiveAccentOverridesWithExplicitChoice() {
        var t = EditorTheme.default
        t.accent = .pink
        XCTAssertEqual(t.effectiveAccent.toHex(), "#ff375f")
    }

    // MARK: ThemeStore + persistence

    private func makeIsolatedDefaults() -> UserDefaults {
        let suite = "PicaMDThemeTest-\(UUID().uuidString)"
        let d = UserDefaults(suiteName: suite)!
        d.removePersistentDomain(forName: suite)
        return d
    }

    func testThemeStoreInitDefaultsWhenNoPersistence() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())
        XCTAssertEqual(store.theme, .default)
    }

    func testThemeStorePersistsAccentChange() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        store.setAccent(.pink)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.theme.accent, .pink)
    }

    func testThemeStorePersistsPresetSwitch() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        store.selectPreset(.editorial)

        let reloaded = ThemeStore(defaults: defaults)
        XCTAssertEqual(reloaded.theme.preset, .editorial)
        XCTAssertEqual(reloaded.theme.headingFont, .serif)
        XCTAssertEqual(reloaded.theme.headingScale, .airy)
    }

    func testThemeStoreUpdateNoOpsOnEqualValue() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        let before = store.theme
        store.setAccent(.system)  // already the default
        XCTAssertEqual(store.theme, before)
    }

    func testThemeStoreResetToDefault() {
        let defaults = makeIsolatedDefaults()
        let store = ThemeStore(defaults: defaults)
        store.selectPreset(.editorial)
        store.setPalette(.oled)
        store.resetToDefault()
        XCTAssertEqual(store.theme, .default)
    }

    // MARK: GAP-06 – Corruption recovery, palette mirror, change notification

    func testThemeStoreFallsBackToDefaultOnCorruptBlob() {
        let defaults = makeIsolatedDefaults()
        let garbageData = Data("garbage".utf8)
        defaults.set(garbageData, forKey: "PicaMD.editorTheme.v1")

        let store = ThemeStore(defaults: defaults)

        XCTAssertEqual(store.theme, .default,
            "ThemeStore must fall back to .default when persisted JSON is corrupt")
    }

    func testCorruptBlobIsBackedUp() {
        let defaults = makeIsolatedDefaults()
        let garbageData = Data("garbage".utf8)
        defaults.set(garbageData, forKey: "PicaMD.editorTheme.v1")

        _ = ThemeStore(defaults: defaults)

        let backup = defaults.data(forKey: "PicaMD.editorTheme.v1.corrupt-backup")
        XCTAssertNotNil(backup,
            "Corrupt blob must be stashed under the .corrupt-backup key")
        XCTAssertEqual(backup, garbageData,
            "The backed-up bytes must match the original corrupt blob exactly")
    }

    func testCurrentPaletteMirrorTracksMutations() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())

        store.setPalette(.oled)

        // Compare by the canonical OLED bg hex – same approach used in the
        // existing palette-hex tests above.
        XCTAssertEqual(ThemeStore.currentPalette.bg.toHex(), Palette.oled.bg.toHex(),
            "currentPalette.bg must reflect the OLED palette after setPalette(.oled)")
    }

    func testUpdatePostsThemeChangedNotification() {
        let store = ThemeStore(defaults: makeIsolatedDefaults())

        // Make sure the accent actually differs from the default (.system)
        // so the update(_:) no-op guard does not suppress the post.
        let expectation = expectation(
            forNotification: ThemeStore.themeChangedNotification,
            object: nil,
            handler: nil
        )

        store.setAccent(.pink)

        wait(for: [expectation], timeout: 1.0)
    }
}
