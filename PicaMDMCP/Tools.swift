import Foundation

/// Tool implementations grouped by namespace. Each `static func`
/// returns a `ToolRegistry.Tool` ready to register. The actual
/// per-document work is delegated to `DocumentRegistry` (read-only
/// list of open docs) and direct filesystem reads/writes.
///
/// Why filesystem direct? Because the main app's `FileWatcher`
/// already detects external edits, so any change the MCP sidecar
/// makes propagates back into the editor in <1 s. We don't need a
/// dedicated XPC channel — the file IS the channel.

// MARK: - workspace.* tools

enum WorkspaceTools {

    /// `workspace.openDocuments` — list every doc the user has open
    /// in PicaMD right now, with paths + word counts. The first thing
    /// Claude usually wants when starting a session.
    static func openDocuments() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "workspace.openDocuments",
            description: "List every document currently open in PicaMD. Returns paths, titles, line counts. Use this to discover what the user is working on before reading any specific document.",
            inputSchema: [
                "type": "object",
                "properties": [:],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { _ in
                let entries = DocumentRegistry.activeDocuments()
                let isoFormatter = ISO8601DateFormatter()
                let summaries: [[String: Any]] = entries.map { entry in
                    let stats = DocumentRegistry.stats(at: entry.path)
                    return [
                        "path": entry.path,
                        "title": stats.title,
                        "lines": stats.lineCount,
                        "words": stats.wordCount,
                        "openedAt": isoFormatter.string(from: entry.openedAt),
                    ]
                }
                return ["documents": summaries]
            }
        )
    }

    /// `workspace.search` — substring search across every open doc,
    /// returning matching `{path, line, snippet}` entries. Case-
    /// insensitive by default; max 100 hits to keep token-cost bounded.
    static func search() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "workspace.search",
            description: "Substring search (case-insensitive) across every document currently open in PicaMD. Returns up to 100 matches with file path, line number, and a snippet.",
            inputSchema: [
                "type": "object",
                "required": ["query"],
                "properties": [
                    "query": ["type": "string"],
                ],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { args in
                guard let query = args["query"] as? String, !query.isEmpty else {
                    throw MCPError("workspace.search: missing or empty `query`")
                }
                var results: [[String: Any]] = []
                let lowered = query.lowercased()
                outer: for entry in DocumentRegistry.activeDocuments() {
                    guard let source = try? requireRead(entry.path) else { continue }
                    let lines = source.components(separatedBy: "\n")
                    for (idx, line) in lines.enumerated() {
                        if line.lowercased().contains(lowered) {
                            results.append([
                                "path": entry.path,
                                "line": idx + 1,
                                "snippet": String(line.prefix(200)),
                            ])
                            if results.count >= 100 { break outer }
                        }
                    }
                }
                return ["matches": results, "totalReturned": results.count]
            }
        )
    }
}

// MARK: - document.* tools

enum DocumentTools {

