import XCTest
@testable import PicaMD

/// Tests for FileWatcher, which watches a file URL via a Dispatch vnode
/// source and fires `onExternalChange` on .main.
///
/// The class is intentionally NOT `@MainActor`: a `@MainActor` XCTestCase
/// with an async `setUp()`/`tearDown()` that awaits `super` trips Xcode
/// 16's "sending main-actor XCTestCase to a nonisolated context" check.
/// Instead each test is marked `@MainActor` (FileWatcher is `@MainActor`)
/// and builds its own fixture with `defer` cleanup — no shared setUp.
final class FileWatcherTests: XCTestCase {

    /// Create a watcher + a unique temp file seeded with initial content
    /// (so O_EVTONLY can open it). Caller is responsible for stop +
    /// removeItem (via `defer`).
    @MainActor
    private func makeFixture() throws -> (FileWatcher, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        try "initial content\n".write(to: url, atomically: true, encoding: .utf8)
        return (FileWatcher(), url)
    }

    /// Append bytes IN PLACE (same inode) so the vnode source sees a
    /// `.write`/`.extend` event → `.modified`. `String.write(atomically:)`
    /// would swap the inode via a rename and fire `.renamedOrDeleted`.
    private func appendInPlace(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data(text.utf8))
    }

    @MainActor
    func testExternalWriteFiresModified() throws {
        let (watcher, url) = try makeFixture()
        defer { watcher.stop(); try? FileManager.default.removeItem(at: url) }

        let fired = expectation(description: "onExternalChange fires .modified")
        watcher.startWatching(url)
        watcher.onExternalChange = { event in
            if case .modified = event { fired.fulfill() }
        }
        try appendInPlace("updated content\n", to: url)
        wait(for: [fired], timeout: 1.5)
    }

    @MainActor
    func testSelfWriteIsSuppressed() throws {
        let (watcher, url) = try makeFixture()
        defer { watcher.stop(); try? FileManager.default.removeItem(at: url) }

        let noEvent = expectation(description: "NO event after noteSelfWrite")
        noEvent.isInverted = true
        watcher.startWatching(url)
        watcher.onExternalChange = { _ in noEvent.fulfill() }

        watcher.noteSelfWrite()
        try appendInPlace("self-written content\n", to: url)
        wait(for: [noEvent], timeout: 0.5)   // inside the 1.5s suppression window
    }

    @MainActor
    func testDeleteFiresRenamedOrDeleted() throws {
        let (watcher, url) = try makeFixture()
        defer { watcher.stop(); try? FileManager.default.removeItem(at: url) }

        let fired = expectation(description: "onExternalChange fires .renamedOrDeleted")
        watcher.startWatching(url)
        watcher.onExternalChange = { event in
            if case .renamedOrDeleted = event { fired.fulfill() }
        }
        try FileManager.default.removeItem(at: url)
        wait(for: [fired], timeout: 1.5)
    }

    @MainActor
    func testStopClearsCurrentURL() throws {
        let (watcher, url) = try makeFixture()
        defer { watcher.stop(); try? FileManager.default.removeItem(at: url) }

        watcher.startWatching(url)
        XCTAssertEqual(watcher.currentURL, url, "currentURL set after startWatching")
        watcher.stop()
        XCTAssertNil(watcher.currentURL, "currentURL nil after stop()")
    }

    @MainActor
    func testStartOverStartReplacesURL() throws {
        let (watcher, urlA) = try makeFixture()
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString + ".md")
        try "second file\n".write(to: urlB, atomically: true, encoding: .utf8)
        defer {
            watcher.stop()
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        watcher.startWatching(urlA)
        XCTAssertEqual(watcher.currentURL, urlA)
        watcher.startWatching(urlB)
        XCTAssertEqual(watcher.currentURL, urlB, "second startWatching replaces the URL")
    }
}
