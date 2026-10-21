import SwiftUI
import AppKit

/// Settings ▸ General: launch behaviour, updates, custom shortcuts.
struct GeneralSettingsPane: View {
    @EnvironmentObject private var updater: UpdaterController
    @AppStorage(EditorPreferences.showWelcomeWindowKey) private var showWelcomeWindow = true

    var body: some View {
        Form {
            Section {
                Toggle("Show welcome window when PicaMD opens", isOn: $showWelcomeWindow)
            }

            Section {
                Toggle("Check for updates automatically", isOn: Binding(
                    get: { updater.automaticallyChecksForUpdates },
                    set: { updater.automaticallyChecksForUpdates = $0 }
                ))
                .disabled(!updater.updaterIsConfigured)
            } footer: {
                if !updater.updaterIsConfigured {
                    Text("This build has no update feed configured.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                LabeledContent("Keyboard shortcuts") {
                    Button("Reveal in Finder") { revealKeybindings() }
                }
            } footer: {
                Text("Editor shortcuts can be changed in keybindings.json in PicaMD's Application Support folder. Changes apply after a restart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Selects keybindings.json in Finder, or opens its folder when the
    /// user hasn't created the file yet (it is optional).
    private func revealKeybindings() {
        guard let url = KeybindingLoader.configURL else { return }
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
            return
        }
        let folder = url.deletingLastPathComponent()
        try? fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
}
