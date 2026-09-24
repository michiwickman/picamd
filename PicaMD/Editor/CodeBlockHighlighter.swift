import AppKit

/// Lightweight regex-based syntax highlighter for fenced code blocks
/// inside the Markdown editor. Covers the dozen most common languages
/// well enough that ` ```swift `, ` ```python ` etc. show coloured
/// keywords / strings / comments without bundling Prism.
///
/// Token attributes are applied directly on the `NSTextStorage` for the
/// code block's character range.
@MainActor
struct CodeBlockHighlighter {

    /// Apply token colours for every fenced code block whose range
    /// intersects `viewportRange` (or for all blocks when nil).
    static func highlight(
        textStorage: NSTextStorage,
        source: String,
        codeBlocks: [NSRange],
        isDark: Bool,
        viewportRange: NSRange?
    ) {
        guard !codeBlocks.isEmpty else { return }
        let palette = TokenPalette(isDark: isDark)
        let nsString = source as NSString
        for block in codeBlocks {
            // Skip blocks fully outside the viewport (incremental pass).
            if let vp = viewportRange, !rangesIntersect(block, vp) {
                continue
            }
            // First line: ```lang   → extract language identifier
            let firstLineRange = nsString.lineRange(for: NSRange(location: block.location, length: 0))
            let firstLine = nsString.substring(with: firstLineRange)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let lang = languageIdentifier(from: firstLine)
            guard let tokenizer = tokenizers[lang] else { continue }

            // Body of the code block: everything between the opening
            // fence line and the closing fence line.
            let bodyStart = NSMaxRange(firstLineRange)
            let bodyLength = (block.location + block.length) - bodyStart
            // Subtract the closing fence line.
            let beforeCloseRange = NSRange(location: block.location, length: block.length - 1)
            let closingLineRange = nsString.lineRange(
                for: NSRange(location: max(beforeCloseRange.location,
                                           NSMaxRange(beforeCloseRange) - 1),
                              length: 0)
            )
            let bodyEnd = closingLineRange.location
            guard bodyEnd > bodyStart else { continue }
            var bodyRange = NSRange(location: bodyStart, length: bodyEnd - bodyStart)
            // Only tokenize the part of a long block that's in the working
            // slice (line-aligned), not all 5,000 lines on every keystroke.
            if let vp = viewportRange {
                bodyRange = NSIntersectionRange(bodyRange, nsString.lineRange(for: vp))
                guard bodyRange.length > 0 else { continue }
            }
            let body = nsString.substring(with: bodyRange)

            // Apply each token type's regex. Comments and strings claim
            // their span: later rules (keywords, types, numbers) must not
            // repaint inside them — `// return if true` stays comment-grey.
            var claimed: [NSRange] = []
            for rule in tokenizer.rules {
                let claims = rule.token == .comment || rule.token == .string
                rule.regex.enumerateMatches(in: body, options: [], range: NSRange(location: 0, length: (body as NSString).length)) { match, _, _ in
                    guard let m = match, m.range.length > 0 else { return }
                    if claimed.contains(where: { NSIntersectionRange($0, m.range).length > 0 }) { return }
                    let absoluteRange = NSRange(location: bodyRange.location + m.range.location,
                                                length: m.range.length)
                    if let color = palette.color(for: rule.token) {
                        textStorage.addAttribute(.foregroundColor, value: color, range: absoluteRange)
                    }
                    if claims { claimed.append(m.range) }
                }
            }
        }
    }

    // MARK: - Token model

    enum Token {
        case keyword
        case type
        case string
        case number
        case comment
        case function
        case symbol
    }

    struct Rule {
        let token: Token
        let regex: NSRegularExpression
    }

    struct Tokenizer {
        let rules: [Rule]
    }

    private struct TokenPalette {
        let keyword: NSColor
        let type: NSColor
        let string: NSColor
        let number: NSColor
        let comment: NSColor
        let function: NSColor
        let symbol: NSColor

