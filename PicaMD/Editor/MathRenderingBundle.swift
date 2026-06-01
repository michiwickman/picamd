import Foundation

/// Owns the on-disk staging area for the bundled KaTeX assets and the
/// per-block HTML files we point WKWebView at via `loadFileURL`.
///
/// `loadHTMLString(_:baseURL:)` with a `file://` baseURL hits
/// WKWebView's cross-origin restriction and can't load sibling JS/CSS
/// files. The robust workaround is to stage everything into a single
/// writeable directory, write the per-render HTML there too, and use
/// `loadFileURL(_:allowingReadAccessTo:)` so the web process gets a
/// single root it's allowed to read from.
enum MathRenderingBundle {
    /// `~/Library/Caches/PicaMD/Math/`. KaTeX's `katex.min.js`,
    /// `katex.min.css` and `fonts/*.woff2` get copied here on first
    /// use; subsequent renders reuse the existing files.
    ///
    /// [F18] Uses the throwing FileManager variant so a sandbox or
    /// permission failure surfaces in the log rather than silently
    /// falling back to a reboot-purged temp dir that forces re-staging
    /// KaTeX every launch.
    static let cacheDir: URL = {
        do {
            let base = try FileManager.default.url(
                for: .cachesDirectory,
                in: .userDomainMask,
                appropriateFor: nil,
                create: true
            )
            return base.appendingPathComponent("PicaMD/Math", isDirectory: true)
        } catch {
            NSLog("PicaMD: Math cache dir fallback to temp: %@", error.localizedDescription)
            return URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("PicaMD/Math", isDirectory: true)
        }
    }()

    /// Copy the KaTeX assets out of the app bundle into `cacheDir`.
    /// Idempotent — only writes files that don't already exist.
    ///
    /// xcodegen with `type: folder` (the default) flattens our
    /// `Resources/katex/{js,css,fonts/*}` into the bundle root, so we
    /// look for the files directly under `Bundle.main.resourceURL`.
    /// The cache structure we lay out is what KaTeX's CSS expects:
    ///
    ///     <cacheDir>/
    ///         katex.min.js
    ///         katex.min.css
    ///         fonts/
    ///             KaTeX_Main-Regular.woff2
    ///             ...
    static func ensureInstalled() {
        let fm = FileManager.default
        try? fm.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: cacheDir.appendingPathComponent("fonts"),
                                withIntermediateDirectories: true)

        guard let resourcesRoot = Bundle.main.resourceURL else { return }

        copyIfMissing(resourcesRoot.appendingPathComponent("katex.min.js"),
                      to: cacheDir.appendingPathComponent("katex.min.js"))
        copyIfMissing(resourcesRoot.appendingPathComponent("katex.min.css"),
                      to: cacheDir.appendingPathComponent("katex.min.css"))

        // Font files: enumerate every KaTeX_*.woff2 in the bundle root.
        if let entries = try? fm.contentsOfDirectory(at: resourcesRoot,
                                                      includingPropertiesForKeys: nil) {
            for url in entries
                where url.lastPathComponent.hasPrefix("KaTeX_")
                   && url.pathExtension == "woff2"
            {
                copyIfMissing(url, to: cacheDir
                    .appendingPathComponent("fonts")
                    .appendingPathComponent(url.lastPathComponent))
            }
        }
    }

    /// True if KaTeX is staged and ready. We can render math math
    /// regardless (it just falls back to source-as-pre when KaTeX
    /// isn't loaded), but the indicator is useful in the WebView's
    /// fallback handler.
    static var isAvailable: Bool {
        FileManager.default.fileExists(
            atPath: cacheDir.appendingPathComponent("katex.min.js").path
        )
    }

    private static func copyIfMissing(_ src: URL, to dst: URL) {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: dst.path) else { return }
        try? fm.copyItem(at: src, to: dst)
    }
}
