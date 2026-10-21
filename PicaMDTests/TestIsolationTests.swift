import XCTest
import AppKit
@testable import PicaMD

/// A test run must leave the user's PicaMD exactly as it was. Hosted by
/// the real app, the suite wrote his preferences domain (twelve recents
/// replaced by temporary test files), and the Keychain, Spotlight and the
/// MCP sidecar's list of open documents were his as well.
@MainActor
final class TestIsolationTests: XCTestCase {

    /// `UserDefaults.standard`, `@AppStorage`, saved window state and
    /// system recents all hang off the bundle identifier.
    func testTestsRunInTheTestHost() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, AppEnvironment.testHostBundleIdentifier)
        XCTAssertNotEqual(Bundle.main.bundleIdentifier, AppEnvironment.bundleIdentifier)
        XCTAssertTrue(AppEnvironment.isolatesUserData)
    }

    /// A write to the standard defaults lands in the test host's domain
    /// and never in the user's.
    func testStandardDefaultsAreTheTestHostDomain() {
        let key = "PicaMD.testIsolation.probe"
        let value = UUID().uuidString
        let defaults = UserDefaults.standard
        defaults.set(value, forKey: key)
        defer { defaults.removeObject(forKey: key) }

        XCTAssertEqual(defaults.persistentDomain(forName: AppEnvironment.testHostBundleIdentifier)?[key] as? String,
                       value)
        XCTAssertNil(defaults.persistentDomain(forName: AppEnvironment.bundleIdentifier)?[key])
    }

    /// The Keychain isn't keyed by bundle identifier, so the services
    /// themselves must differ from the app's.
    func testKeychainUsesTheTestHostServices() {
        XCTAssertEqual(Keychain.service, "de.michaelwittmann.PicaMD.testhost.ai")
        XCTAssertNotEqual(Keychain.service, "de.michaelwittmann.PicaMD.ai")
        XCTAssertNotEqual(UserDefaultsMigration.legacyKeychainService, "de.michaelwittmann.QuickMD.ai")
        XCTAssertTrue(UserDefaultsMigration.legacyKeychainService
            .hasPrefix(AppEnvironment.testHostBundleIdentifier + "."))
    }

    /// Nor is Application Support: the sidecar of the user's app reads
    /// active-documents.json there, and keybindings.json is his.
    func testApplicationSupportFilesAreTemporary() throws {
        let realSupport = try XCTUnwrap(FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first)
            .standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        let files = [
            ActiveDocumentsRegistry.registryFileURL,
            try XCTUnwrap(KeybindingLoader.configURL),
            UserDefaultsMigration.legacyPreferencesURL,
        ]
        for url in files.map(\.standardizedFileURL.path) {
            XCTAssertFalse(url.hasPrefix(realSupport), url)
            XCTAssertTrue(url.hasPrefix(temporary), url)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: UserDefaultsMigration.legacyPreferencesURL.path))
    }

    /// Nor is ~/Library/Caches: rendering a math or Mermaid block writes an
    /// HTML file next to the staged scripts.
    func testRenderCachesAreTemporary() throws {
        let realCaches = try XCTUnwrap(FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first)
            .standardizedFileURL.path
        let temporary = FileManager.default.temporaryDirectory.standardizedFileURL.path
        for url in [MathRenderingBundle.cacheDir, MermaidRenderingBundle.cacheDir].map(\.standardizedFileURL.path) {
            XCTAssertFalse(url.hasPrefix(realCaches), url)
            XCTAssertTrue(url.hasPrefix(temporary), url)
        }
    }

    /// The Spotlight index is per user: test documents would show up in
    /// the user's searches.
    func testSpotlightIndexingIsOff() {
        XCTAssertFalse(SpotlightIndexer.isEnabled)
    }

    /// AppKit's own recents feed  ▸ Recent Items as well.
    func testSystemRecentsAndWindowRestorationAreOff() {
        XCTAssertEqual(NSDocumentController.shared.maximumRecentDocumentCount, 0)
        XCTAssertTrue(UserDefaults.standard.bool(forKey: "ApplePersistenceIgnoreState"))
    }

    /// Sparkle would check the network for updates mid-run.
    func testSparkleStaysOff() {
        XCTAssertFalse(UpdaterController.startsUpdater)
    }

    /// The test host must not show up in other apps' Services menus or
    /// become the default app for Markdown files.
    func testTestHostOffersNoServiceAndNoDefaultHandler() throws {
        let info = try XCTUnwrap(Bundle.main.infoDictionary)
        XCTAssertNil(info["NSServices"])
        let types = try XCTUnwrap(info["CFBundleDocumentTypes"] as? [[String: Any]])
        XCTAssertFalse(types.isEmpty)
        for type in types {
            XCTAssertEqual(type["LSHandlerRank"] as? String, "None", "\(type["CFBundleTypeName"] ?? "?")")
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: Bundle.main.bundleURL.appendingPathComponent("Contents/PlugIns/PicaMDQuickLook.appex").path))
    }

    /// A check of the test helper, not of the app: opening a file adds it
    /// to the recents (MarkdownTextView), and `HostedDocument.close()`
    /// takes it off again, so tests leave no dead entries in the test
    /// host's list. That the list is not the user's is checked above
    /// (`testStandardDefaultsAreTheTestHostDomain`).
    func testHostedDocumentCloseRemovesItsRecent() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDIsolation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("Recent.md")
        try Data("# Recent\n".utf8).write(to: url)
        let before = RecentDocumentsStore.list.storedPaths

        let doc = try HostedDocument.open(url, in: self)
        HostedDocument.spin(until: {
            RecentDocumentsStore.list.storedPaths.contains(url.standardizedFileURL.path)
        })
        XCTAssertTrue(RecentDocumentsStore.list.storedPaths.contains(url.standardizedFileURL.path))
        doc.close()

        XCTAssertEqual(RecentDocumentsStore.list.storedPaths, before)
    }
}
