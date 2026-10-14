#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("HTTP input compatibility diagnostics", .timeLimit(.minutes(1)))
    struct HTTPClientCompatibilityTests {
        @Test("Legacy SSE elicitation is explained without advertising support or breaking tool calls")
        func legacyRejection() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                guard request.httpMethod == "POST" else { return .init(status: 405, body: Data()) }
                await ledger.append(body)
                if body[httpField: "error"] != nil {
                    return .init(status: 202, body: Data())
                }
                switch body[httpField: "method"]?.stringValue {
                case "server/discover": return .init(status: 404, body: Data())
                case "initialize":
                    #expect(body[httpField: "params"]?[httpField: "capabilities"]?[httpField: "elicitation"] == nil)
                    return try .json(httpResult(body, [
                        "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "fixture", "version": "1"],
                    ]))
                case "notifications/initialized": return .init(status: 202, body: Data())
                case "tools/call":
                    let input: Value = [
                        "jsonrpc": "2.0", "id": "legacy-form", "method": "elicitation/create",
                        "params": ["message": "Confirm", "requestedSchema": [
                            "type": "object", "properties": ["confirmed": ["type": "boolean"]],
                        ]],
                    ]
                    let result = httpResult(body, ["content": [["type": "text", "text": "completed"]]])
                    let messages = body[httpField: "params"]?[httpField: "name"] == "form" ? [input, result] : [result]
                    let frames = try messages.map {
                        try "data: \(String(decoding: JSONEncoder().encode($0), as: UTF8.self))\n\n"
                    }.joined()
                    return .init(headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8))
                default: throw HTTPClientError.invalidResponse
                }
            }
            let client = HTTPClient(name: "fixture", version: "1", supportsForms: true)
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let call = try await client.callTool(name: "form") { _ in
                Issue.record("An unsupported callback must not collect input")
                return .init(action: .cancel)
            }
            #expect(try await call.value.content == [.text("completed")])
            let messages = await ledger.requests
            let reply = try #require(messages.first { $0[httpField: "id"] == "legacy-form" })
            #expect(reply[httpField: "error"]?[httpField: "code"] == -32601)
            let explanation = try #require(reply[httpField: "error"]?[httpField: "message"]?.stringValue)
            #expect(explanation.contains(HTTPClient.formElicitationProtocolVersion))
            #expect(explanation.contains("input_required"))
            #expect(reply[httpField: "result"] == nil)
            let next = try await client.callTool(name: "echo")
            #expect(try await next.value.content == [.text("completed")])
            await client.disconnect()
        }

        enum Failure: CaseIterable {
            case url, method, context
        }

        @Test("Unsupported capabilities are distinct from missing call context", arguments: Failure.allCases)
        func inputFailure(_ failure: Failure) async throws {
            let fixture = HTTPClientFixture { _, body in
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                let method = failure == .method ? "sampling/createMessage" : "elicitation/create"
                let params: Value = failure == .url
                    ? ["mode": "url", "message": "Open", "url": "https://example.invalid"]
                    : ["message": "Confirm", "requestedSchema": ["type": "object", "properties": [:]]]
                return try .json(httpResult(body, [
                    "resultType": "input_required", "inputRequests": ["input": ["method": .string(method), "params": params]],
                ]))
            }
            let client = HTTPClient(name: "fixture", version: "1", supportsForms: true)
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let call = try await client.callTool(name: "unsupported")
            do {
                _ = try await call.value
                Issue.record("Expected an input compatibility error")
            } catch let error as HTTPClientError {
                switch (failure, error) {
                case (.url, .unsupportedURLInput), (.method, .unsupportedInputMethod), (.context, .inputUnavailable): break
                default: Issue.record("Incorrect input compatibility error: \(error)")
                }
            }
            await client.disconnect()
        }
    }
#endif
