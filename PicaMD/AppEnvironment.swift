import Foundation

/// Which process this is: the shipped app, or the test host the unit
/// tests run in.
///
/// The unit tests run inside `PicaMDTestHost.app`, the app's sources built
/// under a bundle identifier of their own (target PicaMDTestHost in
/// project.yml). That keeps everything macOS files under the bundle
/// identifier apart from the user's app: `UserDefaults.standard` and
/// `@AppStorage`, saved window state, AppKit's recent documents. The
/// Keychain, Application Support, Caches and the Spotlight index are not
/// kept apart that way, so the code that writes there asks
/// `isolatesUserData`.
enum AppEnvironment {
    /// The shipped app. Its preferences domain holds the user's settings
    /// and recents.
    static let bundleIdentifier = "de.michaelwittmann.PicaMD"
    /// The test host made from the Debug app for `PicaMDTests`.
    static let testHostBundleIdentifier = "de.michaelwittmann.PicaMD.testhost"

    /// True in the test host, and in any process that hosts XCTest (should
    /// a test ever run in the real app again, it still keeps out of the
    /// user's Keychain items and files).
    static let isolatesUserData: Bool =
        Bundle.main.bundleIdentifier == testHostBundleIdentifier || isHostingTests

    /// True when the process is hosting an XCTest bundle. The environment
    /// variable is set before launch, so this already holds in `App.init`.
    static var isHostingTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
            || NSClassFromString("XCTestCase") != nil
    }

    /// PicaMD's folder in Application Support (keybindings.json, the MCP
    /// sidecar's list of open documents). Tests get a folder in the
    /// temporary directory: the sidecar of the user's app reads the real
    /// one, and a test must neither list its documents there nor pick up
    /// the user's own keybindings.
    static let applicationSupportDirectory: URL = {
        if isolatesUserData {
            return FileManager.default.temporaryDirectory
                .appendingPathComponent("PicaMDTestHost/Application Support/PicaMD",
                                        isDirectory: true)
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                            in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PicaMD", isDirectory: true)
    }()

    /// In the test host, the folder that stands in for PicaMD's folder in
    /// ~/Library/Caches (the staged KaTeX and Mermaid scripts and the HTML
    /// file of every rendered block); nil in the app. That folder isn't
    /// per bundle: a test rendering a block would add files to the user's
    /// cache and fill it from the test build's resources.
    static let isolatedCachesDirectory: URL? = isolatesUserData
        ? FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDTestHost/Caches/PicaMD", isDirectory: true)
        : nil

    /// Called first thing at launch. In the test host, turns off what
    /// would still reach the user's session: AppKit's recent documents
    /// (they also feed  ▸ Recent Items) and restoring windows a previous
    /// test run left open. Registered, not stored, so nothing persists.
    static func prepareForLaunch() {
        guard isolatesUserData else { return }
        UserDefaults.standard.register(defaults: [
            "NSRecentDocumentsLimit": 0,
            "ApplePersistenceIgnoreState": true,
        ])
    }
}
