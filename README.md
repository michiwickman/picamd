# PicaMD

Inline-WYSIWYG Markdown editor for macOS. AppKit-native (no Chromium),
file-based (no library DB or vault), MIT.

> **Status:** `v0.8.0-alpha` — first public release. Built on
> `NSTextView`, Swift 6 strict concurrency throughout, ad-hoc signed.

## Where it sits

| | Native AppKit | Inline WYSIWYG | File-based |
|---|---|---|---|
| **PicaMD** | ✓ | ✓ | ✓ |
| Typora | ✗ (Electron) | ✓ | ✓ |
| Obsidian | ✗ (Electron) | ✓ (Live Preview) | ~ (vault DB on top) |
| iA Writer | ✓ | ✗ (syntax highlighting only) | ✓ |
| MarkEdit | ✓ | ✗ (no live preview) | ✓ |
| Bear | ✓ | partial (proprietary "Polar Bear") | ✗ (vault DB) |

The combination — AppKit + inline-WYSIWYG + plain files — is empty
on the market. That's the niche. Everything else (AI hook, MCP
server, themes, export) is built on top.

## Editor

- **Cursor-aware syntax concealment**. The line your cursor sits on
  shows raw markdown; every other line renders. Move the cursor
  away, the markers disappear. Move it back, they come back. Same
  trick Obsidian's Live Preview uses, done natively in AppKit
  instead of CodeMirror-in-WebView. Works for `**`, `*`, `~~`,
  `==`, `` ` ``, `#`, `>`, `[]()`, math `$`, code-fence backticks,
  `<details>`.
- Block overlays for **tables**, **images**, **KaTeX math**
  (offline-bundled), **Mermaid diagrams** (downloaded on first
  use). A lazy webview pool caps `WKWebView` instances at 12 so
  RAM stays bounded on long docs.
- **Interactive task-list checkboxes** — `- [ ]` and `- [x]`
  render as native AppKit checkboxes drawn in your accent
  colour. Click to toggle (Undo-tracked). Checked items strike
  through automatically. Cursor on the line restores the raw
  `[ ]` / `[x]` markup so you can edit it directly.
- Outline sidebar with cursor auto-tracking. Frontmatter bar with
  title + tag chips. Footnote tooltips on `[^id]` hover.
- **Tabs** (`⌘T`), **Focus mode** (`⌃⌘F`), **Typewriter mode**
  (`⌃⌘Y`), **Command palette** (`⌘⇧P`).

## Themes

Three built-in presets — Stock+, Editorial, Tahoe. Four palettes
— White, Off-White, Dark Grey, OLED. Seven accents. Body /
heading font, heading scale, code-block style — all toggleable
in `⌘,` Settings. The chosen palette is independent of macOS
Light/Dark Mode (use the White palette while macOS is in Dark
Mode, if you want).

## AI assistance (opt-in)

Off by default. When enabled, you get **`⌃⌘1`–`⌃⌘9`** bound to
nine starter presets (clean Markdown, summarize, rewrite-natural,
extend, fix grammar, translate DE↔EN, formalise, casualise,
custom). **`⌃Space`** opens a fuzzy picker over every preset.

Each preset is a name + system prompt + user prompt template +
insertion mode (replace selection / append below / blockquote /
HTML comment / popover). All editable, all reorderable, all
re-bindable. Add your own.

Talks to:
- **Anthropic** (Claude API)
- **OpenAI** (or any OpenAI-compatible URL — Groq, Together,
  vLLM, …)
- **Local** (LM Studio, Ollama, llama.cpp `--api`)

API keys go in the macOS Keychain. Endpoint selection is
per-preset; the default is whatever's set in Settings → AI →
Providers.

## Claude Code MCP integration

PicaMD ships with `picamd-mcp`, a stdio-MCP sidecar embedded in
the app bundle. It lets Claude Code (or any MCP client) read and
edit currently-open documents through eight tools.

```json
// ~/.config/claude-code/mcp.json
{
  "mcpServers": {
    "picamd": {
      "command": "/Applications/PicaMD.app/Contents/Resources/picamd-mcp"
    }
  }
}
```

| Tool | What it returns |
|---|---|
| `workspace.openDocuments` | path / title / line-count for every doc currently in a PicaMD window |
| `workspace.search` | substring matches across all open docs |
| `document.metadata` | title, frontmatter tags, word/line counts |
| `document.outline` | heading hierarchy with line numbers |
| `document.readLines` | 1-indexed line range |
| `document.readSection` | body under a heading by text match |
| `document.replaceLines` | atomic line-range write (FileWatcher picks the change up live) |
| `document.appendText` | append with paragraph break |

The point: Claude can call `outline()` + `readSection("Methods")`
instead of `Read(file)` for the whole document — useful for long
docs in repeated edit loops. Whether that's worth using over
Claude's native `Read` with `offset`/`limit` depends on your
workflow; for short docs the overhead isn't worth it.

