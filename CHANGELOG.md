# Changelog

All notable changes to PicaMD are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
is [SemVer](https://semver.org/).

## [Unreleased]

### Changed

- **Table cells wrap by default.** Rendered Markdown tables now word-wrap
  long cell content onto multiple lines (rows grow to fit) instead of
  truncating it with an ellipsis, so wide tables are readable without
  widening columns.
- **Welcome window on launch** (replaces the Finder open panel). Double-
  clicking PicaMD now opens a hub with a **New Document** button, an
  **Open Document…** button, and a **Recently Opened** list (filename +
  path, click to open, with Clear) — instead of forcing you through a
  Finder dialog. New documents are untitled / in-memory until the first
  ⌘S. Opening a file directly (Finder, recents, Open…) skips the hub;
  the hub reappears on a bare launch or a dock-click with no windows.
  Recents are tracked by PicaMD itself (DocumentGroup doesn't maintain
  `NSDocumentController.recentDocumentURLs`).

### Added

- **Markdown-aware Find & Replace** (`⌘F`). A custom in-editor find bar
  replaces the stock `NSTextView` find bar, which couldn't see through the
  editor's marker concealment. Matches are drawn as translucent,
  accent-tinted highlights painted on top of the glyphs, so they stay
  visible even where they cross concealed `**`/`_`/`` ` `` markup; the
  current match gets a bordered highlight and is scrolled into view.
  - Live "n von m" counter, `⌘G` / `⇧⌘G` to cycle matches, `⌘E` to search
    the selection, Esc to close.
  - Toggles for **case-sensitive**, **whole-word**, and **regex** (with an
    invalid-pattern indicator).
  - **Ignore-formatting** search (the Markdown-aware mode): matches against
    the rendered/visible text, so `bold word` finds `**bold**·word` even
    though the `**` markers split it in the source. Strips inline emphasis,
    code, strike, highlight, headings, blockquotes and collapses links to
    their text; fenced-code bodies are searched verbatim.
  - **Find & Replace** (`⌘⌥F`): Replace / Replace All, regex `$1` capture
    templates, single undo step for Replace All. (Replace is disabled while
    ignore-formatting is on — there's no single source span to substitute.)
- **Interactive task-list checkboxes**. `- [ ]` and `- [x]` now
  render as native AppKit checkboxes drawn in the editor's accent
  colour. Click to toggle — the source `[ ]` ↔ `[x]` flip goes
  through `NSTextStorage` so undo works. Checked items get a
  strike-through + dimmed colour on the trailing prose. Cursor
  on the line restores the raw markup for direct editing,
  matching the existing concealment idiom for every other inline
  syntax token. Same UX as Obsidian's Live Preview, native AppKit
  instead of CodeMirror decorations. 13 unit tests.
- **Create New File from launch open panel**. The cold-launch open
  dialog now has a **Create New File…** button next to Cancel /
  Open. One click opens a save panel pre-navigated to the folder
  the open dialog was browsing, you pick a name + location, the
  empty `.md` is created and opened in the editor. Same option is
  available when the dock icon is double-clicked with no open
  documents.

### Security

- **MCP sidecar is now scoped to open documents.** The `document.*`
  tools previously read/wrote any path the caller passed; a
  prompt-injection block in an opened doc could exfiltrate
  `~/.ssh/id_rsa` or overwrite `~/.zshrc`. Paths are now canonicalised
  and rejected unless they match a document actually open in PicaMD.
- **Math/Mermaid blocks no longer execute injected scripts.** A `$$…$$`
  or ```` ```mermaid ```` block containing `</script>` could break out
  of the render WebView's script element and run arbitrary JS. The
  source is now escaped against `</` end-tag detection.
- **Mermaid renders with `securityLevel: 'strict'`** (was `'loose'`),
  running diagram labels through DOMPurify and blocking `<script>` /
  `onerror` / `javascript:` payloads in diagram source.
- **AI endpoints are restricted to http/https** — `file://` and other
  schemes are rejected.
- **HTML pass-through is sanitised** before it reaches the Quick-Look
  preview or an exported `.html`: `<script>`/`<style>`/`<iframe>`/
  `<object>`/`<embed>`, `on*=` handlers, and `javascript:` URLs are
  stripped. Previously raw doc HTML executed verbatim in the export.
- **MCP write tools carry destructive-action annotations** so MCP
  hosts can prompt before `replaceLines`/`appendText`; read tools are
  marked read-only. Malformed JSON-RPC frames now return a `-32700`
  parse error instead of leaving the client hanging.
- The Services-menu handler writes its scratch file to a fresh
  symlink-safe item-replacement directory (was a predictable temp path).

### Fixed

- Mermaid CDN download now validates HTTP status, size, and content
  type before caching — a 503 error page or captive-portal redirect
  no longer poisons the cache permanently.
- The Mermaid online-fallback CDN version is back in lockstep with the
  cached version (was pinned at 10.9.1 while the cache fetched 11.14.0).
- `FileWatcher`'s self-write detection is recorded synchronously on the
  save queue, closing a race where the app's own save could surface as
  a spurious "file changed on disk" alert.
- The MCP active-documents registry now unregisters on window close and
  on Save-As, so the sidecar no longer reports stale/closed documents.
- Clickable task-list checkboxes are suppressed inside fenced code and
  math blocks, stay concealed off-viewport, and reject a stale click
  (after fast typing or an external reload) instead of corrupting text.
- Task-list extraction runs once per highlight pass and reuses a
  compiled regex (was extracted twice and recompiled each time).
- Editor font-size setting now scales headings, code, tables and math
  too (they were pinned to a separate hard-coded base size).
- Inline checkbox overlays reuse an indexed view pool instead of
  tearing down and rebuilding every checkbox on each keystroke.
- `MCP document.replaceLines` rejects a `start` past end-of-file
  instead of silently appending.
- Corrupt persisted theme JSON is logged and backed up (was silently
  reset); Mermaid downloads validate status/size/SHA-pin slot before
  caching and write with `0600` perms.
- WebView-backed math/mermaid blocks stop loading and delete their
  staged HTML on teardown (cache no longer grows unbounded).
- Task checkboxes are VoiceOver-accessible (checkbox role + Space to
  toggle); image/math/mermaid overlays expose their alt text/source.
- The cold-launch open panel is suppressed under XCTest so the test
  host can't hang on a modal dialog.

## [0.8.0-alpha] — 2026-05-07

First public release.

### Editor

- Single-view live preview — markup markers (`**`, `*`, `~~`, `==`,
  `` ` ``, `#`, `>`, `[]()`, math `$`) become invisible as you type
  and reappear when the cursor lands on them. Native `NSTextView`,
  not a CodeMirror-in-WebView.
- Block overlays for tables, images, KaTeX math (offline-bundled),
  and Mermaid diagrams (downloaded on first use). Lazy-render
  WebView pool caps RAM at ~540 MB on a 50-block stress doc.
- Outline sidebar with cursor auto-tracking. Frontmatter bar with
  title and tag chips. Footnote tooltips on `[^id]` hover.
- Tabs (`⌘T`), Focus mode (`⌃⌘F`), Typewriter mode (`⌃⌘Y`),
  Command palette (`⌘⇧P`).

### Theme system

- 3 built-in presets: Stock+, Editorial, Tahoe.
- 4 palettes: White, Off-White, Dark Grey, OLED. 7 accent colours.
- Body / heading font, heading scale, code-block style, hairline
  rule, status bar — all toggleable in `⌘,` Settings.
- Palette is independent of macOS Light/Dark Mode (use the White
  palette while macOS is in Dark Mode if you want).

### AI assistance (opt-in)

- Multi-provider: **Anthropic Claude**, **OpenAI**, or any
  **local OpenAI-compatible server** (LM Studio, Ollama, llama.cpp,
  vLLM, Groq, etc.).
- API keys stored in the macOS Keychain.
- 9 starter prompt presets bound to `⌃⌘1`–`⌃⌘9` (clean Markdown,
  summarize, rewrite, fix grammar, translate, …). Fully editable
  in Settings → AI → Presets. Add your own prompts.
- `⌃Space` opens a fuzzy picker over all presets.
- 5 insertion modes: replace selection, append below, blockquote,
  HTML comment, popover-only.
- Off by default. No data leaves your machine unless you configure
  a cloud endpoint and trigger a request.

### Claude Code MCP server

- Embedded `picamd-mcp` sidecar (`Contents/Resources/picamd-mcp`)
  exposes every open document to Claude Code through 8 tools:
  `workspace.openDocuments`, `workspace.search`,
  `document.metadata`, `document.outline`, `document.readLines`,
  `document.readSection`, `document.replaceLines`,
  `document.appendText`.
- Token-efficient: Claude can call `outline()` + `readSection()`
  instead of re-reading the whole file each pass — typically 10×
  token savings on edit loops.
- Add to `~/.config/claude-code/mcp.json`:
  ```json
  {
    "mcpServers": {
      "picamd": {
        "command": "/Applications/PicaMD.app/Contents/Resources/picamd-mcp"
      }
    }
  }
  ```

### macOS integration

- Quick-Look extension for `.md` files (Spacebar in Finder shows
  a styled preview). Render currently blocked on getting a paid
  Apple Developer ID for proper signing — extension is wired and
  registers correctly; only signing prevents the host from loading
  it. Resolves with v1.0.
- Spotlight indexing via CoreSpotlight (every opened/saved
  document gets frontmatter title + tags + body preview).
- Services menu: "Open Selection in PicaMD" lifts text from any
  other app into a fresh PicaMD doc.
- File → Export As… HTML (in-process, includes KaTeX/Mermaid/
  footnotes), PDF / DOCX / EPUB via user-installed `pandoc`.
- Auto-update via Sparkle 2 (EdDSA-signed appcast).

### Distribution

- `release.sh` produces `dist/PicaMD-<version>.zip` with ad-hoc
  signing today, ready to switch to Developer ID notarization
  when paid credentials land.
- GitHub Actions release workflow on tag push: build, sign, zip,
  generate release notes, upload .zip + SHA-256 checksum.
- 184 unit tests, 9.8 MB bundle, only Apple system libraries
  linked plus the Sparkle framework.

### Known limitations

- Quick-Look render is blocked on paid Apple Developer ID
  (auto-resolves with v1.0).
- Ad-hoc signing means first launch shows macOS's "can't be
  opened" warning — right-click → Open works around it once.
- Streaming AI responses (incremental insertion) is planned
  but not in 0.8.0.

[0.8.0-alpha]: https://github.com/michiwickman/picamd/releases/tag/v0.8.0-alpha
