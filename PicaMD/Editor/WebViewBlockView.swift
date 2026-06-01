import AppKit
import WebKit

/// Base class for block overlays that render via a small WKWebView
/// (KaTeX math, Mermaid diagrams). Subclasses override `htmlForBlock()`
/// to provide their content; this class handles loading, dynamic
/// height reporting back to the host, and dark-mode reload.
///
/// If a subclass needs to reference local resources (e.g. KaTeX's
/// `katex.min.css` and font files), it overrides `resourceBaseURL()`
/// to return the writeable directory those resources live in. In that
/// case the base class writes the HTML there and uses `loadFileURL`
/// so WKWebView's cross-origin policy lets the page reach its assets.
class WebViewBlockView: BlockAttachmentView {
    private let webView: WKWebView
    private var lastHeight: CGFloat = 80
    var onHeightChange: ((CGFloat) -> Void)?

    /// Subclasses that stage their own HTML file should set this so
    /// deinit can delete it and prevent monotonic cache growth.
    /// The base class also sets it when it stages via resourceBaseURL().
    var stagedFileURL: URL?

    override init(block: ExtractedBlock, documentURL: URL?) {
        let cfg = WKWebViewConfiguration()
        let prefs = WKWebpagePreferences()
        prefs.allowsContentJavaScript = true
        cfg.defaultWebpagePreferences = prefs
        self.webView = WKWebView(frame: .zero, configuration: cfg)
        super.init(block: block, documentURL: documentURL)
    }

    required init?(coder: NSCoder) { fatalError() }

    deinit {
        // NOTE: a `@MainActor` class's `deinit` is *nonisolated* under
        // Swift 6, so it may NOT touch the main-actor-isolated WKWebView
        // here (Xcode 16 rejects it). The WebView teardown lives in the
        // main-actor `tearDownWebView()` below, which the owning
        // BlockOverlayManager calls before it drops the view. ARC also
        // tears the WKWebView down when this view deallocates.
        //
        // Deleting the staged HTML file IS nonisolated-safe (FileManager
        // is thread-safe and `stagedFileURL` is a plain stored property).
        if let url = stagedFileURL {
            try? FileManager.default.removeItem(at: url)
        }
    }

    /// Stop any in-flight load and detach handlers so the WebContent
    /// process isn't kept alive past eviction. Must be called on the
    /// main actor (the owning manager is `@MainActor`) BEFORE the view is
    /// removed/released — `deinit` can't do this under Swift 6.
    func tearDownWebView() {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.configuration.userContentController.removeAllScriptMessageHandlers()
    }

    override func setupContent() {
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor(white: 0.5, alpha: 0.04).cgColor

        webView.translatesAutoresizingMaskIntoConstraints = false
        webView.setValue(false, forKey: "drawsBackground")
        webView.navigationDelegate = nil
        addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: topAnchor, constant: 6),
            webView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            webView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            webView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -6),
        ])
        loadHTML()
    }

    /// Subclasses override to inject their HTML body.
    func htmlForBlock() -> String { "" }

    /// Subclasses that need access to local resources return a
    /// directory URL here. Returning nil keeps the legacy
    /// `loadHTMLString(_:baseURL:nil)` path.
    func resourceBaseURL() -> URL? { nil }

    /// Filename used when writing the per-block HTML alongside the
    /// resource bundle. Default is unique-per-block by source range.
    private var stagedFilename: String {
        let kind: String
        switch block.kind {
        case .mathBlock: kind = "math"
        case .mermaid:   kind = "mermaid"
        case .image:     kind = "image"
        case .table:     kind = "table"
        }
        return "\(kind)-\(block.range.location).html"
    }

    private func loadHTML() {
        let bg = isDark ? "#1d1d1f" : "#fafafa"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"
        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <style>
          html, body { margin: 0; padding: 0; background: \(bg); color: \(fg); font-family: -apple-system, system-ui, sans-serif; overflow: hidden; }
          body { padding: 4px 8px; }
        </style>
        </head><body><div id="content">\(htmlForBlock())</div>
        <script>
        function reportHeight() {
          var h = document.body.scrollHeight;
          window.webkit.messageHandlers.height.postMessage(h);
        }
        window.addEventListener('load', function() { setTimeout(reportHeight, 100); });
        </script>
        </body></html>
        """
        let userContent = webView.configuration.userContentController
        userContent.removeAllScriptMessageHandlers()
        userContent.add(WebViewHeightHandler { [weak self] h in
            guard let self = self else { return }
            if abs(h - self.lastHeight) > 1 {
                self.lastHeight = h
                self.onHeightChange?(h + 16)
            }
        }, name: "height")

        // Subclasses that override loadIntoWebView take control;
        // otherwise we fall back to the simple inline-HTML path.
        if loadIntoWebView(webView, isDark: isDark) {
            return
        }

        if let baseURL = resourceBaseURL() {
            let htmlURL = baseURL.appendingPathComponent(stagedFilename)
            do {
                try html.write(to: htmlURL, atomically: true, encoding: .utf8)
                stagedFileURL = htmlURL   // retained for deinit cleanup
                webView.loadFileURL(htmlURL, allowingReadAccessTo: baseURL)
                return
            } catch {
                NSLog("PicaMD: failed to stage block HTML: \(error)")
            }
        }
        webView.loadHTMLString(html, baseURL: nil)
    }

    /// Subclasses override for full control of the load pipeline
    /// (custom HTML + custom file location). Default does nothing
    /// and yields to the base class's standard path.
    /// Returning `true` means "I handled the load, base class can stop".
    func loadIntoWebView(_ webView: WKWebView, isDark: Bool) -> Bool { false }

    override func desiredHeight(for width: CGFloat) -> CGFloat {
        max(60, lastHeight + 12)
    }

    override func appearanceChanged() {
        loadHTML()
    }

    /// Exposed for subclasses that want to register additional script
    /// message handlers in `loadIntoWebView`.
    var underlyingWebView: WKWebView { webView }

    /// Re-installs the height handler. Subclasses that take over the
    /// load pipeline should call this so they still get height updates.
    func installHeightHandler() {
        let userContent = webView.configuration.userContentController
        userContent.removeAllScriptMessageHandlers()
        userContent.add(WebViewHeightHandler { [weak self] h in
            guard let self = self else { return }
            if abs(h - self.lastHeight) > 1 {
                self.lastHeight = h
                self.onHeightChange?(h + 16)
            }
        }, name: "height")
    }
}

/// JS↔Swift bridge for dynamic height reporting from KaTeX/Mermaid render.
private final class WebViewHeightHandler: NSObject, WKScriptMessageHandler {
    let cb: (CGFloat) -> Void
    init(_ cb: @escaping (CGFloat) -> Void) { self.cb = cb }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        if let n = message.body as? CGFloat {
            cb(n)
        } else if let d = message.body as? Double {
            cb(CGFloat(d))
        } else if let i = message.body as? Int {
            cb(CGFloat(i))
        }
    }
}
