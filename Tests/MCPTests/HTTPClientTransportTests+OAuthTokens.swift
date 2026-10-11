@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("OAuth sends access token only via Authorization header", .httpClientTransportSetup)
    func testOAuthDoesNotSendAccessTokenInBodyOrQuery() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAccessTokenOnlyViaAuthorizationHeader()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: scenario.streaming,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test("OAuth sends Bearer Authorization header on every request in a logical session", .httpClientTransportSetup)
    func testOAuthUsesAuthorizationHeaderForEveryRequestInSession() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAuthorizationHeaderForEveryRequestInSession()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()

        try await transport.send(scenario.messageData)
        let receivedFirst = try await iterator.next()
        #expect(receivedFirst == scenario.expectedResponseData)

        try await transport.send(scenario.secondMessageData!)
        let receivedSecond = try await iterator.next()
        #expect(receivedSecond == scenario.secondExpectedResponseData)

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test("OAuth streaming GET requests use Authorization header and not query token", .httpClientTransportSetup)
    func testOAuthStreamingGETUsesAuthorizationHeaderOnly() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthStreamingGETUsesAuthorizationHeaderOnly()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: scenario.streaming,
            sseInitializationTimeout: scenario.sseInitializationTimeout!,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        await transport.disconnect()
    }

    @Test("OAuth rejects non-Bearer token_type for MCP resource requests", .httpClientTransportSetup)
    func testOAuthRejectsNonBearerTokenType() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsNonBearerTokenType()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()

        do {
            try await transport.send(scenario.messageData)
            Issue.record("Expected send to throw an error")
        } catch let error as MCPError {
            guard case .internalError(let detail) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
            for unexpected in scenario.unexpectedErrorSubstrings {
                #expect(detail?.contains(unexpected) == false)
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test("OAuth token endpoint failures redact raw response body", .httpClientTransportSetup)
    func testOAuthTokenEndpointFailureRedactsResponseBody() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthTokenEndpointFailureRedactsResponseBody()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()

        do {
            try await transport.send(scenario.messageData)
            Issue.record("Expected send to throw an error")
        } catch let error as MCPError {
            guard case .internalError(let detail) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
            for unexpected in scenario.unexpectedErrorSubstrings {
                #expect(detail?.contains(unexpected) == false)
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test("OAuth rejects non-HTTPS token endpoint from AS metadata", .httpClientTransportSetup)
    func testOAuthRejectsNonHTTPSTokenEndpoint() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsNonHTTPSTokenEndpoint()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()

        do {
            try await transport.send(scenario.messageData)
            Issue.record("Expected send to throw an error")
        } catch let error as MCPError {
            guard case .internalError(let detail) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
            for unexpected in scenario.unexpectedErrorSubstrings {
                #expect(detail?.contains(unexpected) == false)
            }
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test(
        "OAuth allows loopback http authorization server endpoints when explicitly enabled",
        .httpClientTransportSetup
    )
    func testOAuthAllowsLoopbackHTTPAuthorizationServerEndpointsWhenEnabled() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthAllowsLoopbackHTTPAuthorizationServerEndpoints()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)
        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }
}
#endif
