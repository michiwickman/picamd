import Foundation
import WebKit

/// `$$...$$` math block rendered via KaTeX in a WKWebView.
///
/// KaTeX is bundled with the app (`Resources/katex/`), staged into a
/// writeable cache directory at first use, and loaded via `loadFileURL`
/// so the editor renders math offline — no CDN dependency.
final class MathBlockView: WebViewBlockView {
    override func htmlForBlock() -> String {
        // The base class calls into htmlForBlock() for its string-based
        // path, but for math we override loadIntoWebView() instead so
        // we can use loadFileURL with the staged cache directory.
        ""
    }

    override func loadIntoWebView(_ webView: WKWebView, isDark: Bool) -> Bool {
        MathRenderingBundle.ensureInstalled()
        let cacheDir = MathRenderingBundle.cacheDir
        installHeightHandler()

        // Strip `$$` fences from the source. Order matters here: the
        // mathBlock regex ends with `\s*$` which can include the trailing
        // newline in the captured payload, so we trim *first* and only
        // then check the fences — otherwise `hasSuffix("$$")` is false
        // and the closing fence sticks, KaTeX trips on it and falls back.
        var content = block.payload.trimmingCharacters(in: .whitespacesAndNewlines)
        if content.hasPrefix("$$") { content = String(content.dropFirst(2)) }
        if content.hasSuffix("$$") { content = String(content.dropLast(2)) }
        content = content.trimmingCharacters(in: .whitespacesAndNewlines)

        // VoiceOver: expose the LaTeX source so assistive tech can read it.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(content)

        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            // Defeat the HTML tokeniser's `</script>` end-tag detection.
            // `\(escaped)` is interpolated into a JS template literal inside
            // a <script> element; a doc containing `</script>` would otherwise
            // close the tag early and execute arbitrary injected HTML/JS.
            // `<\/` is a no-op escape in JS strings (yields `/`) but the HTML
            // parser no longer sees a candidate end-tag.
            .replacingOccurrences(of: "</", with: "<\\/")

        let bg = isDark ? "#1d1d1f" : "#fafafa"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"

        let html = """
        <!DOCTYPE html>
        <html><head>
        <meta charset="utf-8">
        <link rel="stylesheet" href="katex.min.css">
        <style>
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
                       font-family: -apple-system, system-ui, sans-serif;
                       overflow:hidden; }
          body { padding:6px 8px; }
          #math { font-size:18px; text-align:center; padding:4px 0; }
          .qmd-fallback { background:transparent; color:inherit; text-align:left;
                          font-family: ui-monospace, 'SF Mono', monospace;
                          font-size:13px; }
        </style>
        </head><body>
        <div id="math"></div>
        <script src="katex.min.js"
                onerror="renderFallback('katex.min.js failed to load')"></script>
        <script>
        function renderFallback(reason) {
          document.getElementById('math').innerHTML =
            '<pre class="qmd-fallback">' +
              `\(escaped)`.replace(/&/g,'&amp;').replace(/</g,'&lt;') +
            '</pre>';
          if (window.webkit) window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
        }
        function tryRender() {
          if (window.katex) {
            try {
              katex.render(`\(escaped)`, document.getElementById('math'),
                            { displayMode: true, throwOnError: false });
            } catch (e) { renderFallback('katex.render: ' + e.message); }
            if (window.webkit) window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
          } else {
            setTimeout(tryRender, 50);
          }
        }
        tryRender();
        </script>
        </body></html>
        """

        // Stage the per-block HTML alongside the KaTeX assets so
        // loadFileURL's allowingReadAccessTo covers everything.
        let htmlURL = cacheDir.appendingPathComponent("math-\(block.range.location).html")
        do {
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            stagedFileURL = htmlURL   // so WebViewBlockView.deinit can delete it
            webView.loadFileURL(htmlURL, allowingReadAccessTo: cacheDir)
            return true
        } catch {
            NSLog("PicaMD: failed to stage math HTML: \(error)")
            webView.loadHTMLString(html, baseURL: nil)
            return true
        }
    }
}
