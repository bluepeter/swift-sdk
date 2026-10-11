@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("OAuth accessTokenProvider receives SDK discovery context", .httpClientTransportSetup)
    func testOAuthAccessTokenProviderReceivesDiscoveryContext() async throws {
        let (scenario, providerTracker) = await MockURLProtocol.requestHandlerStorage
            .configureOAuthAccessTokenProviderReceivesDiscoveryContext()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        let capturedContext = await providerTracker.capturedContext
        #expect(capturedContext != nil)
        #expect(capturedContext?.statusCode == 401)
        #expect(capturedContext?.endpoint == scenario.testEndpoint)
        #expect(capturedContext?.resource == scenario.testEndpoint)
        #expect(capturedContext?.authorizationServer == URL(string: "https://localhost:8080/auth"))
        #expect(capturedContext?.tokenEndpoint == URL(string: "https://localhost:8080/oauth/token"))
        #expect(capturedContext?.challengedScope == "files:read files:write")
        #expect(Set(capturedContext?.scopesSupported ?? []) == Set(["files:read", "files:write"]))
        #expect(capturedContext?.requestedScopes == Set(["files:read", "files:write"]))

        await MockURLProtocol.verifyCallCounts(scenario.expectedCallCounts)
        await transport.disconnect()
    }

    @Test("OAuth discovery uses resource_metadata URL from WWW-Authenticate when present", .httpClientTransportSetup)
    func testOAuthDiscoveryUsesHeaderResourceMetadataWhenPresent() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthDiscoveryUsesHeaderResourceMetadata()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
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

    @Test("OAuth discovery falls back to well-known metadata URLs in required order", .httpClientTransportSetup)
    func testOAuthDiscoveryFallbackWellKnownOrder() async throws {
        let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
            .configureOAuthDiscoveryFallbackWellKnownOrder()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        let metadataRequests = await tracker.requests
        let fallbackPathMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
        let fallbackRootMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource")!
        #expect(metadataRequests == [fallbackPathMetadataURL, fallbackRootMetadataURL])

        await transport.disconnect()
    }

    @Test("OAuth discovery fails when protected resource metadata is unavailable", .httpClientTransportSetup)
    func testOAuthDiscoveryFailsWhenMetadataUnavailable() async throws {
        let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
            .configureOAuthDiscoveryFailsWhenMetadataUnavailable()

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
            Issue.record("Expected send to fail when PRM discovery fails")
        } catch let error as MCPError {
            guard case .internalError(let detail) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(detail?.contains(scenario.expectedErrorSubstring!) == true)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }

        let protectedResourceMetadataRequests = await tracker.requests
        let fallbackPathMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource/public/mcp")!
        let fallbackRootMetadataURL = URL(
            string: "https://localhost:8080/.well-known/oauth-protected-resource")!
        #expect(protectedResourceMetadataRequests == [fallbackPathMetadataURL, fallbackRootMetadataURL])

        await transport.disconnect()
    }

    @Test("OAuth authorization server metadata discovery tries path issuer URLs in RFC order", .httpClientTransportSetup)
    func testOAuthAuthorizationServerMetadataDiscoveryOrderForPathIssuer() async throws {
        let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
            .configureOAuthASMetadataDiscoveryOrderForPathIssuer()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        let requests = await tracker.requests
        let asMetadataOAuthInsertedURL = URL(
            string: "https://localhost:8080/.well-known/oauth-authorization-server/tenant1")!
        let asMetadataOIDCInsertedURL = URL(
            string: "https://localhost:8080/.well-known/openid-configuration/tenant1")!
        let asMetadataOIDCAppendedURL = URL(
            string: "https://localhost:8080/tenant1/.well-known/openid-configuration")!
        #expect(requests == [asMetadataOAuthInsertedURL, asMetadataOIDCInsertedURL, asMetadataOIDCAppendedURL])

        await transport.disconnect()
    }

    @Test("OAuth authorization server metadata discovery tries root issuer URLs in RFC order", .httpClientTransportSetup)
    func testOAuthAuthorizationServerMetadataDiscoveryOrderForRootIssuer() async throws {
        let (scenario, tracker) = await MockURLProtocol.requestHandlerStorage
            .configureOAuthASMetadataDiscoveryOrderForRootIssuer()

        let transport = HTTPClientTransport(
            endpoint: scenario.testEndpoint,
            configuration: MockResponses.ephemeralConfiguration(),
            streaming: false,
            authorizer: OAuthAuthorizer(configuration: scenario.oauthConfiguration),
            logger: nil
        )

        try await transport.connect()
        try await transport.send(scenario.messageData)

        let stream = await transport.receive()
        var iterator = stream.makeAsyncIterator()
        let received = try await iterator.next()
        #expect(received == scenario.expectedResponseData)

        let requests = await tracker.requests
        let asMetadataOAuthURL = URL(
            string: "https://localhost:8080/.well-known/oauth-authorization-server")!
        let asMetadataOIDCURL = URL(
            string: "https://localhost:8080/.well-known/openid-configuration")!
        #expect(requests == [asMetadataOAuthURL, asMetadataOIDCURL])

        await transport.disconnect()
    }
}
#endif
