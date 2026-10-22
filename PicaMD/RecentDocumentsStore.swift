import AppKit

/// Most-recently-opened document paths, persisted in UserDefaults.
///
/// SwiftUI's `DocumentGroup` does NOT populate
/// `NSDocumentController.recentDocumentURLs`, so we track recents
/// ourselves: a URL is recorded whenever a document's `representedURL` is
/// established (open or first save) — see `MarkdownTextView.Coordinator`.
/// The welcome window and File ▸ Open Recent read this list.
///
/// A value type over injected defaults and file checks so tests run on a
/// private suite and made-up paths; the app uses `RecentDocumentsStore`.
struct RecentDocumentsList {
    static let defaultsKey = "PicaMD.recentDocuments.v1"
    static let maxCount = 12

    /// What `urls()` does with a stored path.
    enum Status: Equatable {
        case visible
        /// Missing, but its disk or cloud account isn't reachable right
        /// now (unplugged drive, OneDrive signed out), or PicaMD may not
        /// read it (privacy prompt declined): hidden, kept.
        case hidden
        /// In the Trash, or missing although its location is reachable:
        /// the file is gone, so the entry stops taking one of the 12 places.
        case pruned
    }

    /// What a stat of a stored path says.
    enum FileState: Equatable {
        case exists
        /// No such file (ENOENT, ENOTDIR).
        case missing
        /// Any other failure, mostly EPERM from a privacy-protected folder
        /// (Documents, Desktop, Downloads) PicaMD was not granted. The
        /// file may well be there, so this never prunes.
        case unreadable
    }

    let defaults: UserDefaults
    let home: String
    let startupVolumeName: String
    /// Stats a path. Runs off the main thread (see `statusResolver`).
    let fileState: @Sendable (String) -> FileState
    /// Whether a location root can be listed. A listing, not a stat: a
    /// cloud folder PicaMD may not read (privacy prompt declined) must
    /// count as unreachable, or its files would look deleted.
    let isReachable: @Sendable (String) -> Bool

    func status(of path: String) -> Status {
        statusResolver(path)
    }

    /// `status(of:)` as a function that holds no defaults, so it can run
    /// on a background thread: a stat on a stalled network or cloud
    /// volume blocks until its timeout, and must not freeze the app.
    var statusResolver: @Sendable (String) -> Status {
        let home = home, startupVolumeName = startupVolumeName
        let fileState = fileState, isReachable = isReachable
        return { path in
            if RecentDocumentLocation.isInTrash(path) { return .pruned }
            switch fileState(path) {
            case .exists: return .visible
            case .unreadable: return .hidden
            case .missing: break
            }
            // The home folder is always listable, so its root says nothing
            // about a declined Documents prompt; the errno check above
            // covers that case.
            let root = RecentDocumentLocation.root(
                of: path, home: home, startupVolumeName: startupVolumeName)
            return isReachable(root.path) ? .pruned : .hidden
        }
    }

    /// Record (or promote) a document URL as most-recent.
    func add(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        var paths = storedPaths
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > Self.maxCount { paths = Array(paths.prefix(Self.maxCount)) }
        defaults.set(paths, forKey: Self.defaultsKey)
    }

    /// Recent documents to show, most-recent first. Drops pruned entries
    /// from the store as a side effect.
    func urls() -> [URL] {
        let resolve = statusResolver
        let paths = storedPaths
        return apply(Dictionary(paths.map { ($0, resolve($0)) }, uniquingKeysWith: { a, _ in a }))
    }

    /// Applies statuses worked out earlier (perhaps on another thread) to
    /// the paths stored NOW: prunes, and returns the visible ones. A path
    /// added since has no status and counts as visible — it was just
    /// opened or saved.
    func apply(_ statuses: [String: Status]) -> [URL] {
        let paths = storedPaths
        var kept: [String] = []
        var visible: [URL] = []
        for path in paths {
            switch statuses[path] ?? .visible {
            case .visible:
                kept.append(path)
                visible.append(URL(fileURLWithPath: path))
            case .hidden:
                kept.append(path)
            case .pruned:
                break
            }
        }
        if kept != paths { defaults.set(kept, forKey: Self.defaultsKey) }
        return visible
    }

