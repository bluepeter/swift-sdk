@preconcurrency import Foundation
import Logging
import Testing

@testable import MCP

#if canImport(FoundationNetworking)
    import FoundationNetworking
#endif

#if swift(>=6.1)
extension HTTPClientTransportTests {
    @Test("HTTP 404 Not Found Error", .httpClientTransportSetup)
    func testHTTPNotFoundError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":3}"#.data(using: .utf8)!

        // Set up the handler BEFORE creating the transport
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("Not Found".utf8))
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        do {
            try await transport.send(messageData)
            Issue.record("Expected send to throw an error for 404")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Endpoint not found") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }

    @Test("HTTP 500 Server Error", .httpClientTransportSetup)
    func testHTTPServerError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":4}"#.data(using: .utf8)!

        // Set up the handler BEFORE creating the transport
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (request: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 500, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("Server Error".utf8))
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        do {
            try await transport.send(messageData)
            Issue.record("Expected send to throw an error for 500")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Server error: 500") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }

    @Test("HTTP 400 Bad Request Error", .httpClientTransportSetup)
    func testHTTPBadRequestError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":40}"#.data(using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (_: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 400, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("Bad Request".utf8))
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        do {
            try await transport.send(messageData)
            Issue.record("Expected send to throw an error for 400")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Bad request") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }

    @Test("HTTP 401 Unauthorized Error Without OAuth", .httpClientTransportSetup)
    func testHTTPUnauthorizedErrorWithoutOAuth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":41}"#.data(using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (_: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint,
                statusCode: 401,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "WWW-Authenticate": "Bearer scope=\"files:read\""
                ])!
            return (response, Data())
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        do {
            try await transport.send(messageData)
            Issue.record("Expected send to throw an error for 401 without OAuth")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Authentication required") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }

    @Test("HTTP 403 Forbidden Error Without OAuth", .httpClientTransportSetup)
    func testHTTPForbiddenErrorWithoutOAuth() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let messageData = #"{"jsonrpc":"2.0","method":"test","id":42}"#.data(using: .utf8)!

        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint] (_: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint,
                statusCode: 403,
                httpVersion: "HTTP/1.1",
                headerFields: [
                    "WWW-Authenticate":
                        "Bearer error=\"insufficient_scope\", scope=\"files:write\""
                ])!
            return (response, Data())
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        do {
            try await transport.send(messageData)
            Issue.record("Expected send to throw an error for 403 without OAuth")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Access forbidden") ?? false)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }

    @Test("Session Expired Error (404 with Session ID)", .httpClientTransportSetup)
    func testSessionExpiredError() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]

        let initialSessionID = "expired-session-xyz"
        let firstMessageData = #"{"jsonrpc":"2.0","method":"initialize","id":1}"#.data(
            using: .utf8)!
        let secondMessageData = #"{"jsonrpc":"2.0","method":"ping","id":2}"#.data(
            using: .utf8)!

        // Set up the first handler BEFORE creating the transport
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, initialSessionID] (request: URLRequest) in
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 200, httpVersion: "HTTP/1.1",
                headerFields: [
                    "Content-Type": "application/json",
                    "MCP-Session-Id": initialSessionID,
                ])!
            return (response, Data())
        }

        let transport = HTTPClientTransport(
            endpoint: testEndpoint,
            configuration: configuration,
            streaming: false,
            logger: nil
        )
        try await transport.connect()

        try await transport.send(firstMessageData)
        #expect(await transport.sessionID == initialSessionID)

        // Set up the second handler for the 404 response
        await MockURLProtocol.requestHandlerStorage.setHandler {
            [testEndpoint, initialSessionID] (request: URLRequest) in
            #expect(request.value(forHTTPHeaderField: "MCP-Session-Id") == initialSessionID)
            let response = HTTPURLResponse(
                url: testEndpoint, statusCode: 404, httpVersion: "HTTP/1.1", headerFields: nil)!
            return (response, Data("Not Found".utf8))
        }

        do {
            try await transport.send(secondMessageData)
            Issue.record("Expected send to throw session expired error")
        } catch let error as MCPError {
            guard case .internalError(let message) = error else {
                Issue.record("Expected MCPError.internalError, got \(error)")
                throw error
            }
            #expect(message?.contains("Session expired") ?? false)
            #expect(await transport.sessionID == nil)
        } catch {
            Issue.record("Expected MCPError, got \(error)")
            throw error
        }
    }
}
#endif