        init(isDark: Bool) {
            if isDark {
                keyword  = NSColor(red: 1.00, green: 0.65, blue: 0.40, alpha: 1)   // orange
                type     = NSColor(red: 0.55, green: 0.85, blue: 1.00, alpha: 1)   // cyan
                string   = NSColor(red: 0.65, green: 0.92, blue: 0.65, alpha: 1)   // green
                number   = NSColor(red: 0.95, green: 0.75, blue: 0.55, alpha: 1)   // amber
                comment  = NSColor(white: 0.55, alpha: 1)                          // grey
                function = NSColor(red: 1.00, green: 0.85, blue: 0.50, alpha: 1)   // yellow
                symbol   = NSColor(red: 0.90, green: 0.65, blue: 1.00, alpha: 1)   // purple
            } else {
                keyword  = NSColor(red: 0.65, green: 0.20, blue: 0.10, alpha: 1)
                type     = NSColor(red: 0.10, green: 0.35, blue: 0.65, alpha: 1)
                string   = NSColor(red: 0.10, green: 0.50, blue: 0.20, alpha: 1)
                number   = NSColor(red: 0.55, green: 0.30, blue: 0.05, alpha: 1)
                comment  = NSColor(white: 0.45, alpha: 1)
                function = NSColor(red: 0.55, green: 0.40, blue: 0.05, alpha: 1)
                symbol   = NSColor(red: 0.45, green: 0.10, blue: 0.55, alpha: 1)
            }
        }

        func color(for token: Token) -> NSColor? {
            switch token {
            case .keyword:  return keyword
            case .type:     return type
            case .string:   return string
            case .number:   return number
            case .comment:  return comment
            case .function: return function
            case .symbol:   return symbol
            }
        }
    }

    // MARK: - Language detection + tokenizers

