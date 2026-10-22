# PicaMD

A small, native Markdown editor and viewer for macOS.

Open a `.md` file and it reads like a finished document. Put the cursor
on a line and that line turns back into Markdown; move on and it renders
again. Your files stay plain text wherever you keep them. No library, no
vault, no account. Built with AppKit, not a web view.

## Features

- **Live preview in place.** `**`, `_`, `` ` ``, `#`, `>`, links and
  the like hide when the cursor isn't on them.
- **Rendered blocks.** Tables, images, math (KaTeX, bundled) and
  Mermaid diagrams render inline.
- **Task lists** with clickable checkboxes.
- **Format menu** for headings, bold, italic, strikethrough, code,
  links, checklists, quotes and tables, each a toggle on the selection
  or the word at the caret. Shortcuts can be changed in
  `keybindings.json`.
- **Outline** sidebar, an **inspector** with editable front matter
  (title, tags, date) and document statistics (`⌥⌘I`), a quiet word
  count, footnote previews. Front matter collapses to one grey line
  until the caret enters it.
- **Find & Replace** (`⌘F`) in a bar under the toolbar, with Wrap
  Around, Starts With / Whole Word, regular expressions and an option
  to ignore formatting so `bold word` also finds `**bold** word`.
- **Focus**, **typewriter** and **reflow** modes, tabs, and a command
  palette (`⇧⌘P`) for headings, the View and Format commands, Find,
  Export, Settings and, while AI is on, the AI presets.
- **Themes.** Three presets, four palettes plus your own text and
  background colour, seven accent colours, any installed font, and a
  readable line width. The editor's colours work independently of the
  system's light/dark setting.
- **Export** to HTML. PDF, DOCX and EPUB also work if
  [pandoc](https://pandoc.org) is installed.
- **Spotlight and Services.** Find your notes in Spotlight, and use
  *Open Selection in PicaMD* from other apps. A Quick Look extension is
  included but loads only once the app is signed with a Developer ID
  (see Known limitations).

## Optional extras

These are off until you turn them on, and stay out of the way otherwise.

- **AI presets.** Send a selection to Anthropic, OpenAI, Apple
  Intelligence or your own OpenAI-compatible server (Ollama, LM Studio,
  vLLM, on this Mac or another one) with `⌃⌘1`–`⌃⌘9`, or pick a preset
  with `⌃Space`. Presets are editable. API keys are kept in the
  Keychain. Apple Intelligence runs on the Mac without a key; its
  context window is small, so a long selection is refused before
  anything runs, with a pointer to Anthropic or OpenAI.
- **MCP server.** The app bundle includes `picamd-mcp`, which lets
  Claude Code or any other MCP client read and edit the documents you
  have open:

  ```json
  {
    "mcpServers": {
      "picamd": {
        "command": "/Applications/PicaMD.app/Contents/Resources/picamd-mcp"
      }
    }
  }
  ```

## Install

PicaMD requires macOS 27 or later on a Mac with Apple silicon. The
Apple Intelligence provider also needs Apple Intelligence turned on in
System Settings; the other providers don't.

1. Download the latest `PicaMD-<version>.zip` from
   [Releases](https://github.com/michiwickman/picamd/releases) and move
   `PicaMD.app` to `/Applications`.
2. PicaMD isn't notarized yet, so macOS blocks the first launch. Open
   System Settings ▸ Privacy & Security, click **Open Anyway** next to
   the message about PicaMD and confirm. Or remove the quarantine flag
   before the first launch:
   ```bash
   xattr -dr com.apple.quarantine /Applications/PicaMD.app
   ```

Updates arrive through Sparkle.

## Build from source

You need Xcode 27 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/michiwickman/picamd.git
cd picamd
./build.sh              # build and install to /Applications
INSTALL=0 ./build.sh    # build only
./release.sh            # → dist/PicaMD-<version>.zip (writes the build number into project.yml)
```

## Privacy

PicaMD has no telemetry and no server of its own. Documents stay where
you save them. The update check fetches `appcast.xml` from this
repository. The first Mermaid diagram downloads Mermaid from
cdn.jsdelivr.net, and exported HTML files load KaTeX and Mermaid from
the same CDN when opened. AI requests go only to the provider you
choose, and only when you trigger them. Apple Intelligence runs on the
Mac; Anthropic, OpenAI and custom providers receive the selected text
over the network. The MCP server talks to local clients over stdio,
and can see only the documents open in PicaMD.

## Known limitations

- The app is ad-hoc signed, so the first launch needs the **Open Anyway**
  step above until the app is notarized.
- The Quick Look extension is included, but macOS only loads it for apps
  signed with a Developer ID.

## Acknowledgements

[swift-markdown](https://github.com/apple/swift-markdown),
[Sparkle](https://sparkle-project.org), [KaTeX](https://katex.org)
(bundled, MIT, see
[PicaMD/Resources/katex/LICENSE](PicaMD/Resources/katex/LICENSE))
and [Mermaid](https://mermaid.js.org) (downloaded the first time it's
needed).

## License

MIT. See [LICENSE](LICENSE).
