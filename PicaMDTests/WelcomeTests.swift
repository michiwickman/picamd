import XCTest
import AppKit
import UniformTypeIdentifiers
@testable import PicaMD

/// Welcome window: recents subtitles, the recents store's trash and
/// missing-file handling, the launch decision, and the bits of the
/// window that can be checked without showing it.
@MainActor
final class RecentDocumentLocationTests: XCTestCase {
    private let home = "/Users/m"

    private func subtitle(_ path: String, home: String = "/Users/m") -> String {
        RecentDocumentLocation.subtitle(forFile: path, home: home, startupVolumeName: "Macintosh HD")
    }

    func testHomeRelativeFoldersAsInTheBoard() {
        XCTAssertEqual(subtitle("/Users/m/Documents/Travel/Trip to Porto.md"), "Documents ▸ Travel")
        XCTAssertEqual(subtitle("/Users/m/Documents/Reading list.md"), "Documents")
        XCTAssertEqual(subtitle("/Users/m/Developer/picamd/Release checklist.md"), "Developer ▸ picamd")
        XCTAssertEqual(subtitle("/Users/m/.claude/CLAUDE.md"), ".claude")
    }

    func testFileDirectlyInHome() {
        XCTAssertEqual(subtitle("/Users/m/notes.md"), "Home")
        XCTAssertEqual(subtitle("/Users/m/notes.md", home: "/Users/m/"), "Home")
    }

    func testICloudDrive() {
        XCTAssertEqual(subtitle("/Users/m/Library/Mobile Documents/com~apple~CloudDocs/Groceries.md"),
                       "iCloud Drive")
        XCTAssertEqual(subtitle("/Users/m/Library/Mobile Documents/com~apple~CloudDocs/Notes/Projects/a.md"),
                       "iCloud Drive ▸ Notes ▸ Projects")
    }

    func testOneDriveAndOtherCloudStorage() {
        XCTAssertEqual(subtitle("/Users/m/Library/CloudStorage/OneDrive-Persönlich/Projects/a.md"),
                       "OneDrive – Persönlich ▸ Projects")
        // The file system hands paths over decomposed (NFD); the "ü" must
        // stay one letter and not start a new word.
        let decomposed = "/Users/m/Library/CloudStorage/OneDrive-MusterfirmaGru\u{0308}n/a.md"
        XCTAssertEqual(subtitle(decomposed), "OneDrive – Musterfirma Gru\u{0308}n")
        XCTAssertEqual(subtitle("/Users/m/Library/CloudStorage/GoogleDrive-me@example.com/My Drive/a.md"),
                       "Google Drive – me@example.com ▸ My Drive")
        XCTAssertEqual(subtitle("/Users/m/Library/CloudStorage/Dropbox/a.md"), "Dropbox")
    }

    func testVolumesAndStartupDisk() {
        XCTAssertEqual(subtitle("/Volumes/Archive/Notes/a.md"), "Archive ▸ Notes")
        XCTAssertEqual(subtitle("/Volumes/Archive/a.md"), "Archive")
        XCTAssertEqual(subtitle("/Users/Shared/a.md"), "Macintosh HD ▸ Users ▸ Shared")
        XCTAssertEqual(subtitle("/a.md"), "Macintosh HD")
    }

    func testLongPathsKeepTheLocationAndTheLastTwoFolders() {
        XCTAssertEqual(subtitle("/Users/m/Developer/project/usage/a.md"),
                       "Developer ▸ project ▸ usage")
        XCTAssertEqual(subtitle("/Users/m/Developer/app/build/cache/x/README.md"),
                       "Developer ▸ … ▸ cache ▸ x")
        XCTAssertEqual(subtitle("/Users/m/Library/Mobile Documents/com~apple~CloudDocs/A/B/C/a.md"),
                       "iCloud Drive ▸ … ▸ B ▸ C")
    }

    func testTrashPaths() {
        XCTAssertTrue(RecentDocumentLocation.isInTrash("/Users/m/.Trash/old/notes.md"))
        XCTAssertTrue(RecentDocumentLocation.isInTrash("/Volumes/USB/.Trashes/501/a.md"))
        XCTAssertTrue(RecentDocumentLocation.isInTrash(
            "/Users/m/Library/Mobile Documents/com~apple~CloudDocs/.Trash/a.md"))
        XCTAssertFalse(RecentDocumentLocation.isInTrash("/Users/m/Trash/a.md"))
        XCTAssertFalse(RecentDocumentLocation.isInTrash("/Users/m/.Trash-notes/a.md"))
    }

