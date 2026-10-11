@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("OAuth PRM cache is invalidated when resource_metadata URL changes between challenges", .httpClientTransportSetup)
    func testOAuthPRMCacheInvalidatedOnResourceMetadataURLChange() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthPRMCacheInvalidatedOnResourceMetadataURLChange()

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

    @Test(
        "OAuth token request uses PRM resource field as resource indicator",
        .httpClientTransportSetup)
    func testOAuthResourceUsesPRMResourceField() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthResourceUsesPRMResourceField()

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
        "OAuth tries second authorization server when first returns no metadata",
        .httpClientTransportSetup)
    func testOAuthSecondAuthorizationServerTriedWhenFirstFails() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthSecondAuthorizationServerTriedWhenFirstFails()

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
        "OAuth re-registers client after client_secret_expires_at has passed",
        .httpClientTransportSetup)
    func testOAuthReRegistersAfterClientSecretExpiry() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthReRegistersAfterClientSecretExpiry()

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

    @Test(
        "OAuth skips AS metadata with wrong issuer and uses next URL variant",
        .httpClientTransportSetup)
    func testOAuthIssuerMismatchTriesNextURLVariant() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthIssuerMismatchTriesNextURLVariant()

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
        "OAuth proactively refreshes token when within proactive refresh window",
        .httpClientTransportSetup)
    func testOAuthProactiveTokenRefreshWithinWindow() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthProactiveTokenRefreshWithinWindow()

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
}
#endif