    /// `document.metadata` — title, frontmatter tags, word count.
    /// Cheap (one read), good follow-up after `openDocuments`.
    static func metadata() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.metadata",
            description: "Get title, frontmatter tags, word/line counts for a document by path. Cheap — single file read.",
            inputSchema: [
                "type": "object",
                "required": ["path"],
                "properties": [
                    "path": ["type": "string", "description": "Absolute path to the .md file"],
                ],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { args in
                let path = try requirePath(from: args)
                let stats = DocumentRegistry.stats(at: path)
                return [
                    "path": path,
                    "title": stats.title,
                    "tags": stats.tags,
                    "lines": stats.lineCount,
                    "words": stats.wordCount,
                ]
            }
        )
    }

    /// `document.outline` — heading hierarchy. Use this BEFORE reading
    /// the whole doc; it tells you where each section lives so you
    /// can call `readSection` or `readLines` for just the relevant
    /// part. Critical for token-efficient editing of long docs.
    static func outline() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.outline",
            description: "Return the heading hierarchy of a document. Each entry has `level`, `text`, and `line`. Use this to find which lines a section starts at before calling `readLines` or `replaceLines` — far cheaper than reading the whole document.",
            inputSchema: [
                "type": "object",
                "required": ["path"],
                "properties": [
                    "path": ["type": "string"],
                ],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { args in
                let path = try requirePath(from: args)
                let source = try requireRead(path)
                let headings = parseHeadings(source: source)
                return [
                    "path": path,
                    "headings": headings.map { h in
                        [
                            "level": h.level,
                            "text": h.text,
                            "line": h.line,
                        ] as [String: Any]
                    },
                ]
            }
        )
    }

    /// `document.readLines` — return a 1-indexed inclusive range of
    /// lines. The most token-efficient read tool: instead of pulling
    /// the whole document, Claude can pull just the 30 lines around
    /// the section it wants to edit.
    static func readLines() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.readLines",
            description: "Read a 1-indexed inclusive line range of a document. Use after `outline` so you only fetch the lines for the section you actually need to edit. Far cheaper than reading the full file.",
            inputSchema: [
                "type": "object",
                "required": ["path", "start", "end"],
                "properties": [
                    "path":  ["type": "string"],
                    "start": ["type": "integer", "minimum": 1, "description": "1-indexed start line, inclusive"],
                    "end":   ["type": "integer", "minimum": 1, "description": "1-indexed end line, inclusive"],
                ],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { args in
                let path = try requirePath(from: args)
                guard let start = args["start"] as? Int else { throw MCPError("readLines: `start` required") }
                guard let end   = args["end"] as? Int   else { throw MCPError("readLines: `end` required") }
                guard start >= 1, end >= start else { throw MCPError("readLines: invalid range") }

                let source = try requireRead(path)
                let lines = source.components(separatedBy: "\n")
                let lo = min(start - 1, lines.count)
                let hi = min(end, lines.count)
                guard lo < hi else {
                    return ["path": path, "start": start, "end": end, "text": ""]
                }
                let slice = lines[lo..<hi].joined(separator: "\n")
                return [
                    "path": path,
                    "start": lo + 1,
                    "end": hi,
                    "text": slice,
                ]
            }
        )
    }

    /// `document.readSection` — read a heading subtree by exact text
    /// match. E.g. read everything under `## Methods` until the next
    /// same-or-higher heading. Convenience shortcut for "outline +
    /// readLines for the matching range".
    static func readSection() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.readSection",
            description: "Read everything under a heading by its exact text (case-insensitive). Returns the body up to the next same-or-higher heading. Saves a round-trip vs. calling `outline` then `readLines` manually.",
            inputSchema: [
                "type": "object",
                "required": ["path", "heading"],
                "properties": [
                    "path": ["type": "string"],
                    "heading": ["type": "string", "description": "Heading text to match (case-insensitive, exact match on text after the # markers)"],
                ],
            ],
            annotations: ["readOnlyHint": true],
            invoke: { args in
                let path = try requirePath(from: args)
                guard let target = args["heading"] as? String, !target.isEmpty else {
                    throw MCPError("readSection: `heading` required")
                }
                let source = try requireRead(path)
                let headings = parseHeadings(source: source)
                let needle = target.lowercased().trimmingCharacters(in: .whitespaces)
                guard let matchIdx = headings.firstIndex(where: { $0.text.lowercased() == needle }) else {
                    throw MCPError("readSection: heading not found: \(target)")
                }
                let match = headings[matchIdx]
                let lines = source.components(separatedBy: "\n")
                // Body starts on the line *after* the heading, ends
                // before the next heading at level <= match.level.
                let startLine = match.line  // already 1-indexed
                var endLine = lines.count
                for next in headings.suffix(from: matchIdx + 1) {
                    if next.level <= match.level {
                        endLine = next.line - 1
                        break
                    }
                }
                let lo = startLine     // include the heading itself
                let hi = endLine
                let slice = lines[(lo - 1)..<min(hi, lines.count)].joined(separator: "\n")
                return [
                    "path": path,
                    "heading": match.text,
                    "level": match.level,
                    "startLine": startLine,
                    "endLine": hi,
                    "text": slice,
                ]
            }
        )
    }

    /// `document.replaceLines` — atomic write of a 1-indexed
    /// inclusive line range. Reads the file, splices in the new
    /// content, writes atomically. PicaMD's FileWatcher picks up the
    /// change and the editor re-renders.
    static func replaceLines() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.replaceLines",
            description: "Replace a 1-indexed inclusive line range with new text. Atomic: reads the current file, splices in the new content, writes the whole file back. PicaMD notices the change and offers to reload the open editor. Works on the saved file — unsaved edits in PicaMD are not visible here.",
            inputSchema: [
                "type": "object",
                "required": ["path", "start", "end", "text"],
                "properties": [
                    "path":  ["type": "string"],
                    "start": ["type": "integer", "minimum": 1],
                    "end":   ["type": "integer", "minimum": 1],
                    "text":  ["type": "string", "description": "Replacement content for the whole range. A single trailing newline is optional and ignored."],
                ],
            ],
            annotations: ["destructiveHint": true, "idempotentHint": false],
            invoke: { args in
                let path = try requirePath(from: args)
                guard let start = args["start"] as? Int else { throw MCPError("replaceLines: `start` required") }
                guard let end   = args["end"] as? Int   else { throw MCPError("replaceLines: `end` required") }
                guard let newText = args["text"] as? String else { throw MCPError("replaceLines: `text` required") }
                guard start >= 1, end >= start else { throw MCPError("replaceLines: invalid range") }

                let file = try readFileText(path)
                var lines = file.text.components(separatedBy: "\n")

                // F10: reject start past EOF so callers don't silently insert
                // at end when they meant to replace a line that doesn't exist.
                // start == lines.count+1 is the one allowed edge-case: it
                // yields a zero-line replace (lo == hi) at the very end, which
                // is a valid no-op insert position. Anything beyond that is a
                // programming error; tell the caller to use appendText instead.
                guard start <= lines.count + 1 else {
                    throw MCPError("replaceLines: start=\(start) is past EOF (file has \(lines.count) lines). Use appendText to add content at the end.")
                }
                let lo = start - 1          // 0-indexed; never clamped
                let hi = min(end, lines.count)

                // The replaced lines' own terminators are kept by the
                // join below, so one trailing newline in `text` is the
                // line terminator, not an extra empty line (which would
                // end a table or loosen a list).
                // `text` is split on "\n" like the file: a CRLF from the
                // client would leave a "\r" in every line, and Swift's
                // `hasSuffix("\n")` is false for "\r\n" (one Character),
                // so its terminator became an extra empty line.
                let input = newText.replacingOccurrences(of: "\r\n", with: "\n")
                let body = input.hasSuffix("\n") ? String(input.dropLast()) : input
                let replacementLines = body.components(separatedBy: "\n")
                lines.replaceSubrange(lo..<hi, with: replacementLines)
                let merged = lines.joined(separator: "\n")
                try writeFileText(merged, as: file, to: path)
                return [
                    "path": path,
                    "linesBefore": hi - lo,
                    "linesAfter": replacementLines.count,
                    "newLineCount": lines.count,
                ]
            }
        )
    }

    /// `document.appendText` — append text to the end of the document,
    /// adding a paragraph break before the new content. Convenience
    /// for "Claude wrote a summary, please add it to the end".
    static func appendText() -> ToolRegistry.Tool {
        return ToolRegistry.Tool(
            name: "document.appendText",
            description: "Append text to the end of a document. Inserts a blank line before the new content so it's visually a new paragraph.",
            inputSchema: [
                "type": "object",
                "required": ["path", "text"],
                "properties": [
                    "path": ["type": "string"],
                    "text": ["type": "string"],
                ],
            ],
            annotations: ["destructiveHint": true, "idempotentHint": false],
            invoke: { args in
                let path = try requirePath(from: args)
                guard let raw = args["text"] as? String else { throw MCPError("appendText: `text` required") }
                let text = raw.replacingOccurrences(of: "\r\n", with: "\n")
                let file = try readFileText(path)
                let source = file.text
                // Counted on scalars: `hasSuffix("\n")` is false for a file
                // that ends in "\r\n" (one Character), which a file with
                // mixed breaks keeps, and two blank lines were added.
                let breaks = trailingLineBreaks(source)
                let separator = breaks >= 2 ? "" : (breaks == 1 ? "\n" : "\n\n")
                let updated = source + separator + text + (text.hasSuffix("\n") ? "" : "\n")
                try writeFileText(updated, as: file, to: path)
                return [
                    "path": path,
                    "appendedChars": text.count,
                ]
            }
        )
    }
}

