import SwiftUI
import AppKit

@main
struct PicaMDApp: App {
    @StateObject private var themeStore = ThemeStore()
    @StateObject private var updater = UpdaterController()

    /// Hooks the launch-time "no document open" path to present the
    /// welcome window (recents + New + Open) instead of a Finder panel.
    @NSApplicationDelegateAdaptor(PicaMDAppDelegate.self) private var appDelegate

    /// Long-lived ServicesProvider instance. Stored on the App so it
    /// outlives any individual scene — `NSApplication`'s services-
    /// provider reference is unowned, so the object has to stay alive
    /// for the app's lifetime to receive Service-menu invocations.
    private let servicesProvider = ServicesProvider()

    init() {
        // Note: do NOT install a custom NSDocumentController subclass
        // here. SwiftUI's DocumentGroup ships its own private
        // `PlatformDocumentController` subclass and expects to be the
        // shared singleton; pre-empting it crashes during launch in
        // `PlatformDocumentController.createDocumentClassIfNeeded`.

        // Suppress AppKit's automatic "open panel on launch" for document
        // apps. Without this, DocumentGroup pops a Finder open panel at
        // cold launch (behind our welcome window). With it false, the
        // launch routes through the untitled-file path, which our
        // `PicaMDAppDelegate` intercepts to show the welcome window.
        // Registered in the volatile domain (per-launch, not persisted).
        UserDefaults.standard.register(defaults: [
            "NSShowAppCentricOpenPanelInsteadOfUntitledFile": false
        ])

        // Migrate UserDefaults from the QuickMD-era namespace before
        // anything else reads from defaults. `@StateObject` initialises
        // lazily, so `ThemeStore()` and `AIConfig.load()` haven't fired
        // yet at this point — they'll see the freshly-migrated keys.
        UserDefaultsMigration.migrateFromQuickMDIfNeeded()

        // Register the services provider with AppKit. Has to happen
        // before any service is invoked; init() runs once per app
        // launch which is the right moment.
        NSApplication.shared.servicesProvider = servicesProvider
        // Give the system a kick so a freshly-installed app appears in
        // the Services menu of OTHER running apps without requiring a
        // logout / re-login. `NSUpdateDynamicServices()` reads
        // Info.plist's NSServices and refreshes the menu cache.
        NSUpdateDynamicServices()
    }

    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document)
                .environmentObject(themeStore)
        }
        .defaultSize(width: 940, height: 700)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                Button("New Tab") {
                    // Same effect as `New` while `tabbingMode = .preferred`
                    // on every PicaMD window — the new document spawns
                    // as a tab in the active window's tab group instead
                    // of as a detached window. The system menu also
                    // gains "Show Previous/Next Tab" + "Move Tab to
                    // New Window" automatically once this fires.
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("t", modifiers: .command)
            }
            EditorModeCommands()
            ExportCommands()
            UpdaterCommands(controller: updater)
        }

        Settings {
            SettingsView()
                .environmentObject(themeStore)
        }
    }
}