    func testRoots() {
        let root = { RecentDocumentLocation.root(of: $0, home: self.home, startupVolumeName: "HD").path }
        XCTAssertEqual(root("/Users/m/Documents/a.md"), "/Users/m")
        XCTAssertEqual(root("/Volumes/USB/a/b.md"), "/Volumes/USB")
        XCTAssertEqual(root("/Users/m/Library/CloudStorage/OneDrive-X/a/b.md"),
                       "/Users/m/Library/CloudStorage/OneDrive-X")
        XCTAssertEqual(root("/opt/a.md"), "/")
    }
}

@MainActor
final class RecentDocumentsListTests: XCTestCase {
    /// A private defaults suite per test, emptied when the test ends.
    private lazy var defaults: UserDefaults = makeTestDefaults("RecentDocumentsList")

    /// A store over made-up files and reachable location roots.
    private func list(existing: Set<String>, unreadable: Set<String> = [],
                      reachable: Set<String> = ["/Users/m", "/"]) -> RecentDocumentsList {
        RecentDocumentsList(
            defaults: defaults, home: "/Users/m", startupVolumeName: "HD",
            fileState: { path in
                if existing.contains(path) { return .exists }
                return unreadable.contains(path) ? .unreadable : .missing
            },
            isReachable: { reachable.contains($0) })
    }

    private var stored: [String] {
        defaults.stringArray(forKey: RecentDocumentsList.defaultsKey) ?? []
    }

    func testStatus() {
        let store = list(
            existing: ["/Users/m/a.md", "/Users/m/.Trash/b.md", "/Volumes/USB/c.md"],
            reachable: ["/Users/m", "/", "/Volumes/USB", "/Users/m/Library/CloudStorage/OneDrive-X"])
        XCTAssertEqual(store.status(of: "/Users/m/a.md"), .visible)
        // A trashed file still exists; it used to stay in the list.
        XCTAssertEqual(store.status(of: "/Users/m/.Trash/b.md"), .pruned)
        // Deleted, or its folder renamed, on a disk that is there: gone.
        XCTAssertEqual(store.status(of: "/Users/m/Documents/gone.md"), .pruned)
        XCTAssertEqual(store.status(of: "/Users/m/Library/CloudStorage/OneDrive-X/Old name/n.md"), .pruned)
        XCTAssertEqual(store.status(of: "/Volumes/USB/gone.md"), .pruned)
        // Disk unplugged or cloud account away: hidden, but kept.
        XCTAssertEqual(store.status(of: "/Volumes/Offline/n.md"), .hidden)
        XCTAssertEqual(store.status(of: "/Users/m/Library/CloudStorage/OneDrive-Y/n.md"), .hidden)
    }

    func testURLsPruneTheStoreAndKeepOfflineEntries() {
        defaults.set(["/Users/m/a.md", "/Users/m/.Trash/b.md", "/Volumes/Offline/c.md",
                      "/Users/m/gone.md", "/Users/m/d.md"],
                     forKey: RecentDocumentsList.defaultsKey)
        let store = list(existing: ["/Users/m/a.md", "/Users/m/.Trash/b.md", "/Users/m/d.md"])
        XCTAssertEqual(store.urls().map(\.path), ["/Users/m/a.md", "/Users/m/d.md"])
        XCTAssertEqual(stored, ["/Users/m/a.md", "/Volumes/Offline/c.md", "/Users/m/d.md"])
    }

    /// A declined Documents, Desktop or Downloads prompt makes the stat
    /// fail with EPERM while the home folder stays listable. The file is
    /// still there, so the entry must survive.
    func testUnreadableFilesInAReachableHomeAreKept() {
        defaults.set(["/Users/m/Documents/locked.md", "/Users/m/Desktop/gone.md"],
                     forKey: RecentDocumentsList.defaultsKey)
        let store = list(existing: [], unreadable: ["/Users/m/Documents/locked.md"])
        XCTAssertEqual(store.status(of: "/Users/m/Documents/locked.md"), .hidden)
        XCTAssertTrue(store.urls().isEmpty)
        XCTAssertEqual(stored, ["/Users/m/Documents/locked.md"])
    }

