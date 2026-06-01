import Foundation
import CryptoKit

/// Mermaid is too large (~3 MB) to ship in the app bundle without
/// blowing past the lean-bundle goal. We download it once on first
/// use and cache it under `~/Library/Caches/PicaMD/Mermaid/`.
///
/// When the file is already present, render is offline-capable. When
/// it isn't (and we have no network), the WebView's `onerror` fallback
/// shows the source text in a code-block style.
enum MermaidRenderingBundle {
    private static let mermaidVersion = "11.14.0"
    private static let mermaidURL = "https://cdn.jsdelivr.net/npm/mermaid@\(mermaidVersion)/dist/mermaid.min.js"

    /// The CDN URL for the exact version we cache. Exposed so the
    /// `MermaidBlockView` online-fallback `<script src>` can't drift to
    /// a different version than the one we download for offline use.
    static var cdnURL: String { mermaidURL }

    /// Floor on a plausible mermaid.min.js size. The real bundle is
    /// ~2.8 MB; anything under 100 KB is a captive-portal page, a CDN
    /// error body, or a truncated download — never the real script.
    private static let minPlausibleSize = 100_000

    /// Pinned SHA-256 hex digest of the expected mermaid.min.js for
    /// `mermaidVersion` (jsdelivr serves immutable bytes per npm version).
    /// A download whose hash doesn't match is rejected, so a compromised
    /// CDN or a one-shot MITM on first fetch can't pin malicious JS into
    /// the WebView. Update this in lockstep whenever `mermaidVersion`
    /// changes: `shasum -a 256 mermaid.min.js`.
    private static let expectedSHA256: String? =
        "217b66ef4279c33c141b4afe22effad10a91c02558dc70917be2c0981e78ed87"

    // [F18] Use the throwing FileManager variant so a sandbox/permission
    // failure surfaces in the log instead of silently falling back to
    // a reboot-purged temp dir that forces a re-download every launch.
    static let cacheDir: URL = {
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return base.appendingPathComponent("PicaMD/Mermaid", isDirectory: true)
        } catch {
            NSLog("PicaMD: Mermaid cache dir fallback to temp: %@", error.localizedDescription)
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PicaMD/Mermaid", isDirectory: true)
        }
    }()

    static var localScriptURL: URL {
        cacheDir.appendingPathComponent("mermaid.min.js")
    }

    static var isAvailable: Bool {
        FileManager.default.fileExists(atPath: localScriptURL.path)
    }

    /// Synchronously make sure the cache dir exists. Schedule a
    /// best-effort download in the background. The first Mermaid
    /// block to render will fall back to the source until the
    /// download completes; subsequent renders pick up the cached file.
    static func ensureInstalled(then completion: @escaping @Sendable (Bool) -> Void) {
        // [F2] Surface createDirectory errors instead of silently swallowing them.
        do {
            try FileManager.default.createDirectory(at: cacheDir,
                                                     withIntermediateDirectories: true)
        } catch {
            NSLog("PicaMD: Mermaid createDirectory failed: %@", error.localizedDescription)
            completion(false)
            return
        }
        if isAvailable {
            completion(true)
            return
        }
        guard let remote = URL(string: mermaidURL) else {
            completion(false)
            return
        }
        let dst = localScriptURL
        URLSession.shared.dataTask(with: remote) { data, response, error in
            // [F2] Log network errors so failures are diagnosable.
            if let error = error {
                NSLog("PicaMD: Mermaid download error: %@", error.localizedDescription)
                completion(false)
                return
            }
            // Validate before caching: a 503 HTML error page or a captive
            // portal login page both arrive as (non-nil data, nil error),
            // and writing that garbage to mermaid.min.js poisons the cache
            // permanently (isAvailable then returns true forever, renders
            // fall back to source, and the only fix is nuking the cache dir).
            guard let data = data,
                  let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode),
                  data.count >= minPlausibleSize else {
                completion(false)
                return
            }
            // Cheap content sniff: reject HTML error / captive-portal bodies.
            let head = String(data: data.prefix(64), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased() ?? ""
            if head.hasPrefix("<!doctype") || head.hasPrefix("<html") {
                completion(false)
                return
            }
            // [F4] SHA-256 integrity check. When expectedSHA256 is nil the
            // bundle is considered unpinned — log once and allow caching.
            // When a digest is pinned and the download doesn't match, reject
            // it without writing so a MITM or CDN compromise can't poison
            // the local cache.
            let digest = SHA256.hash(data: data)
            let hexDigest = digest.map { String(format: "%02x", $0) }.joined()
            if let pinned = expectedSHA256 {
                guard hexDigest == pinned else {
                    NSLog("PicaMD: Mermaid integrity check FAILED — got %@ expected %@",
                          hexDigest, pinned)
                    completion(false)
                    return
                }
            } else {
                NSLog("PicaMD: Mermaid bundle is unpinned — SHA-256 is %@", hexDigest)
            }
            do {
                // Write with restricted permissions (owner read/write only)
                // so the cached JS is not world-readable/writable.
                try data.write(to: dst, options: .atomic)
                try FileManager.default.setAttributes(
                    [.posixPermissions: 0o600],
                    ofItemAtPath: dst.path
                )
                completion(true)
            } catch {
                completion(false)
            }
        }.resume()
    }
}
