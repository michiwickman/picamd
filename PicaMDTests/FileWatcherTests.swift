import XCTest
@testable import PicaMD

/// Tests for FileWatcher, which watches a file URL via a Dispatch vnode
/// source and fires `onExternalChange` on .main.
///
/// Each test creates its own unique temp file and removes it in tearDown.
/// Vnode delivery can take tens of ms; generous timeouts (1.5s) are used.
/// The self-write suppression window is EditorTiming.selfWriteIgnoreInterval
/// (1.5 s); the inverted expectation for that test uses 0.5 s so the test
/// finishes before the window expires.
@MainActor
final class FileWatcherTests: XCTestCase {

    private var watcher: FileWatcher!
    private var tempURL: URL!

    override func setUp() async throws {
        try await super.setUp()
        watcher = FileWatcher()
        // Unique file per test instance to avoid cross-test interference.
        let name = UUID().uuidString + ".md"
        tempURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(name)
        // Create an initial file so O_EVTONLY can open it.
        try "initial content\n".write(to: tempURL, atomically: true, encoding: .utf8)
    }

    override func tearDown() async throws {
        watcher.stop()
        watcher = nil
        if let url = tempURL {
            try? FileManager.default.removeItem(at: url)
            tempURL = nil
        }
        try await super.tearDown()
    }

    /// Append bytes to the watched file IN PLACE (same inode), so the
    /// vnode source sees a `.write`/`.extend` event → `.modified`. A
    /// `String.write(atomically: true)` would instead swap the inode via
    /// a temp-file rename, firing `.rename`/`.delete` (`.renamedOrDeleted`)
    /// — which is not what these "content changed" tests intend.
    private func appendInPlace(_ text: String, to url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        handle.seekToEndOfFile()
        try handle.write(contentsOf: Data(text.utf8))
    }

    // MARK: - testExternalWriteFiresModified

    /// Writing new bytes to the watched file from an external process
    /// (simulated via FileManager here, without noteSelfWrite()) must fire
    /// `.modified` through `onExternalChange`.
    func testExternalWriteFiresModified() throws {
        let expectation = expectation(description: "onExternalChange fires .modified")

        watcher.startWatching(tempURL)
        watcher.onExternalChange = { event in
            if case .modified = event {
                expectation.fulfill()
            }
        }

        // Write without calling noteSelfWrite() — simulates an external change.
        try appendInPlace("updated content\n", to: tempURL)

        wait(for: [expectation], timeout: 1.5)
    }

    // MARK: - testSelfWriteIsSuppressed

    /// After `noteSelfWrite()` is called, a write within the ignore window
    /// must NOT produce an `onExternalChange` callback. Uses an inverted
    /// expectation with a 0.5 s timeout (well within the 1.5 s window).
    func testSelfWriteIsSuppressed() throws {
        let noEvent = expectation(description: "NO event should arrive after noteSelfWrite")
        noEvent.isInverted = true

        watcher.startWatching(tempURL)
        watcher.onExternalChange = { _ in
            noEvent.fulfill()   // fulfill = test failure (inverted)
        }

        // Record a self-write synchronously, then write the file in place
        // (a real `.write` event the suppression window must swallow).
        watcher.noteSelfWrite()
        try appendInPlace("self-written content\n", to: tempURL)

        // Wait 0.5 s — inside the 1.5 s suppression window.
        wait(for: [noEvent], timeout: 0.5)
    }

    // MARK: - testDeleteFiresRenamedOrDeleted

    /// Removing the watched file must fire `.renamedOrDeleted`.
    func testDeleteFiresRenamedOrDeleted() throws {
        let expectation = expectation(description: "onExternalChange fires .renamedOrDeleted")

        watcher.startWatching(tempURL)
        watcher.onExternalChange = { event in
            if case .renamedOrDeleted = event {
                expectation.fulfill()
            }
        }

        try FileManager.default.removeItem(at: tempURL)

        wait(for: [expectation], timeout: 1.5)
    }

    // MARK: - testStopClearsCurrentURL

    /// `currentURL` must equal the watched URL after `startWatching`, and
    /// must be `nil` after `stop()`.
    func testStopClearsCurrentURL() {
        watcher.startWatching(tempURL)
        XCTAssertEqual(watcher.currentURL, tempURL,
                       "currentURL must be set after startWatching")

        watcher.stop()
        XCTAssertNil(watcher.currentURL,
                     "currentURL must be nil after stop()")
    }

    // MARK: - testStartOverStartReplacesURL

    /// Calling `startWatching` a second time (with a different URL) must
    /// replace the previous watch; `currentURL` must reflect the new URL.
    func testStartOverStartReplacesURL() throws {
        // Create a second temp file.
        let nameB = UUID().uuidString + ".md"
        let urlB = FileManager.default.temporaryDirectory
            .appendingPathComponent(nameB)
        try "second file\n".write(to: urlB, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: urlB) }

        watcher.startWatching(tempURL)
        XCTAssertEqual(watcher.currentURL, tempURL,
                       "currentURL must equal the first URL after first startWatching")

        watcher.startWatching(urlB)
        XCTAssertEqual(watcher.currentURL, urlB,
                       "currentURL must equal the second URL after second startWatching")
    }
}
