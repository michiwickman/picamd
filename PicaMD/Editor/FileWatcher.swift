// `@preconcurrency` so `DispatchSourceFileSystemObject` (non-Sendable
// in Dispatch's modern annotations) doesn't trip Swift 6 strict-
// concurrency in the deinit below. The cancel call is thread-safe;
// the type just isn't *typed* as Sendable.
@preconcurrency import Dispatch
import Foundation
import os

/// Watches a file URL for external changes via Dispatch's vnode-events.
/// Designed for editor use: detects writes and renames from other
/// processes (git pull, iCloud sync, another editor saving over us)
/// and notifies on the main queue.
///
/// The watcher debounces its own saves: after `noteSelfWrite()` is
/// called, any change events within `selfWriteIgnoreInterval` seconds
/// are treated as our own and not forwarded.
@MainActor
final class FileWatcher {
    enum Event {
        case modified
        case renamedOrDeleted
    }

    private var source: DispatchSourceFileSystemObject?
    private var fileDescriptor: CInt = -1
    private var watchedURL: URL?
    /// Lock-protected so `noteSelfWrite()` can be `nonisolated` and run
    /// SYNCHRONOUSLY from whatever thread posts `documentWillWrite` (the
    /// document save queue). The self-write must be recorded BEFORE the
    /// vnode `.write` event fires on `.main`; hopping through a
    /// `Task { @MainActor }` to set this races the event handler and lets
    /// our own save surface as a spurious "file changed on disk" alert.
    private let lastSelfWrite = OSAllocatedUnfairLock<Date>(initialState: .distantPast)
    private let selfWriteIgnoreInterval: TimeInterval = EditorTiming.selfWriteIgnoreInterval

    /// Called on the main queue when the watched file changed externally.
    var onExternalChange: ((Event) -> Void)?

    func startWatching(_ url: URL) {
        stop()
        guard url.isFileURL else { return }
        let path = url.path
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else {
            // O_EVTONLY can fail on some network/SMB volumes (EACCES),
            // a since-deleted file (ENOENT), or fd exhaustion (EMFILE).
            // Surface it: silently disabling external-change detection
            // is exactly the data-loss hazard this watcher exists to
            // prevent. (errno must be read before any other libc call.)
            let err = errno
            NSLog("PicaMD: FileWatcher open(O_EVTONLY) failed for %@ (errno %d)", path, err)
            return
        }
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: .main
        )
        let lastSelf = lastSelfWrite   // Sendable lock box; safe to capture
        let interval = selfWriteIgnoreInterval
        let cb = { [weak self] (event: Event) in
            self?.onExternalChange?(event)
        }
        src.setEventHandler {
            // Filter out writes we triggered ourselves
            let now = Date()
            if now.timeIntervalSince(lastSelf.withLock { $0 }) < interval {
                return
            }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                cb(.renamedOrDeleted)
            } else {
                cb(.modified)
            }
        }
        src.setCancelHandler { [fd] in
            close(fd)
        }
        src.resume()

        self.source = src
        self.fileDescriptor = fd
        self.watchedURL = url
    }

    func stop() {
        source?.cancel()
        source = nil
        fileDescriptor = -1
        watchedURL = nil
    }

    /// Call right after writing the file ourselves so the next vnode
    /// event isn't reported as an external change. `nonisolated` +
    /// lock-protected so it can run synchronously on the save queue,
    /// before the vnode event fires — see `lastSelfWrite` above.
    nonisolated func noteSelfWrite() {
        lastSelfWrite.withLock { $0 = Date() }
    }

    var currentURL: URL? { watchedURL }

    deinit {
        // `@preconcurrency import Dispatch` (top of file) is what
        // lets us touch `source` here — see comment there.
        source?.cancel()
    }
}