It's also worth knowing this isn't unique. Obsidian has
[obsidian-claude-code-mcp](https://github.com/iansinnott/obsidian-claude-code-mcp)
and others; Claude Desktop has a built-in filesystem connector.
PicaMD's MCP is convenient if you live in PicaMD anyway, but it
isn't a moat.

## macOS integration

- **Quick-Look** extension for `.md` files (Spacebar in Finder).
  Built and registered, but the render is currently blocked —
  macOS 14+ requires a Developer ID Application certificate for
  the QL host to load third-party extensions, and the alpha is
  ad-hoc-signed. Resolves with v1.0 notarization.
- **Spotlight** — every opened/saved doc gets indexed via
  CoreSpotlight with frontmatter title and tags.
- **Services menu** — "Open Selection in PicaMD" lifts text from
  any other app into a fresh PicaMD doc.
- **Export** — `File → Export As…`. HTML in-process (KaTeX +
  Mermaid auto-render via CDN, footnotes, tables, frontmatter).
  PDF / DOCX / EPUB via user-installed `pandoc`.

## Install

### Pre-built

1. Download `PicaMD-<version>.zip` from the
   [latest release](https://github.com/michiwickman/picamd/releases).
2. Unzip, drag `PicaMD.app` into `/Applications/`.
3. **First launch**: right-click `PicaMD.app` → **Open** →
   confirm in the dialog. The alpha is ad-hoc-signed because the
   project doesn't have an Apple Developer Program subscription
   yet, so macOS will refuse to open it via double-click. Once
   confirmed, subsequent launches work normally.

   One-line alternative:
   ```bash
   xattr -dr com.apple.quarantine /Applications/PicaMD.app
   ```

### From source

Requires Xcode 16+ (Swift 6) and `xcodegen`.

```bash
brew install xcodegen
git clone https://github.com/michiwickman/picamd.git
cd picamd
./release.sh           # → dist/PicaMD-<version>.zip
INSTALL=1 ./build.sh   # or, local install
```

## Limitations & honest disclosure

- **Quick-Look render** — extension is wired but blocked on a
  paid Apple Developer ID. Auto-resolves with v1.0 notarization.
- **First-launch Gatekeeper warning** — same root cause. Each
  Sparkle auto-update will re-trigger the warning until v1.0
  notarized. If that sounds annoying, you might prefer manual
  GitHub-Releases checks for now and disable auto-checks in
  Settings → Updates.
- **MCP isn't unique** — Obsidian has multiple MCP plugins, and
  Claude Desktop has a filesystem connector. PicaMD's MCP is
  convenient *if* you're already living in PicaMD, not a reason
  to switch.
- **Audience overlap is small** — native-macOS-user × Markdown
  writer × inline-WYSIWYG-not-vault × Claude-Code-user. If you
  fit all four, this is for you. If three of four, you have other
  options.

## Privacy & data flow

PicaMD stores nothing on a remote server.

- **Documents** stay where you save them — no cloud sync, no
  telemetry, no analytics.
- **AI features** are off by default. When enabled, PicaMD sends
  the selection (or paragraph) to whichever endpoint *you*
  configure. PicaMD never routes through a PicaMD-owned proxy.
- **API keys** live in the macOS Keychain (per-app isolated, no
  iCloud sync).
- **MCP server** (`picamd-mcp`) only exposes documents currently
  open in PicaMD windows; data flows over stdio to Claude Code on
  the local machine.
- **Auto-update** checks hit
  `raw.githubusercontent.com/michiwickman/picamd/main/appcast.xml`
  for a new version manifest. No telemetry pings.

## Repository layout

```
PicaMD/
├── project.yml                       # xcodegen spec
├── build.sh                          # local build + install
├── release.sh                        # build → ad-hoc-sign → zip
├── appcast.xml                       # Sparkle update manifest
├── CHANGELOG.md
├── CONTRIBUTING.md
├── LICENSE                           # MIT
├── README.md
├── samples/                          # Welcome.md + test-document.md
├── PicaMD/                           # main app source (~30 files)
├── PicaMDQuickLook/                  # QL extension target
├── PicaMDMCP/                        # MCP sidecar target
├── PicaMDTests/                      # 162 unit tests
└── PicaMDMCPTests/                   # 22 unit tests for the sidecar
```

## Bundle stats

- **9.8 MB** Release bundle (incl. embedded Sparkle.framework).
- 197 unit tests. CI runs both bundles on `macos-15` /
  Xcode 16 with Swift 6 strict concurrency.
- Linked: only Apple system frameworks + `Sparkle.framework`
  for auto-update. No other third-party dynamic libraries.

## Dependencies

| Library | Version | Where |
|---|---|---|
| [apple/swift-markdown](https://github.com/apple/swift-markdown) | 0.7+ | HTML export, Quick-Look render |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | 2.6+ | auto-update |
| [KaTeX](https://katex.org/) | 0.16.45 | math rendering — bundled in `Resources/katex/` |
| [Mermaid](https://mermaid.js.org/) | 11.14.0 | diagrams — downloaded on first use into Caches |

## License

MIT. See [LICENSE](LICENSE).

## Status & roadmap

This is `v0.8.0-alpha`. The alpha goal is to find out whether the
AppKit + inline-WYSIWYG positioning has takers. If it does, the
plausible v1.0 work is:

1. Apple Developer ID — unblocks Quick-Look render, removes
   first-launch Gatekeeper warning, makes Sparkle auto-updates
   smooth.
2. Streaming AI responses (incremental insertion).
3. iA-Writer-style "show all markup at all times" toggle (Phase 5
   leftover).

If you found it via HN/Reddit/etc., please [file issues](https://github.com/michiwickman/picamd/issues)
or jump into [Discussions](https://github.com/michiwickman/picamd/discussions)
— that feedback is what decides whether v1.0 happens.
