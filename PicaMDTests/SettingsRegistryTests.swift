import XCTest
import AppKit
@testable import PicaMD

/// "Nothing may be dropped": every stored setting has a control in the
/// Settings window. The list below is maintained by hand. Adding a theme
/// field without giving it a control, or removing a field from this list,
/// fails the test.
@MainActor
final class SettingsRegistryTests: XCTestCase {

    /// Stored `EditorTheme` field → pane and control that edits it.
    private let themeFieldHomes: [String: (SettingsPane, String)] = [
        "preset":                (.appearance, "preset cards"),
        "paletteName":           (.appearance, "Background swatches"),
        "useCustomColors":       (.appearance, "Background ▸ Custom swatch"),
        "customTextColor":       (.appearance, "Text colour picker"),
        "customBackgroundColor": (.appearance, "Background colour picker"),
        "accent":                (.appearance, "Accent color dots"),
        "appearance":            (.appearance, "Appearance segments"),
        "bodyFont":              (.appearance, "Font popup (SF Pro / SF Mono)"),
        "bodyFontName":          (.appearance, "Font popup (New York / Other…)"),
        "headingFont":           (.appearance, "Heading font segments"),
        "fontBaseSize":          (.appearance, "Size stepper"),
        "lineWidth":             (.appearance, "Line width popup"),
        "headingScale":          (.editor, "Heading scale segments"),
        "headingRule":           (.editor, "Hairline under H1 and H2"),
        "codeStyle":             (.editor, "Code block style popup"),
        "cardLayout":            (.editor, "Card layout"),
        "showStatusBar":         (.editor, "Show word count"),
    ]

    /// `UserDefaults` keys written by Settings controls outside the theme.
    private let preferenceKeys: [String: SettingsPane] = [
        "PicaMD.editor.autoPair": .editor,
        "PicaMD.editor.smartPunctuation": .editor,
        "PicaMD.general.showWelcomeWindow": .general,
        "PicaMD.ai.config.v2": .ai,
        "PicaMD.ai.presets.v1": .ai,
    ]

    func testEveryStoredThemeFieldHasASettingsControl() {
        let stored = Set(Mirror(reflecting: EditorTheme.default).children.compactMap(\.label))
        XCTAssertEqual(stored, Set(themeFieldHomes.keys),
                       "EditorTheme fields and the Settings registry disagree")
    }

    func testEveryThemeFieldIsPersisted() throws {
        // A field the encoder skipped would be a setting that resets on
        // relaunch. Optionals are set so they are encoded too.
        var theme = EditorTheme.default
        theme.customTextColor = "#000000"
        theme.customBackgroundColor = "#ffffff"
        theme.bodyFontName = "Menlo"
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(theme)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(themeFieldHomes.keys))
    }

    func testPreferenceKeysArePinned() {
        // Renaming a key silently resets the setting for every user.
        XCTAssertEqual(EditorPreferences.autoPairKey, "PicaMD.editor.autoPair")
        XCTAssertEqual(EditorPreferences.smartPunctuationKey, "PicaMD.editor.smartPunctuation")
        XCTAssertEqual(EditorPreferences.showWelcomeWindowKey, "PicaMD.general.showWelcomeWindow")
        XCTAssertEqual(AIConfig.storageKey, "PicaMD.ai.config.v2")
        XCTAssertEqual(Set(preferenceKeys.values).union(themeFieldHomes.values.map(\.0)),
                       Set(SettingsPane.allCases), "every pane holds at least one setting")
    }

    func testWelcomeWindowDefaultsToOn() {
        let defaults = makeTestDefaults("SettingsRegistry")
        EditorPreferences.registerDefaults(defaults)
        XCTAssertTrue(defaults.bool(forKey: EditorPreferences.showWelcomeWindowKey))
    }

    // MARK: Selected pane

    func testSelectedPaneResolution() {
        XCTAssertEqual(SettingsPane.resolve(stored: "editor", legacyIndex: 4), .editor)
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: nil), .appearance)
        XCTAssertEqual(SettingsPane.resolve(stored: "", legacyIndex: nil), .appearance)
        XCTAssertEqual(SettingsPane.resolve(stored: "colours", legacyIndex: nil), .appearance)
        // 0.9 tabs: Presets, Palette, Typography, Blocks, AI.
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: 0), .appearance)
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: 2), .appearance)
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: 3), .editor)
        // Out of range for the four panes: index 4 was the AI tab in 0.9.
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: 4), .appearance)
        // Out of range for both layouts.
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: 7), .appearance)
        XCTAssertEqual(SettingsPane.resolve(stored: nil, legacyIndex: -1), .appearance)
    }

    // MARK: Font panel

    /// Records `orderOut` instead of touching the screen.
    private final class PanelSpy: NSPanel {
        var orderedOut = false
        override func orderOut(_ sender: Any?) { orderedOut = true }
    }

    func testLeavingAppearanceClosesTheBodyFontPanel() {
        let manager = NSFontManager.shared
        let previousTarget = manager.target
        defer { manager.target = previousTarget }

        manager.target = BodyFontPanel.shared
        let spy = PanelSpy()
        BodyFontPanel.shared.detach(closing: spy)
        XCTAssertTrue(spy.orderedOut, "an open panel would accept choices and drop them")
        XCTAssertNil(manager.target)

        // A panel someone else opened stays open.
        let other = NSObject()
        manager.target = other
        let foreign = PanelSpy()
        BodyFontPanel.shared.detach(closing: foreign)
        XCTAssertFalse(foreign.orderedOut)
        XCTAssertTrue(manager.target === other)
    }

    func testPaneOrderMatchesTheBoard() {
        XCTAssertEqual(SettingsPane.allCases.map(\.title), ["General", "Appearance", "Editor", "AI"])
    }
}
