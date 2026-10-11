#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("2026 HTTP client", .timeLimit(.minutes(1)))
    struct HTTPClientTests {
        @Test("MRTR retains state, arguments, false answers and changes the retry ID")
        func formRoundTrip() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                await ledger.append(body)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fixture")
                #expect(request.value(forHTTPHeaderField: "MCP-Protocol-Version") == "2026-07-28")
                #expect(request.value(forHTTPHeaderField: "Mcp-Method") == body[httpField: "method"]?.stringValue)
                #expect(body[httpField: "params"]?[httpField: "_meta"]?[httpField: HTTPProtocol.versionKey] ==
                    "2026-07-28")
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                #expect(request.value(forHTTPHeaderField: "Mcp-Name") == "confirm")
                if body[httpField: "params"]?[httpField: "inputResponses"] == nil {
                    return try .json(httpResult(
                        body,
                        httpInput
                    ))
                }
                return try .json(httpResult(
                    body,
                    ["resultType": "complete", "content": [["type": "text", "text": "done"]]]
                ))
            }
            let client = HTTPClient(name: "tests", version: "1", supportsForms: true)
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session) { request in
                var request = request
                request.setValue("Bearer fixture", forHTTPHeaderField: "Authorization")
                return request
            }
            let context = try await client.callTool(name: "confirm", arguments: ["number": 7]) { form in
                #expect(form.message == "Confirm")
                return .init(action: .accept, content: ["confirmed": false, "note": "data:text/plain;base64,bm90ZQ=="])
            }
            #expect(try await context.value.content == [.text("done")])
            let calls = await ledger.requests.filter { $0[httpField: "method"] == "tools/call" }
            #expect(calls.count == 2)
            #expect(calls[0][httpField: "id"] != calls[1][httpField: "id"])
            let retry = try #require(calls[1][httpField: "params"])
            #expect(retry[httpField: "requestState"] == "data:text/plain;base64,b3BhcXVl")
            #expect(
                retry[httpField: "inputResponses"]?[httpField: "confirmation"]?[httpField: "content"]?[
                    httpField: "note"
                ] ==
                    "data:text/plain;base64,bm90ZQ=="
            )
            #expect(retry[httpField: "arguments"] == ["number": 7])
            #expect(retry[httpField: "inputResponses"]?[httpField: "confirmation"]?[httpField: "content"] == [
                "confirmed": false,
                "note": "data:text/plain;base64,bm90ZQ=="
            ])
            await client.disconnect()
        }

        @Test("Legacy probe failure falls back without advertising elicitation")
        func legacyFallback() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                guard request.httpMethod == "POST" else { return .init(status: 405, body: Data()) }
                await ledger.append(body)
                switch body[httpField: "method"]?.stringValue {
                case "server/discover": return .init(status: 400, body: Data())
                case "initialize":
                    #expect(body[httpField: "params"]?[httpField: "capabilities"]?[httpField: "elicitation"] == nil)
                    var reply = try HTTPClientFixture.Reply.json(httpResult(
                        body,
                        [
                            "protocolVersion": "2025-11-25",
                            "capabilities": ["tools": [:]],
                            "serverInfo": ["name": "old", "version": "1"]
                        ]
                    ))
                    reply.headers["Mcp-Session-Id"] = "legacy"
                    return reply
                case "notifications/initialized": return .init(status: 202, body: Data())
                case "tools/call": return try .json(httpResult(
                        body,
                        ["content": [["type": "text", "text": "old works"]]]
                    ))
                default: throw HTTPClientError.invalidResponse
                }
            }
            let client = HTTPClient(name: "tests", version: "1", supportsForms: true)
            let info = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            #expect(info.protocolVersion == "2025-11-25")
            let call = try await client.callTool(name: "echo")
            #expect(try await call.value.content == [.text("old works")])
            await client.disconnect()
        }

        @Test("Modern errors and authentication failures never downgrade", arguments: [
            (400, "future"), (401, "2025-11-25"), (403, "2025-11-25"),
            (429, "2025-11-25"), (500, "2025-11-25")
        ])
        func noDowngrade(status: Int, supported: String) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return try .json([
                    "jsonrpc": "2.0",
                    "id": body[httpField: "id"] ?? .null,
                    "error": ["code": -32022, "message": "Unsupported", "data": ["supported": [.string(supported)]]]
                ], status: status)
            }
            let client = HTTPClient(name: "tests", version: "1")
            await #expect(throws: HTTPClientError.self) { try await client.connect(
                endpoint: fixture.endpoint,
                session: fixture.session
            ) }
            #expect(await ledger.requests.count == 1)
            await client.disconnect()
        }

        @Test("An oversized response chunk fails before entering the consumer queue")
        func boundedResponseQueue() async throws {
            let fixture = HTTPClientFixture { _, _ in
                .init(body: Data(repeating: 32, count: 2048))
            }
            let stream = HTTPResponseStream(
                request: URLRequest(url: fixture.endpoint), session: fixture.session, maximumBufferedBytes: 1024
            )
            stream.task.resume()
            defer { stream.task.cancel() }
            var iterator = stream.events.makeAsyncIterator()
            guard case .response = try await iterator.next() else {
                Issue.record("Missing response headers")
                return
            }
            await #expect(throws: HTTPClientError.self) { try await iterator.next() }
        }

        @Test("SSE progress and final content are processed within the originating request")
        func sseResponse() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                let notification: Value = [
                    "jsonrpc": "2.0",
                    "method": "notifications/progress",
                    "params": ["progressToken": "p", "progress": 1]
                ]
                let result = httpResult(
                    body,
                    ["content": [], "structuredContent": ["ok": true], "resultType": "complete"]
                )
                let frames = try [notification, result]
                    .map { try "data: \(String(decoding: JSONEncoder().encode($0), as: UTF8.self))\r\n\r\n" }.joined()
                return .init(headers: ["Content-Type": "text/event-stream"], body: Data(frames.utf8))
            }
            let client = HTTPClient(name: "tests", version: "1")
            await client
                .onNotification(ProgressNotification.self) { message in
                    try await ledger.append(HTTPProtocol.value(message))
                }
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let call = try await client.callTool(name: "progress")
            #expect(try await call.value.structuredContent == ["ok": true])
            #expect(await ledger.requests.count == 1)
            await client.disconnect()
        }

        @Test("A form wait permits unrelated calls and cancels without retry", arguments: [false, true])
        func cancelWaitingForm(disconnect: Bool) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                if body[httpField: "params"]?[httpField: "name"] == "wait" {
                    return try .json(httpResult(
                        body,
                        httpInput
                    ))
                }
                return try .json(httpResult(body, ["content": [["type": "text", "text": "parallel"]]]))
            }
            let client = HTTPClient(name: "tests", version: "1", supportsForms: true)
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let (entered, signal) = AsyncStream<Void>.makeStream()
            let (answers, keepAlive) = AsyncStream<Void>.makeStream()
            defer { keepAlive.finish() }
            let waiting = try await client.callTool(name: "wait") { _ in
                signal.yield(())
                for await _ in answers {
                    break
                }
                try Task.checkCancellation()
                return .init(action: .accept)
            }
            var iterator = entered.makeAsyncIterator()
            _ = await iterator.next()
            let parallel = try await client.callTool(name: "echo")
            #expect(try await parallel.value.content == [.text("parallel")])
            if disconnect {
                await client.disconnect()
            } else {
                try await client.cancelRequest(waiting.requestID)
            }
            await #expect(throws: CancellationError.self) { try await waiting.value }
            #expect(await ledger.requests.filter { $0[httpField: "params"]?[httpField: "name"] == "wait" }.count == 1)
            await client.disconnect()
        }

        @Test("State-only retries are bounded and cannot leak state into another call")
        func boundedRetries() async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                if body[httpField: "params"]?[httpField: "name"] == "loop" {
                    return try .json(httpResult(body, ["resultType": "input_required", "requestState": "state-only"]))
                }
                #expect(body[httpField: "params"]?[httpField: "requestState"] == nil)
                return try .json(httpResult(body, ["content": []]))
            }
            let client = HTTPClient(name: "tests", version: "1", maximumInputRounds: 2)
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let loop = try await client.callTool(name: "loop")
            await #expect(throws: HTTPClientError.self) { try await loop.value }
            let ordinary = try await client.callTool(name: "echo")
            _ = try await ordinary.value
            #expect(await ledger.requests.filter { $0[httpField: "params"]?[httpField: "name"] == "loop" }.count == 2)
            await client.disconnect()
        }

        @Test("Header encoding preserves Unicode and prevents control character injection")
        func headers() throws {
            for value in ["\r\nInjected: yes", "中文", " padded ", "=?base64?literal?="] {
                #expect(HTTPRoutingHeaders.encode(value) == "=?base64?\(Data(value.utf8).base64EncodedString())?=")
            }
            var request = try URLRequest(url: #require(URL(string: "https://fixture.invalid")))
            try HTTPRoutingHeaders.apply(
                method: "tools/call",
                parameters: ["name": "echo", "arguments": ["nested": ["region": "east"]]],
                schema: [
                    "type": "object",
                    "properties": ["nested": [
                        "type": "object",
                        "properties": ["region": ["type": "string", "x-mcp-header": "Region"]]
                    ]]
                ],
                to: &request
            )
            #expect(request.value(forHTTPHeaderField: "Mcp-Param-Region") == "east")
        }

        @Test("Invalid header annotations exclude only the malformed tool")
        func invalidToolHeaders() async throws {
            let fixture = HTTPClientFixture { _, body in
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                return try .json(httpResult(body, ["tools": [
                    [
                        "name": "valid",
                        "inputSchema": [
                            "type": "object",
                            "properties": ["region": ["type": "string", "x-mcp-header": "Region"]]
                        ]
                    ],
                    [
                        "name": "invalid",
                        "inputSchema": [
                            "type": "object",
                            "properties": ["region": ["type": "number", "x-mcp-header": "Region"]]
                        ]
                    ]
                ]]))
            }
            let client = HTTPClient(name: "tests", version: "1")
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session)
            let request = try await client.send(ListTools.request(.init()))
            #expect(try await request.value.tools.map(\.name) == ["valid"])
            await client.disconnect()
        }
    }
#endif
