#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("HTTP client authorization", .timeLimit(.minutes(1)))
    struct HTTPClientAuthorizationTests {
        @Test("Discovery and tool calls handle authorization challenges without protocol downgrade", arguments: [401, 403])
        func authorizedRequests(status: Int) async throws {
            let authorizer = HTTPTestAuthorizer()
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, body in
                await ledger.append(body)
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer accepted" else {
                    return .init(
                        status: status,
                        headers: ["WWW-Authenticate": "Bearer scope=\"tools\""], body: Data()
                    )
                }
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                return try .json(httpResult(body, ["content": [["type": "text", "text": "completed"]]]))
            }
            let client = HTTPClient(name: "tests", version: "1")
            let info = try await client.connect(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer
            )
            #expect(info.protocolVersion == "2026-07-28")
            authorizer.token = nil
            let call = try await client.callTool(name: "echo", arguments: ["value": 7])
            #expect(try await call.value.content == [.text(text: "completed", annotations: nil, _meta: nil)])
            let requests = await ledger.requests
            #expect(requests.count == 4)
            #expect(requests[0] == requests[1])
            #expect(requests[2] == requests[3])
            #expect(authorizer.challengeMethods == ["server/discover", "tools/call"])
            #expect(authorizer.challengeStatuses == [status, status])
            #expect(authorizer.challengeHeaders.allSatisfy {
                $0.first { $0.key.lowercased() == "www-authenticate" }?.value == "Bearer scope=\"tools\""
            })
            #expect(authorizer.prepareCount == requests.count)
            await client.disconnect()
        }

        @Test("Authorization challenges have a strict retry budget", arguments: [0, 1, 3])
        func boundedRetries(maximum: Int) async throws {
            let ledger = HTTPRequestLedger()
            let authorizer = HTTPTestAuthorizer(maxAuthorizationAttempts: maximum)
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return .init(status: 401, body: Data())
            }
            let client = HTTPClient(name: "tests", version: "1")
            await expectResponse(status: 401) {
                try await client.connect(endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer)
            }
            #expect(await ledger.requests.count == maximum + 1)
            #expect(authorizer.challengeMethods.count == maximum)
            await client.disconnect()
        }

        @Test("A declined challenge is returned without resending")
        func declinedChallenge() async throws {
            let ledger = HTTPRequestLedger()
            let authorizer = HTTPTestAuthorizer(handlesChallenges: false)
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return .init(status: 403, body: Data())
            }
            let client = HTTPClient(name: "tests", version: "1")
            await expectResponse(status: 403) {
                try await client.connect(endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer)
            }
            #expect(await ledger.requests.count == 1)
            #expect(authorizer.challengeMethods == ["server/discover"])
            await client.disconnect()
        }

        @Test("Application errors and server failures never trigger authorization or replay", arguments: [400, 429, 500])
        func failuresAreNotReplayed(status: Int) async throws {
            let ledger = HTTPRequestLedger()
            let authorizer = HTTPTestAuthorizer(token: "accepted")
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                if body[httpField: "method"] == "server/discover" {
                    return try .json(httpResult(body, httpDiscovery))
                }
                return .init(status: status, body: Data())
            }
            let client = HTTPClient(name: "tests", version: "1")
            _ = try await client.connect(endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer)
            let call = try await client.callTool(name: "write")
            await expectResponse(status: status) {
                try await call.value
            }
            #expect(await ledger.requests.count == 2)
            #expect(authorizer.challengeMethods.isEmpty)
            await client.disconnect()
        }

        @Test("OAuth headers are scoped to the configured resource and override custom Authorization")
        func modifierCannotRedirectToken() async throws {
            let ledger = HTTPRequestLedger()
            let authorizer = HTTPTestAuthorizer(token: "accepted")
            let fixture = HTTPClientFixture { request, body in
                await ledger.append(body)
                #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer accepted")
                return try .json(httpResult(body, httpDiscovery))
            }
            let client = HTTPClient(name: "tests", version: "1")
            _ = try await client.connect(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer,
                requestModifier: { request in
                    var request = request
                    request.setValue("Bearer wrong", forHTTPHeaderField: "Authorization")
                    return request
                }
            )
            await client.disconnect()
            await #expect(throws: HTTPClientError.self) {
                try await client.connect(
                    endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer,
                    requestModifier: { request in
                        var request = request
                        request.url = URL(string: "https://other.invalid/mcp")!
                        return request
                    }
                )
            }
            #expect(await ledger.requests.count == 1)
            await client.disconnect()
        }

        @Test("The same authorizer protects legacy fallback and later tool calls")
        func legacyFallback() async throws {
            let authorizer = HTTPTestAuthorizer(maxAuthorizationAttempts: 1)
            let fixture = HTTPClientFixture { request, body in
                guard request.httpMethod == "POST" else { return .init(status: 405, body: Data()) }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer accepted" else {
                    return .init(status: 401, headers: ["WWW-Authenticate": "Bearer"], body: Data())
                }
                switch body[httpField: "method"]?.stringValue {
                case "server/discover": return .init(status: 400, body: Data())
                case "initialize":
                    var reply = try HTTPClientFixture.Reply.json(httpResult(body, [
                        "protocolVersion": "2025-11-25", "capabilities": ["tools": [:]],
                        "serverInfo": ["name": "legacy", "version": "1"]
                    ]))
                    reply.headers["Mcp-Session-Id"] = "legacy"
                    return reply
                case "notifications/initialized": return .init(status: 202, body: Data())
                case "tools/call": return try .json(httpResult(body, [
                    "content": [["type": "text", "text": "legacy completed"]]
                ]))
                default: throw HTTPClientError.invalidResponse
                }
            }
            let client = HTTPClient(name: "tests", version: "1")
            let info = try await client.connect(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer
            )
            #expect(info.protocolVersion == "2025-11-25")
            authorizer.token = nil
            let call = try await client.callTool(name: "echo")
            #expect(try await call.value.content == [.text(text: "legacy completed", annotations: nil, _meta: nil)])
            #expect(authorizer.challengeMethods == ["server/discover", "tools/call"])
            await client.disconnect()
        }

        @Test("Token preparation and challenges also protect subscription streams")
        func subscription() async throws {
            let authorizer = HTTPTestAuthorizer(token: "accepted")
            let ledger = HTTPRequestLedger()
            let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
            let fixture = HTTPClientFixture { request, body in
                await ledger.append(body)
                if body[httpField: "method"] == "server/discover" {
                    authorizer.token = nil
                    return try .json(httpResult(body, httpDiscovery))
                }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer accepted" else {
                    return .init(status: 401, body: Data())
                }
                let acknowledgement: Value = [
                    "jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged",
                    "params": [
                        "_meta": [HTTPProtocol.subscriptionKey: body[httpField: "id"] ?? .null],
                        "notifications": ["toolsListChanged": true]
                    ]
                ]
                let data = try JSONEncoder().encode(acknowledgement)
                var frame = Data("data: ".utf8)
                frame.append(data)
                frame.append(Data("\n\n".utf8))
                return .init(headers: ["Content-Type": "text/event-stream"], body: frame, additionalBody: stream)
            }
            let client = HTTPClient(name: "tests", version: "1")
            await client.onNotification(ToolListChangedNotification.self) { _ in }
            let info = try await client.connect(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer
            )
            #expect(info.supportsToolListChanges)
            #expect(authorizer.challengeMethods == ["subscriptions/listen"])
            #expect(authorizer.prepareCount == 3)
            #expect(await ledger.requests.count == 3)
            await client.disconnect()
            continuation.finish()
        }
        private func expectResponse<Result>(status: Int, operation: () async throws -> Result) async {
            do {
                _ = try await operation()
                Issue.record("Expected an HTTP response failure")
            } catch let HTTPClientError.response(receivedStatus, code, message, data) {
                #expect(receivedStatus == status)
                #expect(code == nil)
                #expect(message == nil)
                #expect(data == nil)
            } catch {
                Issue.record(error)
            }
        }

    }
#endif