    func remove(_ url: URL) {
        let path = url.standardizedFileURL.path
        let paths = storedPaths
        let kept = paths.filter { $0 != path }
        if kept != paths { defaults.set(kept, forKey: Self.defaultsKey) }
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    var storedPaths: [String] {
        defaults.stringArray(forKey: Self.defaultsKey) ?? []
    }

    /// Subtitle for a recent document ("Documents ▸ Travel").
    func subtitle(for url: URL) -> String {
        RecentDocumentLocation.subtitle(
            forFile: url.path, home: home, startupVolumeName: startupVolumeName)
    }

    /// File ▸ Open Recent titles: the file name, plus its folder when two
    /// recents share a name ("README.md — PicaMD"), as the system's own
    /// Open Recent menus do.
    static func menuTitles(for urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        return urls.map { url in
            let name = url.lastPathComponent
            guard names.filter({ $0 == name }).count > 1 else { return name }
            return "\(name) — \(url.deletingLastPathComponent().lastPathComponent)"
        }
    }
}

extension RecentDocumentsList {
    /// The real store: standard defaults, the user's home folder and disk.
    static func live() -> RecentDocumentsList {
        let fileManager = FileManager.default
        let volumeName = (try? URL(fileURLWithPath: "/")
            .resourceValues(forKeys: [.volumeLocalizedNameKey]))?.volumeLocalizedName
        return RecentDocumentsList(
            defaults: .standard,
            home: fileManager.homeDirectoryForCurrentUser.path,
            startupVolumeName: volumeName ?? "Macintosh HD",
            fileState: { path in
                // stat, not FileManager.fileExists: that one reports a file
                // PicaMD may not read as missing, which would prune it.
                var info = stat()
                if stat(path, &info) == 0 { return .exists }
                return errno == ENOENT || errno == ENOTDIR ? .missing : .unreadable
            },
            isReachable: { (try? FileManager.default.contentsOfDirectory(atPath: $0)) != nil }
        )
    }
}

/// The app's recents, shared by the welcome window and File ▸ Open Recent.
@MainActor
enum RecentDocumentsStore {
    static let list = RecentDocumentsList.live()

    static func add(_ url: URL) {
        list.add(url)
        RecentDocumentsMenuModel.shared.refresh()
    }

    static func remove(_ url: URL) {
        list.remove(url)
        RecentDocumentsMenuModel.shared.refresh()
    }

    static func clear() {
        list.clear()
        RecentDocumentsMenuModel.shared.refresh()
    }

    /// Opens a recent document. A failure (moved, unreadable, not UTF-8)
    /// shows the error instead of doing nothing, and the list is
    /// refreshed so a file that has gone disappears from it.
    static func open(_ url: URL) {
        NSDocumentController.shared.openDocument(withContentsOf: url, display: true) { _, _, error in
            guard let error else { return }
            NSAlert(error: error).runModal()
            RecentDocumentsMenuModel.shared.refresh()
        }
    }
}

/// Observable mirror of the recents list for File ▸ Open Recent and the
/// welcome window. Refreshed on every change through the store and when
/// the app becomes active, so files deleted or trashed in Finder in the
/// meantime drop out of the menu.
///
/// The file checks run on a background task: `shared` is created while the
/// App struct is built, before launch finishes, and refreshes on every
/// activation, and a stat of a file on a stalled SMB or cloud volume blocks
/// until its timeout. Until a check reports, the menu shows the stored
/// list as it was.
@MainActor
final class RecentDocumentsMenuModel: ObservableObject {
    static let shared = RecentDocumentsMenuModel(list: RecentDocumentsStore.list,
                                                 observesActivation: true)
    @Published private(set) var urls: [URL] = []

    private let list: RecentDocumentsList
    /// Counts refreshes, so the result of an older check that finishes
    /// late does not overwrite a newer one.
    private var generation = 0
    /// The check in flight, for tests.
    private(set) var pendingCheck: Task<Void, Never>?

    init(list: RecentDocumentsList, observesActivation: Bool = false) {
        self.list = list
        urls = list.storedPaths.map { URL(fileURLWithPath: $0) }
        refresh()
        guard observesActivation else { return }
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func refresh() {
        generation += 1
        let current = generation
        let paths = list.storedPaths
        let resolve = list.statusResolver
        pendingCheck = Task { [weak self] in
            let statuses = await Task.detached(priority: .userInitiated) {
                Dictionary(paths.map { ($0, resolve($0)) }, uniquingKeysWith: { a, _ in a })
            }.value
            guard let self, current == self.generation else { return }
            let resolved = self.list.apply(statuses)
            if resolved != self.urls { self.urls = resolved }
        }
    }
}
