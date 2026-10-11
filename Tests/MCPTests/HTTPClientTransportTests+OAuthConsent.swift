@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("OAuth client credentials performs discovery and retries after 401", .httpClientTransportSetup)
    func testOAuthClientCredentialsRetryAfter401() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthClientCredentialsRetryAfter401()

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

    @Test("OAuth scope selection falls back to scopes_supported when challenge scope is absent", .httpClientTransportSetup)
    func testOAuthScopeSelectionFallsBackToScopesSupportedWhenChallengeScopeMissing()
        async throws
    {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthScopeSelectionFallsBackToScopesSupported()

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

    @Test("OAuth omits scope parameter when challenge scope and scopes_supported are unavailable", .httpClientTransportSetup)
    func testOAuthScopeSelectionOmitsScopeWhenNoHintsAvailable() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthScopeOmittedWhenNoHints()

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

    @Test("OAuth includes canonical resource in both authorization and token requests", .httpClientTransportSetup)
    func testOAuthResourceParameterIncludedInAuthorizationAndTokenRequests() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthResourceParameterInAuthorizationAndToken()

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

    @Test(
        "OAuth rejects authorization when AS metadata omits code_challenge_methods_supported",
        .httpClientTransportSetup
    )
    func testOAuthRejectsAuthorizationWithoutPKCEMetadata() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationWithoutPKCEMetadata()

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
        "OAuth rejects authorization when AS metadata lacks PKCE S256 support",
        .httpClientTransportSetup
    )
    func testOAuthRejectsAuthorizationWithoutS256PKCE() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationWithoutS256PKCE()

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
        "OAuth rejects authorization response redirect URI mismatch",
        .httpClientTransportSetup
    )
    func testOAuthRejectsAuthorizationResponseRedirectMismatch() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationResponseRedirectMismatch()

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
        "OAuth rejects authorization response state mismatch",
        .httpClientTransportSetup
    )
    func testOAuthRejectsAuthorizationResponseStateMismatch() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage.configureOAuthRejectsAuthorizationResponseStateMismatch()

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
}
#endif
