@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1) && !canImport(FoundationNetworking)
extension HTTPClientTransportTests {
    @Test("OAuth registration prefers CIMD when AS advertises support", .httpClientTransportSetup)
    func testOAuthRegistrationPrefersCIMDWhenAdvertised() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRegistrationPrefersCIMDWhenAdvertised()

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

    @Test("OAuth pre-registration uses static client credentials without dynamic registration", .httpClientTransportSetup)
    func testOAuthPreRegistrationUsesStaticCredentialsWithoutDynamicRegistration() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthPreRegistrationUsesStaticCredentials()

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

    @Test("OAuth registration falls back to dynamic registration when CIMD is not advertised", .httpClientTransportSetup)
    func testOAuthRegistrationFallsBackToDynamicRegistrationWhenCIMDNotAdvertised() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDNotAdvertised()

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

    @Test("OAuth registration falls back to dynamic registration when CIMD capability is absent", .httpClientTransportSetup)
    func testOAuthRegistrationFallsBackToDynamicRegistrationWhenCIMDCapabilityMissing() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRegistrationFallsBackToDynamicRegistrationCIMDCapabilityMissing()

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

    @Test("OAuth registration surfaces actionable error when no supported mechanism is available", .httpClientTransportSetup)
    func testOAuthRegistrationMissingMechanismReturnsActionableError() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRegistrationMissingMechanismReturnsActionableError()

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

    @Test("OAuth CIMD rejects non-HTTPS client_id URL when AS advertises support", .httpClientTransportSetup)
    func testOAuthCIMDRejectsNonHTTPSClientIDURL() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthCIMDRejectsNonHTTPSClientIDURL()

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

    @Test("OAuth rejects insecure MCP endpoint URL", .httpClientTransportSetup)
    func testOAuthRejectsInsecureMCPEndpointURL() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRejectsInsecureMCPEndpointURL()

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

    @Test("OAuth rejects non-loopback http redirect URI", .httpClientTransportSetup)
    func testOAuthRejectsNonLoopbackHTTPRedirectURI() async throws {
        let scenario = await MockURLProtocol.requestHandlerStorage
            .configureOAuthRejectsNonLoopbackHTTPRedirectURI()

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
