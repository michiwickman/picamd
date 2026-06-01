import Foundation

/// Read-side of the active-documents handshake. The main PicaMD app
/// writes `~/Library/Application Support/PicaMD/active-documents.json`
/// every time a window opens / closes / saves-as; this module reads
/// that file on demand whenever an MCP tool needs to know what's
/// open.
///
/// Each call re-reads the file (no caching) so the sidecar always
/// sees the freshest state — Claude opening a fourth tool call
/// after the user opens a new document picks up the new doc
/// immediately. Reads are cheap (<100 µs).
enum DocumentRegistry {

    struct ActiveEntry: Decodable {
        let path: String
        let openedAt: Date
    }

    /// Test-only override for the registry file location, so unit tests
    /// can stage a controlled set of "open" documents without touching
    /// the real `~/Library/Application Support` file. Production code
    /// never sets this; tests set it serially on the main thread, so the
    /// `nonisolated(unsafe)` opt-out of Swift 6's global-state check is
    /// sound here.
    nonisolated(unsafe) static var registryFileURLOverride: URL?

    static var registryFileURL: URL {
        if let override = registryFileURLOverride { return override }
        let base = FileManager.default.urls(for: .applicationSupportDirectory,
                                              in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("PicaMD/active-documents.json")
    }

    static func activeDocuments() -> [ActiveEntry] {
        guard let data = try? Data(contentsOf: registryFileURL) else {
            return []
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode([ActiveEntry].self, from: data)) ?? []
    }

    // MARK: - Doc stats helpers

    struct DocStats {
        var title: String        // frontmatter title or filename without ext
        var tags: [String]       // frontmatter tags
        var lineCount: Int
        var wordCount: Int
    }

    /// Read a document and return basic stats. Used by `metadata` and
    /// `openDocuments` tool implementations. Returns `nil` if the file
    /// is unreadable; the caller decides what fallback to use.
    static func stats(at path: String) -> DocStats {
        guard let source = try? String(contentsOfFile: path, encoding: .utf8) else {
            // File deleted out from under us — synthesize a minimal
            // entry so `openDocuments` doesn't suddenly become an
            // error response.
            return DocStats(
                title: (path as NSString).lastPathComponent
                    .replacingOccurrences(of: ".md", with: ""),
                tags: [],
                lineCount: 0,
                wordCount: 0
            )
        }
        let (title, tags) = parseFrontmatter(source: source)
        let resolvedTitle = title
            ?? extractFirstHeading(source: source)
            ?? (path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: "")
        let lineCount = source.components(separatedBy: "\n").count
        let wordCount = source
            .split(whereSeparator: { $0.isWhitespace })
            .count
        return DocStats(
            title: resolvedTitle,
            tags: tags,
            lineCount: lineCount,
            wordCount: wordCount
        )
    }

    // MARK: - Frontmatter parsing (lightweight, sidecar-local)

    /// Parse the top-of-file `---` YAML frontmatter for `title:` and
    /// `tags:`. We don't pull in a full YAML parser — a one-pass
    /// line scanner covers >95 % of frontmatter shapes users actually
    /// write (single-line title, comma-separated or flow-style tags).
    private static func parseFrontmatter(source: String) -> (title: String?, tags: [String]) {
        let lines = source.components(separatedBy: "\n")
        guard lines.first?.trimmingCharacters(in: .whitespaces) == "---" else {
            return (nil, [])
        }
        var title: String?
        var tags: [String] = []
        for i in 1..<lines.count {
            let line = lines[i]
            if line.trimmingCharacters(in: .whitespaces) == "---" { break }
            if let kv = parseFrontmatterLine(line) {
                if kv.key == "title" {
                    title = kv.value
                } else if kv.key == "tags" {
                    tags = parseTagsValue(kv.value)
                }
            }
        }
        return (title, tags)
    }

    private static func parseFrontmatterLine(_ line: String) -> (key: String, value: String)? {
        guard let colonIdx = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colonIdx].trimmingCharacters(in: .whitespaces)
        let value = line[line.index(after: colonIdx)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        // Strip surrounding quotes if present.
        let unquoted = value
            .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        return (key, unquoted)
    }

    private static func parseTagsValue(_ raw: String) -> [String] {
        // Flow style: `[a, b, c]`
        if raw.hasPrefix("[") && raw.hasSuffix("]") {
            let inner = raw.dropFirst().dropLast()
            return inner
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
                .filter { !$0.isEmpty }
        }
        // Plain comma-separated: `a, b, c`
        return raw
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " '\"")) }
            .filter { !$0.isEmpty }
    }

    private static func extractFirstHeading(source: String) -> String? {
        for line in source.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("# ") {
                return String(trimmed.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            }
        }
        return nil
    }
}
