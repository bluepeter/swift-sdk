#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("HTTP discovery fallback", .timeLimit(.minutes(1)))
    struct HTTPDiscoveryFallbackTests {
        @Test("Transport rejections reach stateless legacy SSE tools regardless of error ID",
              arguments: ["2025-11-25", "2025-06-18"], ["server-error", .null, nil] as [Value?])
        func transportErrorID(version: String, responseID: Value?) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                guard request.httpMethod == "POST" else { return .init(status: 405, body: Data()) }
                await ledger.append(body)
                let method = body[httpField: "method"]?.stringValue
                let accept = request.value(forHTTPHeaderField: "Accept") ?? ""
                #expect(accept.contains("application/json") && accept.contains("text/event-stream"))
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-only")
                #expect(request.value(forHTTPHeaderField: "Mcp-Session-Id") == nil)
                if method == "server/discover" {
                    #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
                    // Captured Kagi/FastMCP rejection before JSON-RPC request dispatch.
                    var response: [String: Value] = [
                        "jsonrpc": "2.0",
                        "error": [
                            "code": -32600,
                            "message": .string("Bad Request: Unsupported protocol version: 2026-07-28. "
                                + "Supported versions: 2024-11-05, 2025-03-26, 2025-06-18, 2025-11-25")
                        ]
                    ]
                    response["id"] = responseID
                    return try .json(.object(response), status: 400)
                }
                #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") ==
                    (method == "initialize" ? "2025-11-25" : version))
                let result: Value
                switch method {
                case "initialize":
                    #expect(body[httpField: "params"]?[httpField: "protocolVersion"] == "2025-11-25")
                    result = [
                        "protocolVersion": .string(version), "capabilities": ["tools": ["listChanged": true]],
                        "serverInfo": ["name": "stateless-fixture", "version": "1"]
                    ]
                case "notifications/initialized": return .init(status: 202, body: Data())
                case "tools/list":
                    result = ["tools": [["name": "echo", "inputSchema": ["type": "object", "properties": [:]]]]]
                case "tools/call": result = ["content": [["type": "text", "text": "completed"]]]
                default: throw HTTPClientError.invalidResponse
                }
                let encoded = try JSONEncoder().encode(httpResult(body, result))
                return .init(
                    headers: ["Content-Type": "text/event-stream"],
                    body: Data("event: message\r\ndata: \(String(decoding: encoded, as: UTF8.self))\r\n\r\n".utf8)
                )
            }
            let client = HTTPClient(name: "tests", version: "1", supportsForms: true)
            do {
                let info = try await client.connect(endpoint: fixture.endpoint, session: fixture.session) { request in
                    var request = request
                    request.setValue("Bearer fixture-only", forHTTPHeaderField: "Authorization")
                    return request
                }
                #expect(info.protocolVersion == version)
                let listing = try await client.send(ListTools.request(.init()))
                #expect(try await listing.value.tools.map(\.name) == ["echo"])
                let call = try await client.callTool(name: "echo")
                #expect(try await call.value.content == [.text(text: "completed", annotations: nil, _meta: nil)])
                #expect(await ledger.requests.compactMap { $0[httpField: "method"]?.stringValue } == [
                    "server/discover", "initialize", "notifications/initialized", "tools/list", "tools/call"
                ])
                await client.disconnect()
            } catch {
                await client.disconnect()
                throw error
            }
        }

        @Test("Modern tool errors preserve HTTP status without fallback or replay")
        func toolErrorKeepsConnectionUsable() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                if body[httpField: "params"]?[httpField: "name"] == "rejected" {
                    return try .json([
                        "jsonrpc": "2.0", "id": "server-error",
                        "error": ["code": -32602, "message": "Invalid parameters"]
                    ], status: 400)
                }
                return try .json(httpResult(body, ["content": [["type": "text", "text": "completed"]]]))
            }
            let client = HTTPClient(name: "tests", version: "1")
            do {
                _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
                let rejected = try await client.callTool(name: "rejected")
                do {
                    _ = try await rejected.value
                    Issue.record("Expected a tool error")
                } catch let HTTPClientError.response(status, code, _, _) {
                    #expect(status == 400)
                    #expect(code == -32602)
                }
                let next = try await client.callTool(name: "echo")
                #expect(try await next.value.content == [.text(text: "completed", annotations: nil, _meta: nil)])
                let requests = await ledger.requests
                #expect(requests.compactMap { $0[httpField: "method"]?.stringValue } == [
                    "server/discover", "tools/call", "tools/call"
                ])
                #expect(requests.compactMap { $0[httpField: "params"]?[httpField: "name"]?.stringValue } == [
                    "rejected", "echo"
                ])
                await client.disconnect()
            } catch {
                await client.disconnect()
                throw error
            }
        }

        @Test("Successful HTTP responses reject unrelated result and error IDs", arguments: [false, true])
        func mismatchedResponseID(errorResponse: Bool) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                let response: Value = errorResponse
                    ? ["jsonrpc": "2.0", "id": "unrelated", "error": ["code": -32601, "message": "Unknown method"]]
                    : ["jsonrpc": "2.0", "id": "unrelated", "result": httpDiscovery]
                return try .json(response)
            }
            let client = HTTPClient(name: "tests", version: "1")
            do {
                _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
                Issue.record("Expected rejection of an unrelated response")
            } catch HTTPClientError.invalidResponse {
                #expect(await ledger.requests.count == 1)
            }
            await client.disconnect()
        }
    }
#endif
