import Foundation

/// Registry of MCP tool implementations. Each tool exposes a JSON-
/// schema describing its arguments and an `invoke` closure that
/// executes the work and returns a result dictionary.
///
/// The list is built once at startup (see `installDefaults`) and
/// stays static — the user can't add/remove tools at runtime; the
/// surface is what we ship.
final class ToolRegistry {
    /// One MCP tool entry. Spec at https://modelcontextprotocol.io
    struct Tool {
        let name: String
        let description: String
        let inputSchema: [String: Any]
        /// Optional MCP tool annotations (readOnlyHint, destructiveHint,
        /// idempotentHint, …). Serialised under the `annotations` key in
        /// tools/list responses. nil → key omitted from response.
        let annotations: [String: Any]?
        let invoke: ([String: Any]) throws -> Any

        init(
            name: String,
            description: String,
            inputSchema: [String: Any],
            annotations: [String: Any]? = nil,
            invoke: @escaping ([String: Any]) throws -> Any
        ) {
            self.name = name
            self.description = description
            self.inputSchema = inputSchema
            self.annotations = annotations
            self.invoke = invoke
        }
    }

    private var tools: [String: Tool] = [:]

    func register(_ tool: Tool) {
        tools[tool.name] = tool
    }

    // MARK: - tools/list

    /// Build the JSON-RPC result for an MCP `tools/list` request.
    /// Format:
    ///   { "tools": [ { "name", "description", "inputSchema" }, … ] }
    func toolsListResult() -> [String: Any] {
        let serialised: [[String: Any]] = tools.values
            .sorted { $0.name < $1.name }
            .map { tool in
                var entry: [String: Any] = [
                    "name": tool.name,
                    "description": tool.description,
                    "inputSchema": tool.inputSchema,
                ]
                // C8: emit annotations only when present so the response stays
                // compact for unannotated tools.
                if let ann = tool.annotations {
                    entry["annotations"] = ann
                }
                return entry
            }
        return ["tools": serialised]
    }

    // MARK: - tools/call

    /// Dispatch a `tools/call` request to the matching tool. The MCP
    /// `tools/call` payload looks like:
    ///   { "name": "…", "arguments": { … } }
    /// We return the standard MCP content-block shape:
    ///   { "content": [ { "type": "text", "text": "…" } ] }
    func invoke(params: [String: Any]) throws -> [String: Any] {
        guard let name = params["name"] as? String else {
            throw MCPError("missing tool name")
        }
        guard let tool = tools[name] else {
            throw MCPError("unknown tool: \(name)")
        }
        let args = params["arguments"] as? [String: Any] ?? [:]

        let result = try tool.invoke(args)
        // MCP requires every tools/call result to be a content array.
        // We always emit text-content and stringify whatever the tool
        // returned — this keeps the surface simple, and MCP clients
        // can re-parse the JSON if they want structured fields.
        let text: String
        if let s = result as? String {
            text = s
        } else {
            // F11: surface JSON-serialization failures explicitly rather than
            // letting a debug "\(result)" string slip through to the client,
            // which would be invalid JSON in a JSON-RPC context and hard to
            // diagnose. Any tool that returns a non-serializable type has a
            // bug; fail loudly.
            guard JSONSerialization.isValidJSONObject(result) else {
                throw MCPError("tool \(name): result is not JSON-serializable (\(type(of: result)))")
            }
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: result,
                    options: [.prettyPrinted, .sortedKeys]
                )
                guard let s = String(data: data, encoding: .utf8) else {
                    throw MCPError("tool \(name): JSON data is not valid UTF-8")
                }
                text = s
            } catch let serErr as MCPError {
                throw serErr
            } catch {
                throw MCPError("tool \(name): JSON serialization failed: \(error.localizedDescription)")
            }
        }
        return [
            "content": [
                ["type": "text", "text": text],
            ],
        ]
    }
}

// MARK: - Error type

struct MCPError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

// MARK: - Default tool installation

extension ToolRegistry {
    /// Install the full PicaMD tool surface. Implementations live in
    /// `Tools.swift` so the registry stays focused on routing.
    func installDefaults() {
        register(WorkspaceTools.openDocuments())
        register(WorkspaceTools.search())
        register(DocumentTools.metadata())
        register(DocumentTools.outline())
        register(DocumentTools.readLines())
        register(DocumentTools.readSection())
        register(DocumentTools.replaceLines())
        register(DocumentTools.appendText())
    }
}
