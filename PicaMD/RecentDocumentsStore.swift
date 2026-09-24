import Foundation

/// Most-recently-opened document paths, persisted in UserDefaults.
///
/// SwiftUI's `DocumentGroup` does NOT populate
/// `NSDocumentController.recentDocumentURLs`, so we track recents
/// ourselves: a URL is recorded whenever a document's `representedURL` is
/// established (open or first save) — see `MarkdownTextView.Coordinator`.
/// The welcome window and File ▸ Open Recent read this list.
@MainActor
enum RecentDocumentsStore {
    private static let key = "PicaMD.recentDocuments.v1"
    private static let maxCount = 12

    /// Record (or promote) a document URL as most-recent.
    static func add(_ url: URL) {
        guard url.isFileURL else { return }
        let path = url.standardizedFileURL.path
        var paths = UserDefaults.standard.stringArray(forKey: key) ?? []
        paths.removeAll { $0 == path }
        paths.insert(path, at: 0)
        if paths.count > maxCount { paths = Array(paths.prefix(maxCount)) }
        UserDefaults.standard.set(paths, forKey: key)
        RecentDocumentsMenuModel.shared.refresh()
    }

    /// Recent document URLs, most-recent first, filtered to those that
    /// still exist on disk.
    static func urls() -> [URL] {
        (UserDefaults.standard.stringArray(forKey: key) ?? [])
            .map { URL(fileURLWithPath: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
        RecentDocumentsMenuModel.shared.refresh()
    }
}

/// Observable mirror of the recents list for File ▸ Open Recent.
@MainActor
final class RecentDocumentsMenuModel: ObservableObject {
    static let shared = RecentDocumentsMenuModel()
    @Published private(set) var urls: [URL] = []

    private init() { refresh() }

    func refresh() {
        let current = RecentDocumentsStore.urls()
        if current != urls { urls = current }
    }
}
