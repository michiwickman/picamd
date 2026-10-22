import XCTest
@testable import PicaMD

/// The starter presets have English names for new installs, while
/// presets a user already has keep the names they were saved with.
@MainActor
final class AIPresetDefaultsTests: XCTestCase {

    func testStarterPresetsHaveEnglishNamesInHotkeyOrder() {
        XCTAssertEqual(AIPreset.defaults.map(\.name), [
            "Clean Up Markdown",
            "Summarize",
            "Rewrite Naturally",
            "Continue Paragraph",
            "Fix Grammar & Spelling",
            "Translate (German ↔ English)",
            "Make More Formal",
            "Make More Casual",
            "Custom Prompt",
        ])
        XCTAssertEqual(AIPreset.defaults.map(\.hotkey), (1...9).map { Optional($0) })
    }

    func testFreshInstallSeedsTheEnglishStarterSet() {
        let defaults = makeTestDefaults("AIPresetDefaults.fresh")
        let store = AIPresetStore(defaults: defaults)
        XCTAssertEqual(store.presets.map(\.name), AIPreset.defaults.map(\.name))
        XCTAssertNotNil(defaults.data(forKey: "PicaMD.ai.presets.v1"), "the seed is saved on first launch")
    }

    func testStoredPresetsKeepTheirNames() throws {
        let defaults = makeTestDefaults("AIPresetDefaults.stored")
        var old = AIPreset.defaults[0]
        old.name = "Bereinige Markdown"
        defaults.set(try JSONEncoder().encode([old]), forKey: "PicaMD.ai.presets.v1")

        let store = AIPresetStore(defaults: defaults)
        XCTAssertEqual(store.presets.map(\.name), ["Bereinige Markdown"])
        XCTAssertEqual(store.presets.first?.id, old.id)
    }

    func testResetGivesTheEnglishStarterSet() throws {
        let defaults = makeTestDefaults("AIPresetDefaults.reset")
        var old = AIPreset.defaults[0]
        old.name = "Bereinige Markdown"
        defaults.set(try JSONEncoder().encode([old]), forKey: "PicaMD.ai.presets.v1")

        let store = AIPresetStore(defaults: defaults)
        store.resetToDefaults()
        XCTAssertEqual(store.presets.map(\.name), AIPreset.defaults.map(\.name))
    }
}