    private static func languageIdentifier(from fenceLine: String) -> String {
        // Strip leading backticks/tildes
        var s = fenceLine
        while let first = s.first, first == "`" || first == "~" { s.removeFirst() }
        let lang = s.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)?.lowercased() ?? ""
        return languageAliases[lang] ?? lang
    }

    /// Common short names for the languages above.
    private static let languageAliases: [String: String] = [
        "js": "javascript", "jsx": "javascript", "mjs": "javascript", "node": "javascript",
        "ts": "typescript", "tsx": "typescript",
        "py": "python", "python3": "python",
        "sh": "bash", "zsh": "bash", "shell": "bash", "console": "bash",
        "yml": "yaml", "rs": "rust", "golang": "go",
        "htm": "html", "xml": "html", "jsonc": "json",
    ]

    private static func compile(_ pattern: String, options: NSRegularExpression.Options = []) -> NSRegularExpression {
        try! NSRegularExpression(pattern: pattern, options: options)
    }

    private static let stringRule = Rule(
        token: .string,
        regex: compile(#""([^"\\]|\\.)*"|'([^'\\]|\\.)*'"#)
    )
    private static let numberRule = Rule(
        token: .number,
        regex: compile(#"\b\d+(?:\.\d+)?\b"#)
    )
    private static let lineCommentSlashRule = Rule(
        token: .comment,
        regex: compile(#"//[^\n]*"#)
    )
    private static let blockCommentRule = Rule(
        token: .comment,
        regex: compile(#"/\*[\s\S]*?\*/"#)
    )
    private static let hashCommentRule = Rule(
        token: .comment,
        regex: compile(#"#[^\n]*"#)
    )
    private static let dashCommentRule = Rule(
        token: .comment,
        regex: compile(#"--[^\n]*"#)
    )

    private static func keywordRule(_ words: [String]) -> Rule {
        let escaped = words.map { NSRegularExpression.escapedPattern(for: $0) }
        return Rule(token: .keyword,
                    regex: compile("\\b(?:\(escaped.joined(separator: "|")))\\b"))
    }

    /// Per-language token-rule sets. Order matters: comments and strings
    /// come first so keyword/number rules don't paint inside them.
    private static let tokenizers: [String: Tokenizer] = [

        "swift": Tokenizer(rules: [
            blockCommentRule, lineCommentSlashRule, stringRule,
            keywordRule(["import", "func", "let", "var", "if", "else", "guard", "return",
                         "for", "while", "switch", "case", "default", "break", "continue",
                         "do", "try", "catch", "throw", "throws", "rethrows", "async", "await",
                         "struct", "class", "enum", "protocol", "extension", "init", "deinit",
                         "self", "Self", "super", "true", "false", "nil",
                         "public", "private", "internal", "fileprivate", "open", "static",
                         "final", "lazy", "weak", "unowned", "mutating", "nonmutating",
                         "in", "as", "is", "where", "typealias", "associatedtype"]),
            Rule(token: .type, regex: compile(#"\b[A-Z][A-Za-z0-9_]*\b"#)),
            Rule(token: .function, regex: compile(#"\b[a-z_][A-Za-z0-9_]*(?=\()"#)),
            numberRule
        ]),

        "python": Tokenizer(rules: [
            stringRule, hashCommentRule,
            keywordRule(["def", "class", "if", "elif", "else", "while", "for", "in", "not",
                         "and", "or", "is", "None", "True", "False", "return", "yield",
                         "import", "from", "as", "with", "try", "except", "finally", "raise",
                         "lambda", "pass", "break", "continue", "global", "nonlocal",
                         "async", "await", "self", "cls"]),
            Rule(token: .function, regex: compile(#"\b[a-z_][A-Za-z0-9_]*(?=\()"#)),
            numberRule
        ]),

        "javascript": Tokenizer(rules: [
            blockCommentRule, lineCommentSlashRule, stringRule,
            keywordRule(["function", "const", "let", "var", "if", "else", "switch", "case",
                         "default", "for", "while", "do", "break", "continue", "return",
                         "throw", "try", "catch", "finally", "new", "delete", "typeof",
                         "instanceof", "in", "of", "this", "super", "class", "extends",
                         "import", "export", "from", "as", "async", "await", "yield",
                         "true", "false", "null", "undefined"]),
            Rule(token: .function, regex: compile(#"\b[a-z_$][A-Za-z0-9_$]*(?=\()"#)),
            numberRule
        ]),

        "typescript": Tokenizer(rules: [
            blockCommentRule, lineCommentSlashRule, stringRule,
            keywordRule(["function", "const", "let", "var", "if", "else", "switch", "case",
                         "default", "for", "while", "do", "break", "continue", "return",
                         "throw", "try", "catch", "finally", "new", "delete", "typeof",
                         "instanceof", "in", "of", "this", "super", "class", "extends",
                         "implements", "interface", "type", "enum", "namespace", "module",
                         "import", "export", "from", "as", "async", "await", "yield",
                         "public", "private", "protected", "readonly", "abstract", "static",
                         "true", "false", "null", "undefined", "any", "void", "never", "unknown"]),
            Rule(token: .type, regex: compile(#"\b[A-Z][A-Za-z0-9_]*\b"#)),
            Rule(token: .function, regex: compile(#"\b[a-z_$][A-Za-z0-9_$]*(?=\()"#)),
            numberRule
        ]),

        "rust": Tokenizer(rules: [
            blockCommentRule, lineCommentSlashRule, stringRule,
            keywordRule(["fn", "let", "mut", "const", "static", "if", "else", "match", "while",
                         "for", "loop", "in", "break", "continue", "return", "as", "use", "mod",
                         "pub", "crate", "extern", "unsafe", "async", "await", "move",
                         "struct", "enum", "trait", "impl", "type", "where", "self", "Self",
                         "ref", "true", "false", "Some", "None", "Ok", "Err"]),
            Rule(token: .type, regex: compile(#"\b[A-Z][A-Za-z0-9_]*\b"#)),
            Rule(token: .function, regex: compile(#"\b[a-z_][A-Za-z0-9_]*(?=\()"#)),
            numberRule
        ]),

        "go": Tokenizer(rules: [
            blockCommentRule, lineCommentSlashRule, stringRule,
            keywordRule(["package", "import", "func", "var", "const", "type", "struct",
                         "interface", "map", "chan", "if", "else", "switch", "case", "default",
                         "for", "range", "break", "continue", "return", "go", "defer", "select",
                         "fallthrough", "true", "false", "nil"]),
            Rule(token: .type, regex: compile(#"\b[A-Z][A-Za-z0-9_]*\b"#)),
            Rule(token: .function, regex: compile(#"\b[a-z_][A-Za-z0-9_]*(?=\()"#)),
            numberRule
        ]),

        "bash": Tokenizer(rules: [
            stringRule, hashCommentRule,
            keywordRule(["if", "then", "else", "elif", "fi", "case", "esac", "for", "in",
                         "do", "done", "while", "until", "function", "return", "break",
                         "continue", "echo", "export", "local", "readonly", "set", "unset",
                         "true", "false"]),
            Rule(token: .symbol, regex: compile(#"\$\{?[A-Za-z_][A-Za-z0-9_]*\}?"#)),
            numberRule
        ]),

        "json": Tokenizer(rules: [
            stringRule,
            keywordRule(["true", "false", "null"]),
            numberRule
        ]),

        "yaml": Tokenizer(rules: [
            stringRule, hashCommentRule,
            keywordRule(["true", "false", "null", "yes", "no", "on", "off"]),
            Rule(token: .symbol, regex: compile(#"^[ \t]*[A-Za-z_][\w-]*(?=:)"#, options: [.anchorsMatchLines])),
            numberRule
        ]),

        "sql": Tokenizer(rules: [
            stringRule, dashCommentRule, blockCommentRule,
            keywordRule(["SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
                         "SET", "DELETE", "JOIN", "INNER", "LEFT", "RIGHT", "FULL", "OUTER",
                         "ON", "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET",
                         "CREATE", "TABLE", "DROP", "ALTER", "ADD", "COLUMN", "PRIMARY",
                         "KEY", "FOREIGN", "REFERENCES", "INDEX", "VIEW",
                         "AS", "AND", "OR", "NOT", "IN", "EXISTS", "BETWEEN", "LIKE",
                         "IS", "NULL", "TRUE", "FALSE", "DISTINCT", "UNION", "ALL"]),
            keywordRule(["select", "from", "where", "insert", "into", "values", "update",
                         "set", "delete", "join", "inner", "left", "right", "full", "outer",
                         "on", "group", "by", "order", "having", "limit", "offset",
                         "create", "table", "drop", "alter", "add", "column", "primary",
                         "key", "foreign", "references", "index", "view",
                         "as", "and", "or", "not", "in", "exists", "between", "like",
                         "is", "null", "true", "false", "distinct", "union", "all"]),
            numberRule
        ]),

        "html": Tokenizer(rules: [
            stringRule,
            Rule(token: .keyword, regex: compile(#"</?[A-Za-z][\w-]*"#)),
            Rule(token: .type, regex: compile(#"\b[a-z-]+(?==)"#)),
            Rule(token: .comment, regex: compile(#"<!--[\s\S]*?-->"#)),
        ]),

        "css": Tokenizer(rules: [
            blockCommentRule, stringRule,
            Rule(token: .type, regex: compile(#"\b[a-z-]+(?=\s*:)"#)),
            Rule(token: .keyword, regex: compile(#"#[A-Fa-f0-9]{3,8}\b"#)),
            numberRule
        ]),
    ]

    // MARK: - Helpers

    private static func rangesIntersect(_ a: NSRange, _ b: NSRange) -> Bool {
        return a.location < NSMaxRange(b) && b.location < NSMaxRange(a)
    }
}
