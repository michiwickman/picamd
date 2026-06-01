import XCTest

// MARK: - MCPServer frame-level tests (GAP-08)
//
// These tests drive MCPServer.handle(frameData:write:) directly via an
// in-memory capture closure — no real stdin/stdout loop needed.
// handle() was made `internal` (was `private`) to enable this.

final class MCPServerTests: XCTestCase {

    // Helper: send one JSON-RPC frame and return the parsed response.
    private func send(
        _ object: [String: Any],
        to server: MCPServer
    ) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object)
        var captured = Data()
        server.handle(frameData: data) { responseData in
            captured = responseData
        }
        guard !captured.isEmpty else {
            // Notifications (no id) produce no response — return empty dict.
            return [:]
        }
        guard let parsed = try? JSONSerialization.jsonObject(with: captured) as? [String: Any] else {
            XCTFail("Response is not valid JSON: \(String(data: captured, encoding: .utf8) ?? "<binary>")")
            return [:]
        }
        return parsed
    }

    // Helper: craft a malformed-JSON frame.
    private func malformedFrame() -> Data {
        return "{not valid json".data(using: .utf8)!
    }

    // MARK: - initialize handshake

    func testInitializeReturnsProtocolVersionAndServerName() throws {
        let server = MCPServer()
        let response = try send([
            "jsonrpc": "2.0",
            "id": 1,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": ["name": "test-client", "version": "0.0.1"],
            ],
        ], to: server)

        let result = try XCTUnwrap(response["result"] as? [String: Any],
                                   "initialize must return a result object")
        XCTAssertEqual(result["protocolVersion"] as? String, "2024-11-05",
                       "protocolVersion must match MCP spec value")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, "picamd-mcp",
                       "serverInfo.name must be picamd-mcp")
    }

    // MARK: - unknown method → -32601

    func testUnknownMethodReturnsMethodNotFound() throws {
        let server = MCPServer()
        let response = try send([
            "jsonrpc": "2.0",
            "id": 2,
            "method": "no_such_method",
        ], to: server)

        let error = try XCTUnwrap(response["error"] as? [String: Any],
                                  "unknown method must return an error object")
        XCTAssertEqual(error["code"] as? Int, -32601,
                       "JSON-RPC 'Method not found' code must be -32601")
    }

    // MARK: - malformed JSON → -32700 (F12)

    func testMalformedJSONReturnsParseError() throws {
        let server = MCPServer()
        var captured = Data()
        server.handle(frameData: malformedFrame()) { responseData in
            captured = responseData
        }
        // F12: malformed frames must now produce a response, not silence.
        XCTAssertFalse(captured.isEmpty,
                       "malformed JSON must produce a parse-error response, not silence")
        guard let parsed = try? JSONSerialization.jsonObject(with: captured) as? [String: Any] else {
            XCTFail("parse-error response is not valid JSON")
            return
        }
        let error = try XCTUnwrap(parsed["error"] as? [String: Any])
        XCTAssertEqual(error["code"] as? Int, -32700,
                       "parse-error code must be -32700 per JSON-RPC 2.0 §5")
        // id must be present and null (NSNull serializes as JSON null).
        XCTAssertTrue(parsed.keys.contains("id"),
                      "parse-error response must include the 'id' key (set to null)")
        XCTAssertTrue(parsed["id"] is NSNull,
                      "parse-error response id must be null (NSNull), got \(String(describing: parsed["id"]))")
    }

    // MARK: - missing method field → -32600

    func testMissingMethodFieldReturnsInvalidRequest() throws {
        let server = MCPServer()
        // A valid JSON object but with no "method" key is an invalid request.
        let response = try send([
            "jsonrpc": "2.0",
            "id": 3,
            // deliberately omit "method"
        ], to: server)

        let error = try XCTUnwrap(response["error"] as? [String: Any],
                                  "request with no method must return an error object")
        XCTAssertEqual(error["code"] as? Int, -32600,
                       "JSON-RPC 'Invalid request' code must be -32600")
    }
}
