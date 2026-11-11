#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("Legacy HTTP authorization boundaries", .timeLimit(.minutes(1)))
    struct HTTPLegacyAuthorizationTests {
        private enum PreparationFailure: Error { case rejected }

        @Test("Failed or cancelled OAuth preparation cannot send a tool request", arguments: [false, true])
        func preparationStopsRequest(cancelled: Bool) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return try .json(httpResult(body, ["content": []]))
            }
            let authorizer = HTTPTestAuthorizer(token: "stale") {
                if cancelled { throw CancellationError() }
                throw PreparationFailure.rejected
            }
            let transport = HTTPClientTransport(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer
            )
            try await transport.connect()
            do {
                try await transport.send(toolRequest)
                Issue.record("OAuth preparation failure must abort the request")
            } catch {
                if cancelled {
                    #expect(error is CancellationError)
                } else {
                    #expect(error is PreparationFailure)
                }
            }
            #expect(await ledger.requests.isEmpty)
            #expect(authorizer.challengeMethods.isEmpty)
            await transport.disconnect()
        }

        @Test("Cancelled challenge handling remains cancellation and never retries", arguments: [false, true])
        func cancelledChallenge(urlError: Bool) async throws {
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { _, body in
                await ledger.append(body)
                return .init(status: 401, body: Data())
            }
            let error: any Error = urlError ? URLError(.cancelled) : CancellationError()
            let authorizer = HTTPTestAuthorizer(challengeError: error)
            let transport = HTTPClientTransport(
                endpoint: fixture.endpoint, session: fixture.session, authorizer: authorizer
            )
            try await transport.connect()
            do {
                try await transport.send(toolRequest)
                Issue.record("Expected cancellation")
            } catch {
                if urlError {
                    #expect((error as? URLError)?.code == .cancelled)
                } else {
                    #expect(error is CancellationError)
                }
            }
            #expect(await ledger.requests.count == 1)
            #expect(authorizer.challengeMethods == ["tools/call"])
            await transport.disconnect()
        }

        @Test("Legacy notification streams handle OAuth challenges", arguments: [401, 403])
        func notificationChallenge(status: Int) async throws {
            let authorizer = HTTPTestAuthorizer(token: "expired", maxAuthorizationAttempts: 1)
            let ledger = HTTPRequestLedger()
            let fixture = HTTPClientFixture { request, message in
                await ledger.append(.string(request.httpMethod ?? ""))
                if request.httpMethod == "POST" {
                    var reply = try HTTPClientFixture.Reply.json(httpResult(message, [:]))
                    reply.headers["Mcp-Session-Id"] = "legacy"
                    return reply
                }
                guard request.value(forHTTPHeaderField: "Authorization") == "Bearer accepted" else {
                    return .init(
                        status: status, headers: ["WWW-Authenticate": "Bearer scope=\"tools\""], body: Data()
                    )
                }
                let notification = Data(
                    "data: {\"jsonrpc\":\"2.0\",\"method\":\"notifications/tools/list_changed\"}\n\n".utf8
                )
                return .init(headers: ["Content-Type": "text/event-stream"], body: notification)
            }
            let transport = HTTPClientTransport(
                endpoint: fixture.endpoint, session: fixture.session, streaming: true, authorizer: authorizer
            )
            let messages = await transport.receive()
            try await transport.connect()
            try await transport.send(Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\"}".utf8))
            var receivedNotification = false
            for try await data in messages {
                let message = try JSONDecoder().decode(HTTPJSONValue.self, from: data).value
                if message[httpField: "method"] == "notifications/tools/list_changed" {
                    receivedNotification = true
                    break
                }
            }
            await transport.disconnect()
            #expect(receivedNotification)
            let requests = await ledger.requests
            #expect(requests.filter { $0 == .string("GET") }.count >= 2)
            #expect(authorizer.challengeStatuses == [status])
            #expect(authorizer.challengeMethods == [nil])
        }

        private var toolRequest: Data {
            Data("{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"write\"}}".utf8)
        }
    }
#endif
