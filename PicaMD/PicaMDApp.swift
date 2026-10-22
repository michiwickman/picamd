import SwiftUI
import AppKit

@main
struct PicaMDApp: App {
    /// Applies Settings ▸ Appearance ▸ Appearance to the whole app's
    /// chrome; the editor surface keeps the palette's colours.
    @StateObject private var themeStore = ThemeStore(appearanceSink: { NSApp.appearance = $0 })
    @StateObject private var updater = UpdaterController()
    @ObservedObject private var recents = RecentDocumentsMenuModel.shared

    /// Hooks the launch-time "no document open" path to present the
    /// welcome window (recents + New + Open) instead of a Finder panel.
    @NSApplicationDelegateAdaptor(PicaMDAppDelegate.self) private var appDelegate

    /// Long-lived ServicesProvider instance. Stored on the App so it
    /// outlives any individual scene — `NSApplication`'s services-
    /// provider reference is unowned, so the object has to stay alive
    /// for the app's lifetime to receive Service-menu invocations.
    private let servicesProvider = ServicesProvider()

    init() {
        // Before anything reads or writes defaults: the test host turns
        // off system recents and window restoration here.
        AppEnvironment.prepareForLaunch()

        // Note: do NOT install a custom NSDocumentController subclass
        // here. SwiftUI's DocumentGroup ships its own private
        // `PlatformDocumentController` subclass and expects to be the
        // shared singleton; pre-empting it crashes during launch in
        // `PlatformDocumentController.createDocumentClassIfNeeded`.

        // Migrate UserDefaults from the QuickMD-era namespace before
        // anything else reads from defaults. `@StateObject` initialises
        // lazily, so `ThemeStore()` and `AIConfig.load()` haven't fired
        // yet at this point — they'll see the freshly-migrated keys.
        UserDefaultsMigration.migrateFromQuickMDIfNeeded()
        EditorPreferences.registerDefaults()

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
        // Room for the outline (248) and a readable column; the
        // inspector starts closed (ContentView sets the minimum size).
        .defaultSize(width: 1100, height: 750)
        // No open panel and no untitled window at launch: the app
        // delegate shows the welcome window or a new document instead.
        // Files from Finder and restored windows still open.
        .defaultLaunchBehavior(.suppressed)
        .commands {
            CommandGroup(replacing: .newItem) {
                // New window or tab as System Settings ▸ Desktop & Dock ▸
                // "Prefer tabs" says.
                Button("New") {
                    NSDocumentController.shared.newDocument(nil)
                }
                .keyboardShortcut("n", modifiers: .command)
                // Always a tab in the frontmost document window.
                Button("New Tab") {
                    DocumentTabs.newTab()
                }
                .keyboardShortcut("t", modifiers: .command)
                // Replacing `.newItem` also removes the stock Open… and
                // Open Recent, which left ⌘O dead in document windows.
                // On macOS 27 DocumentGroup adds a stock Open… of its own
                // in the next section, without ⌘O; MenuIconSuppressor
                // hides it so File shows one Open….
                Button("Open…") {
                    NSDocumentController.shared.openDocument(nil)
                }
                .keyboardShortcut("o", modifiers: .command)
                Menu("Open Recent") {
                    let titles = RecentDocumentsList.menuTitles(for: recents.urls)
                    ForEach(Array(zip(recents.urls, titles)), id: \.0) { url, title in
                        Button(title) { RecentDocumentsStore.open(url) }
                    }
                    if !recents.urls.isEmpty {
                        Divider()
                    }
                    Button("Clear Menu") {
                        RecentDocumentsStore.clear()
                    }
                    .disabled(recents.urls.isEmpty)
                }
            }
            FindCommands()
            FormatCommands(keybindings: PicaMDTextView.keybindings)
            ViewCommands(themeStore: themeStore)
            ExportCommands()
            UpdaterCommands(controller: updater)
        }

        Settings {
            SettingsView()
                .environmentObject(themeStore)
                .environmentObject(updater)
        }
    }
}
