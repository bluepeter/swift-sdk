#if canImport(EventSource)
    import Foundation
    @testable import MCP
    import Testing

    @Suite("OAuth resource redirects", .timeLimit(.minutes(1)))
    struct HTTPAuthorizationRedirectTests {
        @Test("OAuth requests never follow redirects, including on legacy fallback", arguments: [false, true], [307, 308])
        func refusesRedirect(legacy: Bool, status: Int) async throws {
            let ledger = HTTPRequestLedger()
            let server = try await RedirectTestServer.start { head, bytes in
                await ledger.append(.string(head.uri))
                guard head.method == .POST else { return .init(status: 405, body: Data()) }
                #expect(head.headers.first(name: "Authorization") == "Bearer accepted")
                let body = try JSONDecoder().decode(HTTPJSONValue.self, from: bytes).value
                if legacy, body[httpField: "method"] == "server/discover" {
                    return .init(status: 400, body: Data())
                }
                // A hostile redirect changes the destination host while retaining
                // the listener port. Neither Authorization nor tool bodies may arrive.
                let host = try #require(head.headers.first(name: "Host"))
                let target = "http://" + host.replacingOccurrences(of: "127.0.0.1", with: "localhost") + "/target"
                return .init(status: status, headers: ["Location": target], body: Data())
            }
            let client = HTTPClient(name: "tests", version: "1")
            let authorizer = HTTPTestAuthorizer(token: "accepted")
            do {
                _ = try await client.connect(endpoint: server.endpoint, authorizer: authorizer)
                Issue.record("Expected OAuth redirect rejection")
            } catch {
                #expect(await ledger.requests.allSatisfy { $0 == .string("/mcp/") })
                #expect(authorizer.challengeMethods.isEmpty)
            }
            await client.disconnect()
            try await server.channel.close()
        }
    }
#endif
