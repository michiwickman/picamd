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
- **Outline** sidebar, frontmatter title and tags, footnote previews.
- **Find & Replace** (`⌘F`), with an option to ignore formatting so
  `bold word` also finds `**bold** word`.
- **Focus** and **typewriter** modes, tabs, and a command palette
  (`⇧⌘P`).
- **Themes.** A few presets, four palettes, seven accent colours. They
  work independently of the system's light/dark setting.
- **Export** to HTML. PDF, DOCX and EPUB also work if
  [pandoc](https://pandoc.org) is installed.
- **Quick Look, Spotlight and Services.** Preview in Finder, find your
  notes in Spotlight, and use *Open Selection in PicaMD* from other apps.

## Optional extras

These are off until you turn them on, and stay out of the way otherwise.

- **AI presets.** Send a selection to Anthropic, OpenAI or a local
  OpenAI-compatible server (LM Studio, Ollama, llama.cpp) with
  `⌃⌘1`–`⌃⌘9`, or pick a preset with `⌃Space`. Presets are editable.
  API keys are kept in the Keychain.
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

1. Download the latest `PicaMD-<version>.zip` from
   [Releases](https://github.com/michiwickman/picamd/releases) and move
   `PicaMD.app` to `/Applications`.
2. The first time, right-click the app and choose **Open**. PicaMD isn't
   notarized yet, so macOS asks once. Or run:
   ```bash
   xattr -dr com.apple.quarantine /Applications/PicaMD.app
   ```

Updates arrive through Sparkle.

## Build from source

You need Xcode 16 or later and [XcodeGen](https://github.com/yonaskolb/XcodeGen).

```bash
brew install xcodegen
git clone https://github.com/michiwickman/picamd.git
cd picamd
./build.sh              # build and install to /Applications
INSTALL=0 ./build.sh    # build only
./release.sh            # → dist/PicaMD-<version>.zip
```

## Privacy

PicaMD has no telemetry and no server of its own. Documents stay where
you save them. The update check fetches `appcast.xml` from this
repository. AI requests go only to the endpoint you configure, and only
when you trigger them. The MCP server talks to local clients over stdio,
and can see only the documents open in PicaMD.

## Known limitations

- The app is ad-hoc signed, so the first launch needs the right-click
  **Open** step above, and so does each update, until the app is
  notarized.
- The Quick Look extension is included, but macOS only loads it for apps
  signed with a Developer ID.

## Acknowledgements

[swift-markdown](https://github.com/apple/swift-markdown),
[Sparkle](https://sparkle-project.org), [KaTeX](https://katex.org)
(bundled) and [Mermaid](https://mermaid.js.org) (downloaded the first
time it's needed).

## License

MIT. See [LICENSE](LICENSE).
