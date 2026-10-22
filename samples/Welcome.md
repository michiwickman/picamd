---
title: Welcome to PicaMD
tags: [welcome, getting-started]
date: 2026-05-07
---

# Welcome to PicaMD 👋

You're looking at a Markdown file rendered **inline as you type**.
Move your cursor onto the next paragraph — the `**` markers around
that bold word disappear. Click back into them and they come back.
That's the live-preview model: the text never gets reformatted into
a different mode, you're always editing the actual Markdown source.

## Try the AI presets

Settings → AI (`⌘,`, then AI) lets you wire up Anthropic
Claude, OpenAI, Apple Intelligence (on-device) or your own
OpenAI-compatible server such as Ollama or LM Studio. Off by default.
Once configured:

- Select a paragraph
- `⌃⌘1` — Clean Up Markdown (cleans typography, em-dashes, etc.)
- `⌃⌘2` — Summarize (3–5 bullet summary as blockquote)
- `⌃⌘3` — Rewrite Naturally (rewrite for flow)
- `⌃⌘4` — Continue Paragraph (continue writing)
- `⌃Space` — fuzzy-search picker over all 9 presets

Every preset is fully editable in Settings → AI → Presets.
Add your own, change the prompts, rebind hotkeys.

## Hand a file to Claude Code via MCP

PicaMD ships an MCP server (`picamd-mcp`) that lets Claude Code
read and edit your open documents *by section*, not by re-reading
the whole file each pass. Add it to Claude Code:

```bash
claude mcp add picamd -- /Applications/PicaMD.app/Contents/Resources/picamd-mcp
```

Other MCP clients take the same command in their `mcpServers`
configuration.

Then in Claude Code:

> "What's the Methods section of the doc I have open in PicaMD?
> Rewrite the second paragraph to be tighter."

Claude calls `workspace.openDocuments`, `document.outline`,
`document.readSection`, and `document.replaceLines` — and your
edit appears live in the editor here, since PicaMD's file-watcher
picks up the change.

## Render anything

Math: $a^2 + b^2 = c^2$ inline, or display:

$$
\sum_{n=1}^{\infty}\frac{1}{n^2} = \frac{\pi^2}{6}
$$

Mermaid:

```mermaid
flowchart LR
  A[You write] --> B[PicaMD shows]
  B --> C{Want AI?}
  C -->|Yes| D[⌃⌘1-9 presets]
  C -->|Or Claude Code| E[picamd-mcp]
  D --> F[Edit applies live]
  E --> F
```

Tables:

| Shortcut | What it does |
|---|---|
| `⌘,` | Settings (themes, AI, presets) |
| `⌘T` | New tab in the front window |
| `⌘⇧P` | Command palette (headings and commands) |
| `⌃⌘F` | Focus mode (dim non-cursor paragraphs) |
| `⌃⌘Y` | Typewriter mode (cursor stays centered) |
| `⌃Space` | AI preset picker |
| `⌃⌘1`–`⌃⌘9` | AI preset by hotkey |

Code blocks with syntax highlighting:

```swift
struct PicaMDApp: App {
    var body: some Scene {
        DocumentGroup(newDocument: MarkdownDocument()) { file in
            ContentView(document: file.$document)
        }
    }
}
```

Footnotes are real too[^1].

[^1]: They render as a numbered superscript inline and a footer
    block at the bottom of HTML exports.

## Export anywhere

`File → Export As` covers:

- **HTML** — one file with the CSS embedded. Math and diagrams load
  KaTeX and Mermaid from a CDN when the file is opened, so they need
  a network connection.
- **PDF / DOCX / EPUB** via `pandoc` (auto-detected if installed).
  `brew install pandoc` if missing.

## Privacy

No telemetry, no analytics, no PicaMD server. The update check
fetches `appcast.xml` from GitHub, and the first Mermaid diagram
downloads Mermaid from a CDN. AI requests go only to the provider you
chose, when you run a preset; Apple Intelligence runs on-device. The
MCP server talks only to local clients. The README covers this in
detail.

## Where to next

- **Settings → Appearance** (presets, palette, fonts, line width) and
  **Settings → Editor** (typing, blocks) to make this comfortable for
  *your* eyes (try Editorial preset for a serif H1 / sans body
  combo).
- **Add an AI preset** for whatever you do most ("Translate to
  English", "Make it pirate-speak", whatever).
- **File a bug** at <https://github.com/michiwickman/picamd/issues>
  if something's off.

Have fun.