// MARK: - Helpers

private func requirePath(from args: [String: Any]) throws -> String {
    guard let raw = args["path"] as? String, !raw.isEmpty else {
        throw MCPError("missing `path` argument")
    }
    let expanded = (raw as NSString).expandingTildeInPath

    // SCOPE GUARD. The sidecar runs unsandboxed inside the app bundle and
    // inherits the user's full disk access. Without a check here, every
    // document.* tool would read/write ANY path the caller passes — so a
    // prompt-injection block inside an opened .md could tell the LLM to
    // `readLines path='~/.ssh/id_rsa'` and exfiltrate it via `appendText`,
    // or `replaceLines path='~/.zshrc'` to plant a shell backdoor. Restrict
    // to files the user actually has open in PicaMD. Canonicalize BOTH the
    // request and the registry entries the same way (resolve symlinks +
    // standardize) so `../` traversal and /private symlink games can't
    // escape the allow-list.
    let canonical = canonicalize(expanded)
    let openDocs = DocumentRegistry.activeDocuments().map { canonicalize($0.path) }
    guard openDocs.contains(canonical) else {
        throw MCPError("path is not an open PicaMD document: \(raw)")
    }
    return expanded
}

/// Resolve a path to a canonical form for allow-list comparison:
/// expand `~`, resolve symlinks, and standardize away `..`/`.` segments.
private func canonicalize(_ path: String) -> String {
    let expanded = (path as NSString).expandingTildeInPath
    return (expanded as NSString).resolvingSymlinksInPath
}

