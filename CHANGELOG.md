# Changelog

All notable changes to PicaMD are documented here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning
is [SemVer](https://semver.org/).

## [Unreleased]

## [0.10.0] — 2026-10-21

The first release since 0.8.0-alpha. It also contains every change listed
under
[0.9.0](https://github.com/michiwickman/picamd/blob/main/CHANGELOG.md#090--never-released),
which was never released on its own. Requires macOS 27 on Apple silicon.

### Added

- **Apple Intelligence as an AI provider.** Presets can run on the
  on-device model: no key, nothing leaves the Mac. Settings ▸ AI shows
  whether it's ready, the model (e.g. "AFM 3 Core Advanced") and its
  context size, and offers System Settings when it's turned off. The
  context is small (8,192 tokens on recent Macs), so a selection that
  doesn't fit is refused before anything runs, with a pointer to
  Anthropic or OpenAI. New installs default to Apple Intelligence when
  it's available, else to Anthropic.
- **Custom providers.** Add any number of OpenAI-compatible servers
  (Ollama, LM Studio, vLLM, on this Mac or another one) in Settings ▸ AI
  with a name, base URL, model and an optional API key (kept in the
  Keychain), and choose one as the default provider.
- **Settings, redesigned:** four panes, General, Appearance, Editor and
  AI. Every earlier option is still there; your saved look stays as it
  was.
  - **Appearance** (Automatic / Light / Dark) for the window chrome. The
    editor page keeps its own background colour.
  - **Custom colours:** a fifth background swatch with your own text and
    background colour; code blocks, rules and muted text are derived
    from the pair.
  - **Font:** SF Pro, SF Mono, New York or any installed family (Other…
    opens the font panel).
  - **Line width:** Readable (about 66 characters of the body font),
    Wide (100) or Full. New installs use Readable, existing settings
    keep Full.
  - **Card layout** is its own switch (Settings ▸ Editor). It used to
    come only with the Tahoe preset, which still turns it on.
  - General: show the welcome window on launch, check for updates
    automatically, reveal `keybindings.json`.

- **macOS 27 window.** The outline runs edge to edge down the left side
  with the system's sidebar button (View ▸ Show Outline, ⌃⌘S). One
  toolbar shows the document name, Share and the inspector button.
  Share sends the Markdown file. An untitled document, or one with
  unsaved edits, is shared as a temporary `.md` of the current text.
- **Inspector** (View ▸ Show Inspector, ⌥⌘I, closed when a window
  opens): the front matter's title, tags and date; words, characters,
  lines, reading time and headings; where the file lives, when it was
  modified and its format.
- **Editable front matter fields.** Title, Tags (chips: × on hover or
  right-click to remove, "Add…" to add) and Date write back into the
  YAML when you press Return or leave the field, as one undo step
  (Edit ▸ Undo Edit Title). Only the edited key's line changes: other
  keys, comments, order, quoting and list style stay as they were, CRLF
  files keep CRLF. A document without front matter gets a block at the
  top on the first entry; clearing a field removes its key. The date
  shows as "October 3, 2026" and as written while you edit it.
- **Front matter collapses to one grey line** at the top of the editor
  ("October 3, 2026 · travel, portugal"; the title is added when it
  differs from the first heading). Put the caret into it (arrow up,
  click) to see and edit the raw YAML; it collapses again when the
  caret leaves. The file is not changed. A document opens with the
  caret below the front matter; Backspace there opens the block
  instead of deleting its hidden last line break.
- **Word count** in the editor's bottom-right corner ("412 words"),
  replacing the status bar. It counts the words you read: no Markdown
  markers, front matter, code or math blocks, list bullets and numbers,
  footnote labels or table pipes.
- **File ▸ New Tab (⌘T)** opens a new document as a tab of the front
  window. ⌘N follows System Settings ▸ Desktop & Dock ▸ Prefer tabs.
- **Find options menu** behind the magnifier in the find field: Ignore
  Case, Wrap Around, Contains / Starts With / Whole Word, Regular
  Expression, Ignore Markdown Formatting. **Wrap Around** off stops at
  the first and last match with a beep; **Starts With** finds matches
  at the start of a word. The choice is remembered and applies to
  every window.
- **⌘G / ⇧⌘G with the find bar closed** search again for the last
  query and select the match, as in other Mac apps. ⌘E also puts the
  selection on the system find pasteboard, and an empty find bar starts
  with the string another app put there.
- A space in the query also matches a line break inside a paragraph,
  so "tram out" finds a hard-wrapped `tram⏎out` (what Reflow shows as
  one line). A blank line still ends the match.
- **Format menu** between Edit and View: Heading 1–3 (⌘1–⌘3), Body
  (⌘0), Bold (⌘B), Italic (⌘I), Strikethrough, Inline Code, Link… (⌘K),
  Checklist, Quote, Table, Move Line Up/Down (⌥⌘↑/↓), Duplicate Line
  (⇧⌘D). Each is one undo step named after it.
  - Bold, Italic, Strikethrough and Inline Code work on the selection or
    the word at the caret and take the markers off again when the text
    already has them (also when they sit just outside the selection, or
    the caret is anywhere in the styled span). A selection over several
    styled spans takes each span's markers off. Over several lines each
    line is styled on its own, after its bullet, checkbox, `>` or `#`.
  - Link… asks for the address, prefilled with a URL on the clipboard;
    inside a link it changes the address or removes the link.
  - Checklist turns lines (and `-`/`1.` list items) into `- [ ]` tasks
    and back; Quote adds or removes `> `; Table inserts a three-column
    table after the selection and selects its first header.
  - New `keybindings.json` names: `bold`, `italic`, `strikethrough`,
    `inlineCode`, `link`, `checklist`, `quote`, `table`. A rebinding
    also moves the shortcut shown in the menu. Heading 4–6 (⌘4–⌘6) and
    Select Line (⌘L) stay key bindings and are in the command palette.
- **View menu:** Show Outline (⌃⌘S), Show Inspector (⌥⌘I) and Show Word
  Count with checkmarks; Focus Mode (⌃⌘F), Typewriter Mode (⌃⌘Y),
  Reflow Mode (⌃⌘R); Command Palette… (⇧⌘P).

### Changed

- **Requires macOS 27 or later** (0.8.0-alpha ran on macOS 14). Macs on
  macOS 14 to 26 stay on 0.8.0-alpha; the update is not offered to them.
- **The starter AI presets have English names** (Clean Up Markdown,
  Summarize, Rewrite Naturally …) on new installs and after Reset.
  Presets you already have keep their names.
- **New app icon:** three lines of paper, the middle one raw Markdown
  with a blue `#` and the caret.
- Quick Look previews Markdown files only; plain text files keep the
  system's own preview. It reads the same encodings PicaMD opens
  (UTF-16, Windows 1252, ISO Latin-1), not only UTF-8.
- The outline uses the system sidebar colours and highlights the
  current heading in your accent colour. The bar of front matter above
  the editor is gone; its fields are in the inspector.
- Windows open at 1100 × 750 and can't get narrower than 820 pt, so
  outline, editor and inspector always fit.
- **Default models:** Anthropic `claude-sonnet-5-5` (was
  `claude-sonnet-4-6`), OpenAI `gpt-6-luna` (was `gpt-4o-mini`). Saved
  settings that still had an old default move along; a model you chose
  yourself stays.
- New installs start with SF Pro as the body font (was SF Mono).
- "Show status bar" is now "Show word count" (Settings ▸ Editor); the
  stored choice carries over.
- AI: an Anthropic refusal shows the reason the API gives. Settings ▸ AI
  is one grouped form with providers, custom providers and presets.
- **Find bar, redesigned:** docked under the toolbar across the editor
  column and pushing the text down, instead of a card floating over it.
  "2 of 3" sits inside the search field, ‹ › and Done beside it;
  Replace, Replace and All below in Find and Replace mode. Shift-Return
  goes to the previous match. Replace and All are disabled, with a
  tooltip saying why, while Ignore Markdown Formatting is on.
- Find matches are system yellow instead of the accent colour; the
  current match is solid yellow with dark text and a thin outline.
- **Command palette, redesigned:** a panel floating over the window
  instead of a sheet. It lists only what matches what you type, under
  "Headings" ("Heading 2 · line 4") and "Commands" with their shortcuts:
  every View and Format command, Find, Export, Settings (also straight to
  one pane) and, while AI is on, the AI presets. Arrow keys move,
  Return runs, Esc or a click outside closes it, ⇧⌘P again too. The
  selection is filled with your accent colour.
- **Welcome window, redesigned** (800 × 500): app icon, name and version
  on the left with New Document and Open… cards and the "Show this window
  when PicaMD opens" checkbox (the same setting as Settings ▸ General);
  recent documents on the right with their folder ("Documents ▸ Travel",
  "iCloud Drive", "OneDrive"), the first one selected in
  your accent colour. Arrow keys move, Return opens, a click opens.
  Right-click a recent for Show in Finder, Remove from Recents and Clear
  Recents. Follows light and dark mode.
- **Launch:** with "Show this window when PicaMD opens" off, a plain
  launch opens a new untitled document. A Dock click with no window open
  always shows the welcome window.
- File ▸ Open Recent adds the folder when two recents share a name
  ("README.md — PicaMD").
- No icons in the menus: the ones AppKit still adds (Find, AutoFill,
  Emoji & Symbols, Share, the window list) are hidden.

### Removed

- The "Edit Mode" menu. Its items are in the View menu.
- The built-in "Local (LM Studio / Ollama)" provider. One that was in use
  (selected, used by a preset, given a key or a different address)
  becomes a custom provider named "Local"; an untouched one is dropped.

### Fixed

- No empty untitled window flashes before the welcome window at launch.
- Files moved to the Trash no longer appear as recent documents, and
  deleted ones leave the list instead of taking up one of its 12 places.
  A file on a disk that isn't connected, or in a folder PicaMD hasn't been
  given access to, stays in the list and comes back when it can be read.
- Opening a recent document that can't be opened shows the error; from
  File ▸ Open Recent it used to do nothing.
- The welcome window's Open… accepts plain text files like File ▸ Open.
- macOS no longer quits PicaMD in the background while no window is
  open (automatic termination is off).
- **Undo takes back a typed word in one step** ("Undo Typing"). Every
  keystroke used to leave an extra undo step of SwiftUI's own next to
  the editor's, so ⌘Z went back one character at a time and each step
  held a copy of the document.
- **Files in other encodings open.** UTF-8 with or without a byte order
  mark, UTF-16 with one, and older 8-bit files as Western (Windows 1252)
  or ISO Latin-1. Saving writes the encoding and the byte order mark
  back; a UTF-8 BOM used to be dropped. If the text gains characters the
  file's encoding can't store, PicaMD saves it as UTF-8 and says so once.
  UTF-8 with a few damaged bytes, and a file whose byte order mark
  doesn't match its bytes, are still refused instead of opening as
  garbled 8-bit text. Edits through the MCP server keep the encoding,
  the byte order mark and CRLF line breaks too.
- **Another program changes an open file:** without unsaved changes the
  window reloads it silently, as TextEdit does. With unsaved changes it
  asks, and Return keeps your version (it used to reload and discard
  them). Reverting clears the undo history, and saving after keeping
  your version doesn't ask a second time.
- Move Line, Duplicate Line and the heading commands keep Windows (CRLF)
  line breaks; they used to add bare line feeds or join a line with the
  next one. Return in a CRLF file types CRLF. Moving a line down onto a last line without a line break no
  longer glues the two together.
- A checkbox no longer stays drawn over its revealed `[ ]` when the
  caret is at the end of the line above it.
- A table too wide for the text column keeps every word whole and
  scrolls sideways (trackpad swipe or Shift-scroll); it used to break
  words in the middle ("Ausprägun|g"). A fade marks the hidden side.
- `\|` inside a table cell is drawn as `|`, in code spans too
  (`` `M8\|M10` `` shows `M8|M10`).
- Front matter detection: `title: foo---` and a `----` line no longer
  close the block, CRLF files and an empty block (`---` twice) are
  recognised everywhere, and the editor, search, word count and
  inspector use one rule. Escapes in quoted values (`\"`, `''`) are
  resolved, `# comments` after a value are not part of it, and lines
  indented under a key are not read as keys of their own. A note that
  starts with a horizontal rule and has prose before the next `---` is
  not taken for front matter. A `'` or `"` inside a tag (`don't`) no
  longer merges it with the next one, and a blank line inside a `|`
  text keeps the whole text in its key.
- A `# comment` inside the front matter no longer shows up as a heading
  in the outline.
- Serif (Editorial) headings use New York; they fell back to Georgia.
- Picking a preset no longer turns the word count back on.
- Two actions bound to the same combo in `keybindings.json` always run
  the same one; which one won used to change from launch to launch.
- The font size shows half points ("14.5 pt", was "14 pt").
- A preset card is only shown as selected while the look still matches
  it. The body font is not part of that match: it has its own popup, so
  a fresh install (Stock+ with SF Pro) shows Stock+ selected, and a click
  on the selected card no longer changes the font.
- A table that grows from a cell edit or a new row is no longer cut off
  at the bottom until the window is resized.
- After a cell edit the caret stays on its character below the table
  (it could land inside the table, which then fell back to raw pipes),
  and Return or Esc in a cell gives the keyboard back to the editor.
  Tab wraps to the next row also when a row ends in blanks after its
  last `|`.
- Find highlights on the first line of a strip redrawn after scrolling
  are painted.
- Reflow Mode works in CRLF files and in notes that open with a
  horizontal rule, and relayouts only the lines that changed.
- Fenced code: a URL inside a string stays a string, and an apostrophe
  in a `#` comment no longer starts one.
- MCP edits keep a CR in front of a CRLF, and a CRLF at the end of the
  sent text is one line break.
- A file that starts with two UTF-8 byte order marks keeps both.
- Share sends the file itself for an unedited file in UTF-16, Windows
  1252 or with a byte order mark.
- A file launch that takes longer than 1.5 s to open no longer adds an
  Untitled document next to it.
- Recent documents are checked in the background: a stalled network
  volume no longer freezes launch or every activation.
- Custom AI providers on plain http work on any host (`.lan` names,
  Tailscale addresses), not only on private IPs and `.local`.
- Removing the custom provider that is the default switches to Apple
  Intelligence, never to a cloud provider; the same for one that no
  longer loads.
- An empty AI answer changes nothing and is reported.
- The OpenAI entry pointed at another host (Groq and others) and Claude
  3 models are sent an output limit they accept.
- An upgrade that never changed a setting keeps SF Mono at full width.
- The first switch to Custom colours keeps the palette's accent and
  syntax colours.
- Esc in the inspector's Title, Date or Add field gives the keyboard
  back to the editor, and quick successive tag edits all land.
- Smart punctuation no longer scans the document for every letter.
- Accessibility: VoiceOver announces the selection in the command
  palette and the welcome window and the find count, reads one phrase
  per palette row and per tag, names checkboxes after their task and
  table cells by row and column. The palette is modal for VoiceOver and
  keeps Tab inside. A tag's remove button shows when it has keyboard
  focus, checkboxes draw a focus ring, the word count, the invalid-regex
  note and checkbox ticks meet the contrast minimums, and Reduce Motion
  stops the outline and inspector slides.
- **Find & Replace works reliably.** Query, option and ⌘G changes often
  never reached the editor; they now drive it directly. Navigating
  selects the match, ⌘F re-focuses an open bar, the query field gets
  focus on open, Replace All is one real undo step, regex `^`/`$` work
  per line, whole-word handles `#tag`/`C++`/umlauts, and
  ignore-formatting search follows what the editor actually hides
  (`snake_case` is findable again). Edit ▸ Find submenu with the
  standard items plus Jump to Selection (⌘J); bar text in English.
- **Typing:** `don't` no longer becomes `don't'`, a ``` fence is three
  backticks, `---` / `|---|` are no longer turned into dashes. Smart
  punctuation is off by default; both it and auto-pairing are toggles
  in Settings ▸ Editor ▸ Typing.
- ⌘⌥↑/↓ (move line) works, and no shortcut breaks under Caps Lock.
  Show/Hide Outline moved to ⌃⌘S (⌃⌘1 swallowed AI preset 1).
- File ▸ Open… (⌘O) and Open Recent are back.
- Relative images show on open; paths with spaces, titles, `%20`, `~`
  and absolute paths resolve. Dropped/pasted images get link-safe names.
- Long documents: text scrolled into view is restyled (it could stay
  raw Markdown after a theme change or typing a bracket near the top),
  a one-line `$$x$$` no longer swallows the rest of the document, math
  blocks outside the viewport stay rendered, CRLF tables render.
- External changes are detected after the first save, and atomic saves
  by other apps (git, other editors, the MCP sidecar) offer a reload.
- AI: responses land on the text they were made from even if you kept
  typing, one request at a time (Esc cancels), cut-off or refused
  answers never replace text, "Custom Prompt" asks what to do, the
  popover mode shows its text, OpenAI reasoning models work.
- Export: PDF/DOCX/EPUB include relative images and find MacTeX when
  launched from Finder; HTML export keeps math intact and can't be
  used to inject scripts through code-fence languages or links.
- "Open Settings" buttons work, Reset to Default updates
  everything, switching to/from the Tahoe preset keeps caret and undo.
- Auto-update: builds carry a real build number (Sparkle never saw a
  newer version before).

## [0.9.0] — never released

Built in August 2026 but never published. These changes ship for the first
time in 0.10.0. Where the 0.10.0 section above describes the same feature
differently (find highlights, welcome window), 0.10.0 is current.

### Added

- **Reflow Mode** (⌃⌘R, per document, off by default). Markdown written by
  most tools hard-wraps prose at a fixed column with real newline bytes, so a
  paragraph stayed pinned to ~88 characters on a wide window while a table —
  one long source line — spanned the whole width. Reflow typesets a newline
  that merely wraps a paragraph as a space, so paragraphs fill the window like
  tables do. **The file on disk is not modified**, not one byte: the change is
  in typesetting, not in the buffer. Headings, lists, tables, code fences
  (including indented ones), math, frontmatter, blockquote depth changes and
  explicit Markdown hard breaks all keep their line breaks.
- **Edit a table cell without collapsing the table.** Clicking a cell in a
  rendered table opens an in-place editor over that cell; the table stays
  rendered, so you keep your bearings. Tab / Shift-Tab walk the cells (wrapping
  at row ends), ↑/↓ move between rows, Return commits, Esc reverts. Each cell
  edit is one undo step. To edit the whole table as raw Markdown, double-click
  the table chrome or use **Edit as Markdown** in its context menu.

- **Markdown-aware Find & Replace** (`⌘F`). A custom in-editor find bar
  replaces the stock `NSTextView` find bar, which couldn't see through the
  editor's marker concealment. Matches are drawn as translucent,
  accent-tinted highlights painted on top of the glyphs, so they stay
  visible even where they cross concealed `**`/`_`/`` ` `` markup; the
  current match gets a bordered highlight and is scrolled into view.
  - Live "n of m" counter, `⌘G` / `⇧⌘G` to cycle matches, `⌘E` to search
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

- **Rendered tables no longer sit slightly askew over the text.** Three
  separate causes, all of them width-related:
  - The reserved height was measured at one width and the table drawn at
    another (2 pt apart). Usually harmless, but when a cell's text sat on a
    wrap boundary those 2 pt pushed a word onto a new line, growing the row by
    a full line. Measured on real documents: 1 table in 22 was off, by 16 pt.
    Measuring and drawing now derive from a single width that callers cannot
    override.
  - The highlighter and the overlay manager used *different* predicates to
    decide whether the caret was "in" a table. With the caret on the first
    character of the line below one — reached by clicking under it or pressing
    ↓ — the source was revealed while the opaque table stayed drawn on top of
    it. Both now use the same predicate.
  - The reserved height was written only for blocks inside the viewport but
    consumed for every block in the document, so after any width change every
    off-screen table kept a band measured at the old width. Scrolling never
    repaired it; only moving the caret into the table did. A width change now
    forces one document-wide pass.
- **Table columns are sized to their content.** Every column used to get
  `width / columnCount` regardless of what was in it, so a "Nr." column got the
  same space as a column of prose — leaving the trailing column visibly too
  wide while the prose column wrapped needlessly. Columns now take their
  natural width, with the remaining space going to the columns that need it.
- **Tables in CRLF documents rendered as an empty box.** `"\r\n"` is a single
  Swift `Character`, so splitting the block on `"\n"` never fired and the table
  failed to parse.
- The first highlight pass ran before the window had been laid out and reserved
  every table in the document as if the window were 120 pt wide.
- Vertical padding had three independent owners whose constants did not cancel,
  leaving 10 pt of dead space inside every table's border and seating the table
  6 pt above the centre of the space it occupied.
- A table row with more cells than the header row was drawn past the right edge
  with no separator; the column count now follows the widest row.
- An escaped `\|` or a pipe inside a `` `code span` `` no longer manufactures a
  phantom column.

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

[Unreleased]: https://github.com/michiwickman/picamd/compare/v0.10.0...HEAD
[0.10.0]: https://github.com/michiwickman/picamd/compare/v0.8.0-alpha...v0.10.0
[0.8.0-alpha]: https://github.com/michiwickman/picamd/releases/tag/v0.8.0-alpha
