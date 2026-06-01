import Foundation
import WebKit

/// ` ```mermaid ... ``` ` block rendered via mermaid.js in a WKWebView.
///
/// Mermaid is downloaded on first use into the cache dir (it's too
/// large to bundle). If the user is offline at first-render the block
/// falls back to source-as-code; once the download lands, future
/// renders pick up the cached copy.
final class MermaidBlockView: WebViewBlockView {
    override func htmlForBlock() -> String { "" }

    override func loadIntoWebView(_ webView: WKWebView, isDark: Bool) -> Bool {
        let cacheDir = MermaidRenderingBundle.cacheDir
        try? FileManager.default.createDirectory(at: cacheDir,
                                                  withIntermediateDirectories: true)
        installHeightHandler()

        // Strip ```mermaid wrapper.
        var content = block.payload
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count >= 2,
           lines.first?.trimmingCharacters(in: .whitespaces).hasPrefix("```mermaid") == true,
           lines.last?.trimmingCharacters(in: .whitespaces) == "```" {
            content = lines.dropFirst().dropLast().joined(separator: "\n")
        }

        // VoiceOver: expose the Mermaid source so assistive tech can read it.
        setAccessibilityElement(true)
        setAccessibilityRole(.staticText)
        setAccessibilityValue(content)

        let source = content
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let escaped = content
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "`", with: "\\`")
            .replacingOccurrences(of: "$", with: "\\$")
            // Defeat `</script>` end-tag detection — `\(escaped)` is
            // interpolated into JS template literals inside <script>
            // elements (lines below). `<\/` is a no-op JS escape but
            // stops the HTML parser from closing the tag early. The
            // `source` var above is already HTML-escaped (< → &lt;) for
            // the diagram div, so only `escaped` needs this.
            .replacingOccurrences(of: "</", with: "<\\/")

        let theme = isDark ? "dark" : "default"
        let bg = isDark ? "#1d1d1f" : "#fafafa"
        let fg = isDark ? "#e0e0e0" : "#1a1a1a"

        // Prefer local script if cached, otherwise use the remote URL.
        let scriptSrc: String
        if MermaidRenderingBundle.isAvailable {
            scriptSrc = "mermaid.min.js"
        } else {
            // Keep the CDN-fallback version in lockstep with the version
            // MermaidRenderingBundle caches, or the offline copy and the
            // first-render online copy diverge.
            scriptSrc = MermaidRenderingBundle.cdnURL
            // Kick off the download for next time.
            MermaidRenderingBundle.ensureInstalled { _ in }
        }

        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8">
        <style>
          html, body { margin:0; padding:0; background:\(bg); color:\(fg);
                       font-family: -apple-system, system-ui, sans-serif;
                       overflow:hidden; }
          body { padding:6px 8px; }
          .qmd-fallback { background:transparent; color:inherit; text-align:left;
                          font-family: ui-monospace, 'SF Mono', monospace;
                          font-size:13px; white-space:pre; }
        </style>
        </head><body>
        <div id="diagram" class="mermaid">\(source)</div>
        <script src="\(scriptSrc)"
                onerror="document.getElementById('diagram').outerHTML =
                          '<pre class=\\'qmd-fallback\\'>' +
                            `\(escaped)`.replace(/&/g,'&amp;').replace(/</g,'&lt;') +
                          '</pre>';
                          if (window.webkit) window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);"></script>
        <script>
        function tryRender() {
          if (window.mermaid) {
            mermaid.initialize({startOnLoad:false, theme:'\(theme)', securityLevel:'strict'});
            mermaid.run({nodes: [document.getElementById('diagram')]}).then(function() {
              if (window.webkit) window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
            }).catch(function(e) {
              document.getElementById('diagram').outerHTML =
                '<pre class="qmd-fallback">' +
                  `\(escaped)`.replace(/&/g,'&amp;').replace(/</g,'&lt;') +
                '</pre>';
              if (window.webkit) window.webkit.messageHandlers.height.postMessage(document.body.scrollHeight);
            });
          } else {
            setTimeout(tryRender, 80);
          }
        }
        tryRender();
        </script>
        </body></html>
        """

        let htmlURL = cacheDir.appendingPathComponent("mermaid-\(block.range.location).html")
        do {
            try html.write(to: htmlURL, atomically: true, encoding: .utf8)
            stagedFileURL = htmlURL   // so WebViewBlockView.deinit can delete it
            webView.loadFileURL(htmlURL, allowingReadAccessTo: cacheDir)
        } catch {
            webView.loadHTMLString(html, baseURL: nil)
        }
        return true
    }
}
