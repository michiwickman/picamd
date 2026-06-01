import Foundation

/// Minimal MCP-over-stdio server. The Model Context Protocol layers
/// on top of JSON-RPC 2.0 — for our purposes we need to handle:
///   - `initialize`           : capability handshake
///   - `tools/list`           : enumerate available tools
///   - `tools/call`           : run a tool by name with args
///   - `notifications/*`      : fire-and-forget messages from the client
///
/// The protocol assumes line-delimited JSON when running over stdio:
/// each message is a single JSON object on one line, terminated by `\n`.
/// (For TCP/SSE transports MCP uses Content-Length framing; we'll add
/// that when/if we expose a non-stdio transport.)
final class MCPServer {
    private let registry: ToolRegistry

    init() {
        self.registry = ToolRegistry()
        self.registry.installDefaults()
    }

    /// Run the read/dispatch/write loop on stdin/stdout. Returns when
    /// stdin reaches EOF (i.e. Claude Code closes the connection).
    func run() {
        let stdin = FileHandle.standardInput
        let stdout = FileHandle.standardOutput
        var buffer = Data()

        while true {
            let chunk = stdin.availableData
            if chunk.isEmpty { break }   // EOF — parent closed the pipe
            buffer.append(chunk)

            // Process complete `\n`-terminated frames.
            while let nlIndex = buffer.firstIndex(of: 0x0A) {
                let frame = buffer.prefix(upTo: nlIndex)
                buffer.removeSubrange(0...nlIndex)
                guard !frame.isEmpty else { continue }
                handle(frameData: frame, write: { data in
                    stdout.write(data)
                    stdout.write(Data([0x0A]))   // newline terminator
                })
            }
        }
    }

    // MARK: - Frame handling

    /// Internal (not private) so unit tests can drive the server
    /// by feeding raw JSON frames without a real stdin/stdout loop.
    func handle(frameData: Data, write: (Data) -> Void) {
        guard let request = try? JSONSerialization.jsonObject(with: frameData) as? [String: Any] else {
            // F12: JSON-RPC 2.0 §5 requires a parse-error response even when
            // the id cannot be extracted. Use explicit NSNull so the "id" key
            // is present in the response with a JSON null value, rather than
            // being omitted — per spec, id MUST be null on parse error.
            sendError(write: write, id: NSNull(), code: -32700, message: "parse error")
            return
        }
        let id = request["id"]
        guard let method = request["method"] as? String else {
            sendError(write: write, id: id, code: -32600, message: "missing method")
            return
        }
        let params = request["params"] as? [String: Any] ?? [:]

        switch method {
        case "initialize":
            sendResult(write: write, id: id, result: handleInitialize(params: params))

        case "notifications/initialized":
            return  // notifications never get a response

        case "tools/list":
            sendResult(write: write, id: id, result: registry.toolsListResult())

        case "tools/call":
            do {
                let result = try registry.invoke(params: params)
                sendResult(write: write, id: id, result: result)
            } catch {
                sendError(write: write, id: id,
                           code: -32000,
                           message: error.localizedDescription)
            }

        case "ping":
            sendResult(write: write, id: id, result: [:])

        default:
            sendError(write: write, id: id, code: -32601,
                       message: "method not found: \(method)")
        }
    }

    private func handleInitialize(params: [String: Any]) -> [String: Any] {
        return [
            "protocolVersion": "2024-11-05",
            "capabilities": [
                "tools": ["listChanged": false],
            ],
            "serverInfo": [
                "name":    "picamd-mcp",
                "version": "0.7.0",
            ],
        ]
    }

    // MARK: - JSON-RPC writes

    private func sendResult(write: (Data) -> Void, id: Any?, result: Any) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "result": result,
        ]
        if let id = id { response["id"] = id }
        sendJSON(write: write, response)
    }

    private func sendError(write: (Data) -> Void, id: Any?, code: Int, message: String) {
        var response: [String: Any] = [
            "jsonrpc": "2.0",
            "error": ["code": code, "message": message],
        ]
        if let id = id { response["id"] = id }
        sendJSON(write: write, response)
    }

    private func sendJSON(write: (Data) -> Void, _ object: [String: Any]) {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object) else {
            // Last-ditch: log to stderr so users can see what went wrong.
            FileHandle.standardError.write(
                "picamd-mcp: failed to serialize response\n".data(using: .utf8) ?? Data()
            )
            return
        }
        write(data)
    }
}