    func testAddPromotesAndCaps() {
        let store = list(existing: [])
        for index in 0..<14 { store.add(URL(fileURLWithPath: "/Users/m/\(index).md")) }
        XCTAssertEqual(stored.count, RecentDocumentsList.maxCount)
        XCTAssertEqual(stored.first, "/Users/m/13.md")
        store.add(URL(fileURLWithPath: "/Users/m/5.md"))
        XCTAssertEqual(stored.first, "/Users/m/5.md")
        XCTAssertEqual(stored.filter { $0 == "/Users/m/5.md" }.count, 1)
        store.add(URL(string: "https://example.com/a.md")!)
        XCTAssertEqual(stored.first, "/Users/m/5.md")
    }

    func testRemoveAndClear() {
        let store = list(existing: ["/Users/m/a.md", "/Users/m/b.md"])
        store.add(URL(fileURLWithPath: "/Users/m/a.md"))
        store.add(URL(fileURLWithPath: "/Users/m/b.md"))
        store.remove(URL(fileURLWithPath: "/Users/m/a.md"))
        XCTAssertEqual(stored, ["/Users/m/b.md"])
        store.clear()
        XCTAssertTrue(store.urls().isEmpty)
    }

    func testMenuTitlesTellSameNamedFilesApart() {
        let urls = ["/Users/m/PicaMD/README.md", "/Users/m/QuickMD/README.md", "/Users/m/notes.md"]
            .map { URL(fileURLWithPath: $0) }
        XCTAssertEqual(RecentDocumentsList.menuTitles(for: urls),
                       ["README.md — PicaMD", "README.md — QuickMD", "notes.md"])
    }

    /// The live checks against a real folder: a file moved into a Trash
    /// and a deleted file both leave the store.
    func testRealFilesInTrashAndDeleted() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("RecentDocumentsListTests-\(UUID().uuidString)")
        defer { try? fileManager.removeItem(at: home) }
        let trash = home.appendingPathComponent(".Trash")
        try fileManager.createDirectory(at: trash, withIntermediateDirectories: true)
        let kept = home.appendingPathComponent("kept.md")
        let trashed = trash.appendingPathComponent("trashed.md")
        let deleted = home.appendingPathComponent("deleted.md")
        for url in [kept, trashed, deleted] { try Data("x".utf8).write(to: url) }

        var store = RecentDocumentsList.live()
        store = RecentDocumentsList(
            defaults: defaults, home: home.standardizedFileURL.path,
            startupVolumeName: store.startupVolumeName,
            fileState: store.fileState, isReachable: store.isReachable)
        for url in [deleted, trashed, kept] { store.add(url) }
        try fileManager.removeItem(at: deleted)

        XCTAssertEqual(store.urls().map(\.lastPathComponent), ["kept.md"])
        XCTAssertEqual(stored, [kept.standardizedFileURL.path])
    }

    /// The live stat against a folder PicaMD may not search (EACCES, like
    /// the EPERM of a declined privacy prompt): the file counts as
    /// unreadable, not missing, and stays in the store.
    func testRealFileInAnUnsearchableFolderIsKept() throws {
        let fileManager = FileManager.default
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("RecentDocumentsListTests-\(UUID().uuidString)")
        let locked = home.appendingPathComponent("Documents")
        try fileManager.createDirectory(at: locked, withIntermediateDirectories: true)
        let file = locked.appendingPathComponent("locked.md")
        try Data("x".utf8).write(to: file)
        try fileManager.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer {
            try? fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
            try? fileManager.removeItem(at: home)
        }

        let live = RecentDocumentsList.live()
        let store = RecentDocumentsList(
            defaults: defaults, home: home.standardizedFileURL.path,
            startupVolumeName: live.startupVolumeName,
            fileState: live.fileState, isReachable: live.isReachable)
        store.add(file)

        XCTAssertEqual(live.fileState(file.standardizedFileURL.path), .unreadable)
        XCTAssertEqual(live.fileState(home.appendingPathComponent("none.md").path), .missing)
        XCTAssertTrue(store.urls().isEmpty)
        XCTAssertEqual(stored, [file.standardizedFileURL.path])
    }
}

/// Records where the file checks ran.
private final class CheckRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [Bool] = []
    func record() { lock.withLock { calls.append(pthread_main_np() != 0) } }
    var count: Int { lock.withLock { calls.count } }
    var ranOnMain: Bool { lock.withLock { calls.contains(true) } }
}

