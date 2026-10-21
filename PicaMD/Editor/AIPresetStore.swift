import Foundation
import SwiftUI

/// Observable store for the user's AI presets. Persists the full
/// preset list to `UserDefaults` as a single Codable blob, broadcasts
/// changes via `@Published` so the Settings UI can re-render.
///
/// First launch (no stored presets) seeds with `AIPreset.defaults` —
/// the 9 starter presets bound to ⌃⌘1…⌃⌘9. The user can edit them,
/// add their own, or reset to defaults from Settings.
@MainActor
final class AIPresetStore: ObservableObject {
    @Published private(set) var presets: [AIPreset]

    private let defaults: UserDefaults
    private let storageKey = "PicaMD.ai.presets.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: storageKey) {
            do {
                self.presets = try JSONDecoder().decode([AIPreset].self, from: data)
            } catch {
                // Unreadable (e.g. written by a newer PicaMD). Run on the
                // starter set for this session but DON'T save it — that
                // would overwrite the user's own presets for good.
                NSLog("PicaMD: couldn't decode AI presets, using defaults without saving: \(error)")
                self.presets = AIPreset.defaults
            }
        } else {
            self.presets = AIPreset.defaults
            // Persist the seed so subsequent loads are stable — and so
            // a user editing-then-deleting all presets doesn't get the
            // seed re-added on next launch (their explicit choice
            // wins).
            self.save()
        }
    }

    func add(_ preset: AIPreset) {
        presets.append(preset)
        save()
    }

    func remove(at offsets: IndexSet) {
        presets.remove(atOffsets: offsets)
        save()
    }

    func remove(id: UUID) {
        presets.removeAll { $0.id == id }
        save()
    }

    func update(_ preset: AIPreset) {
        guard let idx = presets.firstIndex(where: { $0.id == preset.id }) else { return }
        presets[idx] = preset
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        presets.move(fromOffsets: source, toOffset: destination)
        save()
    }

    func resetToDefaults() {
        presets = AIPreset.defaults
        save()
    }

    /// Find the preset bound to the given `⌃⌘<digit>` shortcut, or
    /// `nil` if none. Iterates forward so the FIRST matching preset
    /// wins — duplicate hotkey assignments are gracefully ignored
    /// rather than thrown as an error.
    func preset(forHotkey digit: Int) -> AIPreset? {
        presets.first { $0.hotkey == digit }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(presets) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