/// A document's text as the tools see it, and how the file stores it.
///
/// The tools read and wrote UTF-8 only: the Foundation decoder drops a
/// UTF-8 byte order mark and the writer never puts it back, so one MCP
/// edit removed it, and PicaMD then reloaded the file without it. A CRLF
/// file got bare "\n" breaks spliced in. The sidecar now decodes the way
/// the app does (`TextFileEncoding`, shared with the app) and writes the
/// same encoding, mark and line breaks back.
struct FileText {
    /// The text with "\n" line breaks, whatever the file uses.
    var text: String
    let encoding: TextFileEncoding
    /// Every line break in the file is CRLF; they are "\n" in `text`.
    let crlf: Bool
}

/// Decode the file the way PicaMD opens it. Line breaks are "\n" in the
/// result when the file uses CRLF throughout; a file with mixed breaks is
/// left as it is.
func readFileText(_ path: String) throws -> FileText {
    let data: Data
    do {
        data = try Data(contentsOf: URL(fileURLWithPath: path))
    } catch {
        throw MCPError("could not read \(path): \(error.localizedDescription)")
    }
    guard let decoded = TextFileEncoding.decode(data) else {
        throw MCPError("could not read \(path): not in a text encoding PicaMD opens")
    }
    let ns = decoded.text as NSString
    let crlfCount = ns.components(separatedBy: "\r\n").count - 1
    let lfCount = ns.components(separatedBy: "\n").count - 1
    let crlf = crlfCount > 0 && crlfCount == lfCount
    let text = crlf ? decoded.text.replacingOccurrences(of: "\r\n", with: "\n") : decoded.text
    return FileText(text: text, encoding: decoded.encoding, crlf: crlf)
}

/// Line breaks at the end of `text`, a "\r\n" counting as one.
func trailingLineBreaks(_ text: String) -> Int {
    var count = 0
    var scalars = text.unicodeScalars.reversed().makeIterator()
    var pending = scalars.next()
    while let scalar = pending, scalar == "\n" {
        count += 1
        pending = scalars.next()
        if pending == "\r" { pending = scalars.next() }
    }
    return count
}

private func requireRead(_ path: String) throws -> String {
    try readFileText(path).text
}

/// Write `text` back the way `original` came: its encoding, byte order
/// mark and line breaks. A file whose encoding can't hold the new text
/// (a Windows 1252 file and an emoji) is refused rather than converted
/// behind the user's back; PicaMD itself asks before switching to UTF-8.
func writeFileText(_ text: String, as original: FileText, to path: String) throws {
    // Only "\n" is expanded. `text` is the read result with the tool's
    // edit spliced in, and the edit is normalised by the tool. Normalising
    // "\r\n" again here took a CR out of every "\r\r\n" the read had
    // left in place, on lines the edit never touched.
    var body = text
    if original.crlf {
        let ns = body as NSString
        body = ns.replacingOccurrences(of: "\n", with: "\r\n", options: .literal,
                                       range: NSRange(location: 0, length: ns.length))
    }
    let (data, written) = original.encoding.encode(body)
    guard written == original.encoding else {
        throw MCPError("could not write \(path): the file is in \(original.encoding.displayName), which can't store some characters of this edit. Make the edit in PicaMD instead.")
    }
    do {
        try data.write(to: URL(fileURLWithPath: path), options: .atomic)
    } catch {
        throw MCPError("could not write \(path): \(error.localizedDescription)")
    }
}

// MARK: - Heading parsing (lightweight, sidecar-local)

struct HeadingHit: Equatable {
    let level: Int
    let text: String
    let line: Int    // 1-indexed
}

/// Pure-Swift heading parser, mirrors what the main app's
/// `HeadingExtractor` does but without any AppKit dependencies — the
/// sidecar runs as a CLI binary and can't link AppKit cleanly.
func parseHeadings(source: String) -> [HeadingHit] {
    let lines = source.components(separatedBy: "\n")
    var headings: [HeadingHit] = []
    var inCodeFence = false
    for (idx, line) in lines.enumerated() {
        // Toggle on triple-backtick fences so we don't confuse `# heading`
        // inside a Markdown code block for a real heading.
        if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            inCodeFence.toggle()
            continue
        }
        if inCodeFence { continue }

        guard let hash = line.firstIndex(where: { $0 != " " && $0 != "\t" }) else { continue }
        guard line[hash] == "#" else { continue }
        var level = 0
        var i = hash
        while i < line.endIndex, line[i] == "#" {
            level += 1
            i = line.index(after: i)
        }
        guard level >= 1, level <= 6 else { continue }
        guard i < line.endIndex, line[i] == " " || line[i] == "\t" else { continue }
        let text = line[i...].trimmingCharacters(in: .whitespacesAndNewlines)
        headings.append(HeadingHit(level: level, text: text, line: idx + 1))
    }
    return headings
}