@MainActor
final class RecentDocumentsMenuModelTests: XCTestCase {
    /// The model is created while the App struct is built and refreshes on
    /// every activation. A stat of a file on a stalled network volume blocks
    /// until its timeout, so no check may run on the main thread.
    func testFileChecksRunOffTheMainThread() async {
        let defaults = makeTestDefaults("RecentDocumentsMenuModel")
        defaults.set(["/Users/m/a.md", "/Users/m/gone.md", "/Volumes/Offline/b.md"],
                     forKey: RecentDocumentsList.defaultsKey)
        let recorder = CheckRecorder()
        let list = RecentDocumentsList(
            defaults: defaults, home: "/Users/m", startupVolumeName: "HD",
            fileState: { path in
                recorder.record()
                return path == "/Users/m/a.md" ? .exists : .missing
            },
            isReachable: { root in
                recorder.record()
                return root == "/Users/m" || root == "/"
            })

        let model = RecentDocumentsMenuModel(list: list)
        await model.pendingCheck?.value

        XCTAssertEqual(model.urls.map(\.path), ["/Users/m/a.md"])
        XCTAssertEqual(defaults.stringArray(forKey: RecentDocumentsList.defaultsKey),
                       ["/Users/m/a.md", "/Volumes/Offline/b.md"], "the gone file is pruned")
        XCTAssertGreaterThan(recorder.count, 0)
        XCTAssertFalse(recorder.ranOnMain, "stat and directory listing must not run on the main thread")
    }
}

@MainActor
final class LaunchDecisionTests: XCTestCase {
    private func action(_ setting: Bool, content: Bool, windows: Bool) -> LaunchAction {
        LaunchDecision.action(showWelcomeOnLaunch: setting, launchedWithContent: content,
                              hasOpenWindows: windows)
    }

    func testPlainLaunchFollowsTheSetting() {
        XCTAssertEqual(action(true, content: false, windows: false), .showWelcome)
        XCTAssertEqual(action(false, content: false, windows: false), .newDocument)
    }

    func testOpenedFilesAndRestoredWindowsWin() {
        for setting in [true, false] {
            // Opened from Finder, a Service, or restoring windows.
            XCTAssertEqual(action(setting, content: true, windows: false), .none)
            XCTAssertEqual(action(setting, content: true, windows: true), .none)
            // A document is already open (restored before the check).
            XCTAssertEqual(action(setting, content: false, windows: true), .none)
        }
    }

    /// The fallback after a file launch cannot tell a failed open from one
    /// that is still reading, so it must never add an untitled document.
    func testLaunchFallbackNeverCreatesADocument() {
        XCTAssertEqual(LaunchDecision.fallbackAction(hasOpenWindows: false), .showWelcome)
        XCTAssertEqual(LaunchDecision.fallbackAction(hasOpenWindows: true), .none)
    }
}

@MainActor
final class WelcomeWindowTests: XCTestCase {
    func testSelectionMovesWithinTheList() {
        XCTAssertEqual(WelcomeRecentsSelection.moved(0, by: 1, count: 3), 1)
        XCTAssertEqual(WelcomeRecentsSelection.moved(2, by: 1, count: 3), 2)
        XCTAssertEqual(WelcomeRecentsSelection.moved(0, by: -1, count: 3), 0)
        XCTAssertEqual(WelcomeRecentsSelection.moved(0, by: 1, count: 0), 0)
        XCTAssertEqual(WelcomeRecentsSelection.clamped(4, count: 2), 1)
        XCTAssertEqual(WelcomeRecentsSelection.clamped(1, count: 0), 0)
    }

    func testOpenPanelAcceptsWhatFileOpenAccepts() {
        let types = WelcomeWindowController.openContentTypes
        XCTAssertEqual(types, MarkdownDocument.readableContentTypes)
        XCTAssertTrue(types.contains(.plainText), ".txt was not selectable in the welcome window")
    }

    func testVersionLineComesFromTheBundle() {
        let info = Bundle.main.infoDictionary
        XCTAssertEqual(WelcomeView.version.short, info?["CFBundleShortVersionString"] as? String)
        XCTAssertEqual(WelcomeView.version.build, info?["CFBundleVersion"] as? String)
    }

    func testWindowMatchesTheBoard() {
        XCTAssertEqual(WelcomeView.size, CGSize(width: 800, height: 500))
        XCTAssertEqual(WelcomeView.leftWidth, 440)
    }

    func testAutomaticTerminationIsOff() {
        // With it on, macOS could quit the windowless app in the
        // background and turn the next Dock click into a fresh launch.
        XCTAssertEqual(Bundle.main.infoDictionary?["NSSupportsAutomaticTermination"] as? Bool, false)
    }
}
