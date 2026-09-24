import Foundation

/// Thin bridge to a `pandoc` binary the user has installed themselves
/// (we never bundle it — pandoc is ~150 MB once the LaTeX deps for
/// PDF generation are pulled in, busting the lean-bundle goal).
///
/// Used for PDF / DOCX export. Plain HTML export goes through the
/// in-process `MarkdownToHTML` so it works on any machine.
enum PandocBridge {

    /// Common Homebrew + MacPorts install paths plus the user's
    /// `$PATH`. Pandoc is rarely in `/usr/bin`, so the system-`PATH`
    /// fallback usually misses it on macOS.
    private static let candidatePaths: [String] = [
        "/opt/homebrew/bin/pandoc",     // Apple-silicon brew
        "/usr/local/bin/pandoc",        // Intel brew
        "/opt/local/bin/pandoc",        // MacPorts
    ]

    /// Resolves the `pandoc` binary, preferring user `$PATH` (which
    /// `/usr/bin/env -i …` would lose) and falling back to the well-
    /// known install dirs. Returns `nil` if pandoc isn't installed.
    static func locate() -> URL? {
        // Try `$PATH` lookup first via /usr/bin/env, mirroring how a
        // user would type `pandoc` in their shell.
        if let envURL = whichOnPath("pandoc") {
            return envURL
        }
        for path in candidatePaths where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }

    /// Where TeX and Homebrew tools live. An app launched from Finder
    /// gets PATH=/usr/bin:/bin:/usr/sbin:/sbin — without MacTeX's
    /// /Library/TeX/texbin pandoc reports "pdflatex not found" even
    /// with MacTeX installed.
    private static let extraToolDirectories = [
        "/Library/TeX/texbin", "/opt/homebrew/bin", "/usr/local/bin", "/opt/local/bin",
    ]

    private static func toolEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let current = env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        env["PATH"] = (extraToolDirectories + [current]).joined(separator: ":")
        return env
    }

    /// A Unicode-capable LaTeX engine if one is installed. pandoc's
    /// default, pdflatex, stops at the first `→`, emoji or CJK character.
    private static func pdfEngine() -> String? {
        for engine in ["xelatex", "lualatex"] {
            for dir in extraToolDirectories {
                let path = "\(dir)/\(engine)"
                if FileManager.default.isExecutableFile(atPath: path) { return path }
            }
        }
        return nil
    }

    private static func whichOnPath(_ tool: String) -> URL? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        p.arguments = [tool]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()   // swallow
        do {
            try p.run()
            p.waitUntilExit()
        } catch {
            return nil
        }
        guard p.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let path = path, !path.isEmpty,
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    enum Format {
        case pdf
        case docx
        case epub

        var pandocFlag: String {
            switch self {
            case .pdf:  return "pdf"
            case .docx: return "docx"
            case .epub: return "epub"
            }
        }
        var fileExtension: String { pandocFlag }
        var displayName: String {
            switch self {
            case .pdf:  return "PDF"
            case .docx: return "Microsoft Word (.docx)"
            case .epub: return "EPUB"
            }
        }
    }

    enum ExportError: LocalizedError {
        case pandocNotInstalled
        case nonZeroExit(code: Int32, stderr: String)
        case ioFailure(String)

        var errorDescription: String? {
            switch self {
            case .pandocNotInstalled:
                return "Pandoc is not installed. Install it via Homebrew (`brew install pandoc`) " +
                       "to enable PDF / DOCX / EPUB export. HTML export works without it."
            case .nonZeroExit(let code, let stderr):
                return "pandoc exited with status \(code). " +
                       (stderr.isEmpty ? "" : "Output:\n\(stderr)")
            case .ioFailure(let msg):
                return "I/O error while running pandoc: \(msg)"
            }
        }
    }

    /// Run `pandoc` to convert a Markdown source to the given format,
    /// writing the result to `outputURL`. Throws on missing binary,
    /// non-zero exit, or any IO error.
    ///
    /// We feed the source via stdin (-f markdown -) instead of writing
    /// it to a temp file. That's faster, leaves no debris, and avoids
    /// permission issues with sandboxed temp dirs.
    /// `resourceDirectory` is the document's folder: relative image paths
    /// (`./assets/…`, which PicaMD itself writes) resolve against it.
    /// Without it pandoc ran in `/` and silently dropped every image.
    static func export(markdown source: String,
                        to outputURL: URL,
                        format: Format,
                        resourceDirectory: URL? = nil) throws {
        guard let pandoc = locate() else {
            throw ExportError.pandocNotInstalled
        }

        let process = Process()
        process.executableURL = pandoc
        process.environment = toolEnvironment()
        var args: [String] = [
            "--from", "gfm+tex_math_dollars+pipe_tables+task_lists+strikeout",
            "--to", format.pandocFlag,
            "-o", outputURL.path,
            "--standalone"
        ]
        if let dir = resourceDirectory {
            process.currentDirectoryURL = dir
            args += ["--resource-path", dir.path]
        }
        if format == .pdf {
            if let engine = pdfEngine() {
                args += ["--pdf-engine", engine]
            }
            args += ["--pdf-engine-opt=-interaction=nonstopmode"]
        }
        process.arguments = args

        let stdinPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardError = stderrPipe
        process.standardOutput = FileHandle.nullDevice   // discarded — `-o` writes directly

        // If pandoc exits before reading all of stdin (bad flag, old
        // version), the write must fail with EPIPE instead of SIGPIPE
        // killing the whole app.
        signal(SIGPIPE, SIG_IGN)

        do {
            try process.run()
        } catch {
            throw ExportError.ioFailure(error.localizedDescription)
        }

        // Drain stderr concurrently. LaTeX is chatty: reading it only
        // after exit deadlocked both processes once ~64 KB of warnings
        // filled the pipe.
        let stderrBuffer = StderrBuffer()
        let drained = DispatchGroup()
        let stderrHandle = stderrPipe.fileHandleForReading
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            stderrBuffer.data = stderrHandle.readDataToEndOfFile()
            drained.leave()
        }

        // Feed the source to pandoc's stdin in one go.
        do {
            if let data = source.data(using: .utf8) {
                try stdinPipe.fileHandleForWriting.write(contentsOf: data)
            }
            try stdinPipe.fileHandleForWriting.close()
        } catch {
            NSLog("PicaMD: pandoc stdin write failed: \(error)")
        }

        process.waitUntilExit()
        drained.wait()

        if process.terminationStatus != 0 {
            let stderr = String(data: stderrBuffer.data, encoding: .utf8) ?? ""
            throw ExportError.nonZeroExit(code: process.terminationStatus, stderr: stderr)
        }
    }
}

/// Written once by the stderr reader, read after `drained.wait()`.
private final class StderrBuffer: @unchecked Sendable {
    var data = Data()
}
